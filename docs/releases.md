---
title: Change Radar
subtitle: Release Notes
document: CR-REL-01
version: "0.3"
date: 24 November 2026
status: For review
audience: Whoever installs or upgrades Change Radar
owner: Simon Owen
release: Change Radar 0.3.0
intro: keep
breaks: none
---
# Releases

> **For:** whoever installs or upgrades Change Radar. **Kind:** reference.
> Each release is a set of managed solutions (Core, Handlers and the optional Ask agent since 0.3.0) built by `setup/dev/New-Release.ps1` from the commit named. Check a download against its SHA-256 before importing. Newest first.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=releases) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=releases)

## 0.3.0 (24 November 2026)

Built from commit `ec2e279`. ChangeRadarCore: 20 tables, 19 flows, 3 security roles.

| File | Size | SHA-256 | Solution checker |
|---|---|---|---|
| `ChangeRadarCore_0.3.0_managed.zip` | 326 KB | `5d459cf663b4e10dca6b537e2c844024f90f266efbb24a01ceca6fa953248de1` | 2 medium: flow-avoid-recursive-loop (readable summary.Write_readable); flow-avoid-recursive-loop (record assessment override.Record_who_and_when) |
| `ChangeRadarHandlers_0.3.0_managed.zip` | 27 KB | `28d268a2139c0366d5bd1a937524b42ee2247d1fee1934cce4e7e9dbba6d8ff5` | 35 medium: meta-include-missingunmanageddependencies (Change Radar Handlers) |
| `ChangeRadarAsk_0.3.0_managed.zip` | 35 KB | `64041e56c269f9104c1d50778b837cc38daa8677b15a22479517bebbae2ff53e` | no issues |

**Install or upgrade:** [`install.md`](install.md). Upgrading keeps your settings and data; import with `--async`.

**Upgrading from 0.2.0** (proved in the install test environment, run 2): import **ChangeRadarHandlers first**, then upgrade ChangeRadarCore **with `--stage-and-upgrade`**, then ChangeRadarAsk. The handler flows keep their ids, their on or off state and their history; see [`install.md`](install.md#upgrade).

**Solution checker review:** Core's two findings are the false positives reviewed in 0.2.0. Handlers' 35 are one rule, `meta-include-missingunmanageddependencies`: Handlers depends on Core's tables by design (ADR 0023), and the upgrade proved they resolve when Core is installed.

**What's new**:

- **Alerts are their own solution, ChangeRadarHandlers** (ADR 0023). Core installs alone, needing only Dataverse and Power Platform for Admins V2 connections; Teams and Outlook are needed only with the handlers.
- **Every handler arrives switched off**, and `setup/Set-Handlers.ps1` switches a handler's flow and its subscriptions together. Subscriptions are seeded disabled.
- **A Handler template** and a guide (`extend.md`, "Add a handler") for writing your own.
- `Test-Install.ps1` checks handlers and runs left queued; deployment settings come as one template per solution.

## 0.2.0 (24 November 2026)

Built from commit `797fd63`. ChangeRadarCore: 20 tables, 23 flows, 3 security roles.

| File | Size | SHA-256 | Solution checker |
|---|---|---|---|
| `ChangeRadarCore_0.2.0_managed.zip` | 349 KB | `d50e35bb481a2035d5c0ed3653a6c7f900eaa1930b294b759a2ed4351ee07dc4` | 2 medium: flow-avoid-recursive-loop (readable summary.Write_readable); flow-avoid-recursive-loop (record assessment override.Record_who_and_when) |
| `ChangeRadarAsk_0.2.0_managed.zip` | 35 KB | `43b5846946affae2cc53c8329a222efef2547af1de4fcae6090dd54b077755a1` | no issues |

**Install or upgrade:** [`install.md`](install.md). Upgrading keeps your settings and data; import with `--async`.

**Solution checker review:** both findings are false positives. Each flow writes a column its own trigger doesn't watch: the readable summary flow is triggered by `crdr_summary` and writes `crdr_summarytext`; the override flow is triggered by the two override columns and writes who and when.

**What's in it**. The first packaged release, proved by a clean install in a new environment (`install-test-log.md`, run 1, findings 1 to 24):

- **Signals** from Message Center, service health, the public roadmap and 22 seeded web sources (Learn pages, blogs, licensing guides), with horizons, fingerprints and plain-English summaries.
- **Your estate** (apps, flows, agents, prompts and their solutions) matched against the signals, rated for impact, and shown on the Radar page by horizon, priority and solution.
- **Alerts** to Teams for service incidents, High or Critical ratings, deadlines, model changes and watch list matches, and a weekly digest; email versions ship switched off.
- **Ask Change Radar** (optional solution), a Copilot Studio agent that answers from your Change Radar data, as the person asking.
- **Roles:** Change Radar User and Change Radar Admin for people, Change Radar Reader for the read-only reader app.
- **Credit safeguards:** per-run caps on fingerprinting, rating and estate assessment, a two-week catch-up for a new install's backlog, demo data off by default. See `requirements.md` section 3 for an estimate.

**Since the install test:** an already-resolved incident no longer raises an "incident opened" card; the Reader role reads exactly the solution's tables; a separate cap on estate assessments; the form script runs in strict mode.
