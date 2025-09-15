# MCP Server Registry Snapshot

Automated (every 4 hours) pull of the public Model Context Protocol registry plus a generated daily trend chart and stats.

**See the latest detailed report (chart + stats) in [`summary.md`](./summary.md).**

This project is inspired by pub.dev's wonderful [pub_insights](https://github.com/loic-sharma/pub_insights) project.

## What This Repo Produces
- `servers.json` - full server objects (sorted)
- `servers.csv` - compact tabular subset
- `servers-per-day.svg` - unique servers per day (line + 7‑day moving average)
- `summary.md` - quick facts, top days, category breakdown

## How It Works
1. `pull-servers.ps1` pages `/v0/servers`, retries on errors / 429, validates `published_at`, outputs JSON + CSV.
2. `generate-report.ps1` parses dates, counts unique server names per day, classifies package / remote types, builds Vega-Lite spec, renders SVG (needs Node), writes `summary.md`.
3. GitHub Actions workflow (`.github/workflows/update-data.yml`) runs every 4 hours: pull -> report -> commit changes.

## Minimal Local Usage
```pwsh
pwsh ./pull-servers.ps1        # fetch latest data
pwsh ./generate-report.ps1     # build chart + summary
```
(Install Node.js if you want a fresh `servers-per-day.svg`; otherwise only `summary.md` updates.)

Optional flags:
```pwsh
pwsh ./pull-servers.ps1 -FilterActive
pwsh ./pull-servers.ps1 -OutputFile path/to/servers.json
pwsh ./generate-report.ps1 -OutMd report.md -OutSvg chart.svg
```

## Extending (Ideas)
- Keep dated snapshots in a `history/` folder
- Add cumulative growth or category trend charts
- Export machine-readable stats (e.g. `stats.json`)
