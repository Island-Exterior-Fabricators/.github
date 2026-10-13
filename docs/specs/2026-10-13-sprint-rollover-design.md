# Sprint rollover on the project board

## Goal

At the end of each sprint, the "Island Software Team" board
(org project #1) is rolled over by hand:

1. Archive every card in the `Last Sprint` status.
2. Move every card in `Done` to `Last Sprint`.

Automate this. When the rollover happens late (for example on
the Tuesday of the new sprint), cards that reached `Done` after
the old sprint ended must stay in `Done`.

## Facts the design relies on

- The `Sprint` iteration field defines sprints: 14-day cadence
  starting Mondays, each iteration 12 days long (Mon through
  the second Fri). Sprint 38 started 2026-09-28; Sprint 39
  started 2026-10-12.
- A card's Status value carries `updatedAt`, the time its
  status last changed. For cards in `Done` it matches the
  issue/PR `closedAt`, so it is the "reached Done" time. For
  cards in `Last Sprint` it is the time they were moved there.
- The `Sprint` field is not usable for selection:
  `project-assign-sprint.yml` stamps the current sprint on any
  card missing one, and cards in `Done` carry stale values.
- `items` on a ProjectV2 excludes archived items.

## Cutoff

The cutoff is 00:00 `America/New_York` on the start date of
the most recent iteration whose `startDate` is on or before
today (Eastern), converted to UTC. Weekend work counts toward
the sprint that just ended; Monday's work stays in `Done`.

If no iteration has started, log it and exit 0.

## Selection

Query every unarchived item with its Status `name` and
`updatedAt`, paginated with `$endCursor`.

| Action               | Status        | Condition             |
|----------------------|---------------|-----------------------|
| Archive              | `Last Sprint` | `updatedAt` < cutoff  |
| Move to Last Sprint  | `Done`        | `updatedAt` < cutoff  |

Anything else is left alone. `Done` cards at or after the
cutoff are reported as "Left in Done".

## Order and idempotence

Archive first (`archiveProjectV2Item`), then move
(`updateProjectV2ItemFieldValue` to the `Last Sprint` option).

No state is stored. On most nights both sets are empty. The
first run after a sprint starts performs the rollover. A
repeat run cannot archive cards it just moved, because their
status `updatedAt` is after the cutoff. A partial failure is
finished by the next run; a missed night catches up.

## Workflow

New file `.github/workflows/project-sprint-rollover.yml` in
`Island-Exterior-Fabricators/.github`, modeled on
`project-assign-sprint.yml`.

- Triggers: `schedule` with cron `0 7 * * *` (an hour after
  assign-sprint), and `workflow_dispatch`.
- Token: `actions/create-github-app-token` with
  `vars.PROJECT_AUTOMATION_CLIENT_ID` and
  `secrets.PROJECT_AUTOMATION_APP_KEY`. No new secrets or
  permissions.
- `concurrency` group so a hand dispatch never overlaps the
  nightly run.
- `workflow_dispatch` input `dry_run` (boolean, default
  `true`). A dry run selects and reports but writes nothing.
  Scheduled runs write.

## Reporting

`$GITHUB_STEP_SUMMARY` lists the cutoff, then:

- Archived (N)
- Moved to Last Sprint (N)
- Left in Done (N)

Each entry shows repo, number, and title, so it is clear what
the run did and what it held back. Items whose content the
token can't read are shown as `(no access) <item id>`.

The summary is written on exit, so a run that fails partway
still lists exactly the cards it changed.

## Failure behavior

- `set -euo pipefail`: a failed query or mutation fails the
  run, and GitHub's failure email is the alert.
- A missing `Sprint` field or `Status` field, or a `Done` or
  `Last Sprint` option that is missing or not unique, fails
  loudly before any write.

## Out of scope

- Changing the `Sprint` field.
- Touching the issues or PRs themselves.
- Any status other than `Done` and `Last Sprint`.

## Testing

`schedule` and `workflow_dispatch` only run from the default
branch, so a `pull_request` trigger (filtered to the rollover
files) runs the tests and a dry run with the App token before
merge. Writes happen only on `schedule` or a dispatch with
`dry_run` unchecked; every other event is a dry run.

1. Open the PR; its run is the dry run.
2. Check the summary against the known board state. On
   2026-10-13 that is 13 archived, 48 moved, and 3 left in
   Done (bom-manager-mcp-server#12, IslandBOMApp#755,
   IslandBOMApp#770).
3. Merge, then let the nightly run perform the rollover, or
   dispatch with `dry_run: false`.
