# migrate-gitops-nudges — GitOps/ArgoCD Nudge Migration

Companion script to `nudge-migrate.sh` for tenant teams who manage their `Component`
CRs through ArgoCD (GitOps). Part of the
[ADR-0067](https://github.com/konflux-ci/architecture/pull/354) migration from
`build-nudges-ref` to `NudgeConfig`.

---

## Why do I need this script?

If you already ran the cluster-side `nudge-migrate.sh`, you may have noticed ArgoCD
reverting the change on the next sync. This happens because ArgoCD compares the cluster
state to the YAML files in your git repository — if `build-nudges-ref` is still present
in those files, ArgoCD restores it.

This script closes that gap:

1. Finds every ArgoCD-managed `Component` on the cluster that still has `build-nudges-ref`
2. Traces each component back to its source git repository via the ArgoCD `Application` CR
3. Opens **one MR/PR per ArgoCD Application** that:
   - Removes `build-nudges-ref` from all affected Component YAML files
   - Adds a `nudge-config.yaml` (`NudgeConfig` CR) so ArgoCD tracks the new resource
   - Updates `kustomization.yaml` if one exists in the source path

> **Not using ArgoCD?** Use `nudge-migrate.sh` instead (see [../README.md](../README.md)).

---

## Prerequisites

### Tools

| Tool | Version | Purpose |
|---|---|---|
| `kubectl` | any recent | Query cluster resources |
| `yq` | **v4** (`mikefarah/yq`) | Edit YAML files in-place |
| `git` | any | Clone, branch, commit, push |
| `curl` | any | GitLab / GitHub API calls |
| `jq` | >= 1.6 | Process JSON from kubectl |
| `python3` | any | URL-encode GitLab repo paths |
| `bash` | **>= 4.3** | Associative arrays and namerefs (macOS ships 3.2 — `brew install bash`) |

To verify you have the right `yq`:
```bash
yq --version   # must show "version v4.x.x"
```

### Access tokens

You need a token with permission to push branches and open MRs/PRs on the source
repository of each ArgoCD Application:

| Platform | Token type | Required scopes |
|---|---|---|
| GitLab | Personal access token | `api` |
| GitHub | Personal access token | `repo` |

Set them as environment variables (or pass via flags — see [Options](#options)):
```bash
export GITLAB_TOKEN=glpat-xxxxxxxxxxxx
export GITHUB_TOKEN=ghp_xxxxxxxxxxxx
```

### Cluster access

You need an authenticated `kubectl` context with permission to:
- `get`/`list` namespaces
- `get`/`list` Components in target namespaces
- `get` ArgoCD `Application` CRs in the ArgoCD namespace

---

## Quickstart

**Always run with `--dry-run` first** to see what would happen without touching anything:

```bash
# 1. Preview — no repos cloned, no MRs created
./migrate-gitops-nudges.sh --dry-run

# 2. Target specific namespaces (recommended before running across all)
./migrate-gitops-nudges.sh --dry-run -n my-tenant,other-tenant

# 3. Run for real on those namespaces
./migrate-gitops-nudges.sh -n my-tenant,other-tenant
```

---

## Options

```
Usage: migrate-gitops-nudges.sh [OPTIONS]

OPTIONS:
  -n, --namespaces NS1,NS2   Comma-separated list of namespaces to scan.
                              If omitted, all ArgoCD-managed namespaces are scanned.
  --argocd-namespace NAME    Namespace where ArgoCD Application CRs live.
                              Default: gitops-service-argocd
  --dry-run                  Print what would be done; do not clone, push, or create MRs/PRs.
  --gitlab-token TOKEN       GitLab token (overrides GITLAB_TOKEN env var).
  --github-token TOKEN       GitHub token (overrides GITHUB_TOKEN env var).
  -h, --help                 Show help and exit.
```

---

## Examples

```bash
# Dry-run across all ArgoCD-managed namespaces
./migrate-gitops-nudges.sh --dry-run

# Dry-run on a single namespace, ArgoCD in a non-default namespace
./migrate-gitops-nudges.sh --dry-run \
  --argocd-namespace openshift-gitops \
  -n my-tenant

# Full run on two namespaces (token via env var)
export GITLAB_TOKEN=glpat-xxxxxxxxxxxx
./migrate-gitops-nudges.sh -n tenant-a,tenant-b

# Full run with token passed as a flag
./migrate-gitops-nudges.sh \
  -n tenant-a \
  --gitlab-token glpat-xxxxxxxxxxxx \
  --github-token ghp_xxxxxxxxxxxx

# Run across all namespaces (be sure to dry-run first!)
./migrate-gitops-nudges.sh
```

---

## What it does, step by step

### 1. Discover namespaces
If you pass `-n`, those namespaces are used. Otherwise the script finds all namespaces
with the label `argocd.argoproj.io/managed-by` — the label ArgoCD puts on every
namespace it is allowed to deploy to.

### 2. Find affected components
In each namespace, the script lists every `Component` CR that has a non-empty
`spec.build-nudges-ref` field.

### 3. Separate ArgoCD-managed from cluster-only
ArgoCD stamps every resource it manages with the label
`app.kubernetes.io/instance=<application-name>`. Components **without** this label
are not ArgoCD-managed; the script warns about them and skips — use `nudge-migrate.sh`
for those instead.

### 4. Trace each component back to its source repo
The script reads the matching ArgoCD `Application` CR and extracts:
- **Repo URL** — where to clone from
- **Source path** — the directory inside the repo that ArgoCD syncs
- **Branch** — which branch ArgoCD tracks (default: `main`)

Both GitLab and GitHub URLs are supported. Anything else is skipped with a warning.

### 5. Open one MR/PR per ArgoCD Application
For each unique ArgoCD Application, the script:

1. **Clones** the repository (shallow clone for speed)
2. **Searches** for `*.yaml` / `*.yml` files under the source path that contain
   `build-nudges-ref` and removes the field from every `Component` document in each file,
   leaving all other documents (e.g. `Application`, `Namespace`) untouched
3. **Generates** a `nudge-config.yaml` file encoding the same nudge relationships in the
   new `NudgeConfig` format
4. **Updates** `kustomization.yaml` (if one exists) by adding `nudge-config.yaml` to the
   resources list — skipped if already present
5. **Pushes** a new branch named `migrate/remove-build-nudges-ref-<namespace(s)>`
6. **Opens** a MR (GitLab) or PR (GitHub) with a summary table of what changed

### 6. Print a summary
After all Applications are processed, a summary is printed showing the MR/PR URL for
each Application and listing any components that were skipped (not ArgoCD-managed).

---

## Generated NudgeConfig

The `nudge-config.yaml` added to your repository looks like this:

```yaml
apiVersion: appstudio.redhat.com/v1beta2
kind: NudgeConfig
metadata:
  name: nudge-config
  namespace: my-tenant
  labels:
    nudging.konflux-ci.dev/owner: build-service
  annotations:
    nudging.konflux-ci.dev/migrated-from: build-nudges-ref
spec:
  nudges:
    - from: component-a
      to: component-b
      mode: immediate
```

- One `NudgeConfig` per namespace (Kubernetes enforces a single object named `nudge-config`)
- All relationships are set to `mode: immediate` (same behaviour as `build-nudges-ref`)
- Labels and annotations match the cluster-side migration script for consistency

---

## Dry-run output

A `--dry-run` run does **not** clone any repository or create any MR/PR. It prints:

```
INFO: === DRY-RUN mode: no repos will be cloned or MRs/PRs created ===

==> Namespace: my-tenant
INFO:   component-a: ArgoCD app=tenant-config-prod
INFO:   Found 1 component(s) with build-nudges-ref; 1 ArgoCD-managed

==> Processing ArgoCD Application: tenant-config-prod
INFO:   Repo:     https://gitlab.cee.redhat.com/releng/konflux-release-data.git
INFO:   Path:     tenants-config/cluster/prod/tenants/my-tenant
INFO:   Branch:   main
INFO:   Platform: gitlab
INFO: [DRY-RUN] Would clone https://gitlab.cee.redhat.com/... (branch: main)
INFO: [DRY-RUN] Would search *.yaml/*.yml under 'tenants-config/.../my-tenant' for 'build-nudges-ref'
INFO: [DRY-RUN]   and remove the field from all Component documents
INFO: [DRY-RUN]   my-tenant/component-a → nudges: component-b
INFO: [DRY-RUN] Would create tenants-config/.../my-tenant/nudge-config.yaml:
apiVersion: appstudio.redhat.com/v1beta2
kind: NudgeConfig
...
INFO: [DRY-RUN] Would push branch 'migrate/remove-build-nudges-ref-my-tenant' and open gitlab MR/PR targeting 'main'
```

---

## After merging the MR/PR

Once ArgoCD syncs the merged changes:

1. Verify `build-nudges-ref` is gone from the cluster:
   ```bash
   kubectl get component -n my-tenant component-a -o jsonpath='{.spec.build-nudges-ref}'
   # should return nothing
   ```

2. Verify the `NudgeConfig` is present:
   ```bash
   kubectl get nudgeconfig nudge-config -n my-tenant -o yaml
   ```

---

## Handling mixed repos (multiple namespaces from one Application)

If a single ArgoCD Application serves components from more than one namespace, the script
creates one `nudge-config-<namespace>.yaml` per namespace in the same source path, and
adds each to `kustomization.yaml`. The branch name includes all affected namespaces
(hyphen-joined).

---

## Kustomize variable substitutions

Some Component YAML files use Kustomize variable syntax in `metadata.name`
(e.g. `name: $(COMPONENT_NAME)`). The script removes `build-nudges-ref` from these
files correctly — the field name is always a literal string regardless of any variable
substitutions. The MR/PR description flags any such files so you can verify the component
name mapping before merging.

---

## Troubleshooting

| Problem | Likely cause | Fix |
|---|---|---|
| `yq v4 required` error | Wrong `yq` installed (e.g., `python-yq`) | Install `mikefarah/yq` v4 |
| `Bash >= 4.3 is required` error | macOS ships Bash 3.2 | `brew install bash`, then run with `/usr/local/bin/bash migrate-gitops-nudges.sh` |
| `ArgoCD Application not found` | Wrong `--argocd-namespace` | Pass the correct namespace with `--argocd-namespace` |
| `Could not resolve GitLab project ID` | Token missing `api` scope or wrong host | Check token scopes and repo URL |
| Component skipped: "not ArgoCD-managed" | Component has no `app.kubernetes.io/instance` label | Run `nudge-migrate.sh` for this component |
| MR/PR creation failed | Insufficient token permissions | Ensure token has push + MR/PR creation rights |
| Branch already exists | Script was run before | Delete the remote branch or the existing MR/PR and re-run |

---

## Related

| Script / Resource | Description |
|---|---|
| [`../nudge-migrate.sh`](../README.md) | Cluster-side migration (non-ArgoCD components) |
| [ADR-0067](https://github.com/konflux-ci/architecture/pull/354) | Architecture decision record for NudgeConfig |
| STONEINTG-1733 | This GitOps migration script |
| STONEINTG-1682 | Cluster-side migration script |
| STONEINTG-1659 / 1660 | NudgeConfig CRD deployment (prerequisite) |
| STONEINTG-1672 | build-service skip patch (prerequisite) |
