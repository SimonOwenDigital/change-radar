---
title: Change Radar
subtitle: Operating Model
document: CR-OPM-01
version: "0.3"
date: 24 November 2026
status: For review
audience: Platform owners, service owners and change managers deciding how Change Radar fits their organisation
owner: Simon Owen
release: Change Radar 0.3.1
intro: keep
breaks: none
---

# Operating model

> **For:** platform owners, service owners and change managers deciding how Change Radar fits their organisation. **Kind:** explanation, with a RACI and a rhythm to adapt.
> **Status:** a starting point for release 0.3.0. The roles, rhythm and measures are suggestions to tailor, not requirements of the software.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=operating-model) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=operating-model)

**In your organisation.** A tool only changes outcomes if someone owns what it tells them. Change Radar finds the changes that touch your estate; deciding what to do, and making sure it's done, stays with people and with the change process you already run. For how AI-enabled change can be owned from first use to retirement, see [AI Agent Lifecycle](https://www.empoweryour.world/modellibrary/07-ai-agent-lifecycle?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=operating-model) on Empower Your World.

## 1. The principle: Change Radar raises, people decide, your tools track

| Change Radar does | People do | Your existing tools do |
|---|---|---|
| Collects Microsoft's changes, matches them to your assets, proposes a rating, raises alerts | Confirm or dismiss, override, decide who acts and by when | Track the work: your change, ticketing or planning tool |

Change Radar doesn't assign work or track remediation. That keeps one system of record for work, and keeps Change Radar read-only against your estate. To send changes into a ticketing or planning tool automatically, build a handler from the Handler template (the Extend guide): it reacts to an event, such as a High rating, and creates the ticket. Any handler that writes outside Change Radar must ship switched off and say what it writes, where and as whom.

## 2. Roles

| Role | Typically | Responsible for |
|---|---|---|
| **Service owner** | Head of the Power Platform service or Centre of Excellence | Change Radar as a service: its budget, capacity, risks and support. Often the same person as the platform owner |
| **Platform owner** | Lead of the platform team | Daily triage and the weekly review; deciding who acts |
| **Admins** | Power Platform and Microsoft 365 admins | Triage with the platform owner; configuration and health (the Operations Runbook) |
| **Solution owners and makers** | Owners of apps, flows, agents and prompts | Fixing their assets when a change touches them |
| **Leadership** | Head of digital or IT | Reading the weekly picture; resolving priorities and funding |
| **Connection owner** | A named admin or a service account | The account the flows run as; keeping its licence and access current |

## 3. RACI

R: responsible · A: accountable · C: consulted · I: informed.

| Activity | Change Radar | Platform owner | Admins | Solution owners | Leaders | Service owner | Conn. owner |
|---|---|---|---|---|---|---|---|
| Collect and match changes | R | A | I | | | | C |
| Review uncertain fingerprints | | A | R | | | | |
| Confirm or dismiss exposures | | A | R | C | | | |
| Override a rating | | A | R | C | | | |
| Decide who acts, and by when | | A, R | C | C | I | | |
| Remediate an asset | | A | | R | | | |
| Close the exposure | R (at the next match) | I | | I | | | |
| Weekly review | | R | C | | I | A | |
| Tune sources, rules, vocabulary, watch topics | | A | R | C | | | |
| Monitor health and capacity | | C | R | | | A | |
| Keep connections and the certificate current | | I | R | | | A | R |
| Access and alert-recipient reviews | | R | C | | | A | |
| Upgrades | | C | R | | | A | |

## 4. Rhythm

| When | Who | What | Time |
|---|---|---|---|
| As it happens | Platform owner, admins | Act on cards: incidents, High or Critical ratings, deadlines, model changes, watch matches | Minutes |
| Each working day | Platform owner or an admin | Triage the Radar: exposures, overrides, fingerprints; decide who acts | 10 minutes |
| Each working day | Admins | Health check: collection runs, cards (Runbook 2.1) | 5 minutes |
| Monday | Platform owner | Digest, What lands when, patterns, watch list | 20 minutes |
| Monday | Leadership | The digest and the matrix | 5 minutes |
| Monthly | Service owner, admins | Capacity against forecast; health check; overrides and dismissals; new releases | 30 minutes |
| Quarterly | Service owner | Access and alert-recipient review; sources and watch topics; connection owner and deputy | 1 hour |
| Yearly | Admins | Certificate renewal; retention jobs; data protection record | 1 hour |

## 5. Plugging into your change process

1. **Intake.** A confirmed exposure with a High or Critical rating, or a deadline, becomes an item in your change or ticket tool: by hand at first, or by a handler you build.
2. **Assessment.** Change Radar's evidence, rating and recommended action go with the item; the solution owner adds their own judgement.
3. **Approval.** Treat the fix like any other change to that solution: Change Radar adds no extra approval step.
4. **Delivery.** The solution owner makes the change.
5. **Verification.** At the next nightly match, the exposure closes as **No longer matches**. Close the ticket when it does.
6. **Review.** The weekly review looks at what is open, what is due, and what was overridden.

Service incidents usually follow your incident process instead: the card tells you; the incident owner decides.

## 6. Decision rights

| Decision | Made by | Recorded where |
|---|---|---|
| Is this exposure real? | Platform owner or admin (User role) | The exposure's status, with who changed it |
| Is the AI's rating right for us? | Platform owner or admin (User role) | The override, with a required reason, who and when |
| Is an uncertain fingerprint right? | Platform owner or admin (User role) | The fingerprint's status |
| What do we watch, read and alert on? | Platform owner, with the service owner (Admin role) | Settings, feeds, rules, vocabulary, watch topics, subscriptions |
| Who acts, and by when? | Platform owner | Your change or ticket tool |
| How much AI capacity to fund? | Service owner | Capacity allocation; the credit forecast |

## 7. Measures of success (suggestions)

| Measure | Suggested target | From |
|---|---|---|
| New exposures triaged | Within 2 working days | Exposures: status and modified on |
| High and Critical items with an owner | 100% within 5 working days | Your ticket tool |
| Deadlines met | No action date passes with an open, confirmed exposure | Radar page; deadline cards |
| Incidents seen | Every incident card acknowledged the same day | Your incident process |
| Overrides | Falling over time, as rules and vocabulary are tuned | Assessments with an override |
| Capacity | Within the monthly forecast | Capacity report; `Get-CreditEstimate.ps1` |
| Service health | Collectors succeed every night | Collection runs |

Choose two or three to start with, and report them in the weekly review.

## 8. Adoption stages

| Stage | Who | What happens | Move on when |
|---|---|---|---|
| **1. Pilot** | Platform team | Install in an evaluation environment with demo data; work through the Learning Path; tune alert destinations | The team can triage the demo estate without help |
| **2. Live with the platform team** | Platform owner and admins | Live estate, demo data off; daily triage and weekly review; cards to the team's channel | Two or three weeks of steady triage; capacity matches the forecast |
| **3. Solution owners** | Solution owners and makers | The User role, the Solution filter and Ask Change Radar for the people who fix their assets | Owners act on changes without being chased |
| **4. Leadership and routine** | Leadership | The weekly digest and matrix in regular reporting; the measures reviewed monthly | Change Radar is part of how the platform is run |

Telling solution owners directly about changes to their solutions is on the backlog (ADR 0021); until then, the platform owner passes them on.
