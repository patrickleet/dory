#!/bin/bash

# Return the completed-test count that Xcode reported. Xcode 25 and older primarily emit
# XCTest's "Executed N tests" summary, while Xcode 26's Swift Testing runner emits
# "Test run with N tests". Individual pass lines are retained as a last-resort completeness signal
# for interrupted runners that never print a summary.
dory_ci_count_completed_tests() {
  local log="$1" swift_summary xctest_summary individual

  swift_summary="$(sed -nE 's/.*Test run with ([0-9]+) tests.*/\1/p' "$log" | tail -1)"
  xctest_summary="$(sed -nE 's/.*Executed ([0-9]+) tests.*/\1/p' "$log" | tail -1)"
  case "$swift_summary" in ''|*[!0-9]*) ;; *) printf '%s\n' "$swift_summary"; return ;; esac
  case "$xctest_summary" in ''|*[!0-9]*) ;; *) printf '%s\n' "$xctest_summary"; return ;; esac

  individual="$(grep -cE "Test case '[^']+' passed|Test .+\(.*\) passed after" "$log" || true)"
  printf '%s\n' "$individual"
}

dory_ci_failure_lines() {
  local log="$1"
  grep -E "Test case '[^']+' failed|Test .+ failed after|(^|[^[:alpha:]])error:" "$log" \
    | tail -50 || true
}
