# 0010: Assessment (phase 4)

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0010-assessment) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0010-assessment)

Date: 2026-11-21. Status: **Accepted**, 2026-11-21 (Simon: all four questions below, recommended option each).

## Context

Phase 4 is done when "each exposed signal has an estate rating, a rationale and an action; overrides persist" (spec §9). The spec §6 sets the score:

```
estate_impact = none if no exposure, else
    generic_impact
  + 1 if an exposed asset is in a production environment
  + 1 if action is required and the key date is within 30 days
  (+ 1 for asset criticality: E1, ignored in v1)
  clamped to estate_impact_max, mapped to Low / Medium / High / Critical
```

The LLM writes the rationale and the recommended action from structured inputs. It doesn't produce the score. Overrides (raise, lower, dismiss) are stored with a reason.

Found on 2026-11-21 in pp-lab:

- `crdr_assessment` exists from phase 0 and is empty.
- The 10 fingerprinted test signals give 5 with open exposures (MC1548034, MC1550533, MC1551122, MC1557509, RM570671). Only MC1550533 has a live exposure; the rest are synthetic.
- Two live assets have no environment type, including the live MC1550533 exposure. These are Copilot-created flows that sit outside a normal environment in the inventory.
- Neither the spec nor the prototype says where generic impact and nature (type of change) come from; the prototype's values were snapshot data.

## Decisions (Simon, 2026-11-21)

1. **Generic impact and nature come from a second AI hub prompt**, "Change Radar signal assessment".
   - It runs only for signals with open exposures, about 0.3 Copilot credits per signal.
   - In one call it returns generic impact, nature, rationale and recommended action.
   - Generic impact for unexposed signals (content value) waits for the same decision as fingerprinting all signals.
2. **The prompt sees facets and counts only:** for example, "3 cloud flows, 2 in production, matched on capability scheduled_prompt". No asset, environment or owner names are sent; the app shows the assets beside the rationale.
3. **Unknown environment type counts as not production**, with no production bonus. The assessment records the number of exposed assets whose environment is unknown, so a reviewer can override.
4. **Overrides are form fields with a required reason.**
   - Override impact: None means dismissed.
   - Override reason: required whenever an override is set.
   - The assess flow never writes either field.
   - A small flow records who overrode the assessment (`overriddenby`) and when.
   - The effective rating is the override when one is set, otherwise the estate impact.

## Rules for the score (the executable specification is `engine/ChangeRadar.Assessment.psm1`)

- **One assessment per signal per source** (live, fixture, synthetic). Sources are never mixed in one rating (spec §15.2).
- **Exposures that count:** status New or Confirmed. Dismissed and No longer matches don't count.
- **Generic impact values:** None 0, Low 1, Medium 2, High 3, Critical 4.
- **Production bonus:** +1 when any counted asset exposure is in a Production environment. Setting exposures have no environment, so they never earn it.
- **Action bonus:** +1 when the signal is action required and its key date is within 30 days from today, or already past.
- **Score:** the sum is clamped to `estate_impact_max` (4). A signal with at least one counted exposure is never rated below Low.
- **No exposures:** a signal that had an assessment for a source but no longer has counted exposures there keeps the row, with estate impact None. Its override is kept.
- **Affected count:** distinct exposed assets, plus setting exposures.

## Steps

1. Expected scoring cases (`tests/assessment/`) and the engine module, before any flow.
2. Expected prompt outputs for the 6 exposed test signals (generic impact range, nature), then spike T8: Simon creates the assessment prompt in AI hub (prompts can't be created through the API, ADR 0009). It's scored by a harness like T7's.
3. Schema additions if needed (unknown-environment count, prompt name config), then the "assess signals" flow: per signal and source, compute the score, call the prompt only when inputs changed, and never touch override fields.
4. Override UI: assessment views and form, the required reason, and the override-recording flow.
5. Parity check (engine vs flow) and the phase 4 demo.

## Consequences

- The score is reproducible and explainable: every rating can be recomputed from exposures, the signal and generic impact.
- Generic impact is an LLM judgment, so it's labelled as assessment, not fact (spec §2), and can be overridden through the estate rating.
- Re-assessment costs credits only when a signal's inputs change: its text, its exposures by source, or the action date crossing 30 days.

## Phase 4 outcome against "done when" (2026-11-21, confirmed by Simon)

Spec §9 phase 4 is done when "each exposed signal has an estate rating, a rationale and an action; overrides persist".

- **Ratings:** the "assess signals" flow rated the 5 exposed test signals. MC1550533 is rated separately for live and synthetic, so that's 6 assessments. Each has generic impact and nature (from the LLM), a computed estate impact, an LLM rationale and a recommended action.

  | Assessment | Generic | Estate | Notes |
  |---|---|---|---|
  | MC1550533, live | high | high | Environment unknown: no production bonus, and the rationale says so. Action date 40 days out. |
  | MC1550533, synthetic | high | high | |
  | MC1551122, synthetic | high | critical | Production apps and connectors |
  | MC1557509, MC1548034, RM570671, synthetic | low | medium | New options, production assets affected |
- **Parity:** `Test-AssessmentParity.ps1` agrees on all 6, including every estate summary character for character. The engine tests are 19 of 19 (15 scoring, 4 summary).
- **Cost:** the first run made 6 prompt calls, about 15,000 tokens. Later runs rescored with 0 prompt calls, because the summary is stable and the prompt only runs when its inputs change.
- **Overrides, tested by Simon in the app:**
  - saving was blocked until a reason was given;
  - "Override set or cleared by" and "on" were recorded by the flow;
  - an assess run then rewrote the row and left the override (Critical) intact.
- **Generic impact varies between calls.** MC1548034 was medium in the T8 run and low in the flow an hour later, both within the confirmed range. Overrides exist for this.

**Known issues carried forward:**

- **App components (fix before phase 7 packaging).** The app module's table components aren't right. `Deploy-AppToDev.ps1` adds tables with `AddAppComponents`, and the export shows them as a placeholder (`schemaName="entity"`). Only `crdr_assessment`, added in the app editor, is a real component. The app works, because the site map drives navigation and every table opens. Validation warns that all forms and views are shown.
- **Menu publish lag.** The played app's menu picked up the Assessments entry about 80 minutes after publishing (see `verified-facts.md`).
- **Generic impact for unexposed signals.** It waits for the same decision as fingerprinting all signals.
