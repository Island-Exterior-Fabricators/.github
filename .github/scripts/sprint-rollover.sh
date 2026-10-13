#!/usr/bin/env bash
# Rolls the project board over once a new sprint has started:
# archives Last Sprint cards, then moves Done cards into Last
# Sprint. Only cards whose status changed before the current
# sprint's Monday midnight (Eastern) are touched, so cards
# finished after the sprint ended stay in Done and a repeat
# run is a no-op. Spec:
#   docs/specs/2026-10-13-sprint-rollover-design.md
#
# Writes only when DRY_RUN=false. Local dry run:
#   bash .github/scripts/sprint-rollover.sh
set -euo pipefail

source "$(dirname "$0")/sprint-rollover-lib.sh"

ORG="Island-Exterior-Fabricators"
PROJECT_NUMBER=1
DRY_RUN="${DRY_RUN:-true}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# ── Project metadata ────────────────────────────────────────
META="$(gh api graphql -f query='
  query($org: String!, $number: Int!) {
    organization(login: $org) {
      projectV2(number: $number) {
        id
        status: field(name: "Status") {
          ... on ProjectV2SingleSelectField {
            id
            options { id name }
          }
        }
        sprint: field(name: "Sprint") {
          ... on ProjectV2IterationField {
            configuration {
              iterations { title startDate }
              completedIterations { title startDate }
            }
          }
        }
      }
    }
  }' -F org="$ORG" -F number="$PROJECT_NUMBER")"

P='.data.organization.projectV2'
PROJECT_ID="$(jq -r "$P.id // empty" <<< "$META")"
STATUS_FIELD_ID="$(jq -r "$P.status.id // empty" <<< "$META")"
OPTIONS="$(jq -c "$P.status.options // []" <<< "$META")"
ITERATIONS="$(jq -c "$P.sprint.configuration
  | (.iterations + .completedIterations) // empty" <<< "$META")"
need "$PROJECT_ID" "Project $ORG/$PROJECT_NUMBER"
need "$STATUS_FIELD_ID" "Status field"
need "$ITERATIONS" "Sprint iteration field"
LAST_SPRINT_ID="$(status_option_id "Last Sprint" <<< "$OPTIONS")"
# Selection matches Done by name; a renamed option would
# silently match nothing.
status_option_id "Done" <<< "$OPTIONS" > /dev/null

# ── Cutoff ──────────────────────────────────────────────────
TODAY="$(eastern_today)"
SPRINT="$(latest_started_sprint "$TODAY" <<< "$ITERATIONS")"
if [[ -z "$SPRINT" ]]; then
  echo "No sprint has started as of $TODAY; nothing to do"
  exit 0
fi
SPRINT_TITLE="$(jq -r .title <<< "$SPRINT")"
SPRINT_START="$(jq -r .startDate <<< "$SPRINT")"
CUTOFF="$(eastern_midnight_utc "$SPRINT_START")"
echo "Current sprint: $SPRINT_TITLE, cutoff $CUTOFF"

# ── Items (unarchived only) ─────────────────────────────────
ITEMS="$(gh api graphql --paginate -f query='
  query($org: String!, $number: Int!, $endCursor: String) {
    organization(login: $org) {
      projectV2(number: $number) {
        items(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            status: fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                updatedAt
              }
            }
            content {
              ... on Issue {
                number
                title
                repository { name }
              }
              ... on PullRequest {
                number
                title
                repository { name }
              }
              ... on DraftIssue { title }
            }
          }
        }
      }
    }
  }' -F org="$ORG" -F number="$PROJECT_NUMBER" \
  | jq -s "[.[] | $P.items.nodes[]]")"

SEL="$(select_rollover "$CUTOFF" <<< "$ITEMS")"

# ── Summary ─────────────────────────────────────────────────
# Written on exit, so a run that fails partway still records
# what it changed.
ARCHIVED=()
MOVED=()
mapfile -t KEPT < <(jq -r '.keep[].label' <<< "$SEL")

section() {
  local title="$1" label
  shift
  echo "### $title ($#)"
  (($#)) || echo "- (none)"
  for label in "$@"; do echo "- $label"; done
  echo
}
write_summary() {
  local status=$?
  {
    MODE="$([[ "$DRY_RUN" == "false" ]] && echo "" \
      || echo " (dry run, nothing changed)")"
    echo "## $SPRINT_TITLE rollover$MODE"
    echo
    if ((status)); then
      echo "**Failed partway.** Only the cards listed below were"
      echo "changed; the next run finishes the rest."
      echo
    fi
    echo "Cutoff: $CUTOFF (00:00 Eastern, $SPRINT_START)"
    echo
    section "Archived" "${ARCHIVED[@]}"
    section "Moved to Last Sprint" "${MOVED[@]}"
    section "Left in Done" "${KEPT[@]}"
  } >> "$SUMMARY"
}
trap write_summary EXIT

# ── Writes ──────────────────────────────────────────────────
archive_item() {
  gh api graphql -f query='
    mutation($projectId: ID!, $itemId: ID!) {
      archiveProjectV2Item(input: {
        projectId: $projectId
        itemId: $itemId
      }) { item { id } }
    }' -F projectId="$PROJECT_ID" \
       -F itemId="$1" > /dev/null
}
move_item() {
  gh api graphql -f query='
    mutation(
      $projectId: ID!, $itemId: ID!,
      $fieldId: ID!, $optionId: String!
    ) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $projectId
        itemId: $itemId
        fieldId: $fieldId
        value: { singleSelectOptionId: $optionId }
      }) { projectV2Item { id } }
    }' -F projectId="$PROJECT_ID" \
       -F itemId="$1" \
       -F fieldId="$STATUS_FIELD_ID" \
       -F optionId="$LAST_SPRINT_ID" > /dev/null
}

# Runs WRITE on each KEY card in $SEL (unless a dry run) and
# appends its label to the array named DONE.
apply() {
  local key="$1" write="$2" id label
  local -n done_labels="$3"
  while IFS=$'\t' read -r id label; do
    [[ -z "$id" ]] && continue
    echo "$key  $label"
    if [[ "$DRY_RUN" == "false" ]]; then
      "$write" "$id"
    fi
    done_labels+=("$label")
  done < <(jq -r --arg k "$key" \
    '.[$k][] | [.id, .label] | @tsv' <<< "$SEL")
}

apply archive archive_item ARCHIVED
apply move    move_item    MOVED
