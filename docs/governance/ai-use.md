---
title: Change Radar
subtitle: AI Use Statement
document: CR-GOV-04
version: "0.3"
date: 24 November 2026
status: For review
audience: AI governance boards, risk, and architecture review
owner: Simon Owen
release: Change Radar 0.3.1
intro: keep
breaks: none
---

# AI use statement

> **For:** AI governance boards, risk, and architecture review. **Kind:** explanation.
> **Status:** describes release 0.3.0. The accuracy figures come from the test sets in the repository and the development build (November 2026).
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=ai-use) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=ai-use)

**In your organisation.** AI that changes model without anyone deciding is exactly the risk Change Radar exists to catch in your estate, so it applies the same discipline to itself: every AI step is named, capped, reviewable and overridable, and the estate rating that drives alerts adds rule-based weights to the AI's judgement and can always be overridden. For a lifecycle view of governing AI agents and prompts after they go live, see [AI Agent Lifecycle](https://www.empoweryour.world/modellibrary/07-ai-agent-lifecycle?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=ai-use) on Empower Your World.

## 1. Where AI is used

| Step | What the AI does | What it doesn't do | Model |
|---|---|---|---|
| **Fingerprint** | Reads a Microsoft announcement and describes what it touches, as values from a fixed vocabulary (products, connectors, capabilities, models) with a confidence | Decide whether your estate is affected: that is done by rules | An AI Builder prompt, Microsoft-operated (GPT-6 Sol at the time of writing) |
| **Rating** | Proposes the change's **generic impact** (how much it matters to any estate, None to Critical) and its nature, and writes the rationale and the recommended action, from structured facts | Set the estate rating alone. The estate impact is computed by rules from the generic impact: plus one if an affected asset is in production, plus one if action is required within 30 days, capped at Critical | The same |
| **Text recognition** | Reads Microsoft's licensing guide PDFs to find their change logs | Rate them: licensing information is never rated | AI Builder text recognition |
| **Ask Change Radar** (optional) | Answers questions about Change Radar's data in Teams and Microsoft 365 Copilot, reading as the person asking | Change anything: it has no tool that writes | A Copilot Studio agent, Microsoft-operated model |

**Not AI:** collecting signals, reading the estate, matching changes to assets, computing scores, raising events and sending alerts are all deterministic, rule-based and repeatable.

## 2. Human oversight

- **Fingerprints below the confidence threshold** (0.7 by default) go to a review queue instead of matching, and a person accepts or rejects them on the Fingerprint review page.
- **Every fingerprint value must exist in the vocabulary.** A value the AI invents can't match anything.
- **Structured sources don't use the AI:** retirement tables, for example, are fingerprinted by rules.
- **Every exposure shows its evidence:** which rule matched which facet of which asset.
- **People confirm or dismiss exposures, and override ratings** (raise, lower or dismiss) with a required reason. The AI never overwrites an override.
- **Ratings are labelled as assessments,** with their rationale, so readers know what the AI wrote.

## 3. Accuracy and testing

| Test | Result |
|---|---|
| Fingerprint test set (10 real announcements with agreed answers) | 8 of 10 correct with no false trigger facets on the chosen model; the alternative scored 7 of 10 |
| Matching engine against the platform's flows (44 cases) | 44 of 44 identical (parity) |
| Rule test suites (config, credits, handlers, events) | Cases written before the rules; all pass at release |
| Ask Change Radar test set | Answers from the data, refuses to change anything, a user without a role gets nothing |

The test sets are in the repository, so you can rerun them after a model change.

## 4. When Microsoft changes the model

Microsoft retires and replaces prompt models on its own schedule; prompts move to the replacement model for their tier automatically (for example on 2 December 2026). Responses can differ after a migration. Change Radar watches for these changes for your estate, and for itself:

- the model retirement tables on Microsoft Learn are one of its sources, so a retirement that touches its own prompts appears on the Radar like any other;
- after a model change, rerun the fingerprint test set and compare;
- the prompt's model is a setting in the AI hub, not code.

## 5. Data and privacy

- The prompts receive Microsoft's announcement text and counts and facets of affected assets, **never asset, owner or environment names** (Data Protection Screening, section 4).
- Microsoft states that prompt inputs and outputs aren't used to train foundation models (Learn, 2026-11-24, [AI Builder architecture](https://learn.microsoft.com/ai-builder/ai-builder-architecture)).
- Prompts run in the environment's region unless an administrator allows data movement across regions.
- No AI service outside Microsoft is used. An option to use a non-Microsoft model through Microsoft (ADR 0004, A+) is deferred and not enabled.

## 6. Cost control

Every prompt call costs AI Builder credits or Copilot Credits. Per-run caps on fingerprinting, rating and estate assessment (25 each by default) bound any month at about 12,400 AI Builder credits, or 1,035 Copilot Credits. `setup/Get-CreditEstimate.ps1` forecasts your use from your own data. Without capacity, the prompts stop and the rest of Change Radar keeps working.

## 7. Known limitations

- The AI can misread an announcement, so fingerprints are reviewed below the threshold, and a rule-based fingerprint is preferred where the source is structured.
- Generic impact comes from the announcement and Microsoft's own wording, which can understate or overstate a change.
- The generic impact is a judgement and can vary between calls for the same announcement (observed: Medium in one run, Low in the next). Overrides exist for this.
- The rationale is written for a platform admin. It is a starting point for a decision, not the decision.
- Ask Change Radar answers from Change Radar's data only, not from Microsoft's documentation.

## 8. Transparency

Change Radar's users know where AI is used: ratings and fingerprints are labelled, the method is published in the repository (this statement, the architecture and the ADRs), and the prompts' instructions are in the solution.
