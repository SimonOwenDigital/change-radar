# 0008: Estate inventory (phase 2)

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0008-estate-inventory) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0008-estate-inventory)

Date: 2026-11-19. Status: **Accepted**, 2026-11-19 (Simon: identity, environments, kit and phase 1b). The build approach is Claude's proposal within those decisions.

## Context

Phase 2 is done when "every app, flow and agent in the tenant appears with facets and evidence" (spec §9).

Verified on Microsoft Learn, 2026-11-19:

- The inventory API and the "Query Power Platform resources" action (Power Platform for Admins V2 connector) support **delegated users only**. A service principal or managed identity gets HTTP 403. ([Inventory API](https://learn.microsoft.com/power-platform/admin/inventory-api))
- Workflow agent flows have no environment information. Model-driven apps have no owner. Flow owner is the creator and doesn't follow ownership changes. ([Known limitations](https://learn.microsoft.com/power-platform/admin/power-platform-inventory#known-limitations))

Observed 2026-11-19: Simon's everyday account can run inventory queries delegated (`pac resource-query`). It sees 3 environments, 5 agents, 9 cloud flows, 13 apps and about 970 connector rows.

## Decision

| Question | Decision |
|---|---|
| Inventory identity | A **Power Platform for Admins V2 connection under Simon's everyday account**, in pp-lab. The run log records the tier. If the connection lapses, a run fails visibly in `crdr_collectionrun`. |
| Dataverse detail | **pp-lab only for now.** The Change Radar Reader role gains read on the component tables (solution, solution component, bot, bot component, workflow, connection reference, custom control). Before EYW-Ops or the default environment, Claude brings Simon the exact privilege list. |
| Copilot Studio Kit | **Deferred.** Agents use native inventory (orchestration, harness, channels, connection provider). MCP, HTTP actions and autonomous triggers stay unknown, and the engine reports them as unknown. Revisit in phase 3 if a rule needs them. |
| Phase 1b | **Folded into phase 2.** Synthetic and live estates land in the same tables (`crdr_asset`, `crdr_assetfingerprint`), labelled by `source`, never mixed in one rating. |

**Build approach:**

- **Live estate:** a generated cloud flow, "collect estate inventory", runs daily. It pages through `PowerPlatformResources` and upserts `crdr_asset`. It derives asset facets in the flow, using maps generated from `seed/asset-signatures.json`, and upserts `crdr_assetfingerprint` with evidence. Assets not seen in a run keep their `lastseen`, so removed assets age out visibly rather than being deleted.
- **Synthetic estate:** a dev script loads an estate file through the local engine's `Get-AssetFingerprints` into the same tables, as `source = synthetic`. It writes to pp-lab only.
- **Parity:** `queries/inventory.ps1` exports the live inventory in estate-file shape, and the engine fingerprints it. A check compares those fingerprints with what the flow wrote. The engine stays the executable specification; the flow is what ships.

## Consequences

- The inventory connection is tied to Simon's account. Installers will need a guide on choosing the account (phase 7 docs).
- Facet derivation exists twice, in the engine and in the flow. The parity check is what keeps them aligned; run it after any change to `asset-signatures.json`.
- Agent capabilities that need the kit or bot components are absent. Phase 3 rules that depend on them will report "unknown", not "no exposure".

## Addendum, 2026-11-20: Dataverse detail scope

**Context.** The reader role now reads the component tables in pp-lab (`Test-ReaderIdentity.ps1`, 15 of 15 checks pass). But pp-lab holds no agents: all 5 tenant agents are in the default environment. Native inventory already reports agent knowledge sources by type, tool counts and triggers (`componentsCounts`), with no extra permission.

**Decision (Simon, 2026-11-20).**

- Agent facets come from inventory where it reports them. First: `capability: custom_knowledge` when `componentsCounts.knowledge > 0`. Assumption: any knowledge source counts, public websites included. Agents without `componentsCounts` get no facet.
- Dataverse detail stays pp-lab only, as a small collector that proves the per-environment path.
- The default environment waits until a phase 3 rule needs MCP or HTTP detail.

**Findings that shape the pp-lab collector** (observed 2026-11-20):

- pp-lab has 357 code components, all Microsoft-shipped and managed. No maker-built PCF exists, so a positive `pcf_control` case needs a fixture PCF imported into pp-lab.
- Canvas apps list their dependencies in `canvasapp.cdsdependencies`. Reading it needs `prvReadCanvasApp`, which is not in the agreed privilege list. Model-driven app dependencies are readable via `dependency`, which has no read privilege.
- Agent `triggers` was empty for every live agent, so its shape is unverified. `autonomous_trigger` is not derived from it yet.

## Addendum 2, 2026-11-20: fixture labelling and Dataverse detail flow

**Decisions (Simon, 2026-11-20).** The reader role also gets `prvReadCanvasApp` and `prvReadPublisher`, in pp-lab and read-only. A fixture PCF goes into pp-lab. Fixtures are recognised by **solution membership**. The fixture solution keeps the name **ChangeRadarFixtures**. Spec §15.1's optional `ChangeRadarDemo` stays a separate, later deliverable. Canvas detection will be proven against a fixture later.

**Design.**

- `crdr_asset.componentid` holds the Dataverse ID from inventory: `appModuleId` for model-driven apps, `workflowEntityId` for flows, and `name` for canvas apps. All three were verified 2026-11-20.
- New flow, **Change Radar: collect Dataverse detail**. It runs daily at 04:30, after inventory at 04:00. For each URL in `crdr_config` `detail_environments` (an installer value; empty means no detail is collected), it calls the Web API as the reader app and does two things:
  - It labels assets whose component is in a solution in `fixture_solutions` as `source = fixture`, and sets `solutionuniquename` and `syntheticorg`.
  - It owns `capability: pcf_control`. A control counts when it is maker-built, meaning it ships in a non-Default solution from a non-Microsoft publisher (seed `pcfMicrosoftPublishers`). The chain is control ← form (60) ← app module (80), or control ← canvas app (300).
- The estate flow sets `source` only when it creates an asset. It matches existing assets of any non-synthetic source, so a relabelled fixture is never duplicated. It never deletes the facets listed in seed `detailFacets`.
- Locally, `queries/dataverse-detail.ps1` applies the same rules and moves fixture resources into a separate estate file with `source = fixture`. `Test-EstateParity.ps1` compares live and fixture separately.

**Consequences.**

- A new fixture asset is labelled live for the time between the 04:00 and 04:30 runs. Nothing rates assets before phase 3; phase 3 must run after the detail flow.
- An asset that leaves a fixture solution is not relabelled live. This is recorded as a gap in the run log.
- Code components on the forms of a table that an app includes without listing its forms are not attributed to the app. This is also recorded as a gap.
- Agents have no `componentid` yet. Bot detail waits for a phase 3 rule that needs it.
