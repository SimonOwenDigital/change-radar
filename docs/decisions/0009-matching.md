# 0009: Matching (phase 3)

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0009-matching) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0009-matching)

Date: 2026-11-20. Status: **Accepted**, 2026-11-20 (Simon: all four questions below, recommended option each).

## Context

Phase 3 is done when "the six worked examples in §5 produce correct exposures (or a correct 'none')" (spec §9). The engine already matches. `Find-Exposures` with `seed/rules.csv` passes 30 of 30 cases from hand-written fingerprints. What phase 3 adds:

1. LLM fingerprints for live signals, with vocabulary and confidence guards (spec §5 rules 2 and 3; ADR 0004 option A, in-tenant).
2. The rules and the vocabulary as Dataverse data.
3. A flow that writes exposures.

Found on 2026-11-20:

- Seven of the eight worked-example IDs are live `crdr_signal` rows in pp-lab: MC1551122, MC1557509, MC1548034, MC1550533, MC1557754 and MC1558033. RM570671 (Work IQ MCP policies) was never collected, because the roadmap product map doesn't include Work IQ.
- `crdr_signalfingerprint`, `crdr_rule`, `crdr_facetvalue`, `crdr_exposure` and `crdr_tenantsetting` are empty.
- Verified on Microsoft Learn, 2026-11-20:
  - The Power Automate **Run a prompt** action can return **JSON in a custom, saved format**. A top-level list of objects is fine; a bare list of values isn't.
  - Prompts run on Azure OpenAI GPT models, only in some regions, and are subject to capacity and credit limits.
  - Token use is readable from `body/responsev2/predictionOutput`.
  - ([JSON output](https://learn.microsoft.com/microsoft-copilot-studio/process-responses-json-output); [Use your prompt in Power Automate](https://learn.microsoft.com/ai-builder/use-a-custom-prompt-in-flow); [Prompt tokens](https://learn.microsoft.com/ai-builder/licensing-prompt-tokens))
- Not verified: whether pp-lab has prompt capacity, and whether a prompt (an AI model) can be created through the Web API rather than the maker portal.

## Proposal

Every step follows the phase 2 pattern: the engine is the executable specification, the flow is what ships, and a parity check keeps the two aligned.

1. **Expected fingerprints first.** `tests/fingerprints/` holds the real text of the seven live worked-example signals, plus a few near misses, each with the facets it should get. This is the accuracy test set ADR 0004 asks for.
2. **Spike T7, prompt action in pp-lab.** Create the fingerprint prompt with a fixed JSON format, run it on the test set, and record accuracy, credits per signal, latency and the authoring route (`spikes/T7/`).
3. **Vocabulary and rules as data.** A deploy script loads `seed/vocabulary.csv` into `crdr_facetvalue` and `seed/rules.csv` into `crdr_rule`. `crdr_tenantsetting` gets a manual row for `copilot_spending_policy`.
4. **Flow "fingerprint signals".** It handles signals that are new or changed and in scope. It calls the prompt (title, summary and products in; facets with confidence out), then applies the same guards as the engine's `Test-SignalFingerprint`:
   - a value outside the vocabulary is written as `rejected`;
   - a value below `fingerprint_confidence_threshold` goes to `review`;
   - anything else is `accepted`.

   Manual fingerprints are never overwritten. The run log records tokens.
5. **Flow "match exposures".** It runs after fingerprinting and the 04:30 detail flow, and implements `Find-Exposures`:
   - groups are alternatives, with AND within a group;
   - scope-only groups never expose;
   - the setting rule checks the tenant setting.

   It upserts `crdr_exposure` per signal, asset and source, with matched facets, rules and evidence. An exposure that no longer matches is marked dismissed, not deleted. Live, fixture and synthetic exposures are never mixed.
6. **Parity.** The engine runs over Dataverse snapshots of signal and asset fingerprints and is compared with what the flow wrote.
7. **Review queue.** The Change Radar app gets a "Fingerprints to review" view and Accept/Reject on the fingerprint form. It's a classic view and form only, with no new charts (ADR 0005).
8. **Demo.** The seven live signals produce the right outcome against the live estate, which is mostly a correct "none". They also produce the expected exposures against the synthetic estate (`samples/synthetic/mid-size-enterprise/exposures`) and the fixture estate. RM570671 is shown through the test suite unless it is collected.

## Decisions (Simon, 2026-11-20)

1. **Prompt authoring:** in spike T7, first try creating the prompt through the Web API from prompt text in the repo. If that isn't workable, Simon creates it in the maker portal from the same text, and it's added to ChangeRadarCore and exported.
2. **Fingerprinting scope:** only the seven worked-example signals until T7 shows the credit cost. Then every in-scope signal once, and only new or changed signals after that.
3. **RM570671:** add Work IQ to the roadmap product map, so the item is collected and the worked example runs live.
4. **Synthetic estate:** matched in Dataverse as `source = synthetic`, never mixed with live or fixture.

## Spike T7 outcome (Simon, 2026-11-20)

The full results are in `spikes/T7/README.md`.

- **Model: GPT-6 Sol** (Premium tier). It is Microsoft-operated, so this stays within ADR 0004 option A. On the 10-case test set:
  - GPT-6 Sol: 8 of 10, no false trigger facets.
  - GPT-6 Luna: 7 of 10, no false trigger facets.
  - GPT-4.1 mini: 5 of 10, three false triggers. It retires on 2026-12-02.

  Check real credit use once the flow runs: the prompt builder's 0.3 Copilot credits per test is a projection.
- **Acceptance bar: zero false trigger facets.** No wrong accepted trigger facet on `tests/fingerprints`, because a wrong one raises false alarms across the estate. Omissions are allowed but measured. A worked example the LLM misses gets a manual fingerprint (`extractedby = manual`) through the review queue, and the flow never overwrites a manual fingerprint.
- **Prompt v3, pasted with the flow step:**
  - "custom control" becomes a synonym in the `pcf_control` description;
  - `connector: shared_wordonlinebusiness` is added to the vocabulary (MC1551122 names it).
- **Authoring:**
  - The prompt is created in AI hub; the API route isn't supported.
  - `Predict` needs a top-level `source` parameter.
  - The **Published** configuration is what runs; a saved **Draft** can hold older text.
- **Model drift:** pinned models are used, never "GPT Chat Latest". `Test-FingerprintPrompt.ps1` is rerun as a regression test whenever the prompt or the model changes.

## Review queue and exposure status (2026-11-21, phase 3 step 6)

**Context:** in step 5 the match flow set exposures that stopped matching to `dismissed`, the same status a person sets. A re-match leaves a person's status alone, so an exposure the flow had dismissed could never come back. That happens if a reviewer rejects a fingerprint and later accepts it again. Separately, the flow only visits signals that have an accepted fingerprint. If every fingerprint of a signal was rejected, its exposures stayed open.

**Decision:**
- **New status, "No longer matches"** (`exposurestatus` value `unmatched`). It's appended to the choice, so existing option values don't move.
  - The match flow sets it when an exposure stops matching, and resets it to `new` when the exposure matches again.
  - The flow also sweeps open exposures of signals with no accepted fingerprint left.
  - `dismissed` is only ever set by a person, and the flow never changes it.
- **The review queue is the app, with no custom commands:**
  - The "Fingerprints to review" view lists LLM fingerprints below `fingerprint_confidence_threshold`.
  - A reviewer sets Status on the fingerprint form: Accepted, Rejected or Review.
  - Manual fingerprints are added from the signal form's Fingerprints list, with Extracted by = Manual, Status = Accepted and their own group (M1, M2 and so on). Sharing a group with LLM rows would AND them together.
  - Accept and Reject command buttons are left to phase 6.
- **The two T7 omissions are seeded as manual fingerprints** in `seed/manual-fingerprints.csv` (public signal ids only), loaded by `Import-MatchingDataToDev.ps1`:
  - MC1551122 group M1: `capability: pcf_control` and `connector: shared_sharepointonline`;
  - RM570671 group M1: `capability: uses_mcp`.

**Consequences:**
- After the next match run, the manual fingerprints add 6 exposures: 44 in total, and parity holds.
- Neither signal has a live match. MC1551122 finds a synthetic code component that loads SharePoint content. The fixture PCF app is correctly not exposed, because it doesn't use SharePoint. RM570671 finds synthetic agents that use MCP.
- A reviewer's decision on an LLM fingerprint lasts until the signal changes. A changed signal is fingerprinted again and its LLM rows are replaced, so they need reviewing again. Manual rows are kept.
- `crdr_reviewedby` isn't filled in yet. The form shows Modified by and Modified on instead.
- **Finding by code (Simon, 2026-11-21):**
  - Signal views show External ID, and fingerprint views show the signal's code through a link to the signal.
  - Exposure names start with the code, so the exposure search already finds them.
  - Quick-find columns can't be set through the Web API: any fetchxml change to a quick-find view returns 400 `0x80040216`, even an unchanged one (observed 2026-11-21). They're set in the maker portal and kept by the solution export:
    - Signal: Title, External ID and Products;
    - Signal fingerprint: Name, Value and Signal.

## Phase 3 outcome against "done when" (2026-11-21, confirmed by Simon after the demo)

Spec §9 phase 3 is done when the six worked examples in §5 produce correct exposures, or a correct "none".

The run behind this table: fingerprint flow (GPT-6 Sol, prompt v3, limited to the 10 test signals) → review → match flow, in pp-lab, on 2026-11-21. Parity (`Test-ExposureParity.ps1`): 44 of 44.

| §5 row | Signal | Accepted fingerprint (\* manual) | Live | Fixture | Synthetic | Why it's correct |
|---|---|---|---|---|---|---|
| 1 | MC1551122 SharePoint tempauth | A, B, C: `sharepoint_tempauth` with Power Apps / cloud flow / custom connector; M1\*: `pcf_control` + `shared_sharepointonline` | none | none | 5 (4 by A, 1 by M1) | No live asset uses temporary SharePoint URLs. The fixture PCF app has a code component but no SharePoint connector, so it's a correct near miss. |
| 2 | MC1557509 service principal auth | A: Copilot Studio + agent flow + `user_owned_production` | none | n/a | 9 | The tenant has no agent flows owned by a user in production. |
| 3 | MC1548034 third-party connections | A: Copilot Studio + agent + `harness: standard` + `custom_web_ui` | none | n/a | 9 | One live agent is on the Standard harness, but none is published to a custom web channel. All four facets must hold. |
| 4 | RM570671 Work IQ MCP policies | A: M365 Copilot (scope only, exposes nothing); M1\*: `uses_mcp` | none | n/a | 5 | No live agent uses MCP. |
| 5 | MC1550533 scheduled prompts | A: Power Automate + cloud flow + `scheduled_prompt` | **1** | n/a | 15 | The live match is a real Copilot scheduled-prompt flow: a Recurrence trigger plus `shared_m365copilotautomations` (the T5 signature). |
| 6 | MC1557754, MC1558033 Copilot Credits (and MC1239927) | A: `copilot_spending_policy` + M365 Copilot | none | n/a | n/a (settings: live only) | The tenant's spending policy covers M365 Copilot, so there's no exposure. Without that policy, or with the policy's scope missing M365 Copilot, a setting exposure would be raised. |

**Near misses:** MC1182703 and RM577859 have scope facets only, so they expose nothing, as `tests/fingerprints` expects.

**Review loop, tested in the app on 2026-11-21:**
1. Simon rejected RM570671's `uses_mcp` in the app. The next match run reported "unmatched 5", and parity was 39 of 39.
2. The fingerprint was accepted again. The next run set the same 5 exposures back to New, created none, and parity was 44 of 44.

**Still open (later phases):**
- Fingerprinting all signals: about 125 credits, by Simon's decision.
- `crdr_reviewedby` isn't filled in.
- Accept and Reject command buttons (phase 6).
- The horizon chart's near-to-far order (phase 6).
