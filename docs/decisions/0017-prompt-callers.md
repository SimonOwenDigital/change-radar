# 0017: The flows and agents that call a prompt

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0017-prompt-callers) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0017-prompt-callers)

Date: 2026-11-23. Status: **Accepted**, 2026-11-23 (Simon: yes to all three recommendations). Built the same day; see "Built" below.

## Context

Change Radar treats prompts (AI Builder or prompt builder prompts) as assets with a model (ADR 0013). A model retirement such as `ML-PR-gpt-4-1-mini`, or Message Center's MC1536101, therefore exposes the **prompt**. But a prompt changes nothing by itself. Behaviour changes in the **flow, agent or app that runs it**, and that's what a maker re-tests and a user notices. Today nothing links a prompt to what calls it. The vocabulary already has the capability `ai_prompt` ("Uses an AI Builder or Copilot prompt action"), but nothing sets it.

Other gaps in AI Builder coverage, noted at the same time:
- other AI Builder models (document processing, custom and prebuilt models) aren't inventoried;
- "AI Builder" isn't a product in the vocabulary or the roadmap product map;
- credit consumption is already planned as a later facet (spec, T4).

### Verified and assumed

| | |
| --- | --- |
| **Verified** (our own flows, 2026-11-20 and 2026-11-23) | A cloud flow runs a prompt with the Dataverse connector operation `aibuilderpredict_customprompt`. Its `recordId` parameter is the prompt's `msdyn_aimodelid`, which is a literal when picked in the designer. The flow definition is in `workflow.clientdata`. The reader role already has `prvReadWorkflow` (ADR 0008). |
| **Assumed, to check in a spike** | Other AI Builder model actions use operation ids starting `aibuilderpredict_`, with the model id in `recordId`. A Copilot Studio prompt tool is a bot component whose data names the prompt's id. Canvas apps that call a prompt (as a data source, or through AI functions) can't be read through the Dataverse API, so they are out of v1. |

## Proposal

1. **Read each flow's definition in the detail environments, keep only the prompt ids.** For each cloud flow, the detail step reads `clientdata`, finds `aibuilderpredict_*` actions and their `recordId`, and stores **only** the facts on the flow asset:
   - the capability `ai_prompt`;
   - a `model` facet copied from each prompt it calls, with the evidence "calls prompt <name> on <model>".

   The definition itself is never stored or sent anywhere.
2. **Retirements expose the callers too.** The prompt-model rule fingerprints (feed `ML-PR`) gain a second group. Group A is a prompt on the model, as today. Group B is any asset with `ai_prompt` and that model. So a retirement exposes both the prompt and every flow that runs it. Case first: an `ML-PR` signal, a prompt on `gpt-41-mini` and a flow calling it give two exposures. A flow calling a prompt on another model gives none.
3. **A model move tells you the callers.** When a prompt's model changes (`asset.modelchanged`), the card lists the flows that call it as "Affected". It's still one card, not one per flow.
4. **Agents next, after a short spike.** Read Copilot Studio prompt tools the same way, once a spike in pp-lab has shown where the prompt id is kept.
5. **Smaller items, no decision needed:**
   - add "AI Builder" to the product vocabulary and, if the roadmap uses that tag, to the roadmap product map;
   - inventory other AI Builder models as assets (template and model), so their lifecycle posts can match.

## Questions for Simon

1. **Reading flow definitions.** Change Radar would read makers' flow definitions in the detail environments, keep only the prompt ids, and drop the rest. The reader role already can (`prvReadWorkflow`); this is new use of an existing read. `docs/permissions-and-data.md` would say so. **Agree?** (Recommended: yes. It's the only way to find the callers, and nothing else is kept.)
2. **Scope for v1:** flows first, with agents after a spike (recommended); or flows and agents together.
3. **Exposures:** both the prompt and its callers (recommended, because the prompt is where the model is set and the flow is where behaviour changes); or callers only.

## Done when

- In pp-lab, Change Radar's own fingerprint and assessment flows show `ai_prompt` and the model of the prompt they call, with evidence.
- A labelled test signal for a retiring prompt model exposes a prompt and the flow that calls it. A flow calling a prompt on another model isn't exposed.
- A test `asset.modelchanged` card for a prompt lists its calling flow under Affected.

## Consequences

- No new permission. The detail step reads more of what the reader can already read, and stores only derived facts.
- The detail flow grows by one loop over flows per detail environment, with no prompt calls and so no credits. Its action count rises with the number of flows (see ADR 0016 for why that matters only if it ever moves to agent flows).
- Change Radar's own flows become exposed by their own prompt models. That's correct: it would tell us when our assessment prompt's model retires.

## Built, 2026-11-23

Answers: 1 yes, read flow definitions and keep only the prompt ids; 2 flows first, agents after a spike; 3 expose both the prompt and its callers.

### Verified while building (pp-lab, 2026-11-23)

- `contains(clientdata,'aibuilderpredict_')` works as an OData filter on `workflows`, so only flows with an AI Builder action are read.
- Cloud flows in a solution are `category` 5 (not 0), `type` 1 (definition). The filter doesn't use the category.
- Stored definitions are compact JSON: the operation is `"operationId":"aibuilderpredict_customprompt"`, and the prompt id is the next `"recordId":"…"` in the same action.
- **Change Radar's own two flows didn't name their prompts.** They looked the prompt up by name at run time (crdr_config `fingerprint_prompt_name` and `assessment_prompt_name`), so their `recordId` was an expression and no definition reader could tell which prompt, or model, they used. The two prompts ship in the solution (component type 401), so their ids are the same in every environment. The flows now call them by id (`solutions/design/prompts.json`), as a flow made in the designer does. The two config keys are gone from `seed/config.csv` (pp-lab's rows are left in place and are no longer read). Behaviour is otherwise unchanged.

### Design as built

- **Engine.** `Get-PromptCalls` (Matching) reads a definition as text, the same way the flow does: after each `"operationId":"aibuilderpredict_`, the operation, and the first `recordId` before the next `"operationId":"`. A `recordId` is a prompt id only if it doesn't start with `@` and is 36 characters in 5 parts; otherwise the prompt is chosen at run time (no model, never a guess). The estate gains `promptCalls` (flow, operation, prompt). `Get-AssetFingerprints` gives a calling flow `capability: ai_prompt` and one `model` facet per known model, the evidence naming the first prompt on it.
- **Who owns the rows.** These facets' evidence starts `flow definition: ` (`seed/asset-signatures.json` `detailFacets.evidencePrefix`). The detail flow writes and reconciles them; the estate flow leaves them alone and doesn't treat a caller's `model` row as the asset's own model (no false `asset.modelchanged`).
- **Signals.** A feed profile's new `callerScope` adds group B. `ML-PR` has `{"capability": ["ai_prompt"]}`, so each prompt retirement has group A (model, resource type prompt) and group B (model, capability ai_prompt). The 9 existing ML-PR signals in pp-lab were backfilled with group B (`Test-ModelFingerprints.ps1 -Backfill`, 18 rows).
- **Cards.** An `asset.modelchanged` event for a prompt carries `callers` (distinct flow names). The card adds "N flows call it, so their results may change too." and lists the prompt then its callers (sorted; 5 names, then "+N more"). The action becomes "Re-test it and the flows that call it…". Still one card.
- **AI Builder** is now a product in the vocabulary, and prompts carry it (`productByType`). The roadmap product map is unchanged: no roadmap item tagged "AI Builder" has been seen, and Message Center files AI Builder posts under Power Apps and Power Automate.
- **Not done yet:** other AI Builder models (document processing, prebuilt and custom models) as assets; Copilot Studio prompt tools (spike first, as agreed).

### Tests

- Models: `promptCalls` pc-01 to pc-07; lfp-04 now expects group B, lfp-05 that agent tables have none.
- Matching: `ml-pr-gpt-4-1-mini` prm-09 to prm-15 (a caller on the retiring model, one on another model, one calling two prompts, a prompt chosen at run time, an unknown model, a Microsoft system prompt's caller, a flow with no prompt); `aib-product-prompts` aib-01 to aib-03.
- Events: card-mc-03 (six callers, +2 more) and card-mc-04 (one caller, singular wording).

### Outcome against done when

**Confirmed by Simon, 2026-11-23.**

| Done when | Shown in pp-lab, 2026-11-23 |
| --- | --- |
| Change Radar's own fingerprint and assessment flows show `ai_prompt` and the model of the prompt they call, with evidence | Both flows have `capability: ai_prompt` ("flow definition: aibuilderpredict_customprompt") and `model: gpt-6-sol` ("flow definition: calls prompt 'Change Radar signal fingerprint' on gpt-6-sol", and the same for the assessment prompt). The estate flow ran afterwards and left them alone. Estate parity: 45 assets, 198 facets, all match. |
| A labelled test signal for a retiring prompt model exposes a prompt and the flow that calls it; a flow calling a prompt on another model isn't | TEST-PRM-0001 (gpt-6-sol, `New-TestSignals.ps1 -Scenario promptmodel`) exposed both prompts (group A) and both calling flows (group B). The real ML-PR-gpt-4-1-mini still exposes only the Microsoft system prompt (status `system`): the flows call prompts on gpt-6-sol, so they aren't exposed. Exposure parity: 297, all match. The test signal and its 5 events (digest only, nothing posted) were removed. |
| A test `asset.modelchanged` card for a prompt lists its calling flow under Affected | `Test-ModelChangeEvent.ps1` (fixture-labelled, not posted): the event's callers were "Change Radar: fingerprint signals". The engine's card from that payload reads "1 flow calls it, so its results may change too." and lists "Change Radar signal fingerprint; Change Radar: fingerprint signals" under Affected. |

A real side effect, correct by the rules: MC1526652 ("AI Builder credits retirement: Prepare to use Copilot Credits") has `ai_prompt` in its fingerprint, so it now exposes Change Radar's two flows too. The next assess run rates it.
