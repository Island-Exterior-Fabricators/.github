# Pure helpers for sprint-rollover.sh. Sourced, not run.
# Tested by test-sprint-rollover.sh.

# US Eastern as a POSIX rule string. Git Bash on Windows has
# no zoneinfo, so `America/New_York` would silently mean UTC
# there; this string works everywhere.
EASTERN_TZ='EST5EDT,M3.2.0,M11.1.0'

# Eastern calendar date (YYYY-MM-DD) of an instant.
eastern_today() {
  TZ="$EASTERN_TZ" date -d "${1:-now}" +%F
}

# UTC instant of 00:00 Eastern on DATE.
eastern_midnight_utc() {
  local local_iso
  local_iso="$(TZ="$EASTERN_TZ" date -d "$1 00:00" -Iseconds)"
  date -u -d "$local_iso" +%FT%TZ
}

# Fails with an Actions error annotation naming WHAT when
# VALUE is empty, so a renamed field or option is diagnosable.
need() {
  local value="$1" what="$2"
  if [[ -z "$value" ]]; then
    echo "::error::$what not found" >&2
    return 1
  fi
}

# stdin: [{id, name}]. Prints the id of the one Status option
# called NAME; fails if there is none or more than one.
status_option_id() {
  local name="$1" ids
  ids="$(jq -c --arg n "$name" '[.[] | select(.name == $n) | .id]')"
  case "$(jq length <<< "$ids")" in
    1) jq -r '.[0]' <<< "$ids" ;;
    0) echo "::error::Status option '$name' not found" >&2
       return 1 ;;
    *) echo "::error::Status option '$name' is not unique" >&2
       return 1 ;;
  esac
}

# stdin: [{title, startDate}]. Prints the latest one that has
# started by TODAY, or nothing. Unlike project-assign-sprint,
# which wants the sprint in progress, this stays on the last
# sprint through the weekend gap: the cutoff is its start.
latest_started_sprint() {
  jq -c --arg today "$1" '
    [.[] | select(.startDate <= $today)]
    | max_by(.startDate) // empty'
}

# stdin: [{id, status: {name, updatedAt}, content}].
# Prints {archive, move, keep}, each [{id, label}]. Timestamps
# are all ISO-8601 UTC, so string order is time order. Items
# whose content the token can't read come back empty.
select_rollover() {
  jq -c --arg cutoff "$1" '
    def card_label:
      if (.content // {}) == {} then
        "(no access) \(.id)"
      elif .content.repository then
        "\(.content.repository.name)#\(.content.number)"
        + " \(.content.title)"
      else
        "(draft) \(.content.title // "untitled")"
      end;
    def pick(name; when):
      [ .[]
        | select(.status.name == name)
        | select(.status.updatedAt | when)
        | {id, label: card_label} ];
    { archive: pick("Last Sprint"; . <  $cutoff),
      move:    pick("Done";        . <  $cutoff),
      keep:    pick("Done";        . >= $cutoff) }'
}
