# CashedBets live pinger

Resilient 5-minute worker for CashedBets NFL live-stats ingestion (Vercel Hobby
crons are limited to daily). An hourly GitHub Actions bootstrap starts the worker
up to eight hours before a known game window. Once active, the worker calls the
protected `/api/cron/tank01/live` endpoint every five minutes and hands the window
to a fresh run before GitHub's six-hour hosted-runner limit.

- Auth: `CRON_SECRET` repository secret (never in code).
- Survivor auth: `FANTASY_REFRESH_SECRET` repository secret, shared with the
  RedZone HQ Production environment.
- Pause: disable the `live-tick` workflow in the Actions tab.
- `keepalive` commits monthly so GitHub never auto-disables the schedule.

`game-windows.json` lists every game day's ping window (earliest kickoff −15 min
→ latest kickoff +6 h), generated from the schedule database. Outside the
bootstrap horizon the job exits without any network call, so Neon stays suspended
on non-game days. While waiting for kickoff, the worker also makes no app or
database call. Live analytics runs for every NFL game window; the separate
Survivor refresh runs only when the generated window contains a regular-season
game, keeping that Neon compute asleep during preseason and playoffs. Regenerate
after schedule changes (and when playoff dates land in January) with:

```
cd ../redzone-signal && npm run pinger:windows
cd ../cashedbets-live-pinger && git commit -am "refresh game windows" && git push
```

After a successful ingestion tick, each 15-minute slot also calls RedZone HQ's
`/api/cron/fantasy/live` route. The fantasy refresh is limited to the active
regular-season week and writes only scores that changed.

GitHub's scheduled bootstrap remains best-effort, but the long-running worker and
self-handoff keep five-minute ticks independent of repeated schedule delivery once
a game window has been claimed. The hourly bootstrap remains a fallback if a
handoff ever fails. An individual endpoint failure is retried and reported, but
does not terminate the worker; the next tick tries again, and Survivor scoring
waits for a successful ingestion tick so it never intentionally refreshes from
stale live data.

Validate the worker without making network calls:

```sh
scripts/test-live-window-worker.sh
```
