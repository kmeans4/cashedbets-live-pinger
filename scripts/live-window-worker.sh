#!/usr/bin/env bash
set -euo pipefail

windows_file="${GAME_WINDOWS_FILE:-game-windows.json}"
# Arm up to twelve hours early to tolerate missed GitHub schedule deliveries.
# Waiting performs no provider or database calls.
bootstrap_lead_seconds="${BOOTSTRAP_LEAD_SECONDS:-43200}"
handoff_after_seconds="${HANDOFF_AFTER_SECONDS:-16200}"
tick_seconds="${TICK_SECONDS:-300}"
max_consecutive_failures="${MAX_CONSECUTIVE_FAILURES:-3}"
failure_backoff_seconds="${FAILURE_BACKOFF_SECONDS:-900}"
dry_run="${DRY_RUN:-false}"
worker_once="${WORKER_ONCE:-false}"

if [[ ! -f "$windows_file" ]]; then
  echo "game-window file not found: $windows_file" >&2
  exit 1
fi

if ! [[ "$tick_seconds" =~ ^[0-9]+$ ]] || (( tick_seconds < 60 )); then
  echo "TICK_SECONDS must be an integer of at least 60" >&2
  exit 1
fi
if ! [[ "$bootstrap_lead_seconds" =~ ^[0-9]+$ ]] || (( bootstrap_lead_seconds < 3600 || bootstrap_lead_seconds > 43200 )); then
  echo "BOOTSTRAP_LEAD_SECONDS must be between 3600 and 43200" >&2
  exit 1
fi
if ! [[ "$max_consecutive_failures" =~ ^[0-9]+$ ]] || (( max_consecutive_failures < 1 )); then
  echo "MAX_CONSECUTIVE_FAILURES must be a positive integer" >&2
  exit 1
fi
if ! [[ "$failure_backoff_seconds" =~ ^[0-9]+$ ]] || (( failure_backoff_seconds < tick_seconds )); then
  echo "FAILURE_BACKOFF_SECONDS must be an integer no shorter than TICK_SECONDS" >&2
  exit 1
fi

clock_now() {
  if [[ -n "${WORKER_NOW_EPOCH:-}" ]]; then
    echo "$WORKER_NOW_EPOCH"
  else
    date +%s
  fi
}

refresh_survivor() {
  local query="$1"
  local url="https://redzone-hq.vercel.app/api/cron/fantasy/live${query}"

  if [[ "$dry_run" == "true" ]]; then
    echo "dry run: fantasy refresh $url"
    return 0
  fi
  if [[ -z "${FANTASY_REFRESH_SECRET:-}" || -z "${HQ_AUTOMATION_SECRET:-}" ]]; then
    echo "fantasy refresh credentials are not configured" >&2
    return 1
  fi
  for attempt in 1 2 3; do
    if curl -fsS -m 120 \
      -H "Authorization: Bearer ${FANTASY_REFRESH_SECRET}" \
      -H "x-vercel-protection-bypass: ${HQ_AUTOMATION_SECRET}" "$url" |
      jq -se --arg query "$query" 'length == 1 and (.[0] | .ok == true and (
        .skipped == "no_active_regular_season_week" or
        ((.week | type) == "number" and
          (if $query == "" then .score != null else .presentationRevision != null end))
      ))' >/dev/null; then
      echo "fantasy refresh ok"
      return 0
    fi
    echo "fantasy refresh attempt $attempt failed; retrying in 15s"
    sleep 15
  done
  echo "all fantasy refresh attempts failed" >&2
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
    local dry_run_presentation_changes="${DRY_RUN_PRESENTATION_CHANGES:-$dry_run_changed_games}"
    local dry_run_slate_settled="${DRY_RUN_SLATE_SETTLED:-false}"
    local dry_run_live_games="${DRY_RUN_LIVE_GAMES:-1}"
    jq -n \
      --argjson changed "$dry_run_changed_games" \
      --argjson presentation "$dry_run_presentation_changes" \
      --argjson live "$dry_run_live_games" --argjson settled "$dry_run_slate_settled" \
      '{summary:{changedGameIDs:[range(0; $changed) | "dry-run-\(.)"],presentationChangedGameIDs:[range(0; $presentation) | "dry-run-presentation-\(.)"],liveGamesNow:(if $settled then 0 else $live end),slateSettled:$settled}}' \
      > "$output_file"
    return 0
  fi
  for attempt in 1 2 3; do
    if curl -fsS -m 120 -H "Authorization: Bearer ${secret}" "$url" > "$output_file" &&
      jq -e '.summary and ((.summary.changedGameIDs // []) | type == "array") and ((.summary.presentationChangedGameIDs // []) | type == "array") and ((.summary.slateSettled // false) | type == "boolean")' "$output_file" >/dev/null; then
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
consecutive_failures=0
circuit_open_until=0
fantasy_refresh_pending=false
catch_up_on_start=true
pending_refresh_query=""

while true; do
  now="$(clock_now)"
  tick_started_at="$now"
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
    if (( now < circuit_open_until )); then
      echo "live ingestion circuit open until ${circuit_open_until}; skipping provider work this tick"
    else
      if live_ingestion_request "${CRON_SECRET:-}" "https://cashedbets-v2.vercel.app/api/cron/tank01/live" "$ingestion_response_file"; then
        live_ingestion_ok=true
        consecutive_failures=0
      else
        consecutive_failures=$((consecutive_failures + 1))
        echo "live ingestion failed; worker will retry on the next tick" >&2
        if (( consecutive_failures >= max_consecutive_failures )); then
          circuit_open_until=$((now + failure_backoff_seconds))
          consecutive_failures=0
          echo "live ingestion circuit opened for ${failure_backoff_seconds}s after repeated failures" >&2
        fi
      fi
    fi

    fantasy_in_window="$(jq -r --argjson now "$now" '[.windows[] | select($now >= .start and $now <= .end and .fantasyEligible == true)] | length' "$windows_file")"
    changed_games=0
    presentation_changes=0
    slate_settled=false
    if [[ "$live_ingestion_ok" == "true" ]]; then
      changed_games="$(jq -r '(.summary.changedGameIDs // []) | length' "$ingestion_response_file")"
      presentation_changes="$(jq -r '(.summary.presentationChangedGameIDs // []) | length' "$ingestion_response_file")"
      slate_settled="$(jq -r '.summary.slateSettled // false' "$ingestion_response_file")"
    fi
    should_refresh=false
    refresh_query=""
    # A previous worker may have imported stats without delivering them to HQ.
    # Reconcile once after startup when live stats exist, even on an unchanged tick.
    if [[ "$live_ingestion_ok" == "true" && "$catch_up_on_start" == "true" ]] &&
      jq -e '(.summary.liveGamesNow // 0) > 0' "$ingestion_response_file" >/dev/null; then
      should_refresh=true
    elif (( changed_games > 0 )) || [[ "$slate_settled" == "true" ]]; then
      should_refresh=true
      refresh_query=""
    elif (( presentation_changes > 0 )); then
      should_refresh=true
      refresh_query="?presentation=1"
    fi

    if (( fantasy_in_window > 0 )) && [[ "$should_refresh" != "false" ]]; then
      # Keep a pending full score even when the next change only updates a clock.
      if [[ "$fantasy_refresh_pending" == "false" || -z "$refresh_query" ]]; then
        pending_refresh_query="$refresh_query"
      fi
      fantasy_refresh_pending=true
    fi

    if (( fantasy_in_window > 0 )) && [[ "$live_ingestion_ok" == "true" ]] && [[ "$fantasy_refresh_pending" == "true" ]]; then
      if refresh_survivor "$pending_refresh_query"; then
        if [[ -z "$pending_refresh_query" ]]; then catch_up_on_start=false; fi
        fantasy_refresh_pending=false
        pending_refresh_query=""
      else
        echo "fantasy refresh failed; worker will retry after the next successful ingestion tick" >&2
      fi
    elif (( fantasy_in_window > 0 )) && [[ "$live_ingestion_ok" != "true" ]]; then
      echo "fantasy refresh deferred until live ingestion succeeds"
    elif (( fantasy_in_window == 0 )); then
      echo "regular-season Survivor refresh skipped"
    fi

    if [[ "$slate_settled" == "true" ]] && [[ "$fantasy_refresh_pending" != "true" ]]; then
      echo "all games settled; ending worker early"
      exit 0
    elif [[ "$slate_settled" == "true" ]]; then
      echo "all games settled; waiting for the pending fantasy refresh"
    fi
  else
    echo "waiting for game window — databases stay asleep"
  fi

  if [[ "$worker_once" == "true" ]]; then
    exit 0
  fi
  next_tick=$((tick_started_at + tick_seconds))
  sleep_seconds=$((next_tick - $(clock_now)))
  if (( sleep_seconds > 0 )); then
    sleep "$sleep_seconds"
  fi
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
  echo "workflow handoff unavailable; scheduled bootstrap remains the fallback" >&2
  exit 1
fi

echo "handing active window to a fresh workflow run"
gh workflow run ping.yml --repo "$GITHUB_REPOSITORY" --ref "${GITHUB_REF_NAME:-main}"
