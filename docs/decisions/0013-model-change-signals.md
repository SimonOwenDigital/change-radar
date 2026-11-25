# 0013: Model-change signals (phase 6b)

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0013-model-change-signals) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0013-model-change-signals)

Date: 2026-11-22. Status: **Accepted**, 2026-11-22 (Simon: questions 1, 3 and 4, recommended option each; question 2 follows from 4: the three Copilot Studio and prompt pages, no Foundry in v1).

## Context

Simon, 2026-11-22: organisations need to see when the AI models behind Microsoft 365 Copilot Chat, Agent Builder and Copilot Studio change, so they can judge the impact and decide what to do across their estate. Simon placed this as phase 6b, after phase 6 and before phase 7 packaging, because it changes what phase 7 installs and documents.

A model change is not like other signals. It changes how an existing agent or prompt *behaves* without anyone editing it. Microsoft moves agents and prompts to a replacement model automatically when a model retires (verified below). So the useful question for an organisation is not "what was announced" but "which of *our* agents and prompts are on that model, and have we re-tested them?"

### What Microsoft publishes (verified on Learn, 2026-11-22)

- **Copilot Studio, standard harness:** [Select a primary AI model](https://learn.microsoft.com/microsoft-copilot-studio/authoring-select-agent-model) has a "Model retirement dates and extension availability" table: retiring model, harness, replacement, retirement date, extension. Agents on the **GPT Chat Latest** alias, or in a managed solution, move automatically. A new major version under that alias comes with at least 30 days' notice.
- **Copilot Studio, Microsoft Copilot harness:** [Model availability](https://learn.microsoft.com/microsoft-copilot-studio/agents-experience/authoring-agent-model-availability) has "Available models" and "Model lifecycle summary" tables: model, provider, status, date, replacement. For example, Claude Sonnet 4.6 retires on 15 February 2027 and is replaced by Claude Sonnet 5.5.
- **Prompts (AI Builder, prompt builder):** [Prompt model availability](https://learn.microsoft.com/microsoft-copilot-studio/prompt-model-availability) lists the 2 December 2026 update. Prompts on GPT-4.1 mini, GPT-4.1, GPT-5 chat, Claude Sonnet 4.6, Grok and others move to the tier's replacement. "Keeping a prompt configured with a retiring model doesn't prevent migration." "Responses can differ after migration."
- **Microsoft 365 Copilot Chat:** [AI models overview](https://learn.microsoft.com/copilot/plan/ai-models-overview) states that not every model change is announced. Message Center is used only when a change needs admin action, affects commitments, or is significant. Other changes appear in the blog or the release notes.
- **Agent Builder:** there is no lifecycle page. The GPT-5 move appeared in the Microsoft 365 Copilot release notes.
- **Message Center does carry Copilot Studio and prompt retirements:** for example MC1506318 (end of support for selected models) and MC1536101 (newer GPT models replace Anthropic, Grok and earlier GPT models in prompts). Change Radar already collects these.
- **The estate side is mostly visible already:**
  - The Power Platform inventory gives `properties.model` for every Copilot Studio agent, and for Agent Builder agents, which report "Microsoft 365 Copilot". Microsoft's [model lifecycle guidance](https://learn.microsoft.com/microsoft-copilot-studio/guidance/plan-agent-model-lifecycle) recommends exactly this query to find agents on a retiring model. It reflects the published version only.
  - Our estate collector already reads the inventory, and the committed redacted sample shows `"Claude Sonnet 4.6"` on one agent.
- **Prompts are not in the inventory.** In Dataverse, a prompt's model is in `msdyn_aiconfiguration.msdyn_customconfiguration` → `modelParameters.modelType`, on the active run configuration (`msdyn_aimodel._msdyn_activerunconfigurationid_value`).
  - This was verified in pp-lab data only. The JSON isn't documented.
  - Values seen: `gpt-6-sol`, `gpt-41-mini` and `default`.
  - Change Radar's own two prompts are on `gpt-6-sol`. So Change Radar is in its own estate.

### What's missing today

- There is no `model` facet, so nothing can match a model signal to the assets on that model.
- The lifecycle pages aren't collected. Changes that never reach Message Center, such as Copilot Chat and some defaults, are missed.
- A silent move is invisible. For example, the GPT Chat Latest alias moves to a new snapshot, or a retired model is auto-replaced. Nobody announces it per agent, but the agent's model value changes in the inventory.

## Proposal

### 1. A `model` facet and a model vocabulary

- Add `model` to the facet choice. This is a schema change: option value 169890008.
- Add rule **R-MODEL**: signal `model` matches asset `model`, with the trigger role, so a model signal can expose assets on its own.
- Add `seed/models.csv`, one canonical id per model, for example `claude-sonnet-4.6`, `gpt-4.1-mini` and `gpt-chat-latest`. Each id lists the spellings that mean it, because the sources disagree:
  - inventory: "Claude Sonnet 4.6";
  - prompt configuration: `gpt-41-mini`;
  - Learn tables: "GPT-4.1 Mini".

  It also has two special ids:
  - `default`, which follows the environment or tier default;
  - `m365-copilot`, for Agent Builder agents, which follow Copilot Chat.
- An unknown spelling is not guessed. It is recorded on the collection run as a gap: "unmapped model 'X'". A person then adds a row to `models.csv`.

### 2. Estate: which model each asset uses

- **Agents:** the estate collector adds facet `model: <canonical id>` from the inventory's `properties.model`. This applies to Copilot Studio agents and to Agent Builder agents (`m365-copilot`). It uses the existing access and needs no new permission.
- **Prompts:** the Dataverse detail collector gains a prompt step for each detail environment.
  - It reads `msdyn_aimodel` (GPT prompt templates), takes the active run configuration, and reads `modelType`.
  - Each prompt becomes an asset with resource type `prompt` and facet `model`.
  - This needs **read** on `msdyn_aimodel` and `msdyn_aiconfiguration` for the reader app's security role.
- **Silent model changes:** when an asset's model differs from the previous run, the collector raises a new event, `asset.modelchanged`: "agent X moved from GPT-5 Chat to GPT-6 Luna". It goes on the card and in the digest, because the agent's behaviour may have changed without anyone touching it.

### 3. Signals: three routes in

1. **Message Center (already collected).** Fingerprint prompt v4 learns the `model` facet from `models.csv`. Expected test cases come first, in `tests/fingerprints`. The catch: fingerprinting is still limited to the 10 test signals by your decision, so this route only works once fingerprinting covers more signals (question 4).
2. **The three Learn model pages, as a new collector.**
   - It polls each page daily and compares its `git_commit_id` meta tag. It does nothing unless the page changed.
   - When a page changes, it turns each row of the retirement table into one signal, keyed by model, surface and date. For example, "Claude Sonnet 4.6 retires from Copilot Studio (Microsoft Copilot harness) on 15 February 2027; replacement Claude Sonnet 5.5".
   - Rows are mapped deterministically: model plus surface, with **no LLM fingerprint**. They also have no Message Center lag, and they cover the changes Message Center doesn't carry.
   - Spike **T9** decides how to read the tables: parse the HTML, or have the in-tenant LLM extract the rows only when a page changes.
3. **The estate itself:** the `asset.modelchanged` events above.

### 4. Impact and recommended action

A retirement with automatic migration is rated as a **behaviour change**. A retirement without one, for example an agent pinned to a model that has no extension, is rated **breaking**. The recommended action names the intervention:

- re-run the agent's evaluation test set in Copilot Studio (agent evaluations are GA) before the date;
- or move the agent to the replacement model now and test it.

The deadline handler already reminds at 14 and 3 days. The Radar page needs no change: these signals appear in the matrix, the timeline and "Your estate" like any other.

## Done when (proposed)

1. **Claude Sonnet 4.6 retiring from Copilot Studio on 15 February 2027** is a signal from the lifecycle collector, and it exposes the live agent on Claude Sonnet 4.6.
2. **The 2 December prompt migration** exposes the prompts on retiring models in the detail environments. In pp-lab today that's the system prompt on `gpt-41-mini`.
3. **An `asset.modelchanged` event** is raised and posted when a test asset's model changes. This uses a test asset only, never a real one.
   - **Clarified (Simon, 2026-11-22):** handlers that post outside Change Radar take live events only (ADR 0011), so a test asset's event is raised but not posted. Shown in three parts: the event row from a test change; the card and digest text from the engine cases (`tests/events`, card-mc and digest-mc); and the first real post when a live asset's model moves. A false change is never written to a live asset.
4. **Tests and parity:** the engine tests and the parity checks include the model facet and the new event.

## Spikes

- **T9:** read the three lifecycle tables reliably, by HTML parsing or by LLM extraction when a page changes. Measure accuracy against the tables as published and the credits used.
- **T10 (optional):** where a Copilot Studio agent's own model setting is stored in Dataverse. This would show unpublished changes and per-tool overrides. It needs a test agent in pp-lab, which is a dev write, and pp-lab has no agents today. The inventory route is enough without it.

## Questions for Simon (answered 2026-11-22)

Answers: 1 all four surfaces; 2 the three pages, Foundry later; 3 yes, read only, in pp-lab, documented in permissions-and-data.md; 4 lifecycle collector first, revisit fingerprinting all signals after 6b.


1. **Surfaces for v1:**
   - Copilot Studio agents, prompts, and Agent Builder (as followers of Copilot Chat).
   - Copilot Chat model changes become tenant-wide signals with no per-asset exposure, because Copilot Chat isn't an asset.

   Recommended: all of these.
2. **Lifecycle pages:** collect the three Copilot Studio and prompt pages (recommended)? Add the Azure Foundry retirement schedule as an early warning (not in v1)?
3. **Prompt detail:** may the reader app's security role gain **read** on `msdyn_aimodel` and `msdyn_aiconfiguration`? It's read-only, but it is a permission change.
4. **Fingerprinting beyond the test signals:** Message Center model posts only match if they are fingerprinted. Reopen the "fingerprint all in-scope signals once" decision (about 125 credits), or rely on the lifecycle collector for v1 (recommended) and revisit later?

## Build order (phase 6b)

1. ~~Spike T9~~ **done 2026-11-22**: table profiles parsed in the flow (XPath), 31 of 31 rows, no LLM (`spikes/T9/README.md`). Then the expected cases: `tests/models/` (model aliases, lifecycle rows to signals, asset model facets, `asset.modelchanged`).
2. ADR 0014's feed table and generic page watcher; the model lifecycle collector on top of it.
3. Schema: `model` facet option, R-MODEL rule, `seed/models.csv`; engine support and tests.
4. Estate: agent `model` facet from inventory; prompt assets from Dataverse (reader role gains read on `msdyn_aimodel`, `msdyn_aiconfiguration`); `asset.modelchanged`.
5. Assessment wording for behaviour-change versus breaking retirements; card and digest text.
6. Demonstrate the done-when list; Simon confirms.

## Step 3 built (2026-11-22)

- **Vocabulary.** Schema: facet value `model`, and `crdr_facetvalue.crdr_aliases` (Simon). There are 33 model rows in `seed/vocabulary.csv`, each with its spellings, plus resource type `prompt` and rule R-MODEL, a trigger.
- **Engine.** `Import-ModelMap` and `Get-ModelId` map spellings, ignoring case; an unknown spelling is a gap. Agents get a `model` facet. Lifecycle signals get rule fingerprints: the model plus the feed profile's `fingerprintScope` (resource type, and harness).
- **Tests.** Models: 18 of 18. Matching: 35 of 35, including `tests/cases/ml-csm-claude-sonnet-4-6.json`. All seven suites, 172 cases, pass.
- **Flows.** The tables collector writes the rule fingerprints when it creates a signal. The estate collector adds `model` through an XML map of models and their spellings, looked up with XPath.
- **Parity.** `Test-ModelFingerprints.ps1` backfilled 72 fingerprints for the 27 existing lifecycle signals, and all match. Estate parity: 42 assets and 173 facets match. Exposure parity: 44 of 44.
- **Correction to done-when 1.** The live agent on Claude Sonnet 4.6 is on the **Standard** harness. The Microsoft Copilot harness retirement therefore correctly does not expose it. That is the near-miss case mdl-02. The four Agent Builder agents follow Copilot Chat (`m365-copilot`). So the live estate has **no** model exposure today, which is the right answer. A labelled demo agent in the synthetic estate is needed to show an exposure end to end.

## Consequences

- One schema change: the facet option. That may come with a second, the ADR 0014 feed table. One new rule, one new seed file, one new event type, two collector extensions, one new collector and one prompt version.
- `models.csv` needs looking after as models appear. An unmapped model shows up as a gap rather than a silent miss.
- Change Radar watches its own prompts, which use the same models.

## Steps 4 and 5 built (2026-11-22)

- **Prompts as assets:** the reader role gained `prvReadmsdyn_AIModel` (pp-lab, Simon). A prompt is an active `msdyn_aimodel` whose active run configuration names `modelParameters.modelType`, read as text. Engine `Get-PromptModelType`; the detail flow writes them as live assets of Change Radar's own type `microsoft.aibuilder/prompts`. Estate parity: 45 assets.
- **Done-when 1:** the labelled synthetic demo agent "Model retirement demo agent (synthetic)" (Microsoft Copilot harness, Claude Sonnet 4.6) is exposed by `ML-CSM-claude-sonnet-4-6`. The generator's agent models come from their own random stream, so nothing else in the synthetic estate moved.
- **Done-when 2:** `ML-PR-gpt-4-1-mini` exposes the live system prompt on `gpt-41-mini`. After the full fingerprint pass, Message Center's MC1536101 exposes it too (route 1).
- **Done-when 3:** `asset.modelchanged` is raised by the estate and prompt loops, with no signal and an asset lookup on the event. It has a card and a digest section ("Model changes"). `setup/dev/Test-ModelChangeEvent.ps1` labels Change Radar's own fingerprint prompt as a fixture, fakes its previous model, runs the detail flow, and checks the event (from `gpt-6-luna` to `gpt-6-sol`, estate fixture), that no handler run is queued, and that the asset is restored. It passed.
- **Step 5:** the nature comes from the rules in `seed/theme-rules.csv`, which win over the LLM: ML-PR and ML-CSM are `behaviour_change` (migration is automatic), ML-CS is `breaking` (only the GPT Chat Latest alias and managed solutions move). 26 signals backfilled. Each feed profile has a `migrationNote` that rating and deadline cards add to their "why" line (engine cases card-mn-01 and card-mn-02).
  - Consequence: behaviour-change retirements no longer count in the Radar page's "Retiring" tile (deprecation and breaking only). They still appear in the matrix, the timeline and the "AI models and lifecycle" theme.
  - Card parity reports one expected difference: the ML-PR-gpt-4-1-mini rating card sent on 2026-11-22, before the note existed.
- **Tests:** themes 19, events 60, models 24, matching 41; all suites pass.

## Phase 6b outcome against "done when" (2026-11-22, confirmed by Simon 2026-11-23)

| Done when | Evidence | Status |
|---|---|---|
| 1. Claude Sonnet 4.6 retiring from Copilot Studio (15 February 2027) is a lifecycle signal and exposes the agent on that model | `ML-CSM-claude-sonnet-4-6` from the tables collector, rule fingerprints `model`, `resource_type: agent`, `harness: microsoft_copilot`. The live agent on Claude Sonnet 4.6 is on the **Standard** harness, so it is correctly not exposed (case mdl-02). The labelled synthetic demo agent is exposed in pp-lab; exposure parity 291 of 291. | Shown, with the correction recorded under "Step 3 built" |
| 2. The 2 December prompt migration exposes the prompts on retiring models in the detail environments | `ML-PR-gpt-4-1-mini` and Message Center MC1536101 both expose the live system prompt on `gpt-41-mini`. Change Radar's own prompts are on `gpt-6-sol` and correctly are not exposed. | Shown |
| 3. An `asset.modelchanged` event is raised and posted when a test asset's model changes | `Test-ModelChangeEvent.ps1` passed: the event was raised from the detail flow for a fixture-labelled test asset, and not posted (live events only). Card and digest text are proven by the engine cases card-mc-01/02 and digest-mc-01/02. The first real post comes with the first live model move (Simon, 2026-11-22). | Shown, as clarified |
| 4. The engine tests and parity checks include the model facet and the new event | Suites: matching 43, models 24, events 60, themes 19 (and assessment 19, radar 38, feeds 11, text 11), all passing (counts as of 2026-11-23, after the third feed and the Critical-card fix). Parity in pp-lab: estate (45 assets, 191 facets), exposures (291), model fingerprints, feeds (six), rule themes and natures (525), events and cards. One expected card difference is noted under "Steps 4 and 5 built". | Shown |

## Addendum, 2026-11-22: the Critical prompt card (Simon)

**What happened:** the rating card for `ML-PR-gpt-4-1-mini` on the live system prompt said **Critical**: generic High (LLM) plus the action-date bonus (+1, action required by 2 December, within 30 days). There was no production bonus, because the prompt is in a developer environment. Three inputs were wrong or missing:
1. The LLM saw only "Replacement: GPT-6 Luna. Tier: Basic.", nothing saying the migration is automatic. 15 of the 19 automatically migrating retirements were rated High.
2. Every Retiring row is action required, so any exposure within 30 days gains +1.
3. The exposed prompt, "Intelligent Weekly Reporting", is Microsoft's own system prompt (solution `msdyn_AISolutionDefaultTemplates`, publisher `microsoftdynamics`), which the organisation can't edit or re-test.

**Decisions (Simon):**
- **Action required stays** for automatic migrations. Depending on the use, a model change may need formal evaluation, and no risk-sizing source is connected yet to say which. Claude's challenge, recorded: whether evaluation is needed depends on the asset's risk, not the retirement. So once a risk-sizing source exists, action required for automatic migrations should come from the asset's risk tier, not apply to all.
- **The rating prompt sees the migration note:** a retiring row's summary now ends with the feed profile's `migrationNote` (engine, Learn tables flow, cases `feed-01` and `feed-03`). 15 stored summaries were rewritten (`Test-FeedParity.ps1 -FixSummaries`), and the 19 ML-PR and ML-CSM signals were re-rated.
- **Microsoft system prompts are labelled, never alerted:** a prompt shipped by a Microsoft publisher (solution component type 401, the same publisher list as code components) gets `crdr_asset.crdr_microsoftsystem`. Its exposures get the new status **system** ("Microsoft system component (not rated)"). They stay visible, but ratings and events count only New and Confirmed. Engine: `microsoftSystem` on assets and `status` on exposures; cases `prm-07` and `prm-08`.
