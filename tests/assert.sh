#!/usr/bin/env bash
# Minimal assertion helpers. Source this, then call assert_eq.
# Increments FAILED (which the caller must initialise to 0).

assert_eq() { # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1"
    echo "         expected: [$2]"
    echo "         actual:   [$3]"
    FAILED=$((FAILED + 1))
  fi
}

