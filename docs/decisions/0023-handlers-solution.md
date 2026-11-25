# 0023: The handlers' own solution

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0023-handlers-solution) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0023-handlers-solution)

Date: 2026-11-24. Status: **Accepted** (Simon, 2026-11-24: all four design choices below). **Built and proved 2026-11-24** (install test run 2, parts A and B; done-when met). Item 2 of ADR 0022's product work.

## Context

Spec §7 and §13.2 put the alert handlers in their own solution, `ChangeRadarHandlers`, all disabled by default, so installers choose the ones they want and can add their own without touching the core. Today the four handlers live in `ChangeRadarCore`, and `ChangeRadarHandlers` exists in pp-lab but is empty (version 0.1.0.0).

Facts checked in the repo (2026-11-24):

- **The split is already clean in the design.** The dispatcher doesn't call handlers as child flows: it writes one queued `crdr_handlerrun` per matching enabled subscription. Notify-Teams and Notify-Email trigger on new handler runs whose name starts with their own name; Digest-Weekly and Digest-Email run on a schedule and collect their queued runs. So Core never depends on a handler.
- **Only the four handlers use Teams or Outlook.** Every other flow uses Dataverse (and the estate flow, Power Platform for Admins V2).
- `seed/subscriptions.csv`: 7 subscriptions each for Notify-Teams and Digest-Weekly (enabled), Notify-Email and Digest-Email (disabled).

## Decision

1. **What moves.** Notify-Teams, Digest-Weekly, Notify-Email and Digest-Email, and the `crdr_teams` and `crdr_outlook` connection references, move to `ChangeRadarHandlers`. Core keeps event raising, the dispatcher, and the tables for subscriptions, handler runs and alert logs. Handlers depends on Core; Core never depends on Handlers. Core installed alone gives the Radar, the app and Ask, with no alerts.
2. **All handlers arrive switched off** (Simon: "All off"). Nothing posts until the admin turns handlers on, after setting destinations. The install guide gets a "turn on alerts" step.
3. **One script switches a handler on or off** (Simon: "One script does both"). `setup/Set-Handlers.ps1 -On <names>` / `-Off <names>` switches each handler's flow and its subscriptions together; plans by default. Subscriptions are seeded disabled, so no runs are queued for a handler nobody runs. `Test-Install.ps1` warns about runs queued more than a day for a handler that's off.
4. **A template for your own handler** (Simon: "Template flow + guide"). `ChangeRadarHandlers` ships a "Handler template" flow, switched off: it triggers on its own queued runs, reads the event, and marks the run Succeeded or Failed with a detail, which is the contract every handler keeps. `extend.md` gets a "write your own handler" section: the writes-outside rule (CLAUDE.md, spec §7), idempotency against the event id, logging to the handler run, and adding a subscription.
5. **Handlers reuse Core's Dataverse connection reference** (Simon: "Reuse Core's"): one Dataverse connection per install.

## Consequences

- **Simpler core install.** Core needs only the Dataverse and Power Platform for Admins V2 connections, and its data policy group shrinks to Dataverse, HTTP with Microsoft Entra ID, HTTP, Power Platform for Admins V2 and AI Builder. Teams and Office 365 Outlook are needed only with the handlers.
- **Existing installs move by upgrade order** (proved in install test run 2, part A): import `ChangeRadarHandlers` first, so the flows are in two solutions with the same ids, then upgrade `ChangeRadarCore` to a version without them; the flows stay because Handlers still holds them. The flows' on or off state survives (an import over existing flows keeps their state; shipping off applies to new installs), as do their ids and run history. Core's upgrade needs `--stage-and-upgrade`: a plain import never removes components.
- **Releases build three solutions** (`New-Release.ps1`), installed in the order Core, Handlers, Ask.
- **Subscriptions change meaning slightly:** enabled now also means "this handler is on". The seed ships them disabled; `Set-Handlers.ps1` enables them.
- pp-lab is unmanaged: the flows are added to `ChangeRadarHandlers` and removed from `ChangeRadarCore` there, and both are exported.

## Build plan

1. Tests first: `Set-Handlers` plan cases (on, off, unknown name, already on, a handler whose flow isn't installed) and the template's contract.
2. Generator: tag the four handler flows and the template with their solution; the template flow.
3. pp-lab: create the template; move the four flows and two connection references to `ChangeRadarHandlers`; export both solutions (the export checks extended: every flow in either solution matches the generator; Core contains no Teams or Outlook reference).
4. `setup/Set-Handlers.ps1`; `seed/subscriptions.csv` all disabled; `Test-Install.ps1` checks for handlers.
5. `New-Release.ps1` builds three; `deploymentSettings.template.json` split per solution.
6. Docs: `install.md` (connections per solution, "turn on alerts" step), `requirements.md` (data policy), `architecture.md`, `configure.md`, `extend.md`.
7. **Install test run 2** in the test environment: upgrade (Handlers first, then Core) with flows and history intact, and a fresh install of Core alone, then Handlers, in a new Developer environment.

## Done when

- `ChangeRadarCore` holds no handler flow and no Teams or Outlook connection reference; `ChangeRadarHandlers` holds the four handlers and the template, all off when imported.
- In the test environment, the upgrade keeps the handler flows, their run history and the existing handler runs, and `Set-Handlers.ps1 -On Notify-Teams,Digest-Weekly` brings cards back (a test incident card arrives).
- A fresh install of Core alone passes `Test-Install.ps1` with alerts reported as not installed; adding Handlers and switching them on passes it fully.
- Release 0.3.0 contains three solutions, checked and checksummed.
