---
title: Change Radar
subtitle: Data Protection Screening
document: CR-GOV-03
version: "0.3"
date: 24 November 2026
status: For review
audience: Data protection officers and privacy teams
owner: Simon Owen
release: Change Radar 0.3.1
intro: keep
breaks: none
---

# Data protection screening

> **For:** data protection officers and privacy teams. **Kind:** reference, with a pre-filled screening and a processing record.
> **Status:** pre-filled from the design of release 0.3.0. Your organisation is the controller and makes every decision here; the answers below describe what the software does, so that your assessment starts from facts. This is not legal advice.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=data-protection) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=data-protection)

**In your organisation.** Most privacy reviews of AI tools stall on one question: what exactly does the AI see? For Change Radar the answer is short, and this document gives it with the evidence. For a structured way to think about the risks of any AI use case, see [Risk Anatomy of an AI Use Case](https://www.empoweryour.world/modellibrary/06-risk-anatomy-of-an-ai-use-case?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=data-protection) on Empower Your World.

## 1. Purpose of the processing

Change Radar helps the people who run Power Platform and Copilot keep up with Microsoft's changes: it collects Microsoft's announcements, works out which of the organisation's apps, flows, agents and prompts each change touches, rates the impact and alerts the right admins. The processing is about **technology assets, not people**. Personal data is incidental: who owns an asset, who made a decision, who receives alerts.

## 2. Personal data processed

| Category | Data | Whose | Source | Why it's needed |
|---|---|---|---|---|
| Asset ownership | Entra object id of each app, flow, agent or prompt's owner (an identifier, not a name or email) | Makers and owners in the tenant | Power Platform inventory; Dataverse detail | To show who owns an affected asset (backlog: telling solution owners directly) |
| Asset names | Names given by makers, which sometimes include a person's name | Makers | Power Platform inventory | To show which assets a change touches |
| Decisions | Who confirmed, dismissed or overrode, with the reason; created by and modified by on every row | Change Radar's users | The app | Accountability for decisions about changes |
| Alert recipients | Teams user ids, channels and email addresses set by an admin; the alert log of what was sent to whom | Admins who receive alerts | Configuration | To deliver alerts and keep a record of them |
| Questions to the agent (optional) | The question asked of Ask Change Radar, in Copilot Studio's conversation records | Users of the agent | The user | To answer the question |

**Not processed:** special category data; data about customers or the public; the contents of apps, flows or business records; message or email content; activity or productivity monitoring of individuals. Change Radar doesn't profile people or make decisions about them.

## 3. Screening questions

Answer these with your own policy; the second column says what Change Radar does.

| Screening question | What Change Radar does | Likely answer |
|---|---|---|
| Is special category or criminal offence data processed? | No | No |
| Is there large-scale or systematic monitoring of individuals? | No: it monitors technology assets. Owners are recorded as identifiers to route information about their assets | No |
| Is there automated decision-making with legal or similarly significant effects on people? | No. Decisions are about changes and assets, and people review and override them | No |
| Is there profiling or scoring of individuals? | No | No |
| Is new technology, such as AI, used? | Yes: AI writes ratings' rationale and describes Microsoft's announcements. It receives no personal data (section 4) | Yes, low risk |
| Are data sets matched or combined? | Inventory metadata is matched with Microsoft's announcements. No personal data sets are combined | No |
| Is data transferred outside the organisation's geography? | Data is stored in the environment's region. AI prompts may be processed in another region only if an administrator allows data movement across regions, and they contain no personal data | Check your environment's setting |
| Are vulnerable people's data processed? | No | No |
| Could the processing prevent people exercising rights or using a service? | No | No |

**Likely outcome:** a full data protection impact assessment is **not usually required**, because none of the high-risk indicators applies and the AI receives no personal data. Record the screening, and repeat it if you switch on an option that changes the answers: Ask Change Radar, email alerts to wide distribution lists, or a future feature that notifies owners directly.

## 4. What the AI receives

| Prompt | Receives | Personal data |
|---|---|---|
| Fingerprint | A Microsoft announcement's title, products and summary | None |
| Rating | The announcement, and counts and facets of affected assets ("3 cloud flows, 2 in production") | None: no asset, owner or environment names |
| Text recognition | Microsoft's public licensing guides | None |
| Ask Change Radar (optional) | The question, and the rows the asker is allowed to read | Possibly: asset names and owner ids, if the asker's role shows them |

Microsoft states that AI Builder prompt inputs and outputs aren't used to train foundation models and aren't shared with the model's maker (Learn, 2026-11-24, [AI Builder architecture](https://learn.microsoft.com/ai-builder/ai-builder-architecture)).

## 5. Record of processing (a draft entry)

| Field | Draft entry |
|---|---|
| Name of the processing | Change Radar: Power Platform and Copilot change monitoring |
| Purpose | Keeping the organisation's Power Platform and Copilot estate safe and supported as Microsoft changes the platform |
| Lawful basis | To decide. Legitimate interests (operating and securing IT services) is a common choice; record your balancing test |
| Data subjects | Makers and owners of Power Platform assets; Change Radar's users; alert recipients |
| Data categories | Entra object ids; asset names; user records of decisions; Teams ids and email addresses for alerts |
| Recipients | The platform team and admins with a Change Radar role; alert destinations set by an admin |
| Processors | Microsoft (Dataverse, Power Automate, AI Builder, Teams, Exchange), under your existing Microsoft agreements |
| International transfers | None by design. AI prompts only if an administrator allows data movement across regions, and they contain no personal data |
| Retention | To decide. Suggested: 13 months for run logs, events and the alert log; the life of the installation for decisions (see Security and Data Handling, section 4) |
| Security measures | See Security and Data Handling: least privilege, read-only identities, certificate in Key Vault, Dataverse security roles, no telemetry |

## 6. People's rights

- **Access:** an owner's assets can be found by their Entra object id in the Assets view; decisions by the user who made them.
- **Erasure and correction:** asset data is refreshed from Microsoft's inventory every night, so an asset deleted or reassigned in the tenant changes in Change Radar. Decisions and the alert log can be deleted by a Change Radar admin; deleting them removes the audit trail, so record why.
- **Objection:** the asset data comes from Microsoft's tenant inventory, which every Power Platform administrator can already see. Change Radar has no per-owner exclusion today; if your balancing test calls for one, raise it as an issue in the repository.

## 7. Decisions for your organisation

1. The lawful basis, and the balancing test if it is legitimate interests.
2. Retention periods, set as Dataverse bulk delete jobs.
3. Whether data movement across regions is allowed for the environment.
4. Who receives alerts, and whether email is used.
5. Whether Ask Change Radar is enabled, and for whom.
6. Whether the privacy notice for staff needs a line about IT asset monitoring (it usually already covers it).
