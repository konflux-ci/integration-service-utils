#!/usr/bin/env bash
#
# run-tests.sh — offline tests for nudge-migrate.sh
#
# Uses a mock kubectl (tests/mock-kubectl/kubectl) and JSON fixtures, so no
# cluster is required. Run from anywhere:
#
#   bash nudge_migration/tests/run-tests.sh
#
set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$TESTS_DIR/../nudge-migrate.sh"
FIXTURES="$TESTS_DIR/fixtures"
MOCK_DIR="$TESTS_DIR/mock-kubectl"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
declare -a FAILURES=()
CASE_NAME=""
CASE_DIR=""
FIXTURE_DIR=""
BACKUP_DIR=""
OUTPUT=""
RC=0
EXTRA_ENV=()

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------
pass() { PASS=$((PASS + 1)); printf '   ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$CASE_NAME: $1"); printf '   FAIL %s\n' "$1"; }

begin_case() {
  CASE_NAME=$1
  CASE_DIR="$WORK/$CASE_NAME"
  FIXTURE_DIR="$CASE_DIR/fixtures"
  BACKUP_DIR="$CASE_DIR/backups"
  mkdir -p "$FIXTURE_DIR" "$BACKUP_DIR"
  cp "$FIXTURES/namespaces.txt" "$FIXTURE_DIR/"
  cp "$FIXTURES/components.json" "$FIXTURE_DIR/"
  cp "$FIXTURES/pipelineruns.json" "$FIXTURE_DIR/"
  : > "$CASE_DIR/calls.log"
  EXTRA_ENV=()
  printf '\n== %s\n' "$CASE_NAME"
}

use_config() {
  [[ "$1" == "none" ]] && return 0
  cp "$FIXTURES/nudgeconfig-$1.json" "$FIXTURE_DIR/nudgeconfig.json"
}

use_components() { cp "$FIXTURES/$1" "$FIXTURE_DIR/components.json"; }

use_pipelineruns() { cp "$FIXTURES/$1" "$FIXTURE_DIR/pipelineruns.json"; }

run_script() {
  OUTPUT=$(env \
    PATH="$MOCK_DIR:$PATH" \
    MOCK_FIXTURE_DIR="$FIXTURE_DIR" \
    MOCK_CALL_LOG="$CASE_DIR/calls.log" \
    ROLLBACK_SETTLE_SECONDS=0 \
    "${EXTRA_ENV[@]}" \
    bash "$SCRIPT" --context test-context "$@" 2>&1)
  RC=$?
  printf '%s\n' "$OUTPUT" > "$CASE_DIR/output.log"
}

assert_rc() {
  if [[ "$RC" -eq "$1" ]]; then pass "exit $1"; else fail "expected exit $1, got $RC"; fi
}

assert_output() {
  if grep -qF -- "$2" "$CASE_DIR/output.log"; then pass "$1"; else fail "$1 (output lacks '$2')"; fi
}

refute_output() {
  if grep -qF -- "$2" "$CASE_DIR/output.log"; then fail "$1 (output contains '$2')"; else pass "$1"; fi
}

call_count() {
  grep -cE "^$1( |\$)" "$CASE_DIR/calls.log" 2>/dev/null || true
}

assert_call_count() {
  local got
  got=$(call_count "$3")
  [[ -z "$got" ]] && got=0
  if [[ "$got" -eq "$2" ]]; then
    pass "$1"
  else
    fail "$1 (expected $2 '$3' call(s), got $got)"
  fi
}

assert_no_writes() {
  local writes
  writes=$(grep -cE '^(delete|annotate|create|replace)( |$)' "$CASE_DIR/calls.log" 2>/dev/null || true)
  [[ -z "$writes" ]] && writes=0
  if [[ "$writes" -eq 0 ]]; then pass "no mutating kubectl calls"; else fail "expected no mutating calls, got $writes"; fi
}

assert_delete_before_annotate() {
  local del ann
  del=$(grep -nE '^delete( |$)' "$CASE_DIR/calls.log" | head -1 | cut -d: -f1)
  ann=$(grep -nE '^annotate( |$)' "$CASE_DIR/calls.log" | head -1 | cut -d: -f1)
  if [[ -n "$del" && -n "$ann" && "$del" -lt "$ann" ]]; then
    pass "NudgeConfig delete logged before annotations are cleared"
  else
    fail "expected delete (line ${del:-none}) before annotate (line ${ann:-none})"
  fi
}

annotated_names() {
  grep -E '^annotate( |$)' "$CASE_DIR/calls.log" | awk '{print $3}' | sort
}

assert_annotated() {
  if annotated_names | grep -qx -- "$1"; then pass "cleared marker on $1"; else fail "missing marker clear on $1"; fi
}

assert_not_annotated() {
  if annotated_names | grep -qx -- "$1"; then fail "unexpected marker clear on $1"; else pass "left $1 alone"; fi
}

assert_file_contains_json() {
  local file=$1 filter=$2 expected=$3 desc=$4 got
  got=$(jq -r "$filter" "$file" 2>/dev/null)
  if [[ "$got" == "$expected" ]]; then pass "$desc"; else fail "$desc (expected '$expected', got '$got')"; fi
}

# ---------------------------------------------------------------------------
# 0. Syntax
# ---------------------------------------------------------------------------
printf '== script syntax\n'
if bash -n "$SCRIPT"; then pass "bash -n"; else fail "bash -n"; fi

# ---------------------------------------------------------------------------
# 1. Rollback, migration-created config, live run
# ---------------------------------------------------------------------------
begin_case "live rollback of a created config"
use_config created
run_script --rollback --backup-dir "$BACKUP_DIR" tenant-a
assert_rc 0
assert_call_count "deleted the NudgeConfig exactly once" 1 delete
assert_call_count "cleared the marker on exactly four builds" 4 annotate
assert_delete_before_annotate
for n in plr-pre-running plr-in-window plr-label-uppercase plr-annotation-event; do
  assert_annotated "$n"
done
for n in plr-pre-completed plr-non-push plr-no-component plr-is-only plr-after-window; do
  assert_not_annotated "$n"
done
assert_output "summary marks the namespace rolled back" "rolled-back"
assert_output "reports the pre-window exclusion" "1 annotated PLR(s) completed before"
assert_output "footer counts requeued builds" "Build PipelineRuns requeued: 4"
assert_output "warns when a requeued component has no build-nudges-ref" "will not nudge: comp2"
if grep -q "test.appstudio.openshift.io/component-nudge-processed" "$CASE_DIR/calls.log"; then
  fail "never touches the integration-service marker"
else
  pass "never touches the integration-service marker"
fi

backup_json=$(compgen -G "$BACKUP_DIR/tenant-a-nudge-config-*.json" | head -1)
if [[ -n "$backup_json" ]]; then
  pass "wrote a NudgeConfig backup"
  assert_file_contains_json "$backup_json" '.metadata.annotations["nudging.konflux-ci.dev/migrated-action"]' "created" "backup preserved migrated-action"
else
  fail "wrote a NudgeConfig backup"
fi
plr_list=$(compgen -G "$BACKUP_DIR/tenant-a-plrs-*.txt" | head -1)
if [[ -n "$plr_list" && "$(wc -l < "$plr_list")" -eq 4 ]]; then
  pass "wrote a four-entry PLR audit list"
else
  fail "wrote a four-entry PLR audit list"
fi

# ---------------------------------------------------------------------------
# 1b. No warning when every requeued component still has build-nudges-ref
# ---------------------------------------------------------------------------
begin_case "no missing-ref warning when all components nudge"
use_config created
use_components components-all-refs.json
run_script --rollback --backup-dir "$BACKUP_DIR" tenant-a
assert_rc 0
assert_call_count "still requeued four builds" 4 annotate
refute_output "did not warn about missing nudges" "will not nudge"

# ---------------------------------------------------------------------------
# 2. Dry run
# ---------------------------------------------------------------------------
begin_case "dry-run rollback"
use_config created
run_script --rollback --dry-run --backup-dir "$BACKUP_DIR" tenant-a
assert_rc 0
assert_no_writes
assert_output "previews the delete" "Would DELETE NudgeConfig"
assert_output "lists a selected build" "plr-in-window"
refute_output "does not list the pre-window build" "plr-pre-completed"
assert_output "summary marks dry-run rollback" "dry-run:rollback"
if compgen -G "$BACKUP_DIR/*.json" >/dev/null; then
  fail "dry run must not write a backup"
else
  pass "dry run wrote no backup"
fi

# ---------------------------------------------------------------------------
# 3. Ownership refusals
# ---------------------------------------------------------------------------
begin_case "refuse merged config without --force"
use_config merged
run_script --rollback --backup-dir "$BACKUP_DIR" tenant-a
assert_rc 1
assert_no_writes
assert_output "names the reason" "migrated-action=merged"
assert_output "suggests --force" "--force"

begin_case "refuse legacy config without --force"
use_config legacy
run_script --rollback --backup-dir "$BACKUP_DIR" tenant-a
assert_rc 1
assert_no_writes
assert_output "names the reason" "no migration markers"

begin_case "refuse owner mismatch without --force"
use_config owner-mismatch
run_script --rollback --backup-dir "$BACKUP_DIR" tenant-a
assert_rc 1
assert_no_writes
assert_output "names the owner mismatch" "owner label is 'someone-else'"

# ---------------------------------------------------------------------------
# 4. Forced rollback window derivation
# ---------------------------------------------------------------------------
begin_case "forced merged rollback uses migrated-at"
use_config merged
run_script --rollback --force --backup-dir "$BACKUP_DIR" tenant-a
assert_rc 0
assert_call_count "deleted the merged NudgeConfig" 1 delete
assert_call_count "requeued four builds" 4 annotate
refute_output "did not need --since" "pass --since"

begin_case "forced legacy rollback without a window is refused"
use_config legacy
run_script --rollback --force --backup-dir "$BACKUP_DIR" tenant-a
assert_rc 1
assert_no_writes
assert_output "asks for --since" "cannot derive the requeue window"
assert_output "names the legacy config rather than a missing one" "legacy or merged config"
refute_output "does not claim the NudgeConfig is absent" "no NudgeConfig, no backup"

begin_case "forced legacy rollback with --since"
use_config legacy
run_script --rollback --force --since 2026-11-01T00:00:00Z --backup-dir "$BACKUP_DIR" tenant-a
assert_rc 0
assert_call_count "deleted the legacy NudgeConfig" 1 delete
assert_call_count "requeued four builds" 4 annotate

# ---------------------------------------------------------------------------
# 5. NudgeConfig already gone (rerun)
# ---------------------------------------------------------------------------
begin_case "rerun with config already deleted and --since"
use_config none
EXTRA_ENV=(MOCK_NC_NOT_FOUND=true)
run_script --rollback --since 2026-11-01T00:00:00Z --backup-dir "$BACKUP_DIR" tenant-a
assert_rc 0
assert_call_count "no delete when config is absent" 0 delete
assert_call_count "still requeues four builds" 4 annotate
assert_output "reports the config as absent" "NudgeConfig already absent."

begin_case "rerun derives the window from the backup"
use_config none
# The first rollback ran after the in-window builds were created (Nov 2-3).
cp "$FIXTURES/nudgeconfig-created.json" "$BACKUP_DIR/tenant-a-nudge-config-20261104T000000Z.json"
EXTRA_ENV=(MOCK_NC_NOT_FOUND=true)
run_script --rollback --backup-dir "$BACKUP_DIR" tenant-a
assert_rc 0
assert_call_count "no delete when config is absent" 0 delete
assert_call_count "requeues four builds" 4 annotate
assert_output "reads the backup" "Requeue window derived from backup"
assert_output "ends the window at the original rollback time" "Requeue window ends at the original rollback time (2026-11-04T00:00:00Z)"

begin_case "rerun from a backup leaves builds nudged after the rollback alone"
use_config none
use_pipelineruns pipelineruns-post-rollback.json
cp "$FIXTURES/nudgeconfig-created.json" "$BACKUP_DIR/tenant-a-nudge-config-20261104T000000Z.json"
EXTRA_ENV=(MOCK_NC_NOT_FOUND=true)
run_script --rollback --backup-dir "$BACKUP_DIR" tenant-a
assert_rc 0
assert_call_count "requeues only the builds from the migration window" 4 annotate
assert_not_annotated "plr-post-rollback"
assert_output "footer does not count the post-rollback build" "Build PipelineRuns requeued: 4"

begin_case "rerun without a window is refused"
use_config none
EXTRA_ENV=(MOCK_NC_NOT_FOUND=true)
run_script --rollback --backup-dir "$BACKUP_DIR" tenant-a
assert_rc 1
assert_no_writes
assert_output "asks for --since" "cannot derive the requeue window"

# ---------------------------------------------------------------------------
# 6. Partial failures
# ---------------------------------------------------------------------------
begin_case "annotate failure keeps going and exits 1"
use_config created
EXTRA_ENV=(MOCK_ANNOTATE_FAIL_NAMES=plr-in-window)
run_script --rollback --backup-dir "$BACKUP_DIR" tenant-a
assert_rc 1
assert_call_count "attempted all four builds" 4 annotate
assert_annotated "plr-pre-running"
assert_output "summary reports the failure" "Cleared 3, failed 1"

begin_case "pruned PipelineRun is reported but not fatal"
use_config created
EXTRA_ENV=(MOCK_ANNOTATE_NOTFOUND_NAMES=plr-in-window)
run_script --rollback --backup-dir "$BACKUP_DIR" tenant-a
assert_rc 0
assert_output "reports the pruned build" "Pruned: 1"
assert_output "summary counts three requeued" "Requeued 3 PLRs."

begin_case "delete failure leaves annotations untouched"
use_config created
EXTRA_ENV=(MOCK_DELETE_EXIT=1)
run_script --rollback --backup-dir "$BACKUP_DIR" tenant-a
assert_rc 1
assert_call_count "did not clear any marker" 0 annotate
assert_output "explains the abort" "annotations left untouched"

# ---------------------------------------------------------------------------
# 7. Argument validation
# ---------------------------------------------------------------------------
begin_case "argument validation"
run_script --force tenant-a
assert_rc 2
run_script --rollback --since not-a-date tenant-a
assert_rc 2
run_script --rollback --no-backup --backup-dir "$BACKUP_DIR" tenant-a
assert_rc 2
run_script --rollback --since 2999-01-01T00:00:00Z tenant-a
assert_rc 2
assert_no_writes

# ---------------------------------------------------------------------------
# 8. Migration writes the rollback metadata
# ---------------------------------------------------------------------------
begin_case "migration records created metadata"
use_config none
EXTRA_ENV=(MOCK_NC_NOT_FOUND=true)
run_script tenant-a
assert_rc 0
written="$FIXTURE_DIR/last-written.json"
assert_file_contains_json "$written" '.metadata.annotations["nudging.konflux-ci.dev/migrated-action"]' "created" "wrote migrated-action=created"
assert_file_contains_json "$written" '.spec.nudges | length' "1" "wrote one nudge entry"
if jq -r '.metadata.annotations["nudging.konflux-ci.dev/migrated-at"]' "$written" \
     | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  pass "wrote an RFC3339 migrated-at"
else
  fail "wrote an RFC3339 migrated-at"
fi
assert_file_contains_json "$written" '.metadata.labels["nudging.konflux-ci.dev/owner"]' "build-service" "wrote the owner label"

begin_case "re-migration keeps created sticky"
use_config created
use_components components-new-edge.json
run_script tenant-a
assert_rc 0
written="$FIXTURE_DIR/last-written.json"
assert_file_contains_json "$written" '.metadata.annotations["nudging.konflux-ci.dev/migrated-action"]' "created" "kept migrated-action=created"
assert_file_contains_json "$written" '.metadata.annotations["nudging.konflux-ci.dev/migrated-at"]' "2026-11-01T00:00:00Z" "kept the original migrated-at"
assert_file_contains_json "$written" '.spec.nudges | length' "2" "added the new edge"

begin_case "merge into a legacy config records merged"
use_config legacy
use_components components-new-edge.json
run_script tenant-a
assert_rc 0
written="$FIXTURE_DIR/last-written.json"
assert_file_contains_json "$written" '.metadata.annotations["nudging.konflux-ci.dev/migrated-action"]' "merged" "wrote migrated-action=merged"
assert_file_contains_json "$written" '.spec.nudges | length' "2" "added the new edge"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo ""
echo "─────────────────────────────────────────────"
echo "passed: $PASS   failed: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "failures:"
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
exit 0
