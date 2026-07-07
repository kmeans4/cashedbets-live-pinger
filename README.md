# CashedBets live pinger

Free 5-minute scheduler for the CashedBets NFL live-stats ingestion (Vercel Hobby
crons are limited to daily). Every 5 minutes, GitHub Actions calls the protected
`/api/cron/tank01/live` endpoint on cashedbets-v2. Outside game windows the
endpoint exits instantly with zero provider calls; during games it refreshes
schedule status and live box scores.

- Auth: `CRON_SECRET` repository secret (never in code).
- Pause: disable the `live-tick` workflow in the Actions tab.
- `keepalive` commits monthly so GitHub never auto-disables the schedule.

`game-windows.json` lists every game day's ping window (earliest kickoff −15 min
→ latest kickoff +6 h), generated from the schedule database. Ticks outside those
windows exit without any network call, so the Neon database stays suspended and
free on non-game days. Regenerate after schedule changes (and when playoff dates
land in January) with:

```
cd ../redzone-signal && npm run pinger:windows
cd ../cashedbets-live-pinger && git commit -am "refresh game windows" && git push
```

Note: GitHub cron is best-effort — ticks can occasionally run a few minutes late.
