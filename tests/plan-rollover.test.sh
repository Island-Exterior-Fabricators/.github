#!/usr/bin/env bash
# Guard and phase-selection cases for scripts/lib/plan-rollover.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/assert.sh
source "$HERE/assert.sh"
FAILED=0

SCRIPT="$HERE/../scripts/lib/plan-rollover.sh"
FIXTURE="$HERE/fixtures/board-basic.json"

# Closing Sprint 33 (id i33, starting 2026-07-20).
run() { CLOSED_ID="${1:-i33}" CLOSED_START="${2:-2026-07-20}" \
        bash "$SCRIPT" <"$FIXTURE"; }
ids() { awk -F'\t' -v k="$2" '$1==k {print $2}' <<<"$1" | sort | tr '\n' ' '; }

echo "plan-rollover: guard is clear when no Last Sprint item is on i33"
out=$(run)
assert_eq "guard clear" "clear" \
  "$(awk -F'\t' '$1=="guard"{print $2}' <<<"$out")"

echo "plan-rollover: archive takes every Last Sprint item"
assert_eq "archive set" "it-ls-old " "$(ids "$out" archive)"

echo "plan-rollover: collect takes Done at or before the closed start"
assert_eq "collect set" "it-done-closed it-done-older " \
  "$(ids "$out" collect)"

echo "plan-rollover: carry takes unfinished items on the closed sprint"
assert_eq "carry set" "it-draft it-review-fresh it-wip-slipped " \
  "$(ids "$out" carry)"

echo "plan-rollover: slips default to 0 and are read when present"
assert_eq "slipped item reports 1" "1" \
  "$(awk -F'\t' '$1=="carry" && $2=="it-wip-slipped"{print $3}' <<<"$out")"
assert_eq "fresh item reports 0" "0" \
  "$(awk -F'\t' '$1=="carry" && $2=="it-review-fresh"{print $3}' <<<"$out")"

echo "plan-rollover: labels"
assert_eq "numbered label" \
  "Island-Exterior-Fabricators/IslandBOMApp#630 — Finished in the closed sprint" \
  "$(awk -F'\t' '$1=="collect" && $2=="it-done-closed"{print $3}' <<<"$out")"
assert_eq "draft label falls back to title" "A draft note with no number" \
  "$(awk -F'\t' '$1=="carry" && $2=="it-draft"{print $4}' <<<"$out")"

echo "plan-rollover: guard trips once Last Sprint holds a closed-sprint item"
tripped=$(jq '.items[0].sprint = {"iterationId":"i33","title":"Sprint 33","startDate":"2026-07-20","duration":12}' \
          "$FIXTURE" \
          | CLOSED_ID=i33 CLOSED_START=2026-07-20 bash "$SCRIPT")
assert_eq "guard tripped" "tripped" \
  "$(awk -F'\t' '$1=="guard"{print $2}' <<<"$tripped")"

echo "plan-rollover: required env"
if CLOSED_ID=i33 bash "$SCRIPT" <"$FIXTURE" >/dev/null 2>&1; then
  echo "  FAIL missing CLOSED_START should exit non-zero"
  FAILED=$((FAILED + 1))
else
  echo "  ok   missing CLOSED_START exits non-zero"
fi

exit $((FAILED > 0))
