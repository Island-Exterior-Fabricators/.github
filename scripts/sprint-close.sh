#!/usr/bin/env bash
# Roll the project board over at sprint close.
#
#   phase 1  archive everything in Last Sprint
#   phase 2  move Done items at or before the closed sprint into it
#   phase 3  carry unfinished closed-sprint items to the next sprint,
#            incrementing Slips
#
# Phase 1 must precede phase 2 or it would archive what phase 2 moves in.
#
# Every phase is idempotent: phase 1 on an empty column is a no-op,
# phase 2 re-runs sweep genuinely late work, and phase 3 cannot
# double-count because an item stops matching once re-stamped.
#
# Env:
#   GH_TOKEN         required
#   ORG              default Island-Exterior-Fabricators
#   PROJECT_NUMBER   default 1
#   DRY_RUN          true|false, default false
#   TODAY            YYYY-MM-DD, default current UTC date
set -euo pipefail

ORG="${ORG:-Island-Exterior-Fabricators}"
PROJECT_NUMBER="${PROJECT_NUMBER:-1}"
DRY_RUN="${DRY_RUN:-false}"
TODAY="${TODAY:-$(date -u +%Y-%m-%d)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failures=0

# ── project + field metadata ────────────────────────────────────────
META=$(gh api graphql -f query='
  query($org: String!, $number: Int!) {
    organization(login: $org) {
      projectV2(number: $number) {
        id
        fields(first: 30) {
          nodes {
            ... on ProjectV2Field { id name }
            ... on ProjectV2SingleSelectField {
              id name options { id name }
            }
            ... on ProjectV2IterationField {
              id name
              configuration {
                iterations { id title startDate duration }
                completedIterations { id title startDate duration }
              }
            }
          }
        }
      }
    }
  }' -F org="$ORG" -F number="$PROJECT_NUMBER")

P=$(jq -r '.data.organization.projectV2' <<<"$META")

field_id() {
  jq -r --arg n "$1" \
    '.fields.nodes[] | select(.name==$n) | .id // empty' <<<"$P"
}

PROJECT_ID=$(jq -r '.id' <<<"$P")
STATUS_FIELD_ID=$(field_id Status)
SPRINT_FIELD_ID=$(field_id Sprint)
SLIPS_FIELD_ID=$(field_id Slips)
LAST_SPRINT_OPTION_ID=$(jq -r '
  .fields.nodes[] | select(.name=="Status")
  | .options[] | select(.name=="Last Sprint") | .id // empty' <<<"$P")

for v in PROJECT_ID STATUS_FIELD_ID SPRINT_FIELD_ID SLIPS_FIELD_ID \
         LAST_SPRINT_OPTION_ID; do
  if [[ -z "${!v}" || "${!v}" == "null" ]]; then
    echo "sprint-close: could not resolve $v" >&2
    exit 2
  fi
done

# ── sprint boundaries ───────────────────────────────────────────────
declare -A S
while IFS='=' read -r k v; do
  [[ -n "$k" ]] && S["$k"]="$v"
done < <(jq -c '.fields.nodes[] | select(.name=="Sprint") | .configuration' \
           <<<"$P" | TODAY="$TODAY" "$HERE/lib/resolve-sprints.sh" \
           | tr -d '\r')

echo "today=$TODAY current=${S[current_title]:-none}" \
     "closed=${S[closed_title]:-none} next=${S[next_title]:-none}"

if [[ -z "${S[closed_id]:-}" ]]; then
  echo "No sprint has completed as of $TODAY; nothing to roll over."
  exit 0
fi

# ── plan ────────────────────────────────────────────────────────────
ITEMS=$(gh project item-list "$PROJECT_NUMBER" --owner "$ORG" \
          --format json --limit 500)

PLAN=$(CLOSED_ID="${S[closed_id]}" CLOSED_START="${S[closed_start]}" \
       "$HERE/lib/plan-rollover.sh" <<<"$ITEMS" | tr -d '\r')

if [[ "$(awk -F'\t' '$1=="guard"{print $2}' <<<"$PLAN")" == "tripped" ]]
then
  echo "Rollover for ${S[closed_title]} has already run; nothing to do."
  exit 0
fi

[[ "$DRY_RUN" == "true" ]] && echo "DRY RUN — no mutations will be sent"

# ── mutation helpers ────────────────────────────────────────────────
gql() { gh api graphql "$@" >/dev/null; }

archive_item() {
  gql -f query='
    mutation($p: ID!, $i: ID!) {
      archiveProjectV2Item(input: { projectId: $p, itemId: $i }) {
        item { id }
      }
    }' -F p="$PROJECT_ID" -F i="$1"
}

set_single_select() { # itemId fieldId optionId
  gql -f query='
    mutation($p: ID!, $i: ID!, $f: ID!, $o: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $p, itemId: $i, fieldId: $f,
        value: { singleSelectOptionId: $o }
      }) { projectV2Item { id } }
    }' -F p="$PROJECT_ID" -F i="$1" -F f="$2" -F o="$3"
}

set_iteration() { # itemId fieldId iterationId
  gql -f query='
    mutation($p: ID!, $i: ID!, $f: ID!, $v: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $p, itemId: $i, fieldId: $f,
        value: { iterationId: $v }
      }) { projectV2Item { id } }
    }' -F p="$PROJECT_ID" -F i="$1" -F f="$2" -F v="$3"
}

set_number() { # itemId fieldId number
  gql -f query='
    mutation($p: ID!, $i: ID!, $f: ID!, $v: Float!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $p, itemId: $i, fieldId: $f,
        value: { number: $v }
      }) { projectV2Item { id } }
    }' -F p="$PROJECT_ID" -F i="$1" -F f="$2" -F v="$3"
}

rows() { awk -F'\t' -v k="$1" '$1==k' <<<"$PLAN"; }
count() { rows "$1" | grep -c . || true; }

# ── phase 1: archive ────────────────────────────────────────────────
echo "phase 1: archiving $(count archive) items from Last Sprint"
while IFS=$'\t' read -r _ id label; do
  [[ -z "${id:-}" ]] && continue
  echo "  $label"
  [[ "$DRY_RUN" == "true" ]] && continue
  if ! archive_item "$id" 2>&1; then
    echo "  ERROR archiving $label (item $id)" >&2
    failures=$((failures + 1))
  fi
done < <(rows archive)

# ── phase 2: collect Done into Last Sprint ──────────────────────────
echo "phase 2: moving $(count collect) Done items to Last Sprint"
while IFS=$'\t' read -r _ id label; do
  [[ -z "${id:-}" ]] && continue
  echo "  $label"
  [[ "$DRY_RUN" == "true" ]] && continue
  if ! set_single_select "$id" "$STATUS_FIELD_ID" \
       "$LAST_SPRINT_OPTION_ID" 2>&1; then
    echo "  ERROR moving $label (item $id)" >&2
    failures=$((failures + 1))
  fi
done < <(rows collect)

# ── phase 3: carry unfinished work forward ──────────────────────────
if [[ -z "${S[next_id]:-}" ]]; then
  echo "phase 3: skipped — no upcoming sprint to carry work into." \
       "Add another iteration in board settings." >&2
else
  echo "phase 3: carrying $(count carry) items to ${S[next_title]}"
  while IFS=$'\t' read -r _ id label slips; do
    [[ -z "${id:-}" ]] && continue
    next=$(( ${slips:-0} + 1 ))
    echo "  $label (slips ${slips:-0} -> $next)"
    [[ "$DRY_RUN" == "true" ]] && continue
    if ! set_iteration "$id" "$SPRINT_FIELD_ID" "${S[next_id]}" 2>&1; then
      echo "  ERROR re-stamping $label (item $id)" >&2
      failures=$((failures + 1))
      continue
    fi
    if ! set_number "$id" "$SLIPS_FIELD_ID" "$next" 2>&1; then
      echo "  ERROR bumping Slips on $label (item $id)" >&2
      failures=$((failures + 1))
    fi
  done < <(rows carry)
fi

# ── runway note ─────────────────────────────────────────────────────
if [[ "${S[iterations_remaining]:-0}" -lt 3 ]]; then
  echo "note: ${S[last_configured_title]} is the last configured" \
       "sprint (ends ${S[last_configured_end]}). Add another in" \
       "board settings."
fi

if [[ "$failures" -gt 0 ]]; then
  echo "completed with $failures failure(s); re-run to repair" >&2
  exit 1
fi
echo "Done."
