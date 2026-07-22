#!/bin/bash
#
# nudge-migrate.sh — One-time migration of build-nudges-ref → NudgeConfig
#
# Reads Component.spec.build-nudges-ref across tenant namespaces and
# creates or merges NudgeConfig CRDs (ADR-0067 Phase 2).
#
# Requirements: kubectl >= 1.24, jq >= 1.6, bash >= 4.0
#
set -euo pipefail

readonly NUDGE_CONFIG_NAME="nudge-config"
readonly NUDGE_CONFIG_API_VERSION="appstudio.redhat.com/v1beta2"
readonly NUDGE_CONFIG_KIND="NudgeConfig"
readonly MAX_NUDGES=256
readonly MAX_RETRIES=3

readonly MIGRATION_LABEL_KEY="nudging.konflux-ci.dev/owner"
readonly MIGRATION_LABEL_VALUE="build-service"
readonly MIGRATION_ANNOTATION_KEY="nudging.konflux-ci.dev/migrated-from"
readonly MIGRATION_ANNOTATION_VALUE="build-nudges-ref"

readonly TENANT_LABELS=(
  "toolchain.dev.openshift.com/type=tenant"
  "konflux.ci/type=user"
  "konflux-ci.dev/type=tenant"
)

DRY_RUN=false
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
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [NAMESPACE...]

Migrate Component.spec.build-nudges-ref to NudgeConfig CRDs.

Options:
  --dry-run    Print what would change without writing anything
  --help       Show this help message

Arguments:
  NAMESPACE    One or more namespaces to process (default: all tenant namespaces)

Examples:
  $(basename "$0") --dry-run                         # Dry-run all tenant namespaces
  $(basename "$0") --dry-run my-tenant-ns             # Dry-run a specific namespace
  $(basename "$0") my-tenant-ns-1 my-tenant-ns-2     # Migrate specific namespaces
  $(basename "$0")                                    # Migrate all tenant namespaces
EOF
  exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)  DRY_RUN=true; shift ;;
      --help|-h)  usage ;;
      -*)         log_error "Unknown flag: $1"; usage 2 ;;
      *)          TARGET_NAMESPACES+=("$1"); shift ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
check_prerequisites() {
  local missing=false
  for cmd in kubectl jq; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "Required command not found: $cmd"
      missing=true
    fi
  done
  $missing && exit 1

  if ! kubectl api-resources --api-group=appstudio.redhat.com 2>/dev/null | grep -q nudgeconfig; then
    log_error "NudgeConfig CRD not found — ensure STONEINTG-1659/1660 is deployed"
    exit 1
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
    if ns_output=$(kubectl get namespaces -l "$label" \
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
    '{
      apiVersion: "appstudio.redhat.com/v1beta2",
      kind: "NudgeConfig",
      metadata: {
        name: "nudge-config",
        namespace: $ns,
        labels: { "nudging.konflux-ci.dev/owner": "build-service" },
        annotations: { "nudging.konflux-ci.dev/migrated-from": "build-nudges-ref" }
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
  if output=$(echo "$manifest" | kubectl create -f - 2>&1); then
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
    if ! existing=$(kubectl get "nudgeconfigs.appstudio.redhat.com" \
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
      '
      .spec.nudges = $nudges |
      .metadata.labels = ((.metadata.labels // {}) + {"nudging.konflux-ci.dev/owner": "build-service"}) |
      .metadata.annotations = ((.metadata.annotations // {}) + {"nudging.konflux-ci.dev/migrated-from": "build-nudges-ref"})
      ')

    local output
    if output=$(echo "$updated" | kubectl replace -f - 2>&1); then
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
  if ! components_json=$(kubectl get components.appstudio.redhat.com \
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
  if existing_nc=$(kubectl get "nudgeconfigs.appstudio.redhat.com" \
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
# Print summary
# ---------------------------------------------------------------------------
print_summary() {
  local prefix=""
  $DRY_RUN && prefix="[DRY RUN] "

  local created=0 updated=0 skipped=0 errored=0 total_mig=0

  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "${prefix}Migration Summary"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  printf "  %-45s %-16s %-7s %-9s %s\n" "NAMESPACE" "ACTION" "FOUND" "MIGRATED" "DETAIL"
  echo "  ─────────────────────────────────────────────────────────────────────────────"

  for entry in "${SUMMARIES[@]}"; do
    IFS='|' read -r ns action found migrated detail <<< "$entry"
    printf "  %-45s %-16s %-7s %-9s %s\n" "$ns" "$action" "$found" "$migrated" "$detail"

    case "$action" in
      created|dry-run:create) created=$((created + 1)); total_mig=$((total_mig + migrated)) ;;
      updated|dry-run:update) updated=$((updated + 1)); total_mig=$((total_mig + migrated)) ;;
      skipped|dry-run:skip)   skipped=$((skipped + 1)) ;;
      error)                  errored=$((errored + 1)) ;;
    esac
  done

  echo "  ─────────────────────────────────────────────────────────────────────────────"
  echo "${prefix}  Namespaces: ${#SUMMARIES[@]} total — $created created, $updated updated, $skipped skipped, $errored errors"
  echo "${prefix}  Relationships migrated: $total_mig"
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
    migrate_namespace "$ns"
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
