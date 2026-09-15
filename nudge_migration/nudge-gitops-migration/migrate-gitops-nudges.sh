#!/bin/bash

# migrate-gitops-nudges.sh - Migrate ArgoCD/GitOps-managed Component CRs from
# build-nudges-ref to NudgeConfig (ADR-0067)
#
# For components managed via ArgoCD GitOps, removing build-nudges-ref from the
# cluster CR is not enough — ArgoCD will re-sync and restore it from the source
# repo. This script:
#   1. Discovers ArgoCD-managed components on the cluster that have build-nudges-ref
#   2. Traces each back to its source GitLab or GitHub repo via the ArgoCD Application CR
#   3. Opens one MR/PR per ArgoCD Application that:
#      - Removes build-nudges-ref from every affected Component YAML
#      - Adds a nudge-config.yaml (generated NudgeConfig CR)
#      - Updates kustomization.yaml resources list if one exists in the source path
#
# Exit codes:
#   0 - Completed (MRs/PRs created or dry-run passed)
#   1 - Fatal error (missing dependencies, auth failure, etc.)

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

success() {
    echo -e "${GREEN}DONE:${NC} $1"
}

info() {
    echo -e "${BLUE}INFO:${NC} $1"
}

warning() {
    echo -e "${YELLOW}WARN:${NC} $1"
}

header() {
    echo -e "\n${CYAN}==>${NC} $1"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Migrate ArgoCD/GitOps-managed components from build-nudges-ref to NudgeConfig (ADR-0067).

OPTIONS:
  -n, --namespaces NS1,NS2   Target namespaces (comma-separated).
                              If omitted, all ArgoCD-managed namespaces are scanned.
  --argocd-namespace NAME    Namespace where ArgoCD Application CRs live.
                              Default: gitops-service-argocd
  --dry-run                  Print what would be done; do not clone, push, or create MRs/PRs.
  --gitlab-token TOKEN       GitLab API token (overrides GITLAB_TOKEN env var).
  --github-token TOKEN       GitHub API token (overrides GITHUB_TOKEN env var).
  -h, --help                 Show this help.

ENVIRONMENT:
  GITLAB_TOKEN               GitLab personal access token (needs api scope).
  GITHUB_TOKEN               GitHub personal access token (needs repo scope).

DEPENDENCIES:
  kubectl, yq (v4), git, curl, jq, python3

EXAMPLES:
  # Dry-run across all ArgoCD-managed namespaces
  $(basename "$0") --dry-run

  # Full run on two specific namespaces
  $(basename "$0") -n my-tenant,other-tenant

  # Target a non-default ArgoCD namespace
  $(basename "$0") --argocd-namespace openshift-gitops -n my-tenant
EOF
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
check_deps() {
    local missing=()
    for cmd in kubectl yq git curl jq python3; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
        error "Install them and retry."
        exit 1
    fi
    # Verify yq is v4 (mikefarah/yq) — v4 uses 'eval' subcommand
    if ! yq --version 2>&1 | grep -q "version v4"; then
        error "yq v4 (mikefarah/yq) is required. Found: $(yq --version 2>&1 | head -1)"
        exit 1
    fi
    # Require Bash >= 4.3 (associative arrays need 4.0+; local -n namerefs need 4.3+)
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]] || \
       { [[ "${BASH_VERSINFO[0]}" -eq 4 ]] && [[ "${BASH_VERSINFO[1]}" -lt 3 ]]; }; then
        error "Bash >= 4.3 is required (found ${BASH_VERSION}). On macOS: brew install bash"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
NAMESPACES_ARG=""
ARGOCD_NAMESPACE="gitops-service-argocd"
DRY_RUN=false
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespaces)
            NAMESPACES_ARG="$2"; shift 2 ;;
        --argocd-namespace)
            ARGOCD_NAMESPACE="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        --gitlab-token)
            GITLAB_TOKEN="$2"; shift 2 ;;
        --github-token)
            GITHUB_TOKEN="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# State: cluster-only components (not ArgoCD-managed) collected across all NS
# ---------------------------------------------------------------------------
CLUSTER_ONLY_COMPONENTS=()

# ---------------------------------------------------------------------------
# Temporary workspace
# ---------------------------------------------------------------------------
WORKDIR=$(mktemp -d)
APPS_DATA_FILE="${WORKDIR}/apps_data.json"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Per-app MR/PR URL registry (populated by process_application, printed in summary)
# ---------------------------------------------------------------------------
declare -A APP_MR_URLS=()

# ---------------------------------------------------------------------------
# Step 1: Discover namespaces
# ---------------------------------------------------------------------------
discover_namespaces() {
    if [[ -n "$NAMESPACES_ARG" ]]; then
        echo "$NAMESPACES_ARG" | tr ',' '\n'
        return
    fi
    info "Discovering ArgoCD-managed namespaces (label: argocd.argoproj.io/managed-by)..."
    kubectl get namespaces \
        -l "argocd.argoproj.io/managed-by" \
        -o jsonpath='{.items[*].metadata.name}' \
        | tr ' ' '\n'
}

# ---------------------------------------------------------------------------
# Step 2: Find components with build-nudges-ref in a namespace
# ---------------------------------------------------------------------------
find_nudging_components() {
    local ns="$1"
    kubectl get components -n "$ns" -o json 2>/dev/null \
        | jq -c '.items[] | select(
            .spec["build-nudges-ref"] != null and
            (.spec["build-nudges-ref"] | length) > 0
          )' \
        || true
}

# ---------------------------------------------------------------------------
# Step 3: Identify ArgoCD Application name from a component JSON
# ---------------------------------------------------------------------------
get_argocd_app() {
    echo "$1" | jq -r '.metadata.labels["app.kubernetes.io/instance"] // empty'
}

# ---------------------------------------------------------------------------
# Step 4: Resolve source repo details from an ArgoCD Application CR
# ---------------------------------------------------------------------------
resolve_app_source() {
    local app_name="$1"
    local app_json
    app_json=$(kubectl get application "$app_name" -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null || true)
    # Some kubectl versions emit deprecation warnings to stdout before the JSON.
    # Strip any leading non-JSON lines so we always pass valid JSON downstream.
    app_json=$(echo "$app_json" | awk 'found || /^\s*\{/{found=1} found')
    if [[ -z "$app_json" ]] || ! echo "$app_json" | jq empty 2>/dev/null; then
        warning "ArgoCD Application '$app_name' not found in namespace '$ARGOCD_NAMESPACE' — skipping"
        echo ""
        return
    fi
    echo "$app_json"
}

detect_platform() {
    local repo_url="$1"
    local host
    host=$(echo "$repo_url" | sed -E 's|https?://([^/]+)/.*|\1|')
    if echo "$host" | grep -qi "gitlab"; then
        echo "gitlab"
    elif [[ "$host" == "github.com" ]]; then
        echo "github"
    else
        echo "unknown"
    fi
}

# ---------------------------------------------------------------------------
# Step 5b: Remove build-nudges-ref from YAML files
# Returns list of changed files (newline-separated)
# ---------------------------------------------------------------------------
remove_build_nudges_ref() {
    local source_path="$1"
    local changed_files=()

    while IFS= read -r -d '' file; do
        if grep -q 'build-nudges-ref' "$file"; then
            # Check for kustomize variable substitutions in component names
            if grep -q '\$(' "$file"; then
                warning "File '$file' contains kustomize variable substitutions — field will still be removed; please verify component name mapping in the MR"
            fi
            # Remove build-nudges-ref from Component documents only.
            # In yq v4, select() used as a path expression with |= preserves all
            # documents — non-matching ones pass through unchanged.
            yq eval 'select(.kind == "Component").spec |= del(."build-nudges-ref")' \
                -i "$file"
            changed_files+=("$file")
        fi
    done < <(find "$source_path" -maxdepth 5 \( -name '*.yaml' -o -name '*.yml' \) -print0)

    printf '%s\n' "${changed_files[@]}"
}

# ---------------------------------------------------------------------------
# Step 5c: Generate NudgeConfig YAML for a namespace
# nudge_relationships: newline-separated "from:to" pairs
# ---------------------------------------------------------------------------
generate_nudge_config() {
    local namespace="$1"
    local output_file="$2"
    shift 2
    local -a pairs=("$@")

    {
        echo "apiVersion: appstudio.redhat.com/v1beta2"
        echo "kind: NudgeConfig"
        echo "metadata:"
        echo "  name: nudge-config"
        echo "  namespace: ${namespace}"
        echo "  labels:"
        echo "    nudging.konflux-ci.dev/owner: build-service"
        echo "  annotations:"
        echo "    nudging.konflux-ci.dev/migrated-from: build-nudges-ref"
        echo "spec:"
        echo "  nudges:"
        for pair in "${pairs[@]}"; do
            local from_comp to_comp
            from_comp="${pair%%:*}"
            to_comp="${pair#*:}"
            echo "    - from: ${from_comp}"
            echo "      to: ${to_comp}"
            echo "      mode: immediate"
        done
    } > "$output_file"
}

# ---------------------------------------------------------------------------
# Step 5d: Update kustomization.yaml if present
# ---------------------------------------------------------------------------
update_kustomization() {
    local source_path="$1"
    local new_resource="$2"

    local kustomize_file="${source_path}/kustomization.yaml"
    if [[ ! -f "$kustomize_file" ]]; then
        return 1
    fi
    # Add the new resource only if it's not already listed
    if yq eval '.resources // []' "$kustomize_file" | grep -q "$new_resource"; then
        return 1
    fi
    yq eval ".resources += [\"${new_resource}\"]" -i "$kustomize_file"
    info "Updated kustomization.yaml: added ${new_resource}"
    return 0
}

# ---------------------------------------------------------------------------
# Step 5f: Create GitLab MR
# ---------------------------------------------------------------------------
create_gitlab_mr() {
    local gitlab_host="$1"
    local repo_path="$2"   # e.g. releng/konflux-release-data
    local source_branch="$3"
    local target_branch="$4"
    local title="$5"
    local body="$6"

    local encoded_path
    encoded_path=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$repo_path")

    local api_resp project_id
    api_resp=$(curl -sS --fail-with-body \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "https://${gitlab_host}/api/v4/projects/${encoded_path}" 2>&1) || {
        error "GitLab API request failed for '${repo_path}': ${api_resp}"
        return 1
    }
    project_id=$(echo "$api_resp" | jq -r '.id' 2>/dev/null) || {
        error "Could not parse GitLab project ID response for '${repo_path}'"
        return 1
    }
    if [[ -z "$project_id" || "$project_id" == "null" ]]; then
        error "Could not resolve GitLab project ID for '${repo_path}' on '${gitlab_host}'"
        return 1
    fi

    local mr_resp mr_url
    mr_resp=$(curl -sS --fail-with-body -X POST \
        "https://${gitlab_host}/api/v4/projects/${project_id}/merge_requests" \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg sb "$source_branch" \
            --arg tb "$target_branch" \
            --arg title "$title" \
            --arg body "$body" \
            '{source_branch:$sb, target_branch:$tb, title:$title, description:$body, remove_source_branch:true}'
        )" 2>&1) || {
        error "GitLab MR creation failed: ${mr_resp}"
        return 1
    }
    mr_url=$(echo "$mr_resp" | jq -r '.web_url' 2>/dev/null) || {
        error "Could not parse GitLab MR URL from response"
        return 1
    }
    echo "$mr_url"
}

# ---------------------------------------------------------------------------
# Step 5f: Create GitHub PR
# ---------------------------------------------------------------------------
create_github_pr() {
    local owner="$1"
    local repo="$2"
    local source_branch="$3"
    local target_branch="$4"
    local title="$5"
    local body="$6"

    local pr_resp pr_url
    pr_resp=$(curl -sS --fail-with-body -X POST \
        "https://api.github.com/repos/${owner}/${repo}/pulls" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -d "$(jq -n \
            --arg title "$title" \
            --arg head "$source_branch" \
            --arg base "$target_branch" \
            --arg body "$body" \
            '{title:$title, head:$head, base:$base, body:$body}'
        )" 2>&1) || {
        error "GitHub PR creation failed: ${pr_resp}"
        return 1
    }
    pr_url=$(echo "$pr_resp" | jq -r '.html_url' 2>/dev/null) || {
        error "Could not parse GitHub PR URL from response"
        return 1
    }
    echo "$pr_url"
}

# ---------------------------------------------------------------------------
# Build MR/PR description body
# ---------------------------------------------------------------------------
build_mr_body() {
    local -n _component_table=$1  # nameref: array of "COMP|NS|TARGETS" strings
    local -n _changed_files=$2    # nameref: array of changed file paths

    local body="## ADR-0067 NudgeConfig migration — remove build-nudges-ref\n\n"
    body+="| Component | Namespace | Nudge targets |\n"
    body+="|---|---|---|\n"
    for row in "${_component_table[@]}"; do
        local comp ns targets
        comp="${row%%|*}"; rest="${row#*|}"; ns="${rest%%|*}"; targets="${rest#*|}"
        body+="| ${comp} | ${ns} | ${targets} |\n"
    done

    body+="\n### Files changed\n"
    for f in "${_changed_files[@]}"; do
        body+="- \`${f}\`\n"
    done

    body+="\n> Components with kustomize variable substitutions in \`metadata.name\` have their"
    body+="\n> \`build-nudges-ref\` field removed. Please verify the component name mapping.\n"
    body+="\nPart of the ADR-0067 NudgeConfig migration."

    echo -e "$body"
}

# ---------------------------------------------------------------------------
# Process one ArgoCD Application: clone, edit, push, create MR/PR
# ---------------------------------------------------------------------------
process_application() {
    local app_name="$1"
    local app_json="$2"

    local repo_url source_path branch
    repo_url=$(echo "$app_json" | jq -r '.spec.source.repoURL')
    source_path=$(echo "$app_json" | jq -r '.spec.source.path // "."')
    branch=$(echo "$app_json" | jq -r '.spec.source.targetRevision // ""')
    # HEAD and empty targetRevision both mean "default branch" in ArgoCD.
    # git clone --branch HEAD fails; clone without --branch and resolve afterwards.
    local use_default_branch=false
    if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
        use_default_branch=true
    fi

    local platform
    platform=$(detect_platform "$repo_url")
    if [[ "$platform" == "unknown" ]]; then
        warning "Cannot determine platform (GitLab/GitHub) for repoURL '${repo_url}' — skipping app '${app_name}'"
        return
    fi

    header "Processing ArgoCD Application: ${app_name}"
    info "  Repo:     ${repo_url}"
    info "  Path:     ${source_path}"
    info "  Branch:   ${branch}"
    info "  Platform: ${platform}"

    # Read component data for this app directly from the JSON data file.
    # Build nudge_pairs_json ({namespace: [{from,to}]}) in a single jq reduce so
    # there are no subshell scoping issues when accumulating across components.
    local component_table=()
    local nudge_pairs_json
    nudge_pairs_json=$(jq -rc --arg app "$app_name" '
        .[$app] | reduce .[] as $entry (
            {};
            . as $acc |
            $entry.ns as $ns |
            $entry.comp.metadata.name as $from |
            ($entry.comp.spec["build-nudges-ref"] // []) |
            reduce .[] as $target (
                $acc;
                .[$ns] += [{"from": $from, "to": $target}]
            )
        )
    ' "$APPS_DATA_FILE")

    # Build component_table rows for the MR body
    while IFS= read -r entry; do
        local ns comp_name targets
        ns=$(echo "$entry" | jq -r '.ns')
        comp_name=$(echo "$entry" | jq -r '.comp.metadata.name')
        targets=$(echo "$entry" | jq -r '.comp.spec["build-nudges-ref"] | join(", ")')
        component_table+=("${comp_name}|${ns}|${targets}")
    done < <(jq -c --arg app "$app_name" '.[$app][]' "$APPS_DATA_FILE")

    if [[ "$DRY_RUN" == "true" ]]; then
        # Derive the branch name the same way the live path does
        local dry_all_ns
        dry_all_ns=$(jq -r --arg app "$app_name" '.[$app][].ns' "$APPS_DATA_FILE" \
            | sort -u | tr '\n' '-' | sed 's/-$//')
        local dry_branch="migrate/remove-build-nudges-ref-${dry_all_ns}"

        info "[DRY-RUN] Would clone ${repo_url} (branch: ${branch})"
        info "[DRY-RUN] Would search *.yaml/*.yml under '${source_path}' for 'build-nudges-ref'"
        info "[DRY-RUN]   and remove the field from all Component documents"
        for row in "${component_table[@]}"; do
            local comp ns targets rest
            comp="${row%%|*}"; rest="${row#*|}"; ns="${rest%%|*}"; targets="${rest#*|}"
            info "[DRY-RUN]   ${ns}/${comp} → nudges: ${targets}"
        done
        # Show the NudgeConfig YAML that would be written
        local ns_count
        ns_count=$(echo "$nudge_pairs_json" | jq 'keys | length')
        echo "$nudge_pairs_json" | jq -r 'keys[]' | while read -r ns; do
            local nc_filename
            if [[ "$ns_count" -eq 1 ]]; then
                nc_filename="nudge-config.yaml"
            else
                nc_filename="nudge-config-${ns}.yaml"
            fi
            info "[DRY-RUN] Would create ${source_path}/${nc_filename}:"
            local -a pairs=()
            while IFS= read -r pair; do pairs+=("$pair"); done \
                < <(echo "$nudge_pairs_json" | jq -r --arg ns "$ns" '.[$ns][] | "\(.from):\(.to)"')
            local tmp_nc; tmp_nc=$(mktemp)
            generate_nudge_config "$ns" "$tmp_nc" "${pairs[@]}"
            cat "$tmp_nc"
            rm -f "$tmp_nc"
        done
        info "[DRY-RUN] Would push branch '${dry_branch}' and open ${platform} MR/PR targeting '${branch}'"
        return
    fi

    # ---- Clone ----
    local clone_dir="${WORKDIR}/${app_name}"

    # Write credentials to a per-clone .netrc so tokens never appear in the
    # clone URL (which would expose them in `ps aux` and .git/config).
    local netrc_file="${WORKDIR}/.netrc-${app_name//[^a-zA-Z0-9]/_}"
    install -m 600 /dev/null "$netrc_file"

    local clone_url
    if [[ "$platform" == "gitlab" ]]; then
        if [[ -z "$GITLAB_TOKEN" ]]; then
            error "GITLAB_TOKEN is required for GitLab repos. Set --gitlab-token or export GITLAB_TOKEN."
            return 1
        fi
        local gitlab_host
        gitlab_host=$(echo "$repo_url" | sed -E 's|https?://([^/]+)/.*|\1|')
        local repo_path
        repo_path=$(echo "$repo_url" | sed -E "s|https?://${gitlab_host}/||" | sed 's|\.git$||')
        printf 'machine %s login oauth2 password %s\n' "$gitlab_host" "$GITLAB_TOKEN" > "$netrc_file"
        clone_url="https://${gitlab_host}/${repo_path}.git"
    else
        if [[ -z "$GITHUB_TOKEN" ]]; then
            error "GITHUB_TOKEN is required for GitHub repos. Set --github-token or export GITHUB_TOKEN."
            return 1
        fi
        local gh_path
        gh_path=$(echo "$repo_url" | sed -E 's|https?://github.com/||' | sed 's|\.git$||')
        printf 'machine github.com login x-access-token password %s\n' "$GITHUB_TOKEN" > "$netrc_file"
        clone_url="https://github.com/${gh_path}.git"
    fi

    info "Cloning ${repo_url} ..."
    if [[ "$use_default_branch" == "true" ]]; then
        GIT_CONFIG_NOSYSTEM=1 HOME="$WORKDIR" NETRC="$netrc_file" \
            git clone --quiet --depth 1 "$clone_url" "$clone_dir"
        # Resolve the actual default branch name for the MR/PR base target
        branch=$(git -C "$clone_dir" symbolic-ref --quiet refs/remotes/origin/HEAD \
            | sed 's@^refs/remotes/origin/@@' || echo "main")
        info "  Resolved default branch: ${branch}"
    else
        GIT_CONFIG_NOSYSTEM=1 HOME="$WORKDIR" NETRC="$netrc_file" \
            git clone --quiet --branch "$branch" --depth 1 "$clone_url" "$clone_dir"
    fi

    local full_source_path="${clone_dir}/${source_path}"

    # ---- Step 5b: Remove build-nudges-ref ----
    local changed_files=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && changed_files+=("${f#${clone_dir}/}")
    done < <(remove_build_nudges_ref "$full_source_path")

    if [[ ${#changed_files[@]} -eq 0 ]]; then
        warning "No files containing 'build-nudges-ref' found under '${source_path}' — skipping app '${app_name}'"
        rm -rf "$clone_dir"
        return
    fi

    # ---- Step 5c: Generate NudgeConfig(s) ----
    local nudge_config_files=()
    while IFS= read -r ns; do
        local -a pairs=()
        while IFS= read -r pair; do pairs+=("$pair"); done \
            < <(echo "$nudge_pairs_json" | jq -r --arg ns "$ns" '.[$ns][] | "\(.from):\(.to)"')

        local nc_filename="nudge-config-${ns}.yaml"
        # If only one namespace, use the standard singleton name
        local ns_count
        ns_count=$(echo "$nudge_pairs_json" | jq 'keys | length')
        if [[ "$ns_count" -eq 1 ]]; then
            nc_filename="nudge-config.yaml"
        fi

        generate_nudge_config "$ns" "${full_source_path}/${nc_filename}" "${pairs[@]}"
        nudge_config_files+=("${source_path}/${nc_filename}")
        changed_files+=("${source_path}/${nc_filename}")

        # ---- Step 5d: Update kustomization.yaml ----
        if update_kustomization "$full_source_path" "$nc_filename"; then
            changed_files+=("${source_path}/kustomization.yaml")
        fi
    done < <(echo "$nudge_pairs_json" | jq -r 'keys[]')

    # Deduplicate changed_files
    mapfile -t changed_files < <(printf '%s\n' "${changed_files[@]}" | sort -u)

    # ---- Step 5e: Branch, commit, push ----
    # Collect unique namespaces for branch name
    local all_ns
    all_ns=$(jq -r --arg app "$app_name" '.[$app][].ns' "$APPS_DATA_FILE" \
        | sort -u | tr '\n' '-' | sed 's/-$//')
    local new_branch="migrate/remove-build-nudges-ref-${all_ns}"

    (
        cd "$clone_dir"
        git config user.email "migration-script@konflux"
        git config user.name "ADR-0067 Migration"
        git remote set-url origin "$clone_url"
        git checkout -b "$new_branch"
        git add -A
        git commit -m "migration: remove build-nudges-ref, add NudgeConfig (ADR-0067)

Automated migration per ADR-0067 NudgeConfig migration.
Removes build-nudges-ref from Component specs and adds NudgeConfig singleton."
        GIT_CONFIG_NOSYSTEM=1 HOME="$WORKDIR" NETRC="$netrc_file" \
            git push origin "$new_branch"
    )

    # ---- Step 5f: Create MR/PR ----
    local mr_title="migration: remove build-nudges-ref, add NudgeConfig (ADR-0067)"
    local mr_body
    mr_body=$(build_mr_body component_table changed_files)

    local mr_url=""
    if [[ "$platform" == "gitlab" ]]; then
        mr_url=$(create_gitlab_mr \
            "$gitlab_host" \
            "$repo_path" \
            "$new_branch" \
            "$branch" \
            "$mr_title" \
            "$mr_body")
    else
        local gh_owner gh_repo
        gh_owner=$(echo "$gh_path" | cut -d/ -f1)
        gh_repo=$(echo "$gh_path" | cut -d/ -f2)
        mr_url=$(create_github_pr \
            "$gh_owner" \
            "$gh_repo" \
            "$new_branch" \
            "$branch" \
            "$mr_title" \
            "$mr_body")
    fi

    if [[ -n "$mr_url" && "$mr_url" != "null" ]]; then
        success "MR/PR created: ${mr_url}"
        APP_MR_URLS["$app_name"]="$mr_url"
    else
        error "MR/PR creation failed for app '${app_name}' — check token permissions and try again"
        APP_MR_URLS["$app_name"]="(failed)"
    fi

    rm -rf "$clone_dir"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    check_deps

    if [[ "$DRY_RUN" == "true" ]]; then
        info "=== DRY-RUN mode: no repos will be cloned or MRs/PRs created ==="
    fi

    # Discover namespaces
    mapfile -t NAMESPACES < <(discover_namespaces)
    if [[ ${#NAMESPACES[@]} -eq 0 ]]; then
        warning "No ArgoCD-managed namespaces found."
        exit 0
    fi

    info "Scanning ${#NAMESPACES[@]} namespace(s): ${NAMESPACES[*]}"

    echo '{}' > "$APPS_DATA_FILE"

    for ns in "${NAMESPACES[@]}"; do
        header "Namespace: ${ns}"

        local count=0 argo_count=0
        while IFS= read -r comp_json; do
            [[ -z "$comp_json" ]] && continue
            count=$((count + 1))

            local comp_name
            comp_name=$(echo "$comp_json" | jq -r '.metadata.name')
            local app_name
            app_name=$(get_argocd_app "$comp_json")

            if [[ -z "$app_name" ]]; then
                warning "  ${comp_name}: no app.kubernetes.io/instance label — not ArgoCD-managed (use cluster-side script)"
                CLUSTER_ONLY_COMPONENTS+=("${ns}/${comp_name}")
                continue
            fi

            argo_count=$((argo_count + 1))
            info "  ${comp_name}: ArgoCD app=${app_name}"

            # Accumulate into APPS_DATA_FILE: {appName: [{ns, comp_json}]}
            local apps_data_new
            apps_data_new=$(jq \
                --arg app "$app_name" \
                --arg ns "$ns" \
                --argjson comp "$comp_json" \
                '.[$app] += [{"ns": $ns, "comp": $comp}]' \
                "$APPS_DATA_FILE")
            echo "$apps_data_new" > "$APPS_DATA_FILE"
        done < <(find_nudging_components "$ns")

        info "  Found ${count} component(s) with build-nudges-ref; ${argo_count} ArgoCD-managed"
    done

    # Process each ArgoCD Application
    if ! jq empty "$APPS_DATA_FILE" 2>/dev/null; then
        error "APPS_DATA_FILE is not valid JSON — this is a bug; run with -x to debug"
        exit 1
    fi
    local app_names
    mapfile -t app_names < <(jq -r 'keys[]' "$APPS_DATA_FILE")

    if [[ ${#app_names[@]} -eq 0 ]]; then
        info "No ArgoCD-managed components with build-nudges-ref found."
    fi

    for app_name in "${app_names[@]}"; do
        local app_json
        app_json=$(resolve_app_source "$app_name")
        if [[ -z "$app_json" ]]; then
            continue
        fi

        process_application "$app_name" "$app_json"
    done

    # Summary
    header "Summary"

    if [[ ${#APP_MR_URLS[@]} -gt 0 ]]; then
        echo ""
        echo "MRs/PRs created:"
        for app in "${!APP_MR_URLS[@]}"; do
            local url="${APP_MR_URLS[$app]}"
            if [[ "$url" == "(failed)" ]]; then
                warning "  ${app}: MR/PR creation FAILED — check token permissions"
            else
                success "  ${app}: ${url}"
            fi
        done
    fi

    if [[ ${#CLUSTER_ONLY_COMPONENTS[@]} -gt 0 ]]; then
        echo ""
        warning "The following components have build-nudges-ref but are NOT ArgoCD-managed."
        warning "Run the companion cluster-side migration script for these:"
        for c in "${CLUSTER_ONLY_COMPONENTS[@]}"; do
            echo "  - ${c}"
        done
    else
        success "All components with build-nudges-ref were ArgoCD-managed."
    fi
}

main "$@"
