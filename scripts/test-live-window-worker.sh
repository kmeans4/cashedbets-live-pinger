#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

preseason_start="$(jq -r '.windows[] | select(.rehearsalEligible == true) | .start' game-windows.json | head -1)"
regular_start="$(jq -r '.windows[] | select(.fantasyEligible == true) | .start' game-windows.json | head -1)"

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

assert_output "outside game-window bootstrap horizon" \
  env DRY_RUN=true WORKER_ONCE=true WORKER_NOW_EPOCH=1 scripts/live-window-worker.sh
assert_output "waiting for game window" \
  env DRY_RUN=true WORKER_ONCE=true WORKER_NOW_EPOCH=$((regular_start - 3600)) scripts/live-window-worker.sh
assert_output "dry run: preseason rehearsal refresh" \
  env DRY_RUN=true WORKER_ONCE=true WORKER_NOW_EPOCH="$preseason_start" CRON_SECRET=test FANTASY_REFRESH_SECRET=test scripts/live-window-worker.sh
assert_output "dry run: fantasy refresh" \
  env DRY_RUN=true WORKER_ONCE=true WORKER_NOW_EPOCH="$regular_start" CRON_SECRET=test FANTASY_REFRESH_SECRET=test scripts/live-window-worker.sh
assert_not_output "fantasy refresh" \
  env DRY_RUN=true DRY_RUN_CHANGED_GAMES=0 WORKER_ONCE=true WORKER_NOW_EPOCH="$regular_start" CRON_SECRET=test FANTASY_REFRESH_SECRET=test scripts/live-window-worker.sh
assert_output "all games settled; ending worker early" \
  env DRY_RUN=true DRY_RUN_CHANGED_GAMES=0 DRY_RUN_SLATE_SETTLED=true WORKER_NOW_EPOCH="$regular_start" CRON_SECRET=test FANTASY_REFRESH_SECRET=test scripts/live-window-worker.sh
assert_output "worker will retry on the next tick" \
  env WORKER_ONCE=true WORKER_NOW_EPOCH="$regular_start" scripts/live-window-worker.sh
assert_output "fantasy refresh deferred until live ingestion succeeds" \
  env WORKER_ONCE=true WORKER_NOW_EPOCH="$regular_start" FANTASY_REFRESH_SECRET=test scripts/live-window-worker.sh
assert_output "dry run: workflow handoff" \
  env DRY_RUN=true WORKER_NOW_EPOCH="$regular_start" HANDOFF_AFTER_SECONDS=0 scripts/live-window-worker.sh

echo "Live-window worker tests passed: off-window, pre-window, changed/unchanged/settled scoring, preseason rehearsal, regular-season, failure, and handoff behavior."
