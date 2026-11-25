---
title: Change Radar
subtitle: Configuration Reference
document: CR-CFG-01
version: "0.3"
date: 24 November 2026
status: For review
audience: The platform admin
owner: Simon Owen
release: Change Radar 0.3.0
intro: keep
breaks: none
---
# Configure

> **For:** the platform admin. **Kind:** reference.
> Every setting below lives in the `crdr_config` table (Change Radar app, **Operations**, **Config**). `setup/Import-Config.ps1` creates any that are missing with the default shown, and never overwrites one you've changed. This table is generated from `seed/config.csv`.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=configure) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=configure)

## Settings

| Key | Default | What it does |
|---|---|---|
| `fingerprint_confidence_threshold` | `0.7` | Signal facets below this confidence go to the review queue instead of matching |
| `abandoned_flow_days` | `180` | A flow with no run in this many days counts as abandoned |
| `estate_impact_max` | `4` | Clamp for the additive estate impact score (1 Low to 4 Critical) |
| `poll_minutes_service_health` | `15` | Graph service health poll interval |
| `poll_minutes_message_center` | `60` | Graph Message Center poll interval |
| `digest_day` | `Monday` | Weekly digest day |
| `poll_hours_roadmap` | `24` | Roadmap poll interval (the roadmap flow runs daily at 05:00 UTC) |
| `horizon_now_days` | `14` | Message Center posts with an action-required date within this many days (or past) are Now (ADR 0007) |
| `horizon_imminent_days` | `90` | Message Center posts with an action-required date within this many days are Imminent (ADR 0007) |
| `graph_services` | `Power Apps;Power Apps in Microsoft 365;Microsoft Power Automate;Microsoft Power Automate in Microsoft 365;Microsoft Copilot (Power Platform);Microsoft Dataverse;Power Platform;Power Pages;Microsoft Copilot (Microsoft 365);Dynamics 365 Apps` | Graph service names (exact, semicolon-separated) whose service health issues and Message Center posts are collected. Copilot Studio appears as Microsoft Copilot (Power Platform) |
| `horizon_recent_days` | `30` | Message Center "plan for change" posts published within this many days are Imminent (ADR 0007, amended) |
| `horizon_roadmap_days` | `45` | Roadmap items still in development whose GA month starts within this many days are Imminent (ADR 0007, amended) |
| `detail_environments` | `` | Dataverse environment URLs (semicolon-separated) where the reader app user exists and the Dataverse detail flow reads component detail (ADR 0008). Empty: no detail is collected |
| `fixture_solutions` | `ChangeRadarFixtures` | Solution unique names (semicolon-separated) whose apps and flows are fixtures: the detail flow labels them source = fixture (spec §15.2, ADR 0008) |
| `fingerprint_signal_ids` | `` | Signal external ids (semicolon-separated) the fingerprint flow is limited to; empty means every in-scope signal. Use to cap Copilot credit use while testing (ADR 0009) |
| `alert_destinations` | `` | Where Change Radar alerts go (ADR 0011 addendum): entries separated by ';', each chat:<user principal name> (Teams chat with the Flow bot), channel:<team id>/<channel id> (Teams channel, as the Flow bot) or email:<address> (sent by Notify-Email and Digest-Email, which ship off). Set at install, never in the repo. Bad entries are reported on the handler run and the others are still sent |
| `alert_recipient` | `` | Older setting, still read: one user principal name, treated as one more chat: entry in alert_destinations. Set at install, never in the repo (ADR 0011). With neither setting, handlers record the run as failed and post nothing |
| `app_url` | `` | Change Radar app URL (environment URL + main.aspx?appid=...), used for card links. Set at install (ADR 0011) |
| `deadline_days` | `14;3` | Days before an action-required key date when a deadline card is sent, for signals with live exposure (spec §7) |
| `rating_scope` | `window` | Which signals the assess flow rates: window (Now, Imminent, key date within 183 days, or exposed; ADR 0012) or all (every active signal except service health, once; ADR 0012 addendum 2026-11-22, within the 500-credit cap) |
| `rating_max_per_run` | `25` | Most signals the assess flow rates in one run (0 = no cap). A credit safeguard: new installs start at 25 so the first night can't run up a large bill; raise it once the cost is known |
| `assessment_max_per_run` | `25` | Most estate assessments the assess flow sends to the prompt in one run (0 = no cap). Separate from `rating_max_per_run`. An exposed signal over the cap is deferred, not skipped: it is assessed on a later run. Usually only a few a night; a large estate change or switching demo data on can need many |
| `catchup_max_per_run` | `100` | Higher per-run cap for the first weeks of an install, while the backlog of Microsoft's existing changes is fingerprinted and rated. Used by fingerprint, rating and estate assessment until `catchup_until`; it never lowers a cap. 0 = no catch-up |
| `catchup_until` | set at install | Date (yyyy-MM-dd) the catch-up ends; from that date the normal caps apply. `Import-Config.ps1` sets it to the install date + 14 days (`-CatchupDays`) when it first creates the setting on a fresh install, and never changes it after. Clear it to end catch-up early. Ignored unless it's a yyyy-MM-dd date within the next 120 days. Each fingerprint and assess run's summary shows the caps it used |
| `fingerprint_max_per_run` | `25` | Most signals the fingerprint flow sends to the prompt in one run (0 = no cap). A credit safeguard: new installs start at 25 so the first night can't run up a large bill; raise it once the cost is known |
| `demo_data` | `off` | Synthetic demo data (ADR 0022): on or off. Off: the match and assess flows skip it (no credits spent on it) and the Radar page hides it; nothing is deleted. Load it with setup/Import-DemoData.ps1 and remove it with setup/Remove-DemoData.ps1. Never load it in production. |

**Install values** (tenant data, never in the repo) are set with `Import-Config.ps1`: `alert_recipient`, `alert_destinations`, `detail_environments`; `app_url` is worked out from the environment.

**Credit safeguards:** `rating_scope`, `rating_max_per_run`, `assessment_max_per_run`, `fingerprint_max_per_run`, the catch-up pair (`catchup_max_per_run`, `catchup_until`) and `demo_data` control how many AI Builder prompt calls run. See [`requirements.md`](requirements.md#3-credits-what-the-ai-costs).

## Environment variables

Set at import, in the deployment settings file (`deploymentSettings.template.json`):

| Variable | What to put in it |
|---|---|
| `crdr_tenantid` | Your Microsoft Entra tenant id |
| `crdr_readerclientid` | The reader app registration's application (client) id |
| `crdr_readercertificate` | The Key Vault secret holding the reader certificate: `/subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<vault>/secrets/<name>` |

## Connection references

| Reference | Connector | Whose connection |
|---|---|---|
| `crdr_dataverse` | Microsoft Dataverse | The connection owner (Change Radar Admin role) |
| `crdr_powerplatformadmin` | Power Platform for Admins V2 | An account that is a Global Reader (least privilege) or Power Platform administrator |
| `crdr_teams` | Microsoft Teams | The account cards are posted as (ChangeRadarHandlers, `deploymentSettings.handlers.template.json`) |
| `crdr_outlook` | Office 365 Outlook | The mailbox email alerts are sent from (ChangeRadarHandlers; optional) |

## Data you can change in the app

| What | Where | Seeded from | Guide |
|---|---|---|---|
| Sources (feeds) | Operations, Feeds | `seed/feeds.csv`, `seed/feed-profiles/` | [`add-a-signal-source.md`](add-a-signal-source.md) |
| Vocabulary | Operations, Vocabulary | `seed/vocabulary.csv` | [`extend.md`](extend.md) |
| Matching rules | Operations, Rules | `seed/rules.csv` | ADR 0009 |
| Tenant settings Change Radar checks | Operations, Tenant settings | manual row | ADR 0009 |
| Watch topics | Radar, Watch list | `seed/watches.csv` | ADR 0015 |
| Subscriptions (which events go to which handler) | Operations, Subscriptions; switch a handler's together with its flow using `setup/Set-Handlers.ps1` | `seed/subscriptions.csv` (all disabled) | ADR 0011, ADR 0023 |
