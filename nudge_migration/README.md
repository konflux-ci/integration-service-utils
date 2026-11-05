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
| **date** | GNU coreutils (`date -d` is used to normalize `--since` and timestamps) |
| **Cluster access** | Authenticated `kubectl` context with sufficient RBAC |

## Usage

```bash
./nudge-migrate.sh [--dry-run] [--context CTX] [NAMESPACE...]
./nudge-migrate.sh --rollback [--dry-run] [--force] [--since RFC3339] \
                   [--backup-dir DIR | --no-backup] [--context CTX] [NAMESPACE...]
```

### Flags

| Flag | Mode | Description |
|---|---|---|
| `--dry-run` | both | Print what would change without writing anything |
| `--context CTX` | both | Use a specific kubeconfig context for every kubectl call |
| `--rollback` | — | Roll back the migration instead of performing it (see [Rollback](#rollback)) |
| `--force` | rollback | Delete a NudgeConfig that is not provably migration-created |
| `--since RFC3339` | rollback | Override the requeue-window start |
| `--backup-dir DIR` | rollback | Where to write the pre-delete backup (default `./nudge-migrate-backups`) |
| `--no-backup` | rollback | Skip the backup |
| `--help` | both | Show help message |

Rollback-only flags are rejected with exit code 2 in migration mode.

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

# Preview a rollback for one namespace
./nudge-migrate.sh --rollback --dry-run my-tenant-ns

# Roll back one namespace (migration-created config, default window)
./nudge-migrate.sh --rollback my-tenant-ns

# Roll back a merged/legacy config whose migration start is known
./nudge-migrate.sh --rollback --force --since 2026-11-01T00:00:00Z my-tenant-ns
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
5. **Checks cardinality** — max 4096 nudge entries per NudgeConfig
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
- **Annotation:** `nudging.konflux-ci.dev/migrated-at: <RFC3339>` — when the
  migration first touched this config
- **Annotation:** `nudging.konflux-ci.dev/migrated-action: created | merged` —
  `created` when the script created the NudgeConfig, `merged` when it added
  entries to a config that already existed

These annotations let a later `--rollback` decide whether the NudgeConfig is
safe to delete without operator input. `created` is sticky: re-running the
migration never downgrades it to `merged`, and an existing `migrated-at` is
never moved forward. Configs migrated before these annotations existed carry
no markers and are treated as legacy (see [Rollback](#rollback)).

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
    verbs: ["get", "create", "update", "delete"]
  # Rollback only: list build PipelineRuns and clear the marker annotation.
  - apiGroups: ["tekton.dev"]
    resources: ["pipelineruns"]
    verbs: ["get", "list", "patch", "update"]
```

The `tekton.dev/pipelineruns` rule is only needed for `--rollback`;
`patch` is what `kubectl annotate` uses (some kubectl versions also send
`update`).

## Rollback

> Deleting the NudgeConfig alone is **not** a complete rollback. Use
> `--rollback`, which also requeues the builds that build-service stopped
> nudging during the migration (STONEINTG-1906).

### Why deleting the NudgeConfig is not enough

build-service stops nudging a namespace as soon as a `NudgeConfig` named
`nudge-config` exists. On every build PipelineRun it reconciles, it writes
`build.appstudio.openshift.io/component-nudge-processed` and removes its
`build-nudge-finalizer`. Its watch predicate then ignores any PipelineRun that
has that annotation and no finalizer — so after the NudgeConfig is deleted,
builds that were in flight during the migration are nudged by neither
controller.

`--rollback` deletes the NudgeConfig and clears the build-service annotation
from the affected build PipelineRuns. After that:

- a completed build is nudged immediately by build-service;
- a running build gets the finalizer re-added and is nudged on completion.

The script only ever removes
`build.appstudio.openshift.io/component-nudge-processed`. It never touches
`test.appstudio.openshift.io/component-nudge-processed`, which is
integration-service's own idempotency guard.

### Safety checks

- A NudgeConfig is deleted without `--force` only when it has
  `nudging.konflux-ci.dev/migrated-action: created` **and**
  `nudging.konflux-ci.dev/owner: build-service`. Merged configs, legacy configs
  without markers, and owner mismatches are refused (exit 1) with nothing
  changed; `--force` overrides.
- Window start precedence: `--since` → `migrated-at` → `metadata.creationTimestamp`
  (the last only for a migration-created config). For merged/legacy configs
  without `migrated-at`, `--since` is required: their `creationTimestamp` is
  the user's original config age, not the migration start.
- If the NudgeConfig is already gone (rerun), the window comes from `--since` or
  the latest backup in `--backup-dir`; with neither, the run fails. A
  backup-derived window **ends at the original rollback time** (read from the
  backup file name), not at "now": builds created after the NudgeConfig was
  deleted were never skipped, so build-service nudged them normally and set the
  annotation itself — requeueing them on a rerun would nudge them twice.
- Before deleting, the config is re-read and its `resourceVersion` compared; a
  change mid-run aborts with nothing written.
- A backup (`<ns>-nudge-config-<ts>.json`) and a PipelineRun audit list
  (`<ns>-plrs-<ts>.txt`) are written first; a backup failure aborts that
  namespace. `--no-backup` disables this, but `--force` does not bypass it.
- The NudgeConfig is deleted **before** any annotation is cleared — the reverse
  order would let build-service re-mark the builds immediately.
- After deletion the script waits `ROLLBACK_SETTLE_SECONDS` (default `5`) so
  build-service's informer observes the deletion before annotations change. If a
  build is re-marked by a lagging reconciler, rerun with `--since`; builds whose
  marker is already cleared no longer match.

### Which builds are requeued

A build PipelineRun is selected when it:

- carries a non-empty `build.appstudio.openshift.io/component-nudge-processed`
  annotation,
- has the `appstudio.openshift.io/component` label and
  `pipelines.appstudio.openshift.io/type=build`,
- was triggered by a `push` or `incoming` event (read from the label or the
  annotation, case-insensitive), and
- either was created in `[window start, window end]` or was still running when
  the window started (`status.completionTime` absent or not before the start).
  The window end is "now", or the original rollback time when the window is
  derived from a backup.

The window is required because build-service also sets the annotation *after a
successful nudge*. Without it, an old already-nudged build would be nudged
again. Builds that completed before the window start are counted and reported
as excluded; widen the window with `--since` only when that is intended.

### Limitations

- PipelineRuns pruned by Tekton cannot be requeued — run the rollback promptly.
  KubeArchive is read-only, so the script does not consult it.
- A requeued build only produces a nudge while `Component.spec.build-nudges-ref`
  still exists for that component. The script warns, per namespace, when a
  component it is about to requeue has no `build-nudges-ref`, but it does not
  fix that for you.
- Clearing the marker on a running build re-adds build-service's finalizer;
  nothing nudges if build-service is not running.
- A second run is a no-op (`skipped`) once the config is gone and markers are
  cleared.

### Examples

```bash
# Preview: which config would be deleted, which builds requeued
./nudge-migrate.sh --rollback --dry-run my-tenant-ns

# Roll back a migration-created config
./nudge-migrate.sh --rollback my-tenant-ns

# Roll back a merged/legacy config with a known migration start
./nudge-migrate.sh --rollback --force --since 2026-11-01T00:00:00Z my-tenant-ns

# Be explicit about the kubeconfig context for a production rollback
./nudge-migrate.sh --rollback --context prod-p02 my-tenant-ns
```

As a last resort, or in a namespace where the script cannot run, delete the
config manually and clear the markers yourself — but never stop at the delete:

```bash
kubectl delete nudgeconfig nudge-config -n <namespace>
kubectl annotate pipelinerun <name> \
  build.appstudio.openshift.io/component-nudge-processed- -n <namespace>
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

In rollback mode the columns change and the footer counts requeued builds:

```
═══════════════════════════════════════════════════════════════════════════════
Migration Summary
═══════════════════════════════════════════════════════════════════════════════
  NAMESPACE                                     ACTION           PLRS    REQUEUED  DETAIL
  ─────────────────────────────────────────────────────────────────────────────
  tenant-ns-1                                   rolled-back      18      18        Deleted NudgeConfig. Requeued 18 PLRs.
  tenant-ns-2                                   skipped          0       0         No NudgeConfig and no affected PLRs
  ─────────────────────────────────────────────────────────────────────────────
  Namespaces: 2 total — 1 rolled back, 1 skipped, 0 errors
  Build PipelineRuns requeued: 18 (pre-window annotated PLRs excluded: 4)
═══════════════════════════════════════════════════════════════════════════════
```

## Related Issues

| Jira | Description |
|---|---|
| STONEINTG-1682 | This migration script |
| STONEINTG-1906 | Rollback mode: requeue builds skipped during migration |
| STONEINTG-1659 | NudgeConfig CRD deployment |
| STONEINTG-1660 | NudgeConfig CRD (related) |
| STONEINTG-1672 | build-service skip patch (prerequisite) |
| STONEINTG-1495 | Parent epic: component nudging in integration-service |
