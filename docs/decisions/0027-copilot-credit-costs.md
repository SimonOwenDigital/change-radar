# 0027: What Change Radar costs in Copilot Credits, and which model it uses

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0027-copilot-credit-costs) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0027-copilot-credit-costs)

Date: 2026-11-27. Status: **Accepted**, 2026-11-27 (Simon). Evidence: spike T13 (`spikes/T13/README.md`), pp-lab, 2026-11-27.

## Context

Until now, the Copilot Credit cost of a prompt call (0.46) was computed. The nightly cloud flows spend AI Builder credits first, so no call had ever been billed in Copilot Credits (`verified-facts.md`, 2026-11-23). Seeded AI Builder credits end when a licence renews (requirements, section 3), so adopters will soon pay in Copilot Credits only. That leaves three open questions:

- What does a call actually bill?
- What would moving the pipeline to agent flows cost (ADR 0016)?
- Would a different model tier rate signals better?

## What was measured (verified, `msdyn_aievent`, 2026-11-27)

- **The billing rule.** A call bills `ceiling((input + output tokens) ÷ 1,000)` units at 0.1 Copilot Credits a unit ("Text and generative AI tools (basic)"). Rounding is per call. A fingerprint call bills 0.4 to 0.5 and a rating or assessment call 0.3 to 0.4. Over 48 calls on the production model, the average was **0.41**. The documented 0.46 holds as a planning figure, with a small margin.
- **The route decides the currency.**
  - Classic cloud flows (`partnerSource` `AIBuilder`) use AI Builder credits while any are left.
  - The Dataverse `Predict` message (`Api`) and agent flows (`AgentFlows`) bill **Copilot Credits straight away**, even when AI Builder credits remain.
- **Agent flows add per-action billing.** A minimal agent flow ran 20 prompt calls in 23 actions. At the documented 13 Copilot Credits per 100 actions, that adds about 0.15 a call. The production fingerprint flow runs about 8 actions a call (ADR 0016), which as an agent flow would add about 1.0 a call, more than doubling the cost. The admin centre's per-flow figure is **to confirm** (it can be a few days late).
- **The model tier label doesn't set the price today.** The production prompts run on `gpt-6-sol`, which the model picker labels Premium. GPT Chat Latest (Standard) and GPT-6 Luna (Basic) all billed as basic, at 0.39 to 0.42 a call.
- **Quality, two passes over the 24 test cases:**

  | Model | Passed |
  | --- | --- |
  | GPT-6 Sol | 43 of 48 |
  | GPT-6 Luna | 43 of 48 |
  | GPT Chat Latest | 37 of 48 (empty answers, and forbidden trigger facets, when fingerprinting) |

## Decision

1. **Cost for adopters.** Plan on **0.46 Copilot Credits a prompt call**, now verified against billing. A normal month is about 185 to 760 Copilot Credits by estate size, and the caps hold any month under about 1,035 (requirements 3.1, unchanged). The development environment's own month is about 1,000 calls, or about 400 Copilot Credits.
2. **The pipeline stays in classic cloud flows** (ADR 0016, option D). Agent flows would bill every action, as measured above.
3. **The prompts stay on GPT-6 Sol.** GPT-6 Luna is the tested fallback if Sol retires or its billing changes. A higher tier gains nothing on the test cases.
4. **Scripts that call a prompt spend Copilot Credits.** The spike scorers and any `Predict` call do, even while AI Builder credits remain. The developer guide says so.

## Consequences

- The credit figures in the requirements, costs and runbook pages are now marked as billed, not computed. Their numbers don't change.
- **Re-check after 2 December 2026**, when the prompt model line-up changes. Score the prompts again and read the billed `featureName` and `llmModelName` from `msdyn_aievent`. If Sol starts billing as premium (10 Copilot Credits per 1,000 tokens), the cost would rise a hundredfold: move to Luna.
- One case (RM570671, `capability: uses_mcp`) failed on every model in every run. It's a prompt or test-case issue for the backlog, not a model choice.
- **Not closed:** spike T4 (the Copilot Credits reporting API, for consumption as an asset facet) is a separate question and stays open.
- The spike cost about 70 Copilot Credits.
