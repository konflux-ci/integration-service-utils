# nudge-migrate — build-nudges-ref to NudgeConfig Migration

One-time migration script that reads `Component.spec.build-nudges-ref` entries
across tenant namespaces and creates or merges `NudgeConfig` CRDs as part of
[ADR-0067](https://github.com/konflux-ci/architecture/pull/354) Phase 2.

## Prerequisites

| Requirement | Details |
|---|---|
| **NudgeConfig CRD** | Must be deployed (STONEINTG-1659/1660) |
| **build-service skip patch** | STONEINTG-1672 must be deployed before live migration |
| **kubectl** | >= 1.24 |
| **jq** | >= 1.6 |
| **bash** | >= 4.0 (associative arrays required) |
| **Cluster access** | Authenticated `kubectl` context with sufficient RBAC |

## Usage

```bash
./nudge-migrate.sh [--dry-run] [NAMESPACE...]
```

### Flags

| Flag | Description |
|---|---|
| `--dry-run` | Print what would change without writing anything |
| `--help` | Show help message |

### Arguments

| Argument | Description |
|---|---|
| `NAMESPACE` | One or more namespaces to process. If omitted, discovers and processes all tenant namespaces. |

### Examples

```bash
# Dry-run all tenant namespaces
./nudge-migrate.sh --dry-run

# Dry-run a specific namespace
./nudge-migrate.sh --dry-run my-tenant-ns

# Migrate specific namespaces
./nudge-migrate.sh my-tenant-ns-1 my-tenant-ns-2

# Migrate all tenant namespaces
./nudge-migrate.sh
```

## How It Works

### Namespace Discovery

When no namespace arguments are provided, the script discovers tenant namespaces
using three label selectors (same as `snapshotgc`):

- `toolchain.dev.openshift.com/type=tenant`
- `konflux.ci/type=user`
- `konflux-ci.dev/type=tenant`

Results are deduplicated and sorted alphabetically.

### Per-Namespace Logic

For each namespace, the script:

1. **Lists all Components** in the namespace
2. **Collects `build-nudges-ref`** entries from each Component
3. **Filters out** invalid entries:
   - Self-nudges (component nudges itself)
   - Dangling references (target component does not exist)
   - Duplicate `(from, to)` pairs
4. **Validates the DAG** — detects cycles using depth-first search
5. **Checks cardinality** — max 256 nudge entries per NudgeConfig
6. **Creates or merges** the NudgeConfig:
   - If `nudge-config` does not exist → creates it
   - If `nudge-config` exists → merges new entries, preserving existing ones

### Merge Behavior

When a NudgeConfig already exists in the namespace:

- **Existing entries are never removed or modified** — user-added entries are preserved
- Only entries from `build-nudges-ref` not already present are added
- Existing entry modes are preserved (e.g., a user-set `validated` mode stays as-is)
- New entries are added with `mode: immediate`

### Migration Metadata

Created or updated NudgeConfig resources are tagged with:

- **Label:** `nudging.konflux-ci.dev/owner: build-service`
- **Annotation:** `nudging.konflux-ci.dev/migrated-from: build-nudges-ref`

### Error Handling

- **Retry on conflict:** Update operations retry up to 3 times on 409 Conflict
  (re-fetches, re-merges, and re-validates on each attempt)
- **AlreadyExists fallback:** If a create races with another actor, the script
  falls back to the merge/update path
- **Partial failure:** Errors in one namespace do not stop processing of other
  namespaces. The script exits with code 1 if any namespace had errors.

### Idempotency

Running the script twice on the same namespace produces the same result.
The second run detects all relationships are already present and skips the
namespace.

## RBAC Requirements

The script needs a ClusterRole with the following permissions:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nudge-migration
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["list"]
  - apiGroups: ["appstudio.redhat.com"]
    resources: ["components"]
    verbs: ["list"]
  - apiGroups: ["appstudio.redhat.com"]
    resources: ["nudgeconfigs"]
    verbs: ["get", "create", "update"]
```

## Rollback

To revert a namespace to build-service nudging, delete the NudgeConfig:

```bash
kubectl delete nudgeconfig nudge-config -n <namespace>
```

## Summary Output

After processing all namespaces, the script prints a summary table:

```
═══════════════════════════════════════════════════════════════════════════════
Migration Summary
═══════════════════════════════════════════════════════════════════════════════
  NAMESPACE                                     ACTION           FOUND   MIGRATED  DETAIL
  ─────────────────────────────────────────────────────────────────────────────
  tenant-ns-1                                   created          3       3         Created with 3 entries
  tenant-ns-2                                   skipped          0       0         No build-nudges-ref entries
  tenant-ns-3                                   updated          2       1         Added 1 entries
  ─────────────────────────────────────────────────────────────────────────────
  Namespaces: 3 total — 1 created, 1 updated, 1 skipped, 0 errors
  Relationships migrated: 4
═══════════════════════════════════════════════════════════════════════════════
```

## Related Issues

| Jira | Description |
|---|---|
| STONEINTG-1682 | This migration script |
| STONEINTG-1659 | NudgeConfig CRD deployment |
| STONEINTG-1660 | NudgeConfig CRD (related) |
| STONEINTG-1672 | build-service skip patch (prerequisite) |
| STONEINTG-1495 | Parent epic: component nudging in integration-service |
