#!/usr/bin/env bash
# Decide which board items each rollover phase should touch.
#
# Reads `gh project item-list --format json` output on stdin.
#
# Env:
#   CLOSED_ID     iterationId of the sprint that just ended (required)
#   CLOSED_START  that sprint's startDate, YYYY-MM-DD  (required)
#
# Writes TAB-separated decisions to stdout:
#   guard    <tripped|clear>
#   archive  <itemId>  <label>
#   collect  <itemId>  <label>
#   carry    <itemId>  <label>  <slips>
#
# Sprints are compared by iterationId and startDate, never by title:
# board history includes iterations named "Holiday iteration" and
# "Iteration 18", so titles do not sort chronologically.
#
# The guard is emitted but not enforced here — the caller decides. The
# remaining lines are still useful under --dry-run when the guard trips.
set -euo pipefail

: "${CLOSED_ID:?CLOSED_ID is required}"
: "${CLOSED_START:?CLOSED_START is required}"

jq -r --arg cid "$CLOSED_ID" --arg cstart "$CLOSED_START" '
  def fmt_label:
    if (.content.number // null) == null then .title
    else "\(.content.repository)#\(.content.number) — \(.title)"
    end;

  .items as $items
  | ( $items | map(select(.status == "Last Sprint")) ) as $last
  | ( $last | map(.sprint.iterationId == $cid) | any ) as $tripped
  | "guard\t" + (if $tripped then "tripped" else "clear" end),
    ( $last[]
      | "archive\t\(.id)\t\(fmt_label)" ),
    ( $items[]
      | select(.status == "Done")
      | select(.sprint != null and .sprint.startDate <= $cstart)
      | "collect\t\(.id)\t\(fmt_label)" ),
    ( $items[]
      | select(.status == "In progress" or .status == "In review")
      | select(.sprint != null and .sprint.iterationId == $cid)
      | "carry\t\(.id)\t\(fmt_label)\t\(.slips // 0)" )
'
