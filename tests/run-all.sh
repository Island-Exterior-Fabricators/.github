#!/usr/bin/env bash
# Run every tests/*.test.sh. Exits non-zero if any file fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0

for f in "$HERE"/*.test.sh; do
  echo "== $(basename "$f")"
  bash "$f" || rc=1
  echo
done

if [[ $rc -eq 0 ]]; then
  echo "all tests passed"
else
  echo "TESTS FAILED"
fi
exit $rc
