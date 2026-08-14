#!/usr/bin/env bash
set -euo pipefail

windows_file="${GAME_WINDOWS_FILE:-game-windows.json}"
bootstrap_lead_seconds="${BOOTSTRAP_LEAD_SECONDS:-28800}"
handoff_after_seconds="${HANDOFF_AFTER_SECONDS:-16200}"
tick_seconds="${TICK_SECONDS:-120}"
dry_run="${DRY_RUN:-false}"
worker_once="${WORKER_ONCE:-false}"

if [[ ! -f "$windows_file" ]]; then
  echo "game-window file not found: $windows_file" >&2
  exit 1
fi

clock_now() {
  if [[ -n "${WORKER_NOW_EPOCH:-}" ]]; then
    echo "$WORKER_NOW_EPOCH"
  else
    date +%s
  fi
}

retry_request() {
  local name="$1"
  local secret="$2"
  local url="$3"

  if [[ -z "$secret" ]]; then
    echo "$name secret is not configured" >&2
    return 1
  fi
  if [[ "$dry_run" == "true" ]]; then
    echo "dry run: $name"
    return 0
  fi
  for attempt in 1 2 3; do
    if curl -fsS -o /dev/null -m 120 -H "Authorization: Bearer ${secret}" "$url"; then
      echo "$name ok"
      return 0
    fi
    echo "$name attempt $attempt failed; retrying in 15s"
    sleep 15
  done
  echo "all $name attempts failed" >&2
  return 1
}

live_ingestion_request() {
  local secret="$1"
  local url="$2"
  local output_file="$3"

  if [[ -z "$secret" ]]; then
    echo "live ingestion secret is not configured" >&2
    return 1
  fi
  if [[ "$dry_run" == "true" ]]; then
    echo 'dry run: live ingestion'
    local dry_run_changed_games="${DRY_RUN_CHANGED_GAMES:-1}"
    local dry_run_slate_settled="${DRY_RUN_SLATE_SETTLED:-false}"
    jq -n \
      --argjson changed "$dry_run_changed_games" \
      --argjson settled "$dry_run_slate_settled" \
      '{summary:{changedGameIDs:[range(0; $changed) | "dry-run-\(.)"],liveGamesNow:(if $settled then 0 else 1 end),slateSettled:$settled}}' \
      > "$output_file"
    return 0
  fi
  for attempt in 1 2 3; do
    if curl -fsS -m 120 -H "Authorization: Bearer ${secret}" "$url" > "$output_file" &&
      jq -e '.summary and ((.summary.changedGameIDs // []) | type == "array") and ((.summary.slateSettled // false) | type == "boolean")' "$output_file" >/dev/null; then
      echo "live ingestion ok"
      return 0
    fi
    echo "live ingestion attempt $attempt failed; retrying in 15s"
    sleep 15
  done
  echo "all live ingestion attempts failed" >&2
  return 1
}

initial_now="$(clock_now)"
window="$(jq -r --argjson now "$initial_now" --argjson lead "$bootstrap_lead_seconds" '
  [.windows[] | select($now <= .end and .start <= ($now + $lead))]
  | sort_by(.start) | first | if . then "\(.start) \(.end)" else empty end
' "$windows_file")"

if [[ -z "$window" ]]; then
  echo "outside game-window bootstrap horizon — skipping (databases stay asleep)"
  exit 0
fi

read -r window_start window_end <<< "$window"
hard_stop=$((initial_now + handoff_after_seconds))
if (( hard_stop > window_end )); then hard_stop="$window_end"; fi
ingestion_response_file="$(mktemp)"
trap 'rm -f "$ingestion_response_file"' EXIT

echo "worker armed for window ${window_start}-${window_end}; polling every ${tick_seconds}s; hard stop ${hard_stop}"

while true; do
  now="$(clock_now)"
  if (( now > window_end )); then
    echo "game window complete"
    exit 0
  fi
  if (( now >= hard_stop )); then
    break
  fi

  in_window="$(jq -r --argjson now "$now" '[.windows[] | select($now >= .start and $now <= .end)] | length' "$windows_file")"
  if (( in_window > 0 )); then
    live_ingestion_ok=false
    if live_ingestion_request "${CRON_SECRET:-}" "https://cashedbets-v2.vercel.app/api/cron/tank01/live" "$ingestion_response_file"; then
      live_ingestion_ok=true
    else
      echo "live ingestion failed; worker will retry on the next tick" >&2
    fi

    fantasy_in_window="$(jq -r --argjson now "$now" '[.windows[] | select($now >= .start and $now <= .end and .fantasyEligible == true)] | length' "$windows_file")"
    rehearsal_in_window="$(jq -r --argjson now "$now" '[.windows[] | select($now >= .start and $now <= .end and .rehearsalEligible == true)] | length' "$windows_file")"
    changed_games=0
    slate_settled=false
    if [[ "$live_ingestion_ok" == "true" ]]; then
      changed_games="$(jq -r '(.summary.changedGameIDs // []) | length' "$ingestion_response_file")"
      slate_settled="$(jq -r '.summary.slateSettled // false' "$ingestion_response_file")"
    fi
    should_refresh=false
    if (( changed_games > 0 )); then
      should_refresh=true
    elif [[ "$slate_settled" == "true" ]]; then
      should_refresh=final
    fi

    if (( fantasy_in_window > 0 )) && [[ "$live_ingestion_ok" == "true" ]] && [[ "$should_refresh" != "false" ]]; then
      if retry_request "fantasy refresh" "${FANTASY_REFRESH_SECRET:-}" "https://redzone-hq.vercel.app/api/cron/fantasy/live"; then
        :
      else
        echo "fantasy refresh failed; worker will retry after the next successful ingestion tick" >&2
      fi
    elif (( fantasy_in_window > 0 )) && [[ "$live_ingestion_ok" != "true" ]]; then
      echo "fantasy refresh deferred until live ingestion succeeds"
    elif (( fantasy_in_window == 0 )); then
      echo "regular-season Survivor refresh skipped"
    fi

    if (( rehearsal_in_window > 0 )) && [[ "$live_ingestion_ok" == "true" ]] && [[ "$should_refresh" != "false" ]]; then
      if retry_request "preseason rehearsal refresh" "${FANTASY_REFRESH_SECRET:-}" "https://redzone-hq.vercel.app/api/cron/fantasy/rehearsal/live"; then
        :
      else
        echo "preseason rehearsal refresh failed; worker will retry after the next successful ingestion tick" >&2
      fi
    elif (( rehearsal_in_window > 0 )) && [[ "$live_ingestion_ok" != "true" ]]; then
      echo "preseason rehearsal refresh deferred until live ingestion succeeds"
    fi

    if [[ "$slate_settled" == "true" ]]; then
      echo "all games settled; ending worker early"
      exit 0
    fi
  else
    echo "waiting for game window — databases stay asleep"
  fi

  if [[ "$worker_once" == "true" ]]; then
    exit 0
  fi
  sleep "$tick_seconds"
done

if (( window_end <= hard_stop )); then
  echo "game window complete"
  exit 0
fi

if [[ "$dry_run" == "true" ]]; then
  echo "dry run: workflow handoff"
  exit 0
fi
if [[ -z "${GITHUB_REPOSITORY:-}" || -z "${GH_TOKEN:-}" ]]; then
  echo "workflow handoff unavailable; hourly bootstrap remains the fallback" >&2
  exit 1
fi

echo "handing active window to a fresh workflow run"
gh workflow run ping.yml --repo "$GITHUB_REPOSITORY" --ref "${GITHUB_REF_NAME:-main}"
