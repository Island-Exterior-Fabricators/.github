#!/usr/bin/env bash
# Resolve sprint boundaries from a Sprint (iteration) field config.
#
# Reads the field's `configuration` object on stdin:
#   { "iterations":          [ { id, title, startDate, duration } ],
#     "completedIterations": [ { id, title, startDate, duration } ] }
#
# Env:
#   TODAY  YYYY-MM-DD (required)
#
# Writes key=value lines to stdout; the value is empty when undefined.
#
# Both lists are merged and re-classified against TODAY rather than
# trusting GitHub's own active/completed split: that split is decided
# server-side from the real date, so callers could not otherwise
# simulate a boundary. Iteration end is exclusive.
set -euo pipefail

: "${TODAY:?TODAY is required (YYYY-MM-DD)}"

jq -r --arg today "$TODAY" '
  def endd:
    (.startDate | strptime("%Y-%m-%d") | mktime)
    + (.duration * 86400) | strftime("%Y-%m-%d");

  [ (.iterations // []) + (.completedIterations // [])
    | .[] | . + { end: endd } ]
  | sort_by(.startDate) as $all
  | ( $all | map(select(.startDate <= $today and $today < .end)) | last )
      as $cur
  | ( $all | map(select(.end <= $today)) | last )   as $closed
  | ( $all | map(select(.end >  $today)) | first )  as $next
  | ( $all | last )                                 as $lastcfg
  | ( $all | map(select(.end >  $today)) | length ) as $remaining
  | "current_id=\($cur.id // "")",
    "current_title=\($cur.title // "")",
    "closed_id=\($closed.id // "")",
    "closed_title=\($closed.title // "")",
    "closed_start=\($closed.startDate // "")",
    "next_id=\($next.id // "")",
    "next_title=\($next.title // "")",
    "last_configured_title=\($lastcfg.title // "")",
    "last_configured_end=\($lastcfg.end // "")",
    "iterations_remaining=\($remaining)"
'
