# 0004: Where the LLM runs

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0004-where-the-llm-runs) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0004-where-the-llm-runs)

Date: 2026-11-18. Status: **Accepted**, 2026-11-19 (Simon): in-tenant only for now (option A).

## Context

The LLM does two jobs (spec §5, §6): turning signal text into facets from the fixed vocabulary (with confidence), and writing the rationale and recommended action from structured inputs. It never scores and never sees estate free text. Spec §8 offers A (in-tenant prompt actions), B (Claude via the Anthropic API) and C (hybrid). §13.3 says the provider must be pluggable behind one child flow with a fixed JSON contract.

Verified on Microsoft Learn, 2026-11-18:

- Claude models are available in Microsoft Copilot and Copilot Studio with **Anthropic operating as a Microsoft subprocessor**, under the Microsoft Product Terms and DPA. An AI Administrator or Global Administrator enables it in the Microsoft 365 admin centre; a Power Platform admin must then allow it per environment or environment group in PPAC. ([Claude models from Anthropic in Microsoft Online Services](https://learn.microsoft.com/copilot/implement/connect-to-ai-subprocessor); [Model availability and controls](https://learn.microsoft.com/microsoft-copilot-studio/agents-experience/authoring-agent-model-availability))
- The subprocessor setting is **on by default except in the EU/EFTA and UK**, where it is off and must be opted into.
- For Anthropic models in Word, Excel and PowerPoint, processing happens outside the EU Data Boundary. Assumed (not verified tonight) to apply to Copilot Studio use as well.

This adds an option the spec didn't have: Claude reasoning without a separate Anthropic contract or API key.

## Options

| Option | Data boundary | Cost | Installer burden | Fit |
|---|---|---|---|---|
| A. Prompt actions, default Microsoft-operated models | Microsoft tenant boundary | Copilot credits | Lowest: nothing to enable beyond licences | Good default for others; dogfoods the platform |
| A+. Prompt actions with a Claude model (Anthropic as Microsoft subprocessor) | Microsoft terms and DPA; processing may leave the EUDB; UK/EU tenants must opt in | Copilot credits | Two admin settings (M365 admin centre + PPAC per environment) | Stronger reasoning, one commercial relationship; good EYW story |
| B. Claude via Anthropic API from a flow or script | Facets and asset names leave for Anthropic under separate terms | Per token | API key in Key Vault, a data-processing decision, a custom connector | Heaviest to install; hard to justify for other installers |
| C. Hybrid: A for fingerprinting and routine ratings, Claude Code on demand on exported, minimised data | Mostly in tenant | Low | None for installers | Spec's recommendation; deep analysis stays a manual, deliberate act |

## Recommendation

**C, with A as the shipped default and A+ as a documented configuration**, not B:

- Ship the child flow contract (`fingerprint` and `rationale`, JSON in and out) with an in-tenant prompt action as the default implementation.
- Document A+ in `permissions-and-data.md` as an opt-in model choice, with the two admin settings and the EUDB note. Simon's own instance can use A+.
- Keep deep analysis (Claude Code over exported, minimised data) as a manual workflow, not part of the product.
- Drop B from v1. Revisit only if A/A+ can't hit acceptable fingerprinting accuracy against the test suite.

Whatever runs, the contract holds: facets in, facets out; vocabulary-checked; below-threshold confidence goes to review.

## Decision

**Keep the LLM in-tenant for now (option A).** The shipped implementation of the `fingerprint` and `rationale` child flows uses an in-tenant prompt action with the default Microsoft-operated models.

- **A+ (Claude as a Microsoft subprocessor):** deferred, not enabled. It may process outside the EU Data Boundary and needs a UK opt-in, so revisit it deliberately. Keep it as a documented option in `permissions-and-data.md`.
- **B (direct Anthropic API):** dropped from v1.
- **Claude Code analysis on exported data (the manual half of C):** not part of the product for now.

The JSON contract is unchanged, so A+ or another provider can be added later without redesign.

## Consequences

- `crdr_config` / environment variable `LLMMode` ships with value `A`. `A+` stays a reserved value until that option is revisited.
- Fingerprinting accuracy needs a test set of real Message Center posts with expected facets (extends `tests/`).
- The setting `anthropic_subprocessor` in the vocabulary doubles as a signal facet and a precondition check for A+.
- To verify before acceptance: whether prompt actions in Power Automate (not only Copilot Studio agents) can select Claude models, and whether the PPAC allow-list applies to prompts. Not checked tonight.

## Note, 2026-11-20 (spike T7)

- The fingerprint prompt uses **GPT-6 Sol**, a Microsoft-operated model, so this is still option A.
- The prompt builder in pp-lab also offers **Claude Sonnet 4.6 and Claude Opus 4.6** ("paid experimental"). That suggests the Anthropic subprocessor setting is already enabled for this tenant.
- A+ remains deferred: those models weren't used.
- When A+ is revisited, the `anthropic_subprocessor` setting check (spec §5) should confirm this from the tenant, not from the UI.
