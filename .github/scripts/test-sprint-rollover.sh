#!/usr/bin/env bash
# Fixture tests for sprint-rollover-lib.sh. No network.
#   bash .github/scripts/test-sprint-rollover.sh
set -euo pipefail

source "$(dirname "$0")/sprint-rollover-lib.sh"

FAILS=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "ok    $name"
  else
    echo "FAIL  $name"
    echo "      expected: $expected"
    echo "      actual:   $actual"
    FAILS=$((FAILS + 1))
  fi
}

# ── eastern_midnight_utc ────────────────────────────────────
check "EDT midnight" "2026-10-12T04:00:00Z" \
  "$(eastern_midnight_utc 2026-10-12)"
check "EST midnight" "2026-12-07T05:00:00Z" \
  "$(eastern_midnight_utc 2026-12-07)"
# Mondays right after the DST changes
check "after fall-back" "2026-11-02T05:00:00Z" \
  "$(eastern_midnight_utc 2026-11-02)"
check "after spring-forward" "2027-03-15T04:00:00Z" \
  "$(eastern_midnight_utc 2027-03-15)"

# ── eastern_today ───────────────────────────────────────────
check "late Sunday ET is still Sunday" "2026-10-11" \
  "$(eastern_today 2026-10-12T03:30:00Z)"
check "Monday 07:00Z is Monday" "2026-10-12" \
  "$(eastern_today 2026-10-12T07:00:00Z)"

# ── latest_started_sprint ───────────────────────────────────
ITERS='[
  {"title":"Sprint 37","startDate":"2026-09-14"},
  {"title":"Sprint 38","startDate":"2026-09-28"},
  {"title":"Sprint 39","startDate":"2026-10-12"},
  {"title":"Sprint 40","startDate":"2026-10-26"}
]'
check "mid-sprint" "Sprint 39" \
  "$(latest_started_sprint 2026-10-13 <<< "$ITERS" \
     | jq -r .title)"
check "start day counts" "Sprint 39" \
  "$(latest_started_sprint 2026-10-12 <<< "$ITERS" \
     | jq -r .title)"
check "weekend between sprints" "Sprint 38" \
  "$(latest_started_sprint 2026-10-11 <<< "$ITERS" \
     | jq -r .title)"
check "none started" "" \
  "$(latest_started_sprint 2026-01-01 <<< "$ITERS")"

# ── select_rollover ─────────────────────────────────────────
CUTOFF="2026-10-12T04:00:00Z"
ITEMS='[
  {"id":"A1","status":{"name":"Last Sprint",
    "updatedAt":"2026-09-28T18:33:00Z"},
   "content":{"number":717,"title":"Old",
    "repository":{"name":"IslandBOMApp"}}},
  {"id":"A2","status":{"name":"Last Sprint",
    "updatedAt":"2026-10-13T07:00:05Z"},
   "content":{"number":767,"title":"Moved today",
    "repository":{"name":"IslandBOMApp"}}},
  {"id":"D1","status":{"name":"Done",
    "updatedAt":"2026-10-09T14:06:00Z"},
   "content":{"number":767,"title":"Done Friday",
    "repository":{"name":"IslandBOMApp"}}},
  {"id":"D2","status":{"name":"Done",
    "updatedAt":"2026-10-12T03:59:59Z"},
   "content":{"number":5,"title":"Done Sunday night",
    "repository":{"name":"bom-manager-mcp-server"}}},
  {"id":"D3","status":{"name":"Done",
    "updatedAt":"2026-10-12T04:00:00Z"},
   "content":{"number":12,"title":"Done at the cutoff",
    "repository":{"name":"bom-manager-mcp-server"}}},
  {"id":"D4","status":{"name":"Done",
    "updatedAt":"2026-10-01T00:00:00Z"},
   "content":{"title":"A draft"}},
  {"id":"R1","status":{"name":"In review",
    "updatedAt":"2026-10-01T00:00:00Z"},
   "content":{"number":1,"title":"Open PR",
    "repository":{"name":"IslandBOMApp"}}},
  {"id":"N1","status":null,
   "content":{"number":2,"title":"No status",
    "repository":{"name":"IslandBOMApp"}}}
]'
SEL="$(select_rollover "$CUTOFF" <<< "$ITEMS")"
ids() { jq -r --arg k "$1" '[.[$k][].id] | join(",")' <<< "$SEL"; }

check "archive only pre-cutoff Last Sprint" "A1" "$(ids archive)"
check "move pre-cutoff Done, incl. draft" "D1,D2,D4" "$(ids move)"
check "keep Done at/after cutoff" "D3" "$(ids keep)"
check "issue label" "IslandBOMApp#717 Old" \
  "$(jq -r '.archive[0].label' <<< "$SEL")"
check "draft label" "(draft) A draft" \
  "$(jq -r '.move[] | select(.id == "D4") | .label' <<< "$SEL")"

echo
if ((FAILS)); then
  echo "$FAILS failed"
  exit 1
fi
echo "all passed"
