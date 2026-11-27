---
title: Change Radar
subtitle: Requirements
document: CR-REQ-01
version: "0.3"
date: 24 November 2026
status: Draft
audience: Whoever plans an install, and the people who approve it: platform owners, licensing and security reviewers
owner: Simon Owen
release: Change Radar 0.3.1
intro: keep
breaks: none
---
# Requirements: roles, permissions, licences and credits

> **For:** whoever plans an install, and the people who approve it. **Kind:** reference.
> **Status:** draft from the development build (24 November 2026). Each line says how it is known: **Learn** (checked on Microsoft Learn, with the date), **measured** (seen in the development environment), or **to verify** (not yet confirmed; the two clean installs of 24 November 2026 confirmed the rest). Nothing here is a licensing opinion: the Microsoft licensing guides are the authority, and they are changing (see "Credits").
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=requirements) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=requirements)

Change Radar needs three groups of people, at three different times:

| Who | When | Typically |
|---|---|---|
| **Installers** | Once, at install | A Power Platform admin, an Entra admin for one consent, an Azure owner for one Key Vault |
| **The connection owner** | Always: the flows run as this account | A named admin or a service account |
| **People who use it** | Day to day | Platform owner, CoE, admins; later solution owners (backlog B2) |

## 1. Installing

| Step | Role needed | Why | Known by |
|---|---|---|---|
| Create the reader app registration | Application Developer, Application Administrator or Cloud Application Administrator (Entra) | The reader identity is an app registration with a certificate | to verify (least role) |
| Grant admin consent for Graph `ServiceHealth.Read.All` and `ServiceMessage.Read.All` (application permissions) | **Privileged Role Administrator** or Global Administrator (Entra). Cloud Application Administrator and Application Administrator can't consent to Microsoft Graph application permissions | Service health and Message Center are read with application permissions | Learn, 2026-11-24 ([grant admin consent](https://learn.microsoft.com/entra/identity/enterprise-apps/grant-admin-consent)) |
| Create a resource group and Key Vault, and generate the certificate in it | Contributor on the subscription or resource group, plus Key Vault Certificates Officer on the vault | The private key is generated in, and never leaves, the vault | measured (`setup/New-ReaderIdentity.ps1`) |
| Assign Key Vault roles (to the installer, and Key Vault Secrets User to the Dataverse service principal) | Owner, User Access Administrator or Role Based Access Control Administrator on the vault | Dataverse reads the certificate through a secret environment variable | measured; least role to verify |
| Import the solutions, create the application user and the Change Radar Reader role, set environment variables, import seed data | **System Administrator** in the Change Radar environment | Standard solution install | measured |
| Make the connections (Dataverse and Power Platform for Admins V2 for the core; Teams, and optionally Office 365 Outlook, for the alert handlers) | The connection owner signs in to each | Flows run on these connections | measured |
| Optional: add Ask Change Radar to Teams and Microsoft 365 Copilot | Copilot Studio maker in the environment; a Teams administrator to make it available organisation-wide (individual sharing needs no approval) | The agent is a Teams app | measured 2026-11-24 |

An admin who is a Global Administrator, or a Power Platform administrator, can give themselves System Administrator in an environment ("self-elevate"), without a Dataverse role (Learn, checked 2026-11-24).

## 2. Running: the connection owner

Scheduled and automated flows run under their **owner's** licence; the connections inside them are separate from the licence check (Learn, 2026-11-24, [Power Automate licensing FAQ](https://learn.microsoft.com/power-platform/admin/power-automate-licensing/faqs)).

| Need | What | Why | Known by |
|---|---|---|---|
| Licence | **Power Automate Premium** for the flow owner (or Process licences on the flows) | The flows use premium features: Dataverse, HTTP, and AI Builder actions (a flow with any AI Builder action is premium) | Learn, 2026-11-24 |
| Power Platform for Admins V2 connection | The connection's account must be a **Global Reader** (read-only, the least privilege), Global Administrator, Power Platform administrator or Dynamics 365 administrator. The inventory query only supports delegated (user) authentication, not a service principal | Estate inventory | Learn, 2026-11-24 ([Power Platform inventory](https://learn.microsoft.com/power-platform/admin/power-platform-inventory)) |
| Dataverse connection | Write access to Change Radar's own tables (System Administrator today; a Change Radar admin role is planned, see section 5) | The flows write signals, exposures, assessments and events | measured |
| Teams connection (handlers only) | Can post to the chats and channels named in `alert_destinations` | Cards and the weekly digest (ChangeRadarHandlers, ADR 0023) | measured |
| Office 365 Outlook connection (handlers only, optional) | A mailbox | Email alerts | measured |
| Data loss prevention | Core: Dataverse, HTTP (with Microsoft Entra ID), HTTP, Power Platform for Admins V2 and AI Builder in the same data group in the environment's data policy; with the alert handlers, add Microsoft Teams, and Office 365 Outlook for email | A flow can't run if its connectors are split across groups | to verify against a real policy |

**Outbound requests** (for proxy and firewall reviews): `graph.microsoft.com` and `login.microsoftonline.com` (reader app), `www.microsoft.com` (roadmap, Power Platform blog), `learn.microsoft.com` (model retirement tables, release notes, licensing pages), `news.microsoft.com` (Book of News), `go.microsoft.com` (licensing guide links, which redirect to the PDF's host: to verify), and the Dataverse URL of each detail environment. Public pages are read with a plain GET as `ChangeRadar/1.0`.

## 3. Credits: what the AI costs

AI Builder capacity is changing. Since 1 November 2025 new customers buy **Copilot Credits** to run AI Builder features; from 1 November 2026 new or renewed Power Platform and Dynamics 365 licences no longer include seeded AI Builder credits. In Power Apps and Power Automate, AI Builder features use AI Builder credits first and then Copilot Credits; with neither, they're blocked (Learn, 2026-11-24, [AI Builder licensing](https://learn.microsoft.com/ai-builder/administer-licensing), [End of AI Builder credits](https://learn.microsoft.com/ai-builder/endofaibcredits)). Change Radar itself flags this change (MC1526652).

| Use | Rate (Learn rate table, 2026-11-24) | What Change Radar uses | Known by |
|---|---|---|---|
| Fingerprint and rating prompts (basic model) | 1.2 AI Builder credits, or 0.1 Copilot Credits, per 1,000 tokens | About 3,400 tokens a rating call and 4,600 a fingerprint call, so about 4 to 6 AI Builder credits, or 0.35 to 0.46 Copilot Credits, per call | measured: 1,041 calls used 4,786 AI Builder credits in November (one-off backfill included). **Billed in Copilot Credits** (spike T13, 2026-11-27): 0.1 per started 1,000 tokens, rounded up per call, so 0.3 to 0.5 a call (ADR 0027) |
| Licensing guide text recognition | 3 AI Builder credits, or 0.1 Copilot Credits, per page | Only when Microsoft replaces a guide | measured twice: spike T12 and the install test (2026-11-24) each logged **one AI event of 3 AI Builder credits for a whole guide**, sent in one call. The rate table charges per page (the guides run to about 30 to 95 pages): **to verify** against the capacity report whether billing matches the event log |
| Ask Change Radar (optional) | Copilot Credits per question (agent actions and generative answers) | About 10 Copilot Credits a question if billed; free for Microsoft 365 Copilot licensed users in Teams and Microsoft 365 Copilot | measured (spike T10); Learn, 2026-11-23 |
| Matching | None | No AI | measured |

**Safeguards:** `fingerprint_max_per_run`, `rating_max_per_run` and `assessment_max_per_run` cap the prompt calls in each night's run (anything over a cap waits for the next night; nothing is skipped); `rating_scope` limits which signals are rated; `demo_data` off stops demo ratings; unrated sources (licensing, Book of News) are never sent to a prompt. Capacity is allocated per environment in the Power Platform admin centre (Licensing, Capacity add-ons).

### 3.1 Estimate your credits

An approximation from the development build and the clean install test (November 2026). Use it to size capacity before you install, then replace the assumptions with your own figures after the first fortnight (section 3.2).

**What drives the cost.** Mostly the number of Microsoft changes you watch, not the size of your estate. Signals are Microsoft's, so a small tenant and a large one with the same sources get the same signals. Estate size only affects the third prompt, the estate assessment, which runs once for each signal that touches something you own.

| Prompt | Runs for | Calls |
|---|---|---|
| Fingerprint | Every new or changed signal, except service health and unrated sources | One a signal, again whenever it changes |
| Rating | New or changed signals in the rating window (`rating_scope = window`: Now, Imminent, key date within six months, or exposed), or all of them (`all`) | One a signal, again whenever it changes |
| Estate assessment | Signals with open exposures in your estate | One when first exposed, again whenever the signal or what it affects changes |

**What one call costs** (measured): about **5.5 AI Builder credits**, or about **0.46 Copilot Credits**. The development environment averaged 5.2 AI Builder credits a fingerprint call and 4.8 a rating call over about 400 of each; the install test's first night averaged 6.1 and 5.3. The Copilot Credit figure has been checked against billing: 48 calls on the production model billed an average of 0.41 (spike T13, ADR 0027). 0.46 leaves a small margin.

**Which currency.** The nightly cloud flows spend AI Builder credits while any are left, then Copilot Credits. A prompt called any other way, from an agent flow or straight through the Dataverse API (for example a test script), bills Copilot Credits straight away. Agent flows also bill their actions, which is why Change Radar's pipeline is built from cloud flows (ADR 0016).

**The inputs.** Measured values come from the development environment and the install test; assumed values are estimates to replace with your own.

| Input | Symbol | Default sources | Known by |
|---|---|---|---|
| Prompt-eligible signals at install (Message Center, roadmap, rated feeds) | S | about 450 | measured: 441 in the install test, 459 in the development environment. Switching on more feeds adds their entries (the 22 seeded feeds, all on, add about 90) |
| Of those, in the rating window | W | about 120 | measured: 119 in both. With `rating_scope = all`, W = S |
| New or changed eligible signals a day | D | 5 to 15 on a working day, fewer at weekends | measured, early: 5 to 12 a day in the development environment's first week of event history |
| Share of those in the rating window | w | about 0.25 (1 with `all`) | measured: W ÷ S |
| Signals with open exposures in your estate | E | 10 small, 50 medium, 150 large | assumed. The development environment, with 50 live assets, has 9 |
| Share of exposed signals re-assessed each night | c | 0.05 (stable estate) to 0.3 (lots of change) | early: 0 to 7 a night across 17 exposed signals in the development environment |

**The formula.** Credits = calls × 5.5 AI Builder credits (or × 0.46 Copilot Credits).

- **First month, one-off backlog:** S + W + E calls. Each night's new changes take their share of the cap first, so the fingerprint backlog takes about S ÷ (cap − D) nights. **New installs start with catch-up** (`catchup_max_per_run` = 100 until `catchup_until`, set at install to 14 days ahead), so the backlog clears in about a week: 5 nights for the default sources. Without catch-up, at 25 a night, it takes three to six weeks, and if D reaches the cap it never clears. Catch-up doesn't add calls; it spends the same backlog sooner.
- **Every month after:** 30 × (D × (1 + w) + E × c) calls.
- **Peak month:** the first, backlog plus a normal month. Capacity resets monthly and doesn't roll over, so buy or allocate for the peak (Learn, 2026-11-24, [Overview of licensing](https://learn.microsoft.com/ai-builder/administer-licensing)).
- **Ceiling:** the caps bound any month at (fingerprint + rating + assessment caps) × 30 calls. At the seeded 25 each, that's 2,250 calls: about **12,400 AI Builder credits or 1,035 Copilot Credits a month at most**, whatever happens. The first month's ceiling, with 14 nights of catch-up at 100, is 5,400 calls (about 29,700 AI Builder credits or 2,480 Copilot Credits); the backlog normally stops well short of it.

**Worked examples** (D = 10, the default sources unless stated):

| | Small | Medium | Large |
|---|---|---|---|
| Setup | E = 10, c = 0.1 | E = 50, c = 0.2 | All 22 feeds on (S = 540), `rating_scope = all`, D = 15, E = 150, c = 0.3 |
| First-month backlog | 580 calls | 620 calls | 1,230 calls |
| Each month after | 405 calls | 675 calls | 1,650 calls: 450 fingerprint, 450 rating, and 750 assessments (the cap holds 1,350 down to 750) |
| Backlog cleared in | 5 nights (30 without catch-up) | 5 nights (30) | 7 nights (54) |
| Peak month | about 5,400 AI Builder credits, or 455 Copilot Credits | about 7,100, or 595 | about 19,100, or 1,600. Without catch-up the caps hold it to about 12,400, or 1,035, and the backlog spills into the next month |
| A normal month | about 2,200, or 185 | about 3,700, or 310 | about 9,100, or 760 |

For scale: a Copilot Credit pack is 25,000 credits a month (Learn, 2026-11-24, [Copilot capacity packs](https://learn.microsoft.com/copilot/implement/copilot-capacity-packs)), and a Power Automate Premium licence bought before 1 November 2026 includes 5,000 AI Builder credits a month until the contract renews ([AI Builder credits](https://learn.microsoft.com/ai-builder/credit-management)). Copilot Credits may be shared with other workloads in your tenant, such as Copilot Chat agents, so check what's already committed.

**What isn't in the estimate:**

- Text recognition on licensing guides: 3 AI Builder credits per guide in the event log (above), only when Microsoft publishes a new one.
- Ask Change Radar (optional): about 10 Copilot Credits a question, unless the asker has a Microsoft 365 Copilot licence.
- Demo data: off by default. With it on, the demo estate's exposures add estate assessments, held by `assessment_max_per_run`.

### 3.2 Measure your own

After a fortnight, swap the assumed inputs for your own. `setup/Get-CreditEstimate.ps1` does this in one read-only run. It measures every input from the environment (falling back to the assumptions above, and saying so, where there's under three days of history), applies your caps, and prints the forecast next to the credits the prompts actually used:

```powershell
./setup/Get-CreditEstimate.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<environment name>'
```

It uses the same formula as above (engine `Get-CreditForecast`; the worked examples are its test cases in `tests/credits/credits.json`). To find the figures by hand:

- **E:** open exposures in the Change Radar app (Radar page, Your estate), counted by signal.
- **D and c:** the **Collection runs** view in the app. The fingerprint run's summary gives signals fingerprinted a night; the assess run's gives rated, prompted (estate assessments) and deferred.
- **Credits actually used:** Power Platform admin centre, Licensing, then AI Builder or Copilot Credits, filtered to the Change Radar environment. Per prompt, the AI events table (`msdyn_aievent`) holds one row per call with the credits it consumed.

If a run's summary shows **deferred** estate assessments every night, `assessment_max_per_run` is lower than your estate needs: raise it, or accept that assessments lag by a night or two.

## 4. Using it

| Who | Needs | Known by |
|---|---|---|
| People who open the Change Radar app (Radar page, Fingerprint review, forms) | A licence with **premium Power Apps** use rights (Power Apps Premium, Power Apps per app, or pay-as-you-go): every user of a model-driven app needs one, and enforcement tightens from **February 2027**. Plus a Change Radar security role (section 5) | Learn, 2026-11-24 ([Power Apps licensing FAQ](https://learn.microsoft.com/power-platform/admin/powerapps-licensing-faq)) |
| People who receive Teams cards and the digest | A Teams account. Opening the app from a card needs the app licence above | measured |
| People who ask Ask Change Radar | Access to the agent (shared to them), and a Change Radar role: the agent reads as them, so someone without a role gets no data (tested 2026-11-24). Whether reading Dataverse through the agent needs a Power Apps licence: **to verify** | measured; to verify |

## 5. Gaps found while writing this (product work, ADR 0022)

- **Security roles for people: built 2026-11-24.** **Change Radar User** (read every table; write exposure status, assessment overrides, a signal's Watched flag and fingerprint review) and **Change Radar Admin** (full rights on Change Radar's tables), both linked to the app and shipped in Core (`solutions/design/roles.json`, `setup/dev/Deploy-RolesToDev.ps1`). Tested at the install test with a real account holding only Basic User and Change Radar User (`install-test-log.md`, finding 22). In the development environment everything had run as System Administrator, which hid the gap.
- **The connection owner holds System Administrator** in the development environment. With the admin role above, the flows can run as a less privileged account.
- **Everything still marked "to verify"** needs something the clean installs could not provide (a real data policy, a least-privilege Entra role, a year of data, a capacity report). Each is checked when an installing organisation can, and this page is corrected from what it finds.
