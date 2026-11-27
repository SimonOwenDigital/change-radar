---
title: Change Radar
subtitle: Admin Tuning Guide
document: CR-OPS-02
version: "0.3"
date: 24 November 2026
status: For review
audience: Change Radar admins who adjust what it collects, matches, rates and sends
owner: Simon Owen
release: Change Radar 0.3.1
intro: keep
breaks: none
---

# Admin tuning guide

> **For:** Change Radar admins who adjust what it collects, matches, rates and sends. **Kind:** how-to.
> **Status:** describes release 0.3.0. Every setting named here is in the Configuration Reference with its default. Tune after the first month, when you have your own evidence: the monthly checks in the Operations Runbook tell you when.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=tuning) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=tuning)

## 1. How to tune safely

Change Radar's behaviour is data, not code: settings, vocabulary, rules, feeds, watch topics and subscriptions are rows you can change in the app (Operations, or Radar, Watch list). Three habits keep a change safe:

1. **Write the expected case first.** For anything that changes what matches, add a case to the test suite before the change, so you know what "right" looks like (section 10).
2. **Change one thing at a time,** then wait for the next nightly run (06:00 UTC for matching, 06:30 for rating).
3. **Check the effect** in Collection runs, the Radar page and, for credits, the forecast (`setup/Get-CreditEstimate.ps1`).

Where a value also lives in `seed/` (the repository's starting data), know what the importers do before you re-run them:

| Importer | Keeps your changes to | Resets to the seed |
|---|---|---|
| `Import-Config.ps1` | Every setting (it only creates missing ones) | Nothing |
| `Import-Watches.ps1` | Every watch topic (it only creates missing ones, switched off) | Nothing |
| `Import-Feeds.ps1` | Each feed's **Active** choice | The feed's other columns and profile |
| `Import-MatchingData.ps1` | Vocabulary, rules, manual fingerprints and subscriptions (it only adds missing ones) | Nothing on a plain run. With `-UpdateToSeed`: all of these except a subscription's **enabled** choice, and vocabulary values not in the seed are deactivated |

So changes made in the app are safe. Rows that differ from the seed show as `keep` in the importer's plan. If you keep your own copy of the seed, load a changed row from it with `-UpdateToSeed`, and read the plan first.

## 2. Vocabulary (facet values)

The vocabulary is the shared list of values a fingerprint can use, in nine facets: product, resource type, connector, capability, authentication mode, harness, setting, environment type and model. A value outside the vocabulary is rejected and can't match anything.

| | |
|---|---|
| **Symptoms** | Fingerprint review shows "not in the vocabulary" warnings; a new connector, capability or model Microsoft mentions never matches; a model spelling on a Learn page isn't recognised |
| **Change** | Add the value (Operations, Vocabulary), with a description. For a model, add the other spellings Microsoft uses as **aliases** |
| **Check** | The next fingerprint run accepts the value; the warning goes from the review page |
| **Case first** | A matching case in `tests/cases/` (positive and near miss) or, for a model, a case in `tests/models/models.json` |

Removing a value from the seed changes nothing on a plain run. With `-UpdateToSeed` the importer sets it inactive, never deletes it.

## 3. Rules

A rule says how a signal's facet joins an asset's facet. Each has a **role**:

| Role | Rules (seeded) | Effect |
|---|---|---|
| `scope` | product, resource type, environment type, harness | Narrows a match; never creates one alone |
| `trigger` | connector, capability, authentication mode, model | Creates a match |
| `setting` | tenant setting check | A setting exposure when a tenant setting is missing or off |

| | |
|---|---|
| **Symptoms** | Exposures you dismiss again and again for the same reason (too wide); changes you know touch you that never expose anything (too narrow) |
| **Change** | Usually a fingerprint or vocabulary fix, not a rule. Change a rule (Operations, Rules: active, condition) only when the join itself is wrong. A rule changed in the app is kept unless `Import-MatchingData.ps1` is run with `-UpdateToSeed` (section 1) |
| **Check** | The match run's summary (created, updated, unmatched) and the exposures on the Radar page |
| **Case first** | A positive case and a near miss in `tests/cases/`, run with `engine/Invoke-MatchingTests.ps1 -SeedDir <your seed copy>` |

## 4. The confidence threshold

`fingerprint_confidence_threshold` (default 0.7): an AI fingerprint value below it waits on the Fingerprint review page instead of matching.

| | |
|---|---|
| **Symptoms** | Dozens of fingerprints waiting every week, mostly accepted when reviewed (threshold too high); exposures you dismiss that came from weak AI fingerprints (too low) |
| **Change** | Config, in steps of 0.05 |
| **Check** | The Review page counts over the next week |
| **Case first** | A guard case in `tests/cases/engine-guards.json` at the new boundary |

## 5. Sources (feeds)

| | |
|---|---|
| **Symptoms** | Signals about a product you don't use (switch a feed off); a Microsoft source you rely on isn't collected (add one); a feed's collection run reports gaps every night (its page changed) |
| **Change** | Operations, Feeds: the **Active** column. `Import-Feeds.ps1 -Activate <key>` or `-Deactivate <key>` does the same from the command line. To add a source, follow Adding a Signal Source |
| **Check** | The feed's collection run, and its signals in the Signals view filtered by source |
| **Case first** | For a changed or new profile, cases in `tests/feeds/cases.json`, run with `engine/Invoke-FeedTests.ps1` |

Licensing guides use AI Builder text recognition when a guide changes (about 3 AI Builder credits a guide in the event log). Signals from licensing and event sources are information only and are never rated.

## 6. Watch topics

| | |
|---|---|
| **Symptoms** | A topic matches things you don't mean (add words to **none of**); it misses things you do (add words to **any of**, or loosen **also one of**) |
| **Change** | Radar, Watch list: any of, also one of, none of, products, active. `Import-Watches.ps1` creates seed topics switched off and never changes yours |
| **Check** | Watch cards, and the **Watched signals** view |
| **Case first** | Matches and near misses in `tests/watch/watch.json`, run with `engine/Invoke-WatchTests.ps1`. The seed's "Copilot Autopilot in the UK" topic excludes "Windows Autopilot" for exactly this reason |

Matching is by word, on the title and readable summary, and costs no credits.

## 7. What gets rated, and how much it costs

| Setting | Default | Raise or lower it when |
|---|---|---|
| `rating_scope` | `window` | `window` rates signals that are Now, Imminent, due within 183 days, or exposed. `all` rates every active signal except service health, once: more credits, more context on the Radar |
| `fingerprint_max_per_run` | 25 | Fingerprint runs report signals left over night after night |
| `rating_max_per_run` | 25 | Rating runs report signals left over |
| `assessment_max_per_run` | 25 | The assess run reports **deferred** estate assessments every night |
| `catchup_max_per_run`, `catchup_until` | 100, install date + 14 days | A new install's backlog is clearing too slowly (extend the date) or the credit forecast is too high (clear the date to end catch-up) |

**Check:** each fingerprint and assess run's summary in Collection runs, then `setup/Get-CreditEstimate.ps1` and the capacity report. A cap of 0 means no cap: avoid it unless you mean it (`Test-Install.ps1` warns). **Case first:** cap and catch-up behaviour is in `tests/config/config.json` and the forecast in `tests/credits/credits.json`; add a case there if you change how caps work, not when you change a value.

## 8. Horizons

| Setting | Default | Effect |
|---|---|---|
| `horizon_now_days` | 14 | Message Center posts with an action date within this many days, or past, are **Now** |
| `horizon_imminent_days` | 90 | Message Center posts with an action date (or start date) within this many days are **Imminent** |
| `horizon_recent_days` | 30 | "Plan for change" posts published within this many days are Imminent |
| `horizon_roadmap_days` | 45 | Roadmap items in development whose general availability month starts within this many days are Imminent |
| `deadline_days` | `14;3` | Days before an action date when a deadline card is sent |

| | |
|---|---|
| **Symptoms** | Now is crowded with things that aren't urgent (lower `horizon_now_days`); changes surprise you because they sat in Future (raise `horizon_imminent_days`) |
| **Check** | Horizons are recomputed every night at 06:00 UTC; the Radar page's tiles and timeline move the next day |

## 9. Services, alerts and subscriptions

- **`graph_services`:** the exact Microsoft service names whose service health and Message Center posts are collected. Add a service to widen collection (for example a Dynamics 365 app you run); remove one to quieten it. A misspelt name collects nothing: copy it from the Microsoft 365 admin centre's service health list.
- **Subscriptions** (Operations, Subscriptions) say which events go to which handler, with optional filters such as minimum impact. Switch whole handlers with `Set-Handlers.ps1`, which switches the flow and its subscriptions together. Disable a single subscription to stop one kind of card, for example `asset.modelchanged` cards if your makers change models deliberately.
- **Alert destinations:** see the Operations Runbook (5.2).

**Case first:** a change to which events a handler receives belongs in `tests/handlers/handlers.json` or `tests/events/`, run with `engine/Invoke-HandlerTests.ps1` and `engine/Invoke-EventTests.ps1`.

## 10. Running the cases

The test suites run locally, on files only, with no tenant access:

```powershell
pwsh -File engine/Invoke-MatchingTests.ps1          # vocabulary, rules, matching
pwsh -File engine/Invoke-WatchTests.ps1             # watch topics
pwsh -File engine/Invoke-FeedTests.ps1              # source profiles
pwsh -File engine/Invoke-ConfigTests.ps1            # caps, catch-up, demo data
```

`Invoke-MatchingTests.ps1 -SeedDir <folder>` runs the cases against your own copy of the seed, so you can try a vocabulary or rule change before you make it in the app. Every suite reports pass or fail per case and exits with 1 on any failure.
