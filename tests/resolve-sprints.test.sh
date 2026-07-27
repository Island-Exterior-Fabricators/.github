#!/usr/bin/env bash
# Boundary-date cases for scripts/lib/resolve-sprints.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/assert.sh
source "$HERE/assert.sh"
FAILED=0

SCRIPT="$HERE/../scripts/lib/resolve-sprints.sh"
FIXTURE="$HERE/fixtures/iterations-basic.json"

run_at() { TODAY="$1" bash "$SCRIPT" <"$FIXTURE"; }
field()  { grep -m1 "^$2=" <<<"$1" | cut -d= -f2-; }

echo "resolve-sprints: mid-sprint (2026-07-27)"
out=$(run_at 2026-07-27)
assert_eq "current is Sprint 33"  "Sprint 33" "$(field "$out" current_title)"
assert_eq "closed is Sprint 32"   "Sprint 32" "$(field "$out" closed_title)"
assert_eq "closed_start"          "2026-07-06" "$(field "$out" closed_start)"
assert_eq "next is Sprint 33"     "Sprint 33" "$(field "$out" next_title)"
assert_eq "3 iterations remain"   "3"         "$(field "$out" iterations_remaining)"

echo "resolve-sprints: first day of the gap (2026-08-01)"
out=$(run_at 2026-08-01)
assert_eq "no current sprint"     ""          "$(field "$out" current_title)"
assert_eq "closed is Sprint 33"   "Sprint 33" "$(field "$out" closed_title)"
assert_eq "closed_start"          "2026-07-20" "$(field "$out" closed_start)"
assert_eq "next is Sprint 34"     "Sprint 34" "$(field "$out" next_title)"
assert_eq "next id"               "i34"       "$(field "$out" next_id)"
assert_eq "2 iterations remain"   "2"         "$(field "$out" iterations_remaining)"

echo "resolve-sprints: second day of the gap (2026-08-02)"
out=$(run_at 2026-08-02)
assert_eq "still no current"      ""          "$(field "$out" current_title)"
assert_eq "closed still 33"       "Sprint 33" "$(field "$out" closed_title)"
assert_eq "next still 34"         "Sprint 34" "$(field "$out" next_title)"

echo "resolve-sprints: new sprint begins (2026-08-03)"
out=$(run_at 2026-08-03)
assert_eq "current is Sprint 34"  "Sprint 34" "$(field "$out" current_title)"
assert_eq "closed is Sprint 33"   "Sprint 33" "$(field "$out" closed_title)"
assert_eq "next equals current"   "Sprint 34" "$(field "$out" next_title)"

echo "resolve-sprints: runway reporting"
out=$(run_at 2026-07-27)
assert_eq "last configured"       "Sprint 35" \
  "$(field "$out" last_configured_title)"
assert_eq "last configured end"   "2026-08-29" \
  "$(field "$out" last_configured_end)"

echo "resolve-sprints: nothing completed yet"
out=$(echo '{"iterations":[{"id":"x","title":"S1","startDate":"2026-07-20","duration":12}],"completedIterations":[]}' \
      | TODAY=2026-07-21 bash "$SCRIPT")
assert_eq "closed empty"          ""          "$(field "$out" closed_title)"

echo "resolve-sprints: TODAY is required"
if TODAY= bash "$SCRIPT" <"$FIXTURE" >/dev/null 2>&1; then
  echo "  FAIL missing TODAY should exit non-zero"
  FAILED=$((FAILED + 1))
else
  echo "  ok   missing TODAY exits non-zero"
fi

exit $((FAILED > 0))
