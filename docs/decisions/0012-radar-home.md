# 0012: Radar home page and signal-level ratings (phase 6)

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0012-radar-home) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0012-radar-home)

Date: 2026-11-21. Status: **Accepted**, 2026-11-21 (Simon: decisions 1 and 2, recommended option each; the rest is Claude's design, open to challenge).

## Context

ADR 0005 (accepted) makes the phase 6 home a generative page that mirrors Simon's prototype mock-up. Phase 6 is done when Simon has walked through it against a checklist, then used it for a week of Monday checks without opening the prototype. The mock-up has these parts:

1. A headline sentence: how many items need action, how many are high impact, and the next deadline.
2. Five tiles: Now (incidents), Action required, High impact, Retiring, Future (roadmap).
3. A **priority matrix**: impact (High, Medium, Low) against time to land (next 30 days, 1 to 3 months, 3 to 6 months, later or landed). Each cell lists items, with a risk or opportunity colour bar and an action marker.
4. **Patterns across the items**: five themes, with item counts and ids.
5. **What lands when**: a timeline of dots for Imminent, Retiring, Shipped and Future, where a red ring means action required, with a Today line.
6. An **Imminent table**: When (with an Action badge), Product, Item (title and summary), Impact (badge, type, audience), Risk and opportunity text with a confidence, and Ref.

Change Radar rated only exposed signals (ADR 0010): 5 of 434 on 2026-11-21. The prototype rated every item. The mock-up's impact rows, "high impact" tile, retiring row, risk and opportunity text and themes all need a rating for each signal.

## Decisions (Simon, 2026-11-21)

1. **Signals are rated if they're Now, Imminent, have a key date within 183 days, or have open exposures.** That was 106 signals on 2026-11-21: about 32 Copilot credits once, then only for new or changed signals, or signals entering the window. Later signals show as "Not yet rated" until they come into it.
2. **The assessment prompt gains the prototype's opportunity lens** (spec §6):
   - **type:** risk, opportunity, or risk and opportunity;
   - **a risk line;**
   - **an opportunity line:** the advisory and content angle;
   - **audience;**
   - **confidence:** high, medium or low;
   - **one theme** from `seed/themes.csv`: the prototype's five plus Other, editable as seed data.

## Design (Claude, 2026-11-21)

- **Generic ratings move to the signal.** New `crdr_signal` columns: generic impact, nature, impact type, risk, opportunity, audience, theme, confidence and "rated on".
  - The assess flow rates each in-scope signal once, with an estate-free summary ("not assessed against an estate").
  - Estate assessments (ADR 0010) then use the signal's generic impact instead of asking again. Their prompt call writes the estate rationale and action only.
  - This removes the per-estate drift seen in phase 4 (MC1548034 rated Medium, then Low).
- **Labels shown on the home page:**
  - **Impact** is the signal's generic rating, as in the prototype. Where the live estate has an assessment, its rating (with any override) is shown alongside it and wins for sorting and the "High impact" count.
  - **Retiring** means nature is deprecation or breaking.
  - **Shipped** means roadmap Launched, or a Message Center post whose key date is past and needs no action.
  - **Time to land** is measured from the key date. A missing or past key date counts as "later or landed".
- **The executable spec is `engine/ChangeRadar.Radar.psm1`:** time-to-land buckets, the headline and tile counts, and the timeline row of each item. Expected cases are written first, in `tests/radar/`.
- **The page is generated with the generative-page tools (PAC CLI and Claude Code)** and reads Dataverse only. The second page, the fingerprint review queue with Accept and Reject (ADR 0005), uses the same route. Both ship in the app, as "UX Agent Project" rows.
- **The access-tier banner** comes from the latest collection runs. The **Demo data badge** appears whenever a fixture or synthetic asset exists.

## Steps

1. This ADR, `seed/themes.csv`, the expected radar cases, and the engine module.
2. Schema: new signal columns. Assessment prompt v2, which Simon updates in AI hub, then a spike on a sample of signals.
3. Assess flow: signal-level rating step, and estate assessments reuse it. Parity checks are updated.
4. The radar home page and the review page.
5. Phase 6 polish:
   - labels for Copilot-generated flows;
   - capitalisation in the digest;
   - the app's table components.
6. Walkthrough, then a week of use. Export and PR.

## Consequences

- About 32 credits once, then around 0.3 credits per new or changed in-scope signal. That's within the limit Simon set: credits are spent only on signals that are near or exposed.
- The prototype's "Claude's assessment" labels become "LLM assessment (in-tenant)". The assessment-not-fact labelling stays (spec §2).

## Addendum, 2026-11-22: themes for everything (Simon)

**Context:** 410 of 515 active signals had no theme. Themes come from the assessment, which only rates the rating window (Now, Imminent, key date within 183 days, or exposed). The unthemed items were mostly history:
- about 330 older Message Center, roadmap and feed items;
- 67 service incidents;
- 15 new feed items in the window, which the next run themes.

A keyword pass over their titles showed that the six themes are maker- and platform-centred. They miss end-user Copilot features (about 100 items) and model lifecycle (about 55).

**Decisions (Simon, recommended option each):**
1. **Three more themes, nine in all (counting Other):**
   - **Copilot for end users:** Copilot Chat, the Copilot app, and Office and Teams features, raising adoption and enablement questions;
   - **AI models and lifecycle:** retirements, new models and defaults;
   - **Service incidents:** split out of Other.
2. **Every signal gets a theme:**
   - Deterministic rules first, at no credit cost: service health becomes Service incidents, and the model-lifecycle feeds become AI models and lifecycle.
   - Then a one-off **theme-only** LLM pass over the remaining unthemed signals. Its cost is measured on a small batch first; the estimate is 30 to 90 credits.
   - After that, only new signals are themed.
   - Rated signals keep the theme from their assessment.
3. **Patterns on the Radar page** count items landing from 90 days ago onwards by default, with a "Show older items" switch.

**Order:**
1. Expected cases first: the theme rules, and the window filter for Patterns.
2. `seed/themes.csv`.
3. The engine.
4. The theme-only prompt mode, with its cost measured on a batch of 10.
5. Rules and backfill.
6. The flow for new signals.
7. The page.

**Further decision (Simon, 2026-11-22): spend spare credits on completeness.**
- **Budget:** about 1,900 of 25,000 Copilot credits used this month. Approved: **a cap of 500 credits** for a one-off pass that **rates every signal** and **fingerprints every signal**. This reopens ADR 0012 decision 1 (the rating window) and the phase 3 deferral of fingerprinting every signal.
- **Ongoing:** new and changed signals only, an estimated 200 to 350 credits a month.
- **Safeguards:**
  - a first batch of 10 is measured, and the pass stops if the cost per call is more than double the estimate (about 0.3 credits);
  - the pass stops at 500 credits;
  - Teams cards stay on.
- **Precondition, found on 2026-11-22:** both prompts carry their option lists in the prompt text. The fingerprint prompt holds the vocabulary, which needs the `model` facet. The assessment prompt holds the themes, which need the three new ones. Prompts can only be changed in the AI hub (ADR 0009), so Simon pastes the regenerated v4 texts before any backfill. Until then the wider scopes stay switched off.

**Built, 2026-11-22 (rules and page):**
- Rules are data: `seed/theme-rules.csv` (match `source` or `feed`, first match wins), checked against `seed/themes.csv` when loaded. Engine: `Import-ThemeRules` and `Get-RuleTheme` (`tests/themes/rules.json`, 13 cases).
- The assess flow applies them after rating, so a rule theme always wins, and writes only signals whose theme differs. `setup/dev/Test-RuleThemes.ps1` checks every signal against the engine; `-Backfill` wrote 94 (67 service incidents, 27 model lifecycle). All 515 now match; 316 are left for the LLM pass.
- Radar page: the new themes in Patterns, except Service incidents (incidents are not items on that page). Patterns uses the 90-day window, with "Show older items" (`tests/radar/radar.json` patternWindow, 7 cases).

**Prepared, 2026-11-22 (switched off until the v4 prompts are in the AI hub):**
- **Prompt v4 texts.** `spikes/T8/prompt.md` (assessment: nine themes) and `spikes/T7/prompt.md` (fingerprint: the `model` facet as a trigger, with every model's spellings and when to use it). Expected fingerprint case `MC1536101` (the 2 December prompt retirement: the nine retiring models and `resource_type: prompt`) added to `tests/fingerprints/expected.json`; `model` is now a scored trigger facet.
- **Switches** (crdr_config, defaults leave behaviour unchanged):
  - `rating_scope`: `window` (default) or `all`, which rates every active signal except service health once;
  - `fingerprint_signal_ids`: clearing it fingerprints every signal. The flow now always skips service health, and skips signals with manual or rule fingerprints;
  - `rating_max_per_run` and `fingerprint_max_per_run`: per-run caps (0 = none), used to measure 10 first and to stay under the 500-credit cap.

**Backfill run, 2026-11-22 (prompts v4 pasted by Simon; text checked through the API, both published):**
- **Prompt tests:** fingerprint 10 of 11; the miss is RM570671, the known 111-character case with a manual fingerprint, so v4 improves on v3's 8 of 10. Assessment 6 of 6. The MC1536101 case was restated as one group per model: the prompt splits them that way, which means the same.
- **Measured batch of 10, each pass:** rating about 3,400 tokens a call, fingerprinting about 4,600 (1.5 times v3's, from the longer vocabulary). Both are under the "double the estimate" stop.
- **Rating:** `rating_scope = all`, 333 signals rated, 0 invalid, about 1.04 million tokens. Every signal now has a theme: none left unthemed.
- **Fingerprinting:** `fingerprint_signal_ids` cleared, 400 signals, 594 rows, 37 of them trigger facets; 27 rule-fingerprinted signals skipped. One create failed on a transient Dataverse request limit ("elastic pool request limit 840"); that signal (RM577827) is retried by the next daily run.
- **Matching:** 422 signals with accepted fingerprints, 291 exposures, flow and engine in parity. Live exposures went from 2 signals to 9. They include MC1536101 exposing the live system prompt (ADR 0013 route 1), SharePoint-connector flows for MC1454816, and tenant settings for the Copilot cost and model posts.
- **Credits:** about 770 prompt calls in all, which at the prompt builder's 0.3 a call is about 230 Copilot credits, within the 500 cap. The admin centre's figure, available the next day, is the real one.
- **Standing settings now:** `rating_scope = all`, `rating_max_per_run = 50`, `fingerprint_signal_ids` empty, `fingerprint_max_per_run = 50`. So only new and changed signals are rated and fingerprinted, at most 50 of each a day.

**Addendum (2026-11-23): what the backfill really cost.**
- The "about 230 Copilot credits" above used the prompt builder's 0.3 a call. pp-lab's AI event log (`msdyn_aievent`) gives the real figure. November to the 23rd: 1,041 prompt calls, **4,786 AI Builder credits** at the basic-model rate, about 5 a call.
- The calls are billed in AI Builder credits, not Copilot credits: classic cloud flows use AI Builder credits first. That's why the Copilot credit figure Simon watches didn't move.
- Billed as Copilot credits, the same calls would be about 480 (0.46 a call): within the 500 cap, but twice the estimate. The ongoing estimate becomes about 0.46 Copilot credits, or 5 AI Builder credits, per new or changed signal for each prompt.
- Where to check: see `verified-facts.md` (2026-11-23).

**Addendum (Simon, 2026-11-24): the priority matrix as an overview visual.**
- The priority matrix is now a grid of counts in the style of "What lands when": rows are impact (High or critical, Medium, Low, Rated no impact, Not yet rated), columns are time to land. Selecting a count lists its items, action first. It replaces the item-list matrix.
- "Later or landed" is split: columns are now Landed, Next 30 days, 1–3 months, 3–6 months and Later. Items without a key date are counted beside the grid. `Get-TimeBucket` and the page's `getTimeBucket` return `landed` and `nodate`; cases bucket-08 to bucket-11 in `tests/radar/radar.json`.
- On open, only the two visuals (Priority matrix, then What lands when) are expanded; Patterns, Imminent and Your estate start collapsed. The storage key moved to v3, so earlier saved choices don't hide the new default.
- In pp-lab on 2026-11-24 the grid sums to 802 items, matching the header, and its top row (35 + 3 + 2) matches the High impact tile (40).
