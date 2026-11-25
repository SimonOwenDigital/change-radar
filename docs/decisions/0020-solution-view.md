# 0020: See the estate by solution

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0020-solution-view) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0020-solution-view)

Date: 2026-11-24. Status: **Accepted**, 2026-11-24 (Simon's idea; Simon accepted all six defaults; build in pp-lab first).

## Context

Change Radar shows exposures one asset at a time: an app, a flow, an agent, a prompt, a setting. People build and own **solutions**: one solution often holds several apps, flows and agents, and a change that touches one of them is the solution's problem. Simon wants to group and filter by solution. Later, the tool could hand a solution's exposures to its owner (ADR 0021), so this view is also the base for that.

What exists today (checked in pp-lab, 2026-11-24):

- `crdr_asset.crdr_solutionuniquename` exists but is filled in only for fixture assets. All 50 live assets have none.
- One component can belong to **several** solutions, and every one belongs to Default. A single column can't hold that.
- The detail flow already reads `solutioncomponents` in pp-lab (fixtures, Microsoft system prompts, PCF controls), and the reader role already reads `solution`, `solutioncomponent` and `publisher` there (ADR 0008). No new permission is needed in pp-lab.
- pp-lab's 33 live assets: 26 are in ChangeRadarCore, 2 in SGSizer, 1 in the Dataverse default solution (Common Data Services Default Solution), and a few Microsoft-managed apps in Microsoft's own solutions. Agent membership needs checking: Ask Change Radar shows none, although it is in ChangeRadarAsk, so the inventory's agent id may not be the bot id that `solutioncomponents` uses.
- The other two environments (15 live assets) are read only through the admin APIs, which don't report solutions. Reading them needs the Reader role in those environments (Dataverse detail), which is beyond today's scope.

## Proposal (defaults)

1. **Data.** A table `crdr_solution` (environment, unique name, display name, publisher, managed, published by Microsoft) and a link table `crdr_solutionmember` (asset, solution). The detail flow fills both for environments that have Dataverse detail, and removes membership rows that no longer hold.
2. **Which solutions count.** All solutions except Default, Active and the Common Data Services Default Solution, which contain everything and say nothing. Solutions published by Microsoft are kept but grouped as "Microsoft solutions", so a Microsoft system prompt shows where it came from.
3. **Assets outside any solution** are grouped as "Not in a solution". Assets in an environment without Dataverse detail are "Solution not known", so the two are never confused.
4. **Engine first.** A pure function in the engine decides membership and grouping from solution component rows; test cases first (`tests/solutions/`), then the flow and the page are checked against it (parity), as everywhere else.
5. **The Radar page:**
   - a **Solution** filter that narrows every section, including the Priority matrix and What lands when;
   - "Your estate" can **group by solution**;
   - a **By solution** section (collapsed by default): one row per solution with its exposed assets, highest impact, next deadline and how many need action. Selecting a row applies the filter.
6. **Synthetic estate.** The demo organisation gets solutions too, generated from its own random stream so nothing else moves, so the view can be shown without live data.

## Done when

1. Cases in `tests/solutions/` (positive, near miss, the three excluded solutions, several solutions per asset, not in a solution, not known) pass in the engine.
2. In pp-lab, membership rows match the engine for every live asset (parity), including agents.
3. The Radar page's Solution filter, grouping and By solution section agree with the engine (page parity) and show ChangeRadarCore and SGSizer correctly in the browser.
4. Nothing new is read outside pp-lab, and no permission changes.

## Build outcome (2026-11-24; confirmed by Simon 2026-11-24)

- **Tests first:** `tests/solutions/solutions.json`, 16 cases (object ids including agents, the three excluded solutions and a near miss, membership with an asset in two solutions, the catch-all groups, the per-solution summary). Engine `ChangeRadar.Solutions.psm1`: 16 of 16. All engine suites: 330 cases pass.
- **Schema:** `crdr_solution` (key: environment + unique name) and `crdr_solutionmember`. The asset lookup is parental and the solution lookup referential: Dataverse allows one parental relationship per table. The Reader role gained read on both (read only, as for every Change Radar table).
- **Agents:** the inventory has no component id for agents, so the object id falls back to the resource id in the source id (the bot id). Ask Change Radar is now found in `ChangeRadarAsk`.
- **Detail flow, step 5:** pp-lab: 34 memberships in 8 solutions (ChangeRadarCore 26, SGSizer 2, ChangeRadarAsk 1, the fixture solution 1, four Microsoft solutions). `setup/dev/Test-SolutionParity.ps1`: parity with the engine. A second run changed nothing. The Common Data Services Default Solution was excluded, as the rule says.
- **Demo data:** the synthetic organisation has 16 solutions and 324 memberships (305 of 912 resources), from their own random stream; nothing else in the estate moved. A demo environment always counts as known, since its solutions are generated with it.
- **Radar page:** a Solution filter (your estate, Microsoft solutions marked, "Solution not known", and demo data apart), a "By solution" section (collapsed by default), and "Group by solution" in Your estate. Page parity 54 of 54 (three new solution cases).
- **Seen in the browser:** live, "Solution not known" 4 assets and 2 items (the EYW default environment and one other have no Dataverse detail), Change Radar Ask 1 and 1, Change Radar Core 3 and 1; an independent count from Dataverse matched. Filtering to Change Radar Core leaves 1 of 802 items, in the matrix as one High item.
- **Found on the way:** a bundle cached by the previous page version had no solutions and broke the first render; the cache key moved to v2.
- **"Known" environments:** an environment counts as having Dataverse detail when it has any solution row. An environment in `detail_environments` whose assets are all outside solutions would show "Solution not known"; not the case in pp-lab.

## Addendum (Simon, 2026-11-24): affects and related

Simon expected a solution to show every signal connected to its components, not only exposures. Exposures are strict on purpose (all of a fingerprint group's facets must match), so Change Radar Core showed 1 signal. Measured for that solution: 1 by exposure, 10 sharing a specific facet, 44 sharing a resource type, 145 sharing a product. **Simon chose "affects + related".**

- **Affects:** an open exposure on one of the solution's components (unchanged).
- **Related:** an accepted signal fingerprint on a connector, capability, model, setting, harness or authentication mode whose value one of the solution's components also has. Product, resource type and environment type are left out as too broad. A signal that affects the solution is not also listed as related. Engine `Get-RelatedSignals`, case rel-01; page parity 55 of 55.
- **On the page:** choosing a solution shows both by default, with a scope line giving the two counts and a switch, "Include related signals". Item lists in the matrix and the timeline say "Affects this solution" or "Related: (links)". By solution gains a Related column.
- **Seen in pp-lab:** Change Radar Core: 1 affects (MC1526652), 9 related, all prompt-model retirements linked by `capability: ai_prompt`. Its flows call prompts, so these are relevant, but its prompts run on gpt-6-sol, which none of them retires: related, not affected, as the labels say.

## Consequences

- Solution is a second way into the same data; the asset stays the unit that's matched and rated.
- Other environments show "Solution not known" until Dataverse detail is extended there (a separate decision: new read access).
- ADR 0021 (delegating to solution owners) builds on this table.
