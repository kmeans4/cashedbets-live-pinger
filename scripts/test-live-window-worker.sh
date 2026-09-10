#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

regular_start="$(jq -r '.windows[] | select(.fantasyEligible == true) | .start' game-windows.json | head -1)"
workflow_source="$(<.github/workflows/ping.yml)"
worker_source="$(<scripts/live-window-worker.sh)"
expected_workflow_tick="TICK_SECONDS: \${{ vars.TANK01_LIVE_TICK_SECONDS || '300' }}"
expected_checkout="actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09"

if [[ "$workflow_source" != *"$expected_workflow_tick"* ]]; then
  echo "workflow must default to the approved 300-second live cadence" >&2
  exit 1
fi
if [[ "$workflow_source" != *"$expected_checkout"* ]]; then
  echo "workflow must pin actions/checkout to the reviewed v5 commit" >&2
  exit 1
fi
if [[ "$worker_source" != *"fantasy_refresh_pending=true"* ]] || [[ "$worker_source" != *"waiting for the pending fantasy refresh"* ]]; then
  echo "worker must retain failed fantasy refreshes and finish them before ending a settled slate" >&2
  exit 1
fi

assert_output() {
  local expected="$1"
  shift
  local output
  output="$("$@" 2>&1)"
  if [[ "$output" != *"$expected"* ]]; then
    echo "expected output to contain: $expected" >&2
    echo "$output" >&2
    exit 1
  fi
}

assert_not_output() {
  local unexpected="$1"
  shift
  local output
  output="$("$@" 2>&1)"
  if [[ "$output" == *"$unexpected"* ]]; then
    echo "expected output not to contain: $unexpected" >&2
    echo "$output" >&2
    exit 1
  fi
}

assert_failure_output() {
  local expected="$1"
  shift
  local output
  local status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if (( status == 0 )); then
    echo "expected command to fail" >&2
    echo "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "expected failure output to contain: $expected" >&2
    echo "$output" >&2
    exit 1
  fi
}

assert_output "outside game-window bootstrap horizon" \
  env DRY_RUN=true WORKER_ONCE=true WORKER_NOW_EPOCH=1 scripts/live-window-worker.sh
assert_output "outside game-window bootstrap horizon" \
  env DRY_RUN=true WORKER_ONCE=true WORKER_NOW_EPOCH=$((regular_start - 14401)) scripts/live-window-worker.sh
assert_output "waiting for game window" \
  env DRY_RUN=true WORKER_ONCE=true WORKER_NOW_EPOCH=$((regular_start - 14400)) scripts/live-window-worker.sh
assert_output "waiting for game window" \
  env DRY_RUN=true WORKER_ONCE=true WORKER_NOW_EPOCH=$((regular_start - 3600)) scripts/live-window-worker.sh
assert_output "polling every 300s" \
  env DRY_RUN=true WORKER_ONCE=true WORKER_NOW_EPOCH="$regular_start" CRON_SECRET=test FANTASY_REFRESH_SECRET=test scripts/live-window-worker.sh
assert_output "polling every 60s" \
  env DRY_RUN=true WORKER_ONCE=true TICK_SECONDS=60 WORKER_NOW_EPOCH="$regular_start" CRON_SECRET=test FANTASY_REFRESH_SECRET=test scripts/live-window-worker.sh
assert_failure_output "TICK_SECONDS must be an integer of at least 60" \
  env DRY_RUN=true WORKER_ONCE=true TICK_SECONDS=30 WORKER_NOW_EPOCH="$regular_start" scripts/live-window-worker.sh
assert_failure_output "BOOTSTRAP_LEAD_SECONDS must be between 3600 and 14400" \
  env DRY_RUN=true WORKER_ONCE=true BOOTSTRAP_LEAD_SECONDS=1800 WORKER_NOW_EPOCH="$regular_start" scripts/live-window-worker.sh
assert_failure_output "MAX_CONSECUTIVE_FAILURES must be a positive integer" \
  env DRY_RUN=true WORKER_ONCE=true MAX_CONSECUTIVE_FAILURES=0 WORKER_NOW_EPOCH="$regular_start" scripts/live-window-worker.sh
assert_failure_output "FAILURE_BACKOFF_SECONDS must be an integer no shorter than TICK_SECONDS" \
  env DRY_RUN=true WORKER_ONCE=true FAILURE_BACKOFF_SECONDS=60 WORKER_NOW_EPOCH="$regular_start" scripts/live-window-worker.sh
assert_output "dry run: fantasy refresh" \
  env DRY_RUN=true WORKER_ONCE=true WORKER_NOW_EPOCH="$regular_start" CRON_SECRET=test FANTASY_REFRESH_SECRET=test scripts/live-window-worker.sh
assert_not_output "presentation=1" \
  env DRY_RUN=true DRY_RUN_CHANGED_GAMES=1 DRY_RUN_PRESENTATION_CHANGES=1 WORKER_ONCE=true WORKER_NOW_EPOCH="$regular_start" CRON_SECRET=test FANTASY_REFRESH_SECRET=test scripts/live-window-worker.sh
assert_not_output "fantasy refresh" \
  env DRY_RUN=true DRY_RUN_CHANGED_GAMES=0 WORKER_ONCE=true WORKER_NOW_EPOCH="$regular_start" CRON_SECRET=test FANTASY_REFRESH_SECRET=test scripts/live-window-worker.sh
assert_output "dry run: fantasy refresh" \
  env DRY_RUN=true DRY_RUN_CHANGED_GAMES=0 DRY_RUN_PRESENTATION_CHANGES=1 WORKER_ONCE=true WORKER_NOW_EPOCH="$regular_start" CRON_SECRET=test FANTASY_REFRESH_SECRET=test scripts/live-window-worker.sh
assert_output "presentation=1" \
  env DRY_RUN=true DRY_RUN_CHANGED_GAMES=0 DRY_RUN_PRESENTATION_CHANGES=1 WORKER_ONCE=true WORKER_NOW_EPOCH="$regular_start" CRON_SECRET=test FANTASY_REFRESH_SECRET=test scripts/live-window-worker.sh
assert_output "all games settled; ending worker early" \
  env DRY_RUN=true DRY_RUN_CHANGED_GAMES=0 DRY_RUN_SLATE_SETTLED=true WORKER_NOW_EPOCH="$regular_start" CRON_SECRET=test FANTASY_REFRESH_SECRET=test scripts/live-window-worker.sh
assert_output "worker will retry on the next tick" \
  env WORKER_ONCE=true WORKER_NOW_EPOCH="$regular_start" scripts/live-window-worker.sh
assert_output "fantasy refresh deferred until live ingestion succeeds" \
  env WORKER_ONCE=true WORKER_NOW_EPOCH="$regular_start" FANTASY_REFRESH_SECRET=test scripts/live-window-worker.sh
assert_output "dry run: workflow handoff" \
  env DRY_RUN=true WORKER_NOW_EPOCH="$regular_start" HANDOFF_AFTER_SECONDS=0 scripts/live-window-worker.sh

echo "Live-window worker tests passed: off-window, pre-window, scoring and presentation changes, regular-season, failure, and handoff behavior."
