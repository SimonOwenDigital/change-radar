---
title: Change Radar
subtitle: Extending Change Radar
document: CR-EXT-01
version: "0.3"
date: 24 November 2026
status: For review
audience: Platform teams and makers who add vocabulary, rules, watch topics, handlers, sources or tenant settings
owner: Simon Owen
release: Change Radar 0.3.0
intro: keep
breaks: none
---

# Extend

> **For:** platform teams and makers who add vocabulary, rules, watch topics, handlers, sources or tenant settings. **Kind:** how-to.
> **Status:** describes release 0.3.0. Every extension here is data or a flow of your own: none needs a change to the core solution.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=extend) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=extend)

## The rule for every extension: cases first

Write the expected cases **before** the change, run them and see them fail, then make the change until they pass. The suites run locally, on files only (`engine/Invoke-*Tests.ps1`), and each exits with 1 on any failure. A case that says what should *not* happen (a near miss) matters as much as one that says what should.

## 1. Add a facet value

The vocabulary holds the values a fingerprint can use, in nine facets: product, resource type, connector, capability, authentication mode, harness, setting, environment type and model.

1. **Cases first.** Add a positive case and a near miss to a file in `tests/cases/` that use the new value (the format is in `tests/README.md`). For a model, add lifecycle cases to `tests/models/models.json` too.
2. **Add the value** to `seed/vocabulary.csv` (`facet`, `value`, `description`, and for a model the other spellings Microsoft uses in `aliases`).
3. **Run** `pwsh -File engine/Invoke-MatchingTests.ps1` (and `Invoke-ModelTests.ps1` for a model) until they pass.
4. **Load it** with `setup/Import-MatchingData.ps1 ... -Apply`, or add it in the app (Operations, Vocabulary). To load a change to an existing value, add `-UpdateToSeed`.

An asset gets facet values from the estate through `seed/asset-signatures.json`. A value the estate can't produce never matches: check that file says how an asset gets it.

## 2. Add a rule

A rule joins a signal facet to an asset facet, with a role: `scope` narrows a match, `trigger` creates one, `setting` checks a tenant setting.

1. **Cases first:** a positive case and a near miss for the new join, in `tests/cases/`.
2. **Add the row** to `seed/rules.csv` (`rule_id`, `name`, `signal_facet`, `asset_facet`, `condition`, `role`, `active`, `description`).
3. **Run** `pwsh -File engine/Invoke-MatchingTests.ps1`. The runner also fails if the engine exposes an asset that has no case, so a near miss can't silently become a match.
4. **Load it** with `Import-MatchingData.ps1 ... -Apply` (add `-UpdateToSeed` to change an existing rule).

A new kind of join that `condition` can't express needs an engine change in `engine/ChangeRadar.Matching.psm1` and the same change in the Match exposures flow, kept in step by the parity check (Developer Guide).

## 3. Add a watch topic

A topic is a named watch: words that must appear (**any of**), optionally a second set of which one must also appear (**also one of**), words that rule a signal out (**none of**), and optionally products.

1. **Cases first:** in `tests/watch/watch.json`, add signals the topic should match and near misses it shouldn't, for example a word inside another word, or a product that shares the name.
2. **Run** `pwsh -File engine/Invoke-WatchTests.ps1`.
3. **Add the topic** in the app (Radar, Watch list), or to `seed/watches.csv` and `setup/Import-Watches.ps1 ... -Apply -Activate '<name>'`. New topics are created switched off.

## 4. Add a handler

A handler is a flow that does something when Change Radar raises an event: post a card, create a task, open a ticket. You add your own without touching the core solution.

**How events reach a handler.** Each event (`signal.new`, `incident.opened`, `assessment.rated`, `deadline.approaching` and the rest; the Architecture Definition lists them) goes to the dispatcher. It looks up the **enabled subscriptions** for the event's type and creates one **handler run** per subscription, named `<handler> | <event type> | …` and marked Queued. A handler triggers on new handler runs whose name starts with its own name, does its work, and marks the run Succeeded or Failed. The dispatcher never calls your flow, so nothing in the core depends on it.

**Start from the template.** `ChangeRadarHandlers` ships a **Handler template** flow, switched off, that keeps this contract:

1. **Cases first.** If your handler filters events (minimum impact, product, nature), add cases to `tests/handlers/handlers.json` and run `pwsh -File engine/Invoke-HandlerTests.ps1`.
2. Copy the template (Power Automate, Save as) into **your own solution**, and name the copy `Change Radar handler: <YourName>`.
3. Change its trigger's filter from `startswith(crdr_name,'Handler template |')` to `startswith(crdr_name,'<YourName> |')`.
4. Put your work in the **Handle** scope, after the **Event** step, which reads the event: its type, name, JSON payload, and the signal, exposure or assessment it points to.
5. Leave **Mark succeeded** and **Mark failed** as they are: the run's outcome and detail are how people, and `Test-Install.ps1`, see what your handler did.
6. Add subscriptions (Operations, Subscriptions): the event type, `handler` = `<YourName>`, any filters, and `writes` = yes if it changes anything outside Change Radar.
7. Turn it on with `setup/Set-Handlers.ps1 ... -On <YourName> -Apply`, which switches the flow and its subscriptions together.

**Rules every handler keeps:**

- **A handler that writes outside Change Radar ships switched off,** with `writes` = yes on its subscriptions, and its documentation says exactly **what it writes, where, and as whom** (for example "creates a Planner task in plan X, as the owner of connection Y"). `Set-Handlers.ps1` names such handlers before turning them on.
- **Idempotent.** A run can be retried: use the event id to check you haven't already done the work, for example by storing it on what you create.
- **Logged.** Always mark the run Succeeded or Failed, with a detail a person can read. A run left Queued for more than a day is reported by `Test-Install.ps1`.
- **Live data only.** The dispatcher creates runs only for live events; demo and test data never reach a handler.

## 5. Add a signal source

Most new public sources (a Learn page, a release notes page, an RSS feed) need no code: a feed row, a profile, a saved sample and expected cases. Follow **Adding a Signal Source** (`docs/add-a-signal-source.md`). A source that fits none of the three kinds needs its own adapter; the end of that guide says what that involves. An authenticated source also needs its permissions recorded in Security and Data Handling and agreed before anything is built.

## 6. Add a tenant setting

Some tenant settings can't be read through any API Change Radar uses. A **tenant setting** row records one by hand, so the setting rule can check it: a signal whose fingerprint names a setting that is missing or off raises a setting exposure.

1. **Cases first:** a case with `target: setting:<key>` in `tests/cases/` (see `mc1557754-copilot-credits-absent.json` and `mc1558033-copilot-credits-present.json`).
2. **Add the setting to the vocabulary** (facet `setting`) if it isn't there.
3. **Record the setting** in the app (Operations, Tenant settings), or with `setup/Import-MatchingData.ps1 ... -TenantSetting @{ key = '<key>'; state = 'enabled'; scope = '<products>'; evidence = '<how you know>' } -Apply`. Tenant settings are your data: they never go in the repository.
4. **Keep it current:** a setting someone changes in the admin centre isn't seen until you update the row.

## 7. Add an estate source

The estate comes from the Power Platform inventory and the Dataverse detail flow. Another source of assets (for example the Copilot Studio Kit's inventory) is mapped to the estate file format (`docs/estate-file-format.md`), with fixture cases first, and is a design decision for an ADR.
