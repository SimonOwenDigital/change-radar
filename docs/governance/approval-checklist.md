---
title: Change Radar
subtitle: Governance Approval Checklist
document: CR-GOV-01
version: "0.3"
date: 24 November 2026
status: For review
audience: Change advisory, architecture, security and data protection boards
owner: Simon Owen
release: Change Radar 0.3.0
intro: keep
breaks: none
---

# Governance approval checklist

> **For:** change advisory, architecture, security and data protection boards. **Kind:** checklist.
> **Status:** pre-filled for release 0.3.0. Each line gives the answer and where the evidence is; the reviewer marks whether it is accepted. The last section records what your organisation must decide, and the sign-off.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=approval-checklist) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=approval-checklist)

**In your organisation.** Governance boards are asked to approve tools they can't see inside. This pack is built so they can: every answer below points to a document, a script that proves it, or the source. For how governance can scale without a board reviewing every request, see [Scalable Governance](https://www.empoweryour.world/modellibrary/01-scalable-governance?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=approval-checklist) on Empower Your World.

## 1. The governance pack

| Document | Answers |
|---|---|
| Governance Approval Checklist (this document) | Is it safe to approve, and what must we decide? |
| Security and Data Handling | What does it read, write, store and send, as whom? |
| Data Protection Screening | Is personal data involved, and is a full impact assessment needed? |
| AI Use Statement | Where is AI used, what does it see, and who stays in control? |
| Risk Register | What could go wrong, and what controls exist? |
| Open Source and Support | What are we adopting, who supports it, and how do we leave? |
| Architecture Definition | How is it built, and how does it support the process? |
| Prerequisites and Requirements | What does it need: people, roles, licences, capacity? |

## 2. Security

| Question | Answer | Evidence | Accepted |
|---|---|---|---|
| Does it change anything in the estate? | No. It writes only to its own tables; alerts are the only output and ship switched off | Security and Data Handling, sections 1 and 6 | ☐ |
| Are permissions least privilege? | Yes: two read-only Graph permissions, a read-only Dataverse role (plus two SharePoint defaults every role gets), Global Reader for the inventory | Security and Data Handling, section 2; `Test-ReaderIdentity.ps1` proves read-only | ☐ |
| Are there secrets in code or settings? | No. The reader's certificate is generated in Key Vault and its private key never leaves it | Security and Data Handling, section 7 | ☐ |
| Does anything go outside Microsoft's cloud? | No external services and no telemetry | Security and Data Handling, section 5 | ☐ |
| Can users see more than they should? | Access is by Dataverse security role; the agent reads as the user; a User role was tested with a non-admin account (32 of 32) | Security and Data Handling, section 2 | ☐ |
| Is the release what it claims to be? | Built from a named commit, solution checker passed, SHA-256 checksums | Open Source and Support, section 3 | ☐ |

## 3. Data protection

| Question | Answer | Evidence | Accepted |
|---|---|---|---|
| Is personal data processed? | Incidentally: owners' Entra object ids, asset names, who made decisions, alert recipients | Data Protection Screening, section 2 | ☐ |
| Does the AI receive personal data? | No. Prompts receive Microsoft's announcement text and counts, never names | Data Protection Screening, section 4 | ☐ |
| Is a full impact assessment needed? | Not usually: no high-risk indicator applies. Your DPO decides | Data Protection Screening, section 3 | ☐ |
| Where is data stored? | In the organisation's own Dataverse environment and region | Security and Data Handling, section 4 | ☐ |

## 4. AI

| Question | Answer | Evidence | Accepted |
|---|---|---|---|
| Does AI make decisions? | No. AI describes changes, proposes a generic impact and writes the rationale; matching is by rules, the estate rating adds rule-based weights, and people review, confirm, dismiss and override | AI Use Statement, sections 1 and 2 | ☐ |
| Is it tested? | Fingerprint test set 8 of 10 with no false triggers; matching parity 44 of 44 | AI Use Statement, section 3 | ☐ |
| What happens when Microsoft changes the model? | Change Radar detects it; rerun the test set | AI Use Statement, section 4 | ☐ |
| Is spend controlled? | Per-run caps bound any month; a forecast script | AI Use Statement, section 6; Requirements, section 3 | ☐ |

## 5. Operations and support

| Question | Answer | Evidence | Accepted |
|---|---|---|---|
| Who supports it? | Your platform team; community support with no service level | Open Source and Support, section 2 | ☐ |
| Can we check it's working? | `Test-Install.ps1` checks the install in one read-only run; collection runs record every run and gap | Installation Guide, step 9 | ☐ |
| Can we leave cleanly? | Yes: an exit plan that needs nothing undone in the estate | Open Source and Support, section 6 | ☐ |
| Are the risks understood? | Sixteen risks with controls and actions | Risk Register | ☐ |

## 6. Decisions for your organisation

| Decision | Options | Decided |
|---|---|---|
| Service owner | A named person or team | |
| Connection owner | A named admin or a service account (Global Reader) | |
| Environment and region | A dedicated environment; whether data movement across regions is allowed | |
| Detail environments | Which environments' solutions and prompts are read | |
| Alert destinations and handlers | Teams chats, channels, email; which handlers are on | |
| Ask Change Radar | Enabled or not, and for whom | |
| Retention | Periods for run logs, events, the alert log and decisions | |
| Lawful basis | As recorded in the Data Protection Screening | |
| AI capacity | Credits allocated, and who monitors them | |
| Support model | Internal support, and how upgrades are taken | |

## 7. Sign-off

| Role | Name | Decision | Conditions | Date |
|---|---|---|---|---|
| Service owner | | | | |
| Security | | | | |
| Data protection | | | | |
| Architecture | | | | |
| Change advisory board | | | | |
