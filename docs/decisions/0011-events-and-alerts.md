# 0011: Events and alerts (phase 5)

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0011-events-and-alerts) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0011-events-and-alerts)

Date: 2026-11-21. Status: **Accepted**, 2026-11-21 (Simon: three questions below, recommended option each; the design choices under "Mechanics" are Claude's, open to challenge).

## Context

Phase 5 is done when "a test incident and a test Message Center post each trigger the right card and the right events" (spec §9). Spec §7 sets the alert rules, and §12 sets the event types, the dispatcher and the reference handlers. Two read-only handlers ship in this phase: **Notify-Teams** (the §7 card) and **Digest-Weekly** (the Monday digest).

`crdr_event`, `crdr_subscription`, `crdr_handlerrun` and `crdr_alertlog` have existed since phase 0 and are empty. `crdr_handlerrun` has an alternate key on (event, subscription).

## Decisions (Simon, 2026-11-21)

1. **Channel: a Teams chat with Simon.** The Flow bot posts to a 1:1 chat with the recipient in config (`alert_recipient`, set at install, never in the repo). No team or channel is needed. A channel can come later through config (`alertchannel` already has `teams_channel`). This settles spec §10, open decision 4, for v1.
2. **Card buttons are links only.**
   - "Open in Change Radar" opens the signal or assessment, and "Open source" opens the Message Center post or roadmap item.
   - Acknowledge and dismiss happen in the app: exposure status, or an assessment override.
   - No flow run waits on a card. Interactive buttons can come later.
3. **The "done when" test uses labelled test signals.**
   - A dev-only script inserts `TEST-INC-0001` (service health) and `TEST-MC-0001` (Message Center), with titles starting `[TEST]`, plus the `created` version rows a collector writes.
   - The normal pipeline then runs on them.
   - A cleanup script removes them, with their events, handler runs, exposures and assessments.
   - It refuses any environment other than the expected one.

## Mechanics (Claude, 2026-11-21)

- **Where events are raised (revised 2026-11-21, after reading the collectors):**
  - **Signal events** come from a Dataverse trigger on new `crdr_signalversion` rows. Every collector write already creates one, with `crdr_changedfields` saying exactly what changed: `created`, or a list such as `key date; date label; last modified`. The test script writes the same version rows a collector would.
  - **Exposure and assessment events** are raised inside the match, assess and record-override flows. A table trigger can't be used for them: those flows rewrite status and rating on every run, even when unchanged, and a trigger can't see the previous value. The flows know the transition.

  | Event | Raised by |
  |---|---|
  | `signal.new` | Version row `created` |
  | `incident.opened` | Version row `created` for a service health signal |
  | `signal.changed` | Version row listing title, key date, date label or action required. A wording-only or last-modified-only change isn't an event; the snapshot keeps it. |
  | `incident.resolved` | Version row listing horizon for a service health signal now in Future (the collector sets Future when `isResolved`, ADR 0007) |
  | `exposure.found` | The match flow: exposure created, or set back to New from No longer matches |
  | `assessment.rated` | The assess flow (assessment created, or estate impact changed) and the record-override flow (override set, changed or cleared) |
  | `deadline.approaching` | A daily flow, for live signals that require action, have a key date exactly 14 or 3 days away, and have open live exposures |

  Each event carries a compact JSON payload: external id, estate (live, fixture or synthetic; none for signal events), estate and override impact, changed fields, and days left. It also carries a correlation id, `<event type>|<record id>|<time or date>`, which the deadline flow uses to avoid raising the same reminder twice.
- **The dispatcher queues; handlers pick up.** This replaces spec §12's child-flow call, so handlers stay fully separate.
  1. The dispatcher triggers on a new `crdr_event`, matches enabled `crdr_subscription` rows, and creates one `crdr_handlerrun` per match, named `<handler> | <event>`, outcome `queued`.
  2. Each handler flow triggers on new handler runs with its own name prefix, does its work, and sets the outcome.
  3. The (event, subscription) key makes a duplicate dispatch fail instead of running twice.
  4. Installers can add a handler by adding a subscription row and a flow, without touching the core solution.
- **Alerts come from live estates only.** Fixture and synthetic events are raised, for demos and tests, but the dispatcher skips them for any handler that posts outside Change Radar. Both v1 handlers post to Teams.
- **Subscriptions are seed data** (`seed/subscriptions.csv`), mapping spec §7 onto handlers:

  | Event | Handler | Filter |
  |---|---|---|
  | `incident.opened`, `incident.resolved` | Notify-Teams | any severity |
  | `assessment.rated` | Notify-Teams | effective impact High or Critical |
  | `deadline.approaching` | Notify-Teams | — |
  | `signal.new`, `signal.changed`, `exposure.found`, `assessment.rated` | Digest-Weekly | — |
- **The card** follows spec §7:
  - title and a "why it matters to you" line;
  - up to 5 affected assets, by name: the card goes to the tenant's own admin inside Teams, so names are fine here, unlike the LLM prompt;
  - key date and recommended action;
  - the two link buttons.

  Each card sent is logged in `crdr_alertlog`.
- **Notify-Teams writes `writes = no`.** It posts a message and changes nothing outside Change Radar (spec §12). It uses a Teams connection reference, `crdr_teams`, which Simon creates as himself.

## Steps

1. Expected cases first, then the engine (`engine/ChangeRadar.Events.psm1`):
   - event derivation from record changes;
   - subscription matching;
   - card content.
2. Schema: `queued` handler outcome; config keys `alert_recipient` (empty in the seed, set at install, so every installer chooses their own) and `app_url`; subscriptions seed. Then the event-raising flows, the dispatcher and the daily deadline flow.
3. The Notify-Teams and Digest-Weekly handlers, once the Teams connection exists.
4. The test-signal scripts, the "done when" run, the demo, the export and the PR.

## Consequences

- Every pipeline change is visible as an event, so later handlers (Planner, GitHub, content ideas) plug in without touching core flows.
- The match, assess and override flows gain event-writing steps. Their parity checks still apply.
- Dataverse triggers add a small delay, typically seconds to a minute. That's well inside spec §7's "within 15 minutes of the poll".
- The test scripts write to the dev environment only, and clean up after themselves.

## Phase 5 outcome against "done when" (2026-11-21, confirmed by Simon)

Test signals were injected with `New-TestSignals.ps1` in pp-lab and removed afterwards with `Remove-TestSignals.ps1`. No `TEST-` signals or events remain.

| Test | Events | Cards (Teams chat, Flow bot) |
|---|---|---|
| TEST-INC-0001 created | `signal.new`, `incident.opened` | "Incident: [TEST] Users can't open model-driven apps" |
| TEST-INC-0001 resolved | `signal.changed`, `incident.resolved` | "Resolved: …" |
| TEST-MC-0001 (scheduled prompts, action due in 14 days, manual fingerprint) | `signal.new`; `exposure.found` ×16 (1 live, 15 synthetic); `assessment.rated` ×2 (live and synthetic, both Critical: generic High from the prompt, +1 action bonus); `deadline.approaching` (14 days) | "Critical for your estate: …" and "Action due in 14 days: …" |
| Digest run early | the 5 queued digest runs | One digest card |

- **Live only:** synthetic events were raised but not dispatched.
- **Simon confirmed** that all 5 cards arrived and that every link opened the right place.
- **Checks:** `Test-EventParity.ps1` covered 24 events, 9 handler runs and 4 cards, and the engine agrees on every one. The exposure and assessment parity checks still hold after the event steps were added. Engine tests: matching 30/30, assessment 19/19, events 35/35.
- **For the phase 6 polish list:**
  - Copilot-created flows carry generated names, for example `OAI_<guid>_MemoryAgent…`, which read badly on a card. Show a friendlier label. **Done 2026-11-22:** cards and the digest show "MemoryAgent (created by Copilot)" (engine `Get-AssetLabel`; cases in `tests/events/labels.json` and card-06).
  - The digest lists ratings in lower case ("critical"); match the cards' capitalisation. **Done 2026-11-22:** rating lines read "RM570671 · Synthetic · High" (engine `Format-DigestLine`).

## Addendum, 2026-11-22: where alerts go (Simon) — accepted 2026-11-23, for packaging

Status: **Accepted** by Simon, 2026-11-23. Not built yet.

**Context:** cards and the digest go to one person (`alert_recipient`) in a Teams chat with the Flow bot. That suits a single admin. An organisation with an admin team needs several people, a Teams channel, email, or a mix.

**Decision:**
- Replace `alert_recipient` with `alert_destinations`: a semicolon-separated list, set at install and never in the repo, where each entry is one of:
  - `chat:<user principal name>`: today's behaviour, one entry per person;
  - `channel:<team id>/<channel id>`: one post the whole team sees and can reply to;
  - `email:<address>`: a person or a shared mailbox, for people who don't live in Teams.
- `alert_recipient`, when set, is read as one `chat:` entry, so existing installs keep working.
- One handler run per destination, so one failure (for example a removed channel) never stops the others, and each run records its own outcome.
- Email needs the Office 365 Outlook connector: one more connection reference, and a data policy (DLP) check at install. It ships in the solution with no destination until one is configured.
- Optionally, a destination per event type later (incidents to the channel, the digest by email). Not in the first version.

**Build decisions (Simon, 2026-11-23), which refine the two points above:**
- **One run, a step per destination.** An event still gets one handler run per handler. Inside it, each destination is sent in its own step, so one failure never stops the others. The run's detail lists each destination's result. The run is Failed if any destination failed or any entry is invalid, so a bad setting gets noticed. The dispatcher, the digest's bookkeeping and the Radar page are unchanged.
- **Email has its own handlers.** `Notify-Email` and `Digest-Email` are separate flows with their own subscription rows, for the same events as the Teams handlers. They ship switched off, and their subscriptions ship disabled. The Teams handlers send to `chat:` and `channel:` entries and never need an Outlook connection. The email handlers send to `email:` entries through connection reference `crdr_outlook` (Office 365 Outlook, Send an email (V2), as the connection's owner). To turn email on: create the connection, switch on the two flows and enable their subscriptions.
- The alert log records each destination that was sent to, by kind: Teams chat, Teams channel or email (a new `email` option on the alert channel choice).

**Live test (2026-11-23, approved by Simon).** In pp-lab, with `alert_recipient` as before, `alert_destinations` set to one `channel:` entry (a test team's General channel) and one `email:` entry (the Outlook connection owner's own address), and only the "Incident opened by email" subscription enabled. One labelled signal, `TEST-INC-0001` (`New-TestSignals.ps1 -Scenario incident`), gave:

| Check | Result |
|---|---|
| Notify-Teams run | Succeeded: "Sent to 2 of 2 Teams destinations." The card arrived in the 1:1 chat and in the channel (posted by Workflows). |
| Notify-Email run | Succeeded: "Sent to 1 of 1 email destination." The email arrived, subject "Incident: [TEST] Users can't open model-driven apps". |
| Alert log | Three rows: Teams chat, Teams channel, Email. |
| Digest-Weekly | The `signal.new` run queued for the digest, as before. |
| `Test-EventParity.ps1` | PARITY: dispatch (including the new Notify-Email subscription) and the card fields agree with the engine. |

Afterwards the test signal and everything it caused were removed (`Remove-TestSignals.ps1`), the email subscription disabled again, `alert_destinations` cleared, and both email flows switched off, so pp-lab is back to its shipped state apart from the Outlook connection. The solution export carries both email flows switched off.

**Consequences:** the card is built once per handler and sent per destination. The install guide gains a "where alerts go" step. The permissions doc names the Outlook connection, if it is used.
