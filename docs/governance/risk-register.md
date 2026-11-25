---
title: Change Radar
subtitle: Risk Register
document: CR-GOV-05
version: "0.3"
date: 24 November 2026
status: For review
audience: IT risk, the Centre of Excellence, and whoever owns the Change Radar service
owner: Simon Owen
release: Change Radar 0.3.0
intro: keep
breaks: none
---

# Risk register

> **For:** IT risk, the Centre of Excellence, and whoever owns the Change Radar service. **Kind:** reference, to copy into your own register.
> **Status:** the risks of adopting Change Radar 0.3.0, as its author sees them. Likelihood and impact are a starting point on a three-point scale (Low, Medium, High) before your own controls; replace them with your organisation's scale and add the owner for each.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=risk-register) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=risk-register)

**In your organisation.** The risk of *not* tracking platform change is the reason Change Radar exists: deadlines missed, a retired model quietly changing a prompt's answers, a connector change breaking a flow nobody knew depended on it. This register covers the other side: the risks the tool itself brings. For how risk decisions can be made once and reused across AI use cases, see the [Make AI Adoption Safe](https://www.empoweryour.world/journeys/make-ai-adoption-safe?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=risk-register) journey on Empower Your World.

## 1. The register

| ID | Risk | Likelihood | Impact | Built-in controls | Your action |
|---|---|---|---|---|---|
| R01 | **A real change is missed** because it isn't announced where Change Radar looks, or the matching rules don't cover it | Medium | High | Several sources (Graph, roadmap, Learn, blogs, licensing guides); rules and vocabulary that admins extend; a watch list for topics; a fixture estate that tests the rules | Treat Change Radar as an aid, not the only control; review the watch list and sources quarterly |
| R02 | **An AI fingerprint or rating is wrong** and leads to a wrong priority | Medium | Medium | Matching by rules; estate rating weighted by rules; ratings labelled as AI assessments; low-confidence fingerprints reviewed by people; vocabulary validation; evidence on every exposure; overrides with reasons | Review High and Critical ratings before acting; rerun the test set after a model change |
| R03 | **AI credit spend overruns** the capacity allocated | Low | Medium | Per-run caps (25 each), a monthly ceiling of about 12,400 AI Builder credits, a credit estimate script, rating scope limited by default | Allocate capacity for the first month; review the capacity report monthly |
| R04 | **AI capacity runs out**, so prompts stop | Medium | Low | Collection, matching and alerts keep working; anything over a cap waits for the next night | Monitor capacity; alerts from the admin centre at 15% remaining |
| R05 | **The connection owner leaves** or their account is disabled, and the flows stop | Medium | High | Collection runs record every failure; `Test-Install.ps1` reports broken connections | Use a service account or a named admin with a deputy; include it in leaver processes |
| R06 | **The reader's certificate expires** or consent is withdrawn | Low | Medium | Certificate in Key Vault; collection runs record authentication failures | Set a renewal reminder from the certificate's expiry date |
| R07 | **Microsoft changes or retires an API** Change Radar uses (Graph, the inventory, a Learn page's layout) | Medium | Medium | Each collector records gaps and failures; sources are data (a feed profile), so a changed page is fixed by editing a profile, not code | Watch the collection runs; update to new releases |
| R08 | **Microsoft migrates the prompt model**, changing results | High | Low | Change Radar collects model retirements, including its own; test sets to rerun | Rerun the fingerprint test set after each migration |
| R09 | **Alert content reaches people who shouldn't see it** | Low | Medium | Handlers off by default; destinations set by an admin; demo data never sent; up to five asset names per card | Send to admins' chats or a private channel; avoid wide distribution lists |
| R10 | **Alert fatigue**, so important cards are ignored | Medium | Medium | Cards only for incidents, High or Critical ratings, deadlines and model changes; a weekly digest for the rest; already-resolved incidents raise nothing | Tune `rating_scope`, the watch list and subscriptions after the first month |
| R11 | **Demo data is mistaken for the real estate** | Low | High | Source labels on every record; one estate shown at a time with a banner; demo data refused in Production | Load demo data only in evaluation and training environments |
| R12 | **Change Radar is used as an access path** to estate information beyond its users' need | Low | Medium | Security roles; the agent reads as the user; no role, no data; the estate data is metadata, not business data | Give the User role to the platform team and admins only |
| R13 | **No vendor support**: Change Radar is open source with no warranty or service level | High | Medium | Open code and design, tests, ADRs and documentation; releases from named commits with checksums | Name an internal service owner; decide your support model (Open Source and Support) |
| R14 | **The project goes quiet** and stops tracking Microsoft's changes | Medium | Medium | Apache 2.0 lets you fork and maintain it; everything needed to build it is in the repository | Keep the ability to build from source; review the project's activity yearly |
| R15 | **Personal data is held longer than needed** | Medium | Low | No personal data sent to the AI; retention guidance | Set retention as Dataverse bulk delete jobs (Data Protection Screening) |
| R16 | **A handler written in-house writes outside Change Radar** without review | Low | High | Handlers ship off; `Set-Handlers.ps1` names any handler that writes outside Change Radar; the Extend guide requires it to say what it writes, where and as whom | Review in-house handlers like any other automation |

## 2. Risks Change Radar reduces

For the business case, the risks it is designed to reduce:

| Risk without it | How Change Radar reduces it |
|---|---|
| A deprecation or retirement breaks apps, flows or agents | Retirements and deadlines matched to the assets they touch, with cards at 14 and 3 days |
| A model change silently alters a prompt's or agent's answers | Model retirement tables collected; prompts and their callers matched to the model they use |
| A licensing change raises cost unexpectedly | Licensing guides and pages collected as information |
| Service incidents go unnoticed by the people who own affected solutions | Service health every 15 minutes, with a card for each new incident |
| Admins can't keep up with Message Center volume | One prioritised view of what touches your estate, and a weekly digest |
