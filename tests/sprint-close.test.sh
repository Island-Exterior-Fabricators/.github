#!/usr/bin/env bash
# Orchestrator behaviour for scripts/sprint-close.sh: guard short-
# circuit, phase ordering, dry-run gating, and failure accounting —
# the parts that decide whether the wrong items get archived.
#
# Uses a fake `gh` on PATH (fixtures/sprint-close/bin/gh) that
# answers metadata/item-list reads from fixture files and records
# every mutation call to a log file instead of touching the network.
# No test here may make a real network call.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/assert.sh
source "$HERE/assert.sh"
FAILED=0

SCRIPT="$HERE/../scripts/sprint-close.sh"
FIXDIR="$HERE/fixtures/sprint-close"
FAKE_GH_BIN="$FIXDIR/bin"

META_CLEAR="$FIXDIR/meta-clear.json"
META_NO_NEXT="$FIXDIR/meta-no-next.json"
ITEMS_TRIPPED="$FIXDIR/items-tripped.json"
ITEMS_CLEAR="$FIXDIR/items-clear.json"
ITEMS_TAB_SLIPS="$FIXDIR/items-tab-slips.json"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# run <log-file> <extra-path> [VAR=value ...] -- runs the orchestrator
# with a fresh mutation log and the given PATH prefix / env overrides.
# Prints "EXIT=<code>" on its own line, then the captured combined
# stdout+stderr.
run() {
  local log="$1" extra_path="$2" out rc
  shift 2
  : >"$log"
  out=$(PATH="$extra_path:$PATH" \
        FAKE_GH_LOG="$log" \
        GH_TOKEN=fake-token ORG=fake-org PROJECT_NUMBER=1 \
        env "$@" bash "$SCRIPT" 2>&1)
  rc=$?
  printf 'EXIT=%s\n%s\n' "$rc" "$out"
}

exit_of() { awk -F= 'NR==1{print $2}' <<<"$1"; }
log_lines() { grep -c . "$1" 2>/dev/null || true; }

echo "sprint-close: guard tripped exits 0 with zero mutations"
LOG="$WORK/tripped.log"
out=$(run "$LOG" "$FAKE_GH_BIN" \
        FAKE_GH_META="$META_CLEAR" FAKE_GH_ITEMS="$ITEMS_TRIPPED" \
        TODAY=2026-08-01)
assert_eq "exit 0" "0" "$(exit_of "$out")"
assert_eq "zero mutations" "0" "$(log_lines "$LOG")"

echo "sprint-close: guard clear + DRY_RUN=true makes zero mutations"
LOG="$WORK/dryrun.log"
out=$(run "$LOG" "$FAKE_GH_BIN" \
        FAKE_GH_META="$META_CLEAR" FAKE_GH_ITEMS="$ITEMS_CLEAR" \
        TODAY=2026-08-01 DRY_RUN=true)
assert_eq "exit 0" "0" "$(exit_of "$out")"
assert_eq "zero mutations" "0" "$(log_lines "$LOG")"

echo "sprint-close: guard clear + live orders archive, then collect;" \
     "iteration before number per carried item"
LOG="$WORK/live.log"
out=$(run "$LOG" "$FAKE_GH_BIN" \
        FAKE_GH_META="$META_CLEAR" FAKE_GH_ITEMS="$ITEMS_CLEAR" \
        TODAY=2026-08-01 DRY_RUN=false)
assert_eq "exit 0" "0" "$(exit_of "$out")"
assert_eq "2 archives" "2" "$(awk -F'\t' '$1=="archive"' "$LOG" \
  | grep -c .)"
assert_eq "2 selects"  "2" "$(awk -F'\t' '$1=="select"' "$LOG" \
  | grep -c .)"
assert_eq "2 iterations" "2" "$(awk -F'\t' '$1=="iteration"' "$LOG" \
  | grep -c .)"
assert_eq "2 numbers" "2" "$(awk -F'\t' '$1=="number"' "$LOG" \
  | grep -c .)"
last_archive=$(grep -n $'^archive\t' "$LOG" | tail -1 | cut -d: -f1)
first_select=$(grep -n $'^select\t' "$LOG" | head -1 | cut -d: -f1)
assert_eq "last archive precedes first select" "1" \
  "$(( last_archive < first_select ))"
carry_ok=1
for id in FAKE_ITEM_CARRY_1 FAKE_ITEM_CARRY_2; do
  iter_line=$(grep -n $'^iteration\t'"$id"$'\t' "$LOG" | cut -d: -f1)
  num_line=$(grep -n $'^number\t'"$id"$'\t' "$LOG" | cut -d: -f1)
  [[ -n "$iter_line" && -n "$num_line" && "$iter_line" -lt "$num_line" ]] \
    || carry_ok=0
done
assert_eq "iteration precedes number per carried item" "1" "$carry_ok"

echo "sprint-close: one failed archive still attempts the rest and" \
     "still runs phases 2 and 3"
LOG="$WORK/fail.log"
out=$(run "$LOG" "$FAKE_GH_BIN" \
        FAKE_GH_META="$META_CLEAR" FAKE_GH_ITEMS="$ITEMS_CLEAR" \
        TODAY=2026-08-01 DRY_RUN=false \
        FAKE_GH_FAIL_ITEM=FAKE_ITEM_ARCH_1)
assert_eq "exit 1" "1" "$(exit_of "$out")"
assert_eq "both archives still attempted" "2" \
  "$(awk -F'\t' '$1=="archive"' "$LOG" | grep -c .)"
assert_eq "phase 2 still ran" "2" \
  "$(awk -F'\t' '$1=="select"' "$LOG" | grep -c .)"
assert_eq "phase 3 still ran" "2" \
  "$(awk -F'\t' '$1=="iteration"' "$LOG" | grep -c .)"

echo "sprint-close: next_id empty skips phase 3 but still mutates" \
     "phases 1 and 2"
LOG="$WORK/nonext.log"
out=$(run "$LOG" "$FAKE_GH_BIN" \
        FAKE_GH_META="$META_NO_NEXT" FAKE_GH_ITEMS="$ITEMS_CLEAR" \
        TODAY=2026-08-01 DRY_RUN=false)
assert_eq "exit 0" "0" "$(exit_of "$out")"
assert_eq "phase 1 still ran" "2" \
  "$(awk -F'\t' '$1=="archive"' "$LOG" | grep -c .)"
assert_eq "phase 2 still ran" "2" \
  "$(awk -F'\t' '$1=="select"' "$LOG" | grep -c .)"
assert_eq "phase 3 skipped" "0" \
  "$(awk -F'\t' '$1=="iteration" || $1=="number"' "$LOG" | grep -c .)"

echo "sprint-close: a CRLF-emitting jq leaves no \r in mutation args"
CRLF_BIN="$WORK/crlf-bin"
mkdir -p "$CRLF_BIN"
REAL_JQ="$(command -v jq)"
cat >"$CRLF_BIN/jq" <<'SHIM'
#!/usr/bin/env bash
# Wraps the real jq but re-emits its output with CRLF line endings,
# reproducing the jq.exe-on-Windows behaviour finding 7 regression-
# tests against (see the comment above the `S`-array build in
# scripts/sprint-close.sh).
"REAL_JQ_PATH" "$@" | awk '{printf "%s\r\n", $0}'
SHIM
sed -i "s#REAL_JQ_PATH#$REAL_JQ#" "$CRLF_BIN/jq"
chmod +x "$CRLF_BIN/jq"
LOG="$WORK/crlf.log"
out=$(run "$LOG" "$CRLF_BIN:$FAKE_GH_BIN" \
        FAKE_GH_META="$META_CLEAR" FAKE_GH_ITEMS="$ITEMS_CLEAR" \
        TODAY=2026-08-01 DRY_RUN=false)
assert_eq "exit 0" "0" "$(exit_of "$out")"
# `grep -c $'\r'` is unreliable here: on this platform its match
# behaviour differs depending on whether stdout is a pipe, so detect
# an embedded CR with a plain bash substring test instead. Append a
# sentinel byte first so command substitution's trailing-CRLF strip
# (see scripts/sprint-close.sh) can't hide a CR at end of file.
log_body="$(cat "$LOG"; printf x)"
if [[ "$log_body" == *$'\r'* ]]; then cr_found=1; else cr_found=0; fi
assert_eq "no \\r in any recorded mutation argument" "0" "$cr_found"

echo "sprint-close: DRY_RUN=1 exits 2 with zero mutations"
LOG="$WORK/badval.log"
out=$(run "$LOG" "$FAKE_GH_BIN" \
        FAKE_GH_META="$META_CLEAR" FAKE_GH_ITEMS="$ITEMS_CLEAR" \
        TODAY=2026-08-01 DRY_RUN=1)
assert_eq "exit 2" "2" "$(exit_of "$out")"
assert_eq "zero mutations" "0" "$(log_lines "$LOG")"

echo "sprint-close: a carry item whose title embeds a literal TAB" \
     "shifts the slips field; it is still re-stamped and Slips" \
     "written as 1, with no crash"
LOG="$WORK/tabslips.log"
out=$(run "$LOG" "$FAKE_GH_BIN" \
        FAKE_GH_META="$META_CLEAR" FAKE_GH_ITEMS="$ITEMS_TAB_SLIPS" \
        TODAY=2026-08-01 DRY_RUN=false)
assert_eq "exit 0" "0" "$(exit_of "$out")"
assert_eq "iteration still written" "1" \
  "$(awk -F'\t' '$1=="iteration"' "$LOG" | grep -c .)"
assert_eq "slips written as 1" "1" \
  "$(awk -F'\t' '$1=="number"{print $3}' "$LOG")"

exit $((FAILED > 0))
