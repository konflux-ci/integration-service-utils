#!/bin/bash
#
# nudge-migrate.sh — One-time migration of build-nudges-ref → NudgeConfig
#
# Reads Component.spec.build-nudges-ref across tenant namespaces and
# creates or merges NudgeConfig CRDs (ADR-0067 Phase 2).
#
# --rollback reverses the migration: it deletes a migration-owned NudgeConfig
# and clears the build-service nudge marker from build PipelineRuns that were
# skipped during the migration window, so build-service nudges them again
# (STONEINTG-1906).
#
# Requirements: kubectl >= 1.24, jq >= 1.6, bash >= 4.0, GNU date
#
set -euo pipefail

readonly NUDGE_CONFIG_NAME="nudge-config"
readonly NUDGE_CONFIG_API_VERSION="appstudio.redhat.com/v1beta2"
readonly NUDGE_CONFIG_KIND="NudgeConfig"
readonly MAX_NUDGES=4096
readonly MAX_RETRIES=3

readonly MIGRATION_LABEL_KEY="nudging.konflux-ci.dev/owner"
readonly MIGRATION_LABEL_VALUE="build-service"
readonly MIGRATION_ANNOTATION_KEY="nudging.konflux-ci.dev/migrated-from"
readonly MIGRATION_ANNOTATION_VALUE="build-nudges-ref"
readonly MIGRATED_AT_ANNOTATION="nudging.konflux-ci.dev/migrated-at"
readonly MIGRATED_ACTION_ANNOTATION="nudging.konflux-ci.dev/migrated-action"

# build-service's marker on build PipelineRuns. It is set both when build-service
# skips a build (NudgeConfig present) and after a successful nudge, so the time
# window is what distinguishes an orphaned build from an already-nudged one.
readonly BUILD_NUDGE_ANNOTATION="build.appstudio.openshift.io/component-nudge-processed"
# integration-service's own idempotency marker — never touched by rollback.
readonly IS_NUDGE_ANNOTATION="test.appstudio.openshift.io/component-nudge-processed"

readonly BUILD_PLR_SELECTOR="pipelines.appstudio.openshift.io/type=build,appstudio.openshift.io/component"
readonly DEFAULT_BACKUP_DIR="./nudge-migrate-backups"
readonly ROLLBACK_SETTLE_SECONDS="${ROLLBACK_SETTLE_SECONDS:-5}"

readonly TENANT_LABELS=(
  "toolchain.dev.openshift.com/type=tenant"
  "konflux.ci/type=user"
  "konflux-ci.dev/type=tenant"
)

DRY_RUN=false
ROLLBACK=false
FORCE=false
NO_BACKUP=false
BACKUP_DIR_SET=false
CONTEXT=""
SINCE_TS=""
BACKUP_DIR="$DEFAULT_BACKUP_DIR"
RUN_TS=""
WINDOW_START=""
WINDOW_END=""
EXCLUDED_TOTAL=0
declare -a TARGET_NAMESPACES=()
declare -a SUMMARIES=()
LAST_ADDED_COUNT=0

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }
log_dry()   { echo "[DRY RUN] $*"; }

# ---------------------------------------------------------------------------
# kubectl wrapper (honours --context)
# ---------------------------------------------------------------------------
kc() {
  if [[ -n "$CONTEXT" ]]; then
    kubectl --context "$CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

# ---------------------------------------------------------------------------
# Timestamp normalisation
# ---------------------------------------------------------------------------
rfc3339() {
  local raw=$1 out
  out=$(date -u -d "$raw" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 1
  echo "$out"
}

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--context CTX] [NAMESPACE...]
       $(basename "$0") --rollback [--dry-run] [--force] [--since RFC3339]
                        [--backup-dir DIR | --no-backup] [--context CTX] [NAMESPACE...]

Migrate Component.spec.build-nudges-ref to NudgeConfig CRDs.
With --rollback, delete a migration-owned NudgeConfig and requeue the build
PipelineRuns that build-service marked as nudge-processed during the migration.

Options:
  --dry-run             Print what would change without writing anything
  --context CTX         kubeconfig context to use (default: current context)
  --help                Show this help message

Rollback options:
  --rollback            Roll back the migration instead of performing it
  --force               Delete a NudgeConfig that is not provably migration-created
                        (merged/legacy/owner mismatch). Requires --since unless the
                        config carries a migrated-at annotation.
  --since RFC3339       Override the requeue window start (default: migrated-at or
                        the NudgeConfig creationTimestamp)
  --backup-dir DIR      Where to save the pre-delete backup (default: $DEFAULT_BACKUP_DIR)
  --no-backup           Do not write a backup before deleting
  --force/--since/--backup-dir/--no-backup are valid only with --rollback.

Arguments:
  NAMESPACE             One or more namespaces to process (default: all tenant namespaces)

Examples:
  $(basename "$0") --dry-run                         # Dry-run all tenant namespaces
  $(basename "$0") --dry-run my-tenant-ns             # Dry-run a specific namespace
  $(basename "$0") my-tenant-ns-1 my-tenant-ns-2     # Migrate specific namespaces
  $(basename "$0")                                    # Migrate all tenant namespaces
  $(basename "$0") --rollback --dry-run my-tenant-ns  # Preview a rollback
  $(basename "$0") --rollback my-tenant-ns            # Roll back a migration
EOF
  exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)    DRY_RUN=true; shift ;;
      --rollback)   ROLLBACK=true; shift ;;
      --force)      FORCE=true; shift ;;
      --no-backup)  NO_BACKUP=true; shift ;;
      --context)
        [[ $# -ge 2 ]] || { log_error "--context requires an argument"; usage 2; }
        CONTEXT=$2; shift 2 ;;
      --since)
        [[ $# -ge 2 ]] || { log_error "--since requires an argument"; usage 2; }
        SINCE_TS=$2; shift 2 ;;
      --backup-dir)
        [[ $# -ge 2 ]] || { log_error "--backup-dir requires an argument"; usage 2; }
        BACKUP_DIR=$2; BACKUP_DIR_SET=true; shift 2 ;;
      --help|-h)    usage ;;
      -*)           log_error "Unknown flag: $1"; usage 2 ;;
      *)            TARGET_NAMESPACES+=("$1"); shift ;;
    esac
  done

  if ! $ROLLBACK; then
    $FORCE       && { log_error "--force requires --rollback"; usage 2; }
    $NO_BACKUP   && { log_error "--no-backup requires --rollback"; usage 2; }
    [[ -n "$SINCE_TS" ]] && { log_error "--since requires --rollback"; usage 2; }
    $BACKUP_DIR_SET && { log_error "--backup-dir requires --rollback"; usage 2; }
  fi

  if $NO_BACKUP && $BACKUP_DIR_SET; then
    log_error "--backup-dir and --no-backup are mutually exclusive"
    usage 2
  fi

  if [[ -n "$SINCE_TS" ]]; then
    local normalized
    normalized=$(rfc3339 "$SINCE_TS") \
      || { log_error "--since is not a valid timestamp: $SINCE_TS (expected RFC3339)"; exit 2; }
    if [[ "$normalized" > "$(now_ts)" ]]; then
      log_error "--since is in the future: $normalized"
      exit 2
    fi
    SINCE_TS=$normalized
  fi

  if [[ ! "$ROLLBACK_SETTLE_SECONDS" =~ ^[0-9]+$ ]]; then
    log_error "ROLLBACK_SETTLE_SECONDS must be a whole number of seconds"
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
check_prerequisites() {
  local missing=false
  for cmd in kubectl jq date; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "Required command not found: $cmd"
      missing=true
    fi
  done
  $missing && exit 1

  # Capture before matching: piping straight into `grep -q` makes grep exit on
  # first match, and the SIGPIPE that kills kubectl surfaces as exit 141 under
  # `set -o pipefail` — reporting the CRD as missing when it is present.
  local api_resources kubectl_err
  kubectl_err=$(mktemp)
  if ! api_resources=$(kc api-resources --api-group=appstudio.redhat.com 2>"$kubectl_err"); then
    log_error "Failed to query API resources: $(cat "$kubectl_err")"
    rm -f "$kubectl_err"
    exit 1
  fi
  rm -f "$kubectl_err"

  if ! grep -q nudgeconfig <<<"$api_resources"; then
    if $ROLLBACK; then
      log_warn "NudgeConfig CRD not found — requeueing annotated PipelineRuns anyway"
    else
      log_error "NudgeConfig CRD not found — ensure STONEINTG-1659/1660 is deployed"
      exit 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# Namespace discovery
# ---------------------------------------------------------------------------
discover_tenant_namespaces() {
  local -A seen=()
  local ns_list=()
  local discovery_errors=0

  for label in "${TENANT_LABELS[@]}"; do
    local kubectl_err ns_output
    kubectl_err=$(mktemp)
    if ns_output=$(kc get namespaces -l "$label" \
                     -o jsonpath='{.items[*].metadata.name}' 2>"$kubectl_err"); then
      while IFS= read -r ns; do
        [[ -z "$ns" ]] && continue
        if [[ -z "${seen[$ns]+x}" ]]; then
          seen[$ns]=1
          ns_list+=("$ns")
        fi
      done <<< "$(echo "$ns_output" | tr ' ' '\n')"
    else
      log_error "Failed to list namespaces with label $label: $(cat "$kubectl_err")"
      discovery_errors=$((discovery_errors + 1))
    fi
    rm -f "$kubectl_err"
  done

  if (( discovery_errors == ${#TENANT_LABELS[@]} )); then
    log_error "All namespace discovery queries failed — check RBAC permissions for namespaces/list"
    exit 1
  elif (( discovery_errors > 0 )); then
    log_warn "$discovery_errors of ${#TENANT_LABELS[@]} namespace discovery queries failed"
  fi

  if [[ ${#ns_list[@]} -eq 0 ]]; then
    TARGET_NAMESPACES=()
    return
  fi

  IFS=$'\n' read -r -d '' -a TARGET_NAMESPACES < <(printf '%s\n' "${ns_list[@]}" | sort && printf '\0') || true
  log_info "Discovered ${#TARGET_NAMESPACES[@]} tenant namespace(s)"
}

# ---------------------------------------------------------------------------
# Build a NudgeConfig JSON manifest
# ---------------------------------------------------------------------------
build_nudge_config() {
  local namespace=$1
  local nudges_json=$2

  jq -n \
    --arg ns "$namespace" \
    --argjson nudges "$nudges_json" \
    --arg migrated_at "$RUN_TS" \
    '{
      apiVersion: "appstudio.redhat.com/v1beta2",
      kind: "NudgeConfig",
      metadata: {
        name: "nudge-config",
        namespace: $ns,
        labels: { "nudging.konflux-ci.dev/owner": "build-service" },
        annotations: {
          "nudging.konflux-ci.dev/migrated-from": "build-nudges-ref",
          "nudging.konflux-ci.dev/migrated-at": $migrated_at,
          "nudging.konflux-ci.dev/migrated-action": "created"
        }
      },
      spec: { nudges: $nudges }
    }'
}

# ---------------------------------------------------------------------------
# Merge incoming nudges into an existing set
# Output: JSON { merged: [...], added: N }
# ---------------------------------------------------------------------------
merge_nudges() {
  local existing_json=$1
  local incoming_json=$2

  jq -n \
    --argjson existing "$existing_json" \
    --argjson incoming "$incoming_json" \
    '
    ($existing | map("\(.from)->\(.to)")) as $keys |
    ($incoming | map(select("\(.from)->\(.to)" | IN($keys[]) | not))) as $new |
    { merged: ($existing + $new), added: ($new | length) }
    '
}

# ---------------------------------------------------------------------------
# DAG cycle detection (DFS in jq)
# Returns 0 if acyclic, 1 if a cycle exists
# ---------------------------------------------------------------------------
detect_cycles() {
  local nudges_json=$1

  local result
  result=$(echo "$nudges_json" | jq -r '
    reduce .[] as $e ({}; .[$e.from] = ((.[$e.from] // []) + [$e.to])) |
    . as $adj |
    # DFS with iterative stack; state: 0=white 1=gray 2=black
    keys | reduce .[] as $start (
      { state: {}, has_cycle: false };
      if .has_cycle then .
      elif (.state[$start] // 0) != 0 then .
      else
        .state[$start] = 1 |
        .stack = [{ node: $start, idx: 0 }] |
        until((.stack | length) == 0 or .has_cycle;
          .stack[-1] as $top |
          ($adj[$top.node] // []) as $nbrs |
          if $top.idx >= ($nbrs | length) then
            .state[$top.node] = 2 |
            .stack = .stack[:-1]
          else
            $nbrs[$top.idx] as $next |
            .stack[-1].idx = ($top.idx + 1) |
            if (.state[$next] // 0) == 1 then .has_cycle = true
            elif (.state[$next] // 0) == 0 then
              .state[$next] = 1 |
              .stack = .stack + [{ node: $next, idx: 0 }]
            else .
            end
          end
        ) |
        del(.stack)
      end
    ) |
    if .has_cycle then "cycle" else "ok" end
  ')

  [[ "$result" == "ok" ]]
}

# ---------------------------------------------------------------------------
# Create NudgeConfig (with AlreadyExists → merge fallback)
# Sets LAST_ADDED_COUNT on success
# ---------------------------------------------------------------------------
create_nudge_config() {
  local namespace=$1
  local nudges_json=$2
  local nudge_count
  nudge_count=$(echo "$nudges_json" | jq 'length')

  local manifest
  manifest=$(build_nudge_config "$namespace" "$nudges_json")

  local output
  if output=$(echo "$manifest" | kc create -f - 2>&1); then
    log_info "Created NudgeConfig in $namespace ($nudge_count entries)"
    LAST_ADDED_COUNT=$nudge_count
    return 0
  fi

  if echo "$output" | grep -qi "AlreadyExists"; then
    log_warn "NudgeConfig appeared in $namespace between check and create, falling back to merge"
    update_nudge_config "$namespace" "$nudges_json"
    return $?
  fi

  log_error "Failed to create NudgeConfig in $namespace: $output"
  return 1
}

# ---------------------------------------------------------------------------
# Update NudgeConfig with retry-on-conflict
# Re-fetches, re-merges, and re-validates on each attempt.
# Sets LAST_ADDED_COUNT on success
# ---------------------------------------------------------------------------
update_nudge_config() {
  local namespace=$1
  local incoming_json=$2
  local attempt=0

  while (( attempt < MAX_RETRIES )); do
    attempt=$((attempt + 1))

    local existing kubectl_err
    kubectl_err=$(mktemp)
    if ! existing=$(kc get "nudgeconfigs.appstudio.redhat.com" \
                      "$NUDGE_CONFIG_NAME" -n "$namespace" -o json 2>"$kubectl_err"); then
      log_error "Failed to fetch NudgeConfig in $namespace (attempt $attempt): $(cat "$kubectl_err")"
      rm -f "$kubectl_err"
      return 1
    fi
    rm -f "$kubectl_err"

    local existing_nudges
    existing_nudges=$(echo "$existing" | jq '.spec.nudges // []')

    local merge_result
    merge_result=$(merge_nudges "$existing_nudges" "$incoming_json")

    local added
    added=$(echo "$merge_result" | jq '.added')

    if [[ "$added" -eq 0 ]]; then
      log_info "All relationships already present in $namespace, nothing to update"
      LAST_ADDED_COUNT=0
      return 0
    fi

    local merged
    merged=$(echo "$merge_result" | jq '.merged')

    local merged_count
    merged_count=$(echo "$merged" | jq 'length')
    if (( merged_count > MAX_NUDGES )); then
      log_error "Merged NudgeConfig in $namespace would have $merged_count entries (max $MAX_NUDGES)"
      return 1
    fi

    if ! detect_cycles "$merged"; then
      log_error "Merged NudgeConfig in $namespace would introduce a cycle, skipping"
      return 1
    fi

    local updated
    updated=$(echo "$existing" | jq \
      --argjson nudges "$merged" \
      --arg migrated_at "$RUN_TS" \
      '
      .spec.nudges = $nudges |
      (.metadata.annotations // {}) as $a |
      .metadata.labels = ((.metadata.labels // {}) + {"nudging.konflux-ci.dev/owner": "build-service"}) |
      .metadata.annotations = ($a + {
        "nudging.konflux-ci.dev/migrated-from": "build-nudges-ref",
        "nudging.konflux-ci.dev/migrated-at":
          ($a["nudging.konflux-ci.dev/migrated-at"] // $migrated_at),
        "nudging.konflux-ci.dev/migrated-action":
          (if $a["nudging.konflux-ci.dev/migrated-action"] == "created" then "created" else "merged" end)
      })
      ')

    local output
    if output=$(echo "$updated" | kc replace -f - 2>&1); then
      log_info "Updated NudgeConfig in $namespace ($added new entries)"
      LAST_ADDED_COUNT=$added
      return 0
    fi

    if echo "$output" | grep -qi "conflict\|the object has been modified"; then
      log_warn "Conflict updating NudgeConfig in $namespace (attempt $attempt/$MAX_RETRIES), retrying..."
      continue
    fi

    log_error "Failed to update NudgeConfig in $namespace: $output"
    return 1
  done

  log_error "Exhausted $MAX_RETRIES retries updating NudgeConfig in $namespace"
  return 1
}

# ---------------------------------------------------------------------------
# Migrate a single namespace
# ---------------------------------------------------------------------------
migrate_namespace() {
  local namespace=$1

  local components_json kubectl_err
  kubectl_err=$(mktemp)
  if ! components_json=$(kc get components.appstudio.redhat.com \
                           -n "$namespace" -o json 2>"$kubectl_err"); then
    log_error "Failed to list Components in $namespace: $(cat "$kubectl_err")"
    rm -f "$kubectl_err"
    SUMMARIES+=("$namespace|error|0|0|Failed to list Components")
    return
  fi
  rm -f "$kubectl_err"

  local component_count
  component_count=$(echo "$components_json" | jq '.items | length')

  if [[ "$component_count" -eq 0 ]]; then
    log_info "No Components in $namespace, skipping"
    SUMMARIES+=("$namespace|skipped|0|0|No Components")
    return
  fi

  # ---- collect relationships ----
  local existing_names
  existing_names=$(echo "$components_json" | jq '[.items[].metadata.name]')

  local raw_relationships
  raw_relationships=$(echo "$components_json" | jq '[
    .items[] |
    .metadata.name as $from |
    (.spec."build-nudges-ref" // [])[] |
    { from: $from, to: . }
  ]')

  local total_found
  total_found=$(echo "$raw_relationships" | jq 'length')

  if [[ "$total_found" -eq 0 ]]; then
    log_info "No build-nudges-ref entries in $namespace, skipping"
    SUMMARIES+=("$namespace|skipped|0|0|No build-nudges-ref entries")
    return
  fi

  # ---- filter ----
  local self_count dangling_count
  self_count=$(echo "$raw_relationships" | jq '[.[] | select(.from == .to)] | length')
  dangling_count=$(echo "$raw_relationships" | jq --argjson names "$existing_names" \
    '[.[] | select(.from != .to) | select(.to | IN($names[]) | not)] | length')

  if (( self_count > 0 )); then
    log_warn "Filtered $self_count self-nudge(s) in $namespace"
  fi
  if (( dangling_count > 0 )); then
    while IFS= read -r line; do
      log_warn "Filtered dangling reference in $namespace: $line"
    done < <(echo "$raw_relationships" | jq -r --argjson names "$existing_names" \
      '.[] | select(.from != .to) | select(.to | IN($names[]) | not) | "\(.from) → \(.to)"')
  fi

  local filtered
  filtered=$(echo "$raw_relationships" | jq --argjson names "$existing_names" '
    map(select(.from != .to)) |
    map(select(.to | IN($names[]))) |
    unique_by("\(.from)->\(.to)") |
    map(. + { mode: "immediate" })
  ')

  local nudge_count
  nudge_count=$(echo "$filtered" | jq 'length')

  if [[ "$nudge_count" -eq 0 ]]; then
    log_info "All $total_found relationships in $namespace were filtered out, skipping"
    SUMMARIES+=("$namespace|skipped|$total_found|0|All entries filtered")
    return
  fi

  # ---- validate ----
  if (( nudge_count > MAX_NUDGES )); then
    log_error "Too many nudge relationships in $namespace: $nudge_count (max $MAX_NUDGES)"
    SUMMARIES+=("$namespace|error|$total_found|0|Exceeds max $MAX_NUDGES entries")
    return
  fi

  if ! detect_cycles "$filtered"; then
    log_error "Cycle detected in nudge graph for $namespace, skipping"
    SUMMARIES+=("$namespace|error|$total_found|0|Cycle detected in graph")
    return
  fi

  # ---- create or merge ----
  local existing_nc nc_err
  nc_err=$(mktemp)
  if existing_nc=$(kc get "nudgeconfigs.appstudio.redhat.com" \
                     "$NUDGE_CONFIG_NAME" -n "$namespace" -o json 2>"$nc_err"); then
    rm -f "$nc_err"
    # NudgeConfig exists → merge
    local existing_nudges
    existing_nudges=$(echo "$existing_nc" | jq '.spec.nudges // []')

    local merge_result
    merge_result=$(merge_nudges "$existing_nudges" "$filtered")
    local added
    added=$(echo "$merge_result" | jq '.added')

    if [[ "$added" -eq 0 ]]; then
      log_info "All relationships already present in $namespace, skipping"
      SUMMARIES+=("$namespace|skipped|$total_found|0|All entries already present")
      return
    fi

    if $DRY_RUN; then
      log_dry "Would UPDATE NudgeConfig in $namespace ($added new entries):"
      echo "$filtered" | jq -r --argjson existing "$existing_nudges" \
        '($existing | map("\(.from)->\(.to)")) as $keys |
         .[] | select("\(.from)->\(.to)" | IN($keys[]) | not) |
         "  + \(.from) → \(.to)"'
      SUMMARIES+=("$namespace|dry-run:update|$total_found|$added|Would add $added entries")
      return
    fi

    if update_nudge_config "$namespace" "$filtered"; then
      if [[ "$LAST_ADDED_COUNT" -eq 0 ]]; then
        SUMMARIES+=("$namespace|skipped|$total_found|0|All entries already present")
      else
        SUMMARIES+=("$namespace|updated|$total_found|$LAST_ADDED_COUNT|Added $LAST_ADDED_COUNT entries")
      fi
    else
      SUMMARIES+=("$namespace|error|$total_found|0|Update failed")
    fi
  else
    local nc_err_msg
    nc_err_msg=$(cat "$nc_err")
    rm -f "$nc_err"

    if ! echo "$nc_err_msg" | grep -qi "not found\|NotFound"; then
      log_error "Failed to get NudgeConfig in $namespace: $nc_err_msg"
      SUMMARIES+=("$namespace|error|$total_found|0|Failed to get NudgeConfig")
      return
    fi

    # NudgeConfig does not exist → create
    if $DRY_RUN; then
      log_dry "Would CREATE NudgeConfig in $namespace with $nudge_count entries:"
      echo "$filtered" | jq -r '.[] | "  + \(.from) → \(.to)"'
      SUMMARIES+=("$namespace|dry-run:create|$total_found|$nudge_count|Would create with $nudge_count entries")
      return
    fi

    if create_nudge_config "$namespace" "$filtered"; then
      SUMMARIES+=("$namespace|created|$total_found|$LAST_ADDED_COUNT|Created with $LAST_ADDED_COUNT entries")
    else
      SUMMARIES+=("$namespace|error|$total_found|0|Create failed")
    fi
  fi
}

# ---------------------------------------------------------------------------
# Rollback: select the build PipelineRuns affected during the window
# Output: JSON { selected: [...], pre_window_excluded: N }
# ---------------------------------------------------------------------------
rollback_select_plrs() {
  local namespace=$1
  local start_ts=$2
  local end_ts=$3

  local plrs_json kubectl_err
  kubectl_err=$(mktemp)
  if ! plrs_json=$(kc get pipelineruns.tekton.dev -n "$namespace" \
                     -l "$BUILD_PLR_SELECTOR" -o json 2>"$kubectl_err"); then
    log_error "Failed to list PipelineRuns in $namespace: $(cat "$kubectl_err")"
    rm -f "$kubectl_err"
    return 1
  fi
  rm -f "$kubectl_err"

  echo "$plrs_json" | jq \
    --arg start "$start_ts" \
    --arg end "$end_ts" \
    '
    def epoch:
      if . == null then null
      else (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601)
      end;
    ($start | epoch) as $s |
    ($end | epoch) as $e |
    def affected($p):
      ($p.metadata.labels // {}) as $l |
      ($p.metadata.annotations // {}) as $a |
      select((($l["appstudio.openshift.io/component"] // "") | length) > 0) |
      select(($l["pipelines.appstudio.openshift.io/type"] // "") == "build") |
      select(((($l["pipelinesascode.tekton.dev/event-type"] //
                 $a["pipelinesascode.tekton.dev/event-type"] // "") | ascii_downcase)
              | . == "push" or . == "incoming")) |
      select((($a["build.appstudio.openshift.io/component-nudge-processed"] // "") | length) > 0) |
      {
        name: $p.metadata.name,
        component: $l["appstudio.openshift.io/component"],
        created: $p.metadata.creationTimestamp,
        completed: ($p.status.completionTime // null),
        c: ($p.metadata.creationTimestamp | epoch),
        d: ($p.status.completionTime | epoch)
      };
    [ .items[] | affected(.) ] as $all |
    {
      selected: [ $all[] | select(.c != null and .c <= $e
                                  and (.d == null or .d >= $s or .c >= $s)) ],
      pre_window_excluded: ([ $all[] | select(.c != null and .c < $s
                                                and .d != null and .d < $s) ] | length)
    }
    '
}

# ---------------------------------------------------------------------------
# Rollback: warn when a requeued build's component no longer nudges anything
# (build-service only nudges while Component.spec.build-nudges-ref is set)
# ---------------------------------------------------------------------------
rollback_warn_missing_refs() {
  local namespace=$1
  local components_json=$2

  local comps_json
  if ! comps_json=$(kc get components.appstudio.redhat.com -n "$namespace" \
                      -o json 2>/dev/null); then
    return 0
  fi

  local missing
  missing=$(echo "$comps_json" | jq -r --argjson wanted "$components_json" '
    [ .items[]
      | .metadata.name as $n
      | select(((.spec["build-nudges-ref"] // []) | length) == 0)
      | select($wanted | index($n))
      | $n ] | unique | .[]' 2>/dev/null || true)

  if [[ -n "$missing" ]]; then
    log_warn "$namespace: these components have no build-nudges-ref, so requeueing" \
             "their builds will not nudge: $(echo "$missing" | tr '\n' ' ' | sed 's/ $//')"
  fi
}

# ---------------------------------------------------------------------------
# Rollback: clear the build-service marker from one PipelineRun
# Returns 0 cleared, 2 already gone (pruned), 1 error
# ---------------------------------------------------------------------------
rollback_clear_annotations() {
  local namespace=$1
  local name=$2

  local err msg
  err=$(mktemp)
  if kc annotate pipelinerun "$name" "${BUILD_NUDGE_ANNOTATION}-" \
       -n "$namespace" >/dev/null 2>"$err"; then
    rm -f "$err"
    return 0
  fi

  msg=$(cat "$err")
  rm -f "$err"
  if echo "$msg" | grep -qi "not found\|NotFound"; then
    log_warn "PipelineRun $name in $namespace no longer exists (pruned?)"
    return 2
  fi
  log_error "Failed to clear $BUILD_NUDGE_ANNOTATION on $name in $namespace: $msg"
  return 1
}

# ---------------------------------------------------------------------------
# Rollback: find the latest backup for a namespace (for window derivation)
# ---------------------------------------------------------------------------
latest_backup_for() {
  local namespace=$1
  local -a backups=("$BACKUP_DIR/${namespace}-nudge-config-"*.json)
  [[ -e "${backups[0]}" ]] || return 1
  printf '%s\n' "${backups[@]}" | sort | tail -n 1
}

# ---------------------------------------------------------------------------
# Rollback: read the run timestamp encoded in a backup file name
# (${ns}-nudge-config-YYYYMMDDTHHMMSSZ.json) as RFC3339.
# Returns 1 when the name does not carry a parsable timestamp.
# ---------------------------------------------------------------------------
backup_timestamp() {
  local file=$1 base stamp
  base=$(basename "$file")
  stamp=$(sed -nE 's/.*-nudge-config-([0-9]{8}T[0-9]{6}Z)\.json$/\1/p' <<<"$base")
  [[ -n "$stamp" ]] || return 1
  date -u -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:9:2}:${stamp:11:2}:${stamp:13:2}Z" \
    +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# ---------------------------------------------------------------------------
# Rollback a single namespace
# ---------------------------------------------------------------------------
rollback_namespace() {
  local namespace=$1

  WINDOW_END=$(now_ts)

  # ---- read NudgeConfig ----
  local config_json="" config_err nc_exists=true
  config_err=$(mktemp)
  if ! config_json=$(kc get nudgeconfigs.appstudio.redhat.com \
                       "$NUDGE_CONFIG_NAME" -n "$namespace" -o json 2>"$config_err"); then
    local err_msg
    err_msg=$(cat "$config_err")
    rm -f "$config_err"
    if echo "$err_msg" | grep -qi "not found\|NotFound"; then
      nc_exists=false
      config_json=""
    else
      log_error "Failed to get NudgeConfig in $namespace: $err_msg"
      SUMMARIES+=("$namespace|error|0|0|Failed to get NudgeConfig")
      return
    fi
  else
    rm -f "$config_err"
  fi

  # ---- ownership preflight ----
  local config_rv="" migrated_action="" migrated_at="" config_created=""
  if $nc_exists; then
    config_rv=$(echo "$config_json" | jq -r '.metadata.resourceVersion // ""')
    migrated_action=$(echo "$config_json" | jq -r --arg k "$MIGRATED_ACTION_ANNOTATION" \
      '.metadata.annotations[$k] // ""')
    migrated_at=$(echo "$config_json" | jq -r --arg k "$MIGRATED_AT_ANNOTATION" \
      '.metadata.annotations[$k] // ""')
    config_created=$(echo "$config_json" | jq -r '.metadata.creationTimestamp // ""')
    local owner
    owner=$(echo "$config_json" | jq -r --arg k "$MIGRATION_LABEL_KEY" \
      '.metadata.labels[$k] // ""')

    local refuse_reason=""
    if [[ "$migrated_action" != "created" ]]; then
      if [[ "$migrated_action" == "merged" ]]; then
        refuse_reason="NudgeConfig was merged into a pre-existing resource (migrated-action=merged)"
      elif [[ -z "$migrated_action" ]]; then
        refuse_reason="NudgeConfig has no migration markers (legacy or foreign config)"
      else
        refuse_reason="unexpected migrated-action=$migrated_action"
      fi
    elif [[ "$owner" != "$MIGRATION_LABEL_VALUE" ]]; then
      refuse_reason="owner label is '${owner:-<none>}', expected '$MIGRATION_LABEL_VALUE'"
    fi

    if [[ -n "$refuse_reason" ]] && ! $FORCE; then
      log_error "$namespace: refusing to delete NudgeConfig — $refuse_reason"
      log_error "Nothing was changed. Re-run with --force (and --since) if this config should be removed."
      SUMMARIES+=("$namespace|error|0|0|Refused: $refuse_reason")
      return
    fi
    if [[ -n "$refuse_reason" ]]; then
      log_warn "$namespace: $refuse_reason — proceeding because --force was given"
    fi
  fi

  # ---- derive requeue window ----
  WINDOW_START=""
  if [[ -n "$SINCE_TS" ]]; then
    WINDOW_START=$SINCE_TS
  elif [[ -n "$migrated_at" ]]; then
    if ! WINDOW_START=$(rfc3339 "$migrated_at"); then
      log_error "$namespace: migrated-at annotation is not a valid timestamp: $migrated_at — pass --since"
      SUMMARIES+=("$namespace|error|0|0|Invalid migrated-at; pass --since")
      return
    fi
  elif $nc_exists && [[ "$migrated_action" == "created" ]]; then
    WINDOW_START=$config_created
  fi

  if [[ -z "$WINDOW_START" ]] && ! $nc_exists; then
    local backup_file
    if backup_file=$(latest_backup_for "$namespace"); then
      WINDOW_START=$(jq -r --arg k "$MIGRATED_AT_ANNOTATION" \
        '.metadata.annotations[$k] // .metadata.creationTimestamp // ""' \
        "$backup_file" 2>/dev/null || true)
      if [[ -n "$WINDOW_START" ]]; then
        if ! WINDOW_START=$(rfc3339 "$WINDOW_START"); then
          WINDOW_START=""
        fi
      fi
      if [[ -n "$WINDOW_START" ]]; then
        # End the window at the original rollback, not at "now": builds created
        # after the NudgeConfig was deleted were never skipped, so they were
        # nudged normally and re-marked by build-service. Requeueing them on a
        # rerun would nudge them a second time.
        local rollback_ts
        if rollback_ts=$(backup_timestamp "$backup_file"); then
          if [[ "$rollback_ts" < "$WINDOW_END" ]]; then
            WINDOW_END=$rollback_ts
            log_info "Requeue window ends at the original rollback time ($WINDOW_END)," \
                     "so builds nudged afterwards are not requeued again"
          fi
        else
          log_warn "$namespace: cannot read the rollback time from $backup_file —" \
                   "using now as the window end; pass --since to narrow it"
        fi
        log_info "Requeue window derived from backup $backup_file"
      fi
    fi
  fi

  if [[ -z "$WINDOW_START" ]]; then
    if $nc_exists; then
      log_error "$namespace: cannot derive the requeue window — the NudgeConfig has no" \
                "migrated-at annotation and migrated-action is '${migrated_action:-<none>}'" \
                "(legacy or merged config); pass --since"
    else
      log_error "$namespace: cannot derive the requeue window (no NudgeConfig, no backup, no --since)"
    fi
    SUMMARIES+=("$namespace|error|0|0|Cannot derive window; pass --since")
    return
  fi

  if [[ "$WINDOW_START" > "$WINDOW_END" ]]; then
    log_error "$namespace: requeue window start $WINDOW_START is after the window end" \
              "$WINDOW_END — pass --since"
    SUMMARIES+=("$namespace|error|0|0|Window start is after the window end")
    return
  fi

  # ---- select affected build PLRs ----
  local selection selected_count excluded_count
  if ! selection=$(rollback_select_plrs "$namespace" "$WINDOW_START" "$WINDOW_END"); then
    SUMMARIES+=("$namespace|error|0|0|Failed to list PipelineRuns")
    return
  fi
  selected_count=$(echo "$selection" | jq '.selected | length')
  excluded_count=$(echo "$selection" | jq '.pre_window_excluded')
  EXCLUDED_TOTAL=$((EXCLUDED_TOTAL + excluded_count))

  if (( excluded_count > 0 )); then
    log_info "$namespace: $excluded_count annotated PLR(s) completed before $WINDOW_START were left alone (use --since to widen)"
  fi

  if (( selected_count > 0 )); then
    local selected_components
    selected_components=$(echo "$selection" | jq -c '[.selected[].component] | unique')
    rollback_warn_missing_refs "$namespace" "$selected_components"
  fi

  # ---- dry run ----
  if $DRY_RUN; then
    if $nc_exists; then
      log_dry "Would DELETE NudgeConfig $NUDGE_CONFIG_NAME in $namespace"
    else
      log_dry "NudgeConfig $NUDGE_CONFIG_NAME is already absent in $namespace"
    fi
    log_dry "Would clear $BUILD_NUDGE_ANNOTATION on $selected_count build PipelineRun(s) created since $WINDOW_START:"
    echo "$selection" | jq -r '
      .selected[] |
      "  - \(.name)  component=\(.component)  created=\(.created)  completed=\(.completed // "running")"'
    SUMMARIES+=("$namespace|dry-run:rollback|$selected_count|$selected_count|Would delete NudgeConfig and requeue $selected_count PLRs")
    return
  fi

  # ---- re-check the NudgeConfig has not changed (TOCTOU) ----
  if $nc_exists; then
    local fresh_json fresh_err fresh_rv
    fresh_err=$(mktemp)
    if ! fresh_json=$(kc get nudgeconfigs.appstudio.redhat.com \
                        "$NUDGE_CONFIG_NAME" -n "$namespace" -o json 2>"$fresh_err"); then
      local fresh_msg
      fresh_msg=$(cat "$fresh_err")
      rm -f "$fresh_err"
      if echo "$fresh_msg" | grep -qi "not found\|NotFound"; then
        log_info "NudgeConfig in $namespace disappeared before deletion, continuing"
        nc_exists=false
      else
        log_error "Failed to re-read NudgeConfig in $namespace: $fresh_msg"
        SUMMARIES+=("$namespace|error|$selected_count|0|Re-read failed; nothing changed")
        return
      fi
    else
      rm -f "$fresh_err"
      fresh_rv=$(echo "$fresh_json" | jq -r '.metadata.resourceVersion // ""')
      if [[ "$fresh_rv" != "$config_rv" ]]; then
        log_error "$namespace: NudgeConfig changed during rollback (resourceVersion $config_rv -> $fresh_rv); re-run"
        SUMMARIES+=("$namespace|error|$selected_count|0|NudgeConfig changed during rollback")
        return
      fi
      config_json=$fresh_json
    fi
  fi

  # ---- backup ----
  local stamp=${RUN_TS//[-:]/}
  if ! $NO_BACKUP; then
    if ! mkdir -p "$BACKUP_DIR"; then
      log_error "$namespace: cannot create backup directory $BACKUP_DIR — nothing was changed"
      SUMMARIES+=("$namespace|error|$selected_count|0|Backup directory unavailable")
      return
    fi
    local backup_file="$BACKUP_DIR/${namespace}-nudge-config-${stamp}.json"
    if $nc_exists; then
      if ! echo "$config_json" | jq '.' > "$backup_file"; then
        log_error "$namespace: failed to write backup $backup_file — nothing was changed"
        SUMMARIES+=("$namespace|error|$selected_count|0|Backup failed")
        return
      fi
      log_info "Backed up NudgeConfig to $backup_file"
    fi
    local plr_file="$BACKUP_DIR/${namespace}-plrs-${stamp}.txt"
    if ! echo "$selection" | jq -r '.selected[].name' > "$plr_file"; then
      log_error "$namespace: failed to write PLR list $plr_file — nothing was changed"
      SUMMARIES+=("$namespace|error|$selected_count|0|Backup failed")
      return
    fi
  fi

  # ---- delete the NudgeConfig first ----
  local delete_note
  if $nc_exists; then
    local del_err
    del_err=$(mktemp)
    if ! kc delete nudgeconfigs.appstudio.redhat.com "$NUDGE_CONFIG_NAME" \
         -n "$namespace" --ignore-not-found --timeout=30s >/dev/null 2>"$del_err"; then
      local del_msg
      del_msg=$(cat "$del_err")
      rm -f "$del_err"
      log_error "Failed to delete NudgeConfig in $namespace: $del_msg — annotations left untouched"
      SUMMARIES+=("$namespace|error|$selected_count|0|Delete failed; annotations untouched")
      return
    fi
    rm -f "$del_err"
    delete_note="Deleted NudgeConfig."
    log_info "Deleted NudgeConfig in $namespace"
    if (( selected_count > 0 && ROLLBACK_SETTLE_SECONDS > 0 )); then
      log_info "Waiting ${ROLLBACK_SETTLE_SECONDS}s for build-service to observe the deletion"
      sleep "$ROLLBACK_SETTLE_SECONDS"
    fi
  else
    delete_note="NudgeConfig already absent."
  fi

  # ---- clear build-service markers ----
  local cleared=0 failed=0 pruned=0 name rc
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    rc=0
    rollback_clear_annotations "$namespace" "$name" || rc=$?
    case $rc in
      0) cleared=$((cleared + 1)) ;;
      2) pruned=$((pruned + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac
  done < <(echo "$selection" | jq -r '.selected[].name')

  local pruned_note=""
  if (( pruned > 0 )); then
    pruned_note=" Pruned: $pruned."
  fi

  if (( failed > 0 )); then
    SUMMARIES+=("$namespace|error|$selected_count|$cleared|$delete_note Cleared $cleared, failed $failed.$pruned_note")
  elif (( selected_count == 0 )); then
    if $nc_exists; then
      SUMMARIES+=("$namespace|rolled-back|0|0|$delete_note No affected build PLRs in window")
    else
      SUMMARIES+=("$namespace|skipped|0|0|No NudgeConfig and no affected PLRs")
    fi
  else
    SUMMARIES+=("$namespace|rolled-back|$selected_count|$cleared|$delete_note Requeued $cleared PLRs.$pruned_note")
  fi
}

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
print_summary() {
  local prefix=""
  $DRY_RUN && prefix="[DRY RUN] "

  local created=0 updated=0 skipped=0 errored=0 rolled_back=0 total_mig=0

  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "${prefix}Migration Summary"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  if $ROLLBACK; then
    printf "  %-45s %-16s %-7s %-9s %s\n" "NAMESPACE" "ACTION" "PLRS" "REQUEUED" "DETAIL"
  else
    printf "  %-45s %-16s %-7s %-9s %s\n" "NAMESPACE" "ACTION" "FOUND" "MIGRATED" "DETAIL"
  fi
  echo "  ─────────────────────────────────────────────────────────────────────────────"

  for entry in "${SUMMARIES[@]}"; do
    IFS='|' read -r ns action found migrated detail <<< "$entry"
    printf "  %-45s %-16s %-7s %-9s %s\n" "$ns" "$action" "$found" "$migrated" "$detail"

    case "$action" in
      created|dry-run:create)       created=$((created + 1)); total_mig=$((total_mig + migrated)) ;;
      updated|dry-run:update)       updated=$((updated + 1)); total_mig=$((total_mig + migrated)) ;;
      rolled-back|dry-run:rollback) rolled_back=$((rolled_back + 1)); total_mig=$((total_mig + migrated)) ;;
      skipped|dry-run:skip)         skipped=$((skipped + 1)) ;;
      error)                        errored=$((errored + 1)) ;;
    esac
  done

  echo "  ─────────────────────────────────────────────────────────────────────────────"
  if $ROLLBACK; then
    echo "${prefix}  Namespaces: ${#SUMMARIES[@]} total — $rolled_back rolled back, $skipped skipped, $errored errors"
    echo "${prefix}  Build PipelineRuns requeued: $total_mig (pre-window annotated PLRs excluded: $EXCLUDED_TOTAL)"
  else
    echo "${prefix}  Namespaces: ${#SUMMARIES[@]} total — $created created, $updated updated, $skipped skipped, $errored errors"
    echo "${prefix}  Relationships migrated: $total_mig"
  fi
  echo "═══════════════════════════════════════════════════════════════════════════════"

  if (( errored > 0 )); then
    echo ""
    echo "${prefix}Namespaces with errors:"
    for entry in "${SUMMARIES[@]}"; do
      IFS='|' read -r ns action _ _ detail <<< "$entry"
      [[ "$action" == "error" ]] && echo "  - $ns: $detail"
    done
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  check_prerequisites

  RUN_TS=$(now_ts)
  WINDOW_END=$RUN_TS

  if $ROLLBACK; then
    log_info "Running in ROLLBACK mode — migration-owned NudgeConfigs will be deleted"
    log_info "and affected builds requeued (build-service re-nudges them)."
  fi
  $DRY_RUN && log_info "Running in DRY RUN mode — no changes will be written"

  if [[ ${#TARGET_NAMESPACES[@]} -eq 0 ]]; then
    log_info "No namespaces specified, discovering tenant namespaces..."
    discover_tenant_namespaces
  else
    log_info "Processing ${#TARGET_NAMESPACES[@]} specified namespace(s)"
  fi

  if [[ ${#TARGET_NAMESPACES[@]} -eq 0 ]]; then
    log_info "No tenant namespaces found, nothing to do"
    exit 0
  fi

  for ns in "${TARGET_NAMESPACES[@]}"; do
    if $ROLLBACK; then
      rollback_namespace "$ns"
    else
      migrate_namespace "$ns"
    fi
  done

  print_summary

  for entry in "${SUMMARIES[@]}"; do
    IFS='|' read -r _ action _ _ _ <<< "$entry"
    if [[ "$action" == "error" ]]; then
      exit 1
    fi
  done
}

main "$@"
