# CashedBets live pinger

Resilient game-window worker for CashedBets NFL live-stats ingestion (Vercel Hobby
crons are limited to daily). An hourly GitHub Actions bootstrap starts the worker
up to eight hours before a known game window. Once active, the worker calls the
protected `/api/cron/tank01/live` endpoint at the configured cadence and hands the
window to a fresh run before GitHub's six-hour hosted-runner limit.

- Auth: `CRON_SECRET` repository secret (never in code).
- Survivor auth: `FANTASY_REFRESH_SECRET` repository secret, shared with the
  RedZone HQ Production environment.
- Pause: disable the `live-tick` workflow in the Actions tab.
- `keepalive` commits monthly so GitHub never auto-disables the schedule.

The workflow defaults to the approved five-minute cadence. Signal keeps live box
scores bounded by its per-run limit and caches the scoreboard between eligible
refreshes. `TANK01_LIVE_TICK_SECONDS` can change the worker without changing
code. A 60-second cadence is only appropriate after the provider plan, daily
call limit, and database impact have been reviewed together.

`game-windows.json` lists every game day's ping window (earliest kickoff −15 min
→ latest kickoff +6 h), generated from the schedule database. Outside the
bootstrap horizon the job exits without any network call, so Neon stays suspended
on non-game days. While waiting for kickoff, the worker also makes no app or
database call. Live analytics runs for every NFL game window. Survivor scoring
refreshes run only during regular-season windows. Regenerate
after schedule changes (and when playoff dates land in January) with:

```
cd ../redzone-signal && npm run pinger:windows
cd ../cashedbets-live-pinger && git commit -am "refresh game windows" && git push
```

After a successful ingestion tick that changed scoring data or live presentation
fields such as the game clock, the worker calls the RedZone HQ route
`/api/cron/fantasy/live` during the regular season. It also makes one final scoring
call when the slate reports no live games. Unchanged ticks do not
modify the Survivor database. Score changes use the normal scoring path, while
clock-only changes increment a lightweight presentation revision.

GitHub's scheduled bootstrap remains best-effort, but the long-running worker and
self-handoff keep live ticks independent of repeated schedule delivery once
a game window has been claimed. The hourly bootstrap remains a fallback if a
handoff ever fails. An individual endpoint failure is retried and reported, but
does not terminate the worker. After three failed ticks, a 15-minute circuit
breaker pauses provider work before trying again. Survivor scoring waits for a
successful ingestion tick, so it never intentionally refreshes from stale live
data.

Validate the worker without making network calls:

```sh
scripts/test-live-window-worker.sh
```
