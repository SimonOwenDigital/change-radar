---
title: Change Radar
subtitle: Service Description Template
document: CR-OPS-04
version: "0.3"
date: 24 November 2026
status: For review
audience: Service owners writing Change Radar's entry in an internal service catalogue
owner: Simon Owen
release: Change Radar 0.3.0
intro: keep
breaks: none
---

# Service description template

> **For:** service owners writing Change Radar's entry in an internal service catalogue. **Kind:** template.
> **Status:** a starting point for release 0.3.0. Replace every `<placeholder>` and delete what doesn't apply.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=service-description) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=service-description)

## 1. The service

| Field | Entry |
|---|---|
| Service name | Change Radar: Power Platform and Copilot change monitoring |
| Service owner | `<named person>`, `<your team>` |
| Purpose | Keeps `<organisation>`'s Power Platform and Copilot estate safe and supported as Microsoft changes the platform: collects Microsoft's change announcements, shows which of our apps, flows, agents and prompts each one touches, rates the impact and alerts the people who act |
| Users | The platform team and Power Platform admins (daily); solution owners and makers (when a change touches their solution); `<leadership group>` (weekly digest) |
| Environment | `<environment name>`, a dedicated environment in `<region>` |
| Version | Change Radar `<version>`, installed `<date>` |

## 2. What's included

- The Radar page, the Fingerprint review page and the Change Radar app.
- Teams cards for service incidents, High or Critical ratings, deadlines, model changes and watch list matches, to `<destinations>`.
- The weekly digest each `<Monday>` at 08:00 UTC.
- `<Ask Change Radar in Teams and Microsoft 365 Copilot>` (delete if not enabled).
- Tuning: sources, vocabulary, rules, watch topics and caps, on request.

## 3. What's not included

- Making the changes Change Radar identifies: owners remediate their own solutions through `<your change process>`.
- Monitoring of anything other than Power Platform and Copilot changes.
- Vendor support: Change Radar is open source with no warranty or service level (Open Source and Support).

## 4. Hours and availability

| | |
|---|---|
| Automated runs | Nightly between 04:00 and 07:00 UTC; service health every 15 minutes; Message Center hourly |
| Support hours | `<your support hours>` |
| Planned maintenance | Upgrades in `<window>`, announced to users `<n>` days ahead |
| If it stops | The estate is unaffected: Change Radar only reads. Alerts and the Radar pause until the next successful run |

## 5. Support

| Tier | Who | Handles |
|---|---|---|
| 1 | `<service desk>` | Access requests, "I can't open the app", routing |
| 2 | `<platform team>` | Failed runs, alerts, tuning, connections, the reader's certificate (Operations Runbook) |
| 3 | `<named maintainer>`; the Change Radar community on GitHub | Defects in Change Radar itself; upgrades |

## 6. Requests

| Request | Who can ask | Fulfilled by | Target |
|---|---|---|---|
| Access (Change Radar User or Admin role, app licence) | Platform team members, solution owners | `<team>` | `<n> working days` |
| A new alert destination (a chat, channel or email) | Platform owner | `<team>`: `alert_destinations` | `<n> working days` |
| A new source of changes | Anyone | `<team>`: Adding a Signal Source | `<n> working days` |
| A new environment to read in detail | Platform owner | `<team>`: `detail_environments` and the reader's application user | `<n> working days` |
| A new watch topic | Anyone | `<team>`: Watch list | `<n> working days` |
| A rating or exposure query | Solution owners | `<team>` | `<n> working days` |

## 7. Measures

| Measure | Target | Source |
|---|---|---|
| Nightly runs succeeded | `<99%>` of nights | Collection runs |
| Incident card delivered | Within `<30 minutes>` of Microsoft posting it | Handler runs |
| High or Critical changes triaged | Within `<2 working days>` | Exposure status |
| AI credit use | Within the allocation of `<n>` a month | Capacity report; `Get-CreditEstimate.ps1` |

## 8. Dependencies

Microsoft Dataverse, Power Automate, AI Builder, Microsoft Teams `<and Exchange Online>`, Microsoft Graph, the Power Platform inventory, Azure Key Vault (the reader's certificate), and the connection owner account `<account>`.

## 9. Costs

| Item | Cost | Paid by |
|---|---|---|
| Power Automate Premium for the connection owner | `<cost>` | `<budget>` |
| Premium Power Apps rights for `<n>` users | `<cost>` | `<budget>` |
| AI Builder credits or Copilot Credits | `<n>` a month (Prerequisites, section 3) | `<budget>` |
| Dataverse capacity | `<n> GB` of the tenant's capacity | `<budget>` |
| Azure Key Vault | `<cost>` | `<budget>` |
| Staff time | About 5 minutes a day, 15 a week and 30 a month for operations (Operations Runbook), plus the platform owner's 10-minute daily triage (User Guide) | `<team>` |

## 10. Governance

Approved by `<board>` on `<date>` (the Governance Approval Checklist). Reviewed `<yearly>`; the data protection record is `<reference>`.
