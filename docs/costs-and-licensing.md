---
title: Change Radar
subtitle: Licensing and Cost Summary
document: CR-COS-01
version: "0.3"
date: 24 November 2026
status: For review
audience: Procurement, licensing and budget holders
owner: Simon Owen
release: Change Radar 0.3.0
intro: keep
breaks: none
---

# Licensing and cost summary

> **For:** procurement, licensing and budget holders. **Kind:** reference.
> **Status:** from the Requirements reference (Microsoft Learn checked 24 November 2026, and measured in a development environment and two clean installs). Microsoft's licensing is changing; the Microsoft licensing guides are the authority, and this is not a licensing opinion. Prices are not given: use your own.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=costs-and-licensing) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=costs-and-licensing)

**In your organisation.** The cost of Change Radar is mostly a question of AI capacity, and AI capacity is a question every organisation adopting Copilot now faces: who allocates it, to what, and how it's watched. For how to make that kind of decision once and reuse it, see the [Make AI Adoption Safe](https://www.empoweryour.world/journeys/make-ai-adoption-safe?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=costs-and-licensing) journey on Empower Your World.

## 1. What's free

- **The software:** open source under the Apache License 2.0. No subscription, no per-user charge.
- **Hosting:** none. It runs entirely in your own tenant.
- **Matching, collection and alerts:** no AI, so no credits.
- **Reading public sources:** no cost.

## 2. Licences

| Who | Licence | How many |
|---|---|---|
| The connection owner (the account the flows run as) | **Power Automate Premium**, or Process licences on the flows | One |
| People who open the Change Radar app | A licence with **premium Power Apps** use rights: Power Apps Premium, Power Apps per app, or pay-as-you-go | One per person. Microsoft tightens enforcement for model-driven apps from February 2027 |
| People who only receive Teams cards and the digest | A Teams account | No extra licence |
| People who use Ask Change Radar (optional) | Nothing more with a **Microsoft 365 Copilot** licence; otherwise each question is billed in Copilot Credits | As used |

## 3. Capacity

| Capacity | Need |
|---|---|
| **Dataverse database** | At least **1 GB available** in the tenant to create the environment. Change Radar's own data is small (a first night held 773 signals, 76 assets and 572 events); its size after a year is **to verify** |
| **AI Builder credits or Copilot Credits**, allocated to the Change Radar environment | See section 4 |
| **Azure** | One Key Vault holding one certificate, for the reader identity |

## 4. AI credits by estate size

One prompt call costs about **5.5 AI Builder credits**, or about **0.46 Copilot Credits** (measured). The cost depends mostly on how many Microsoft changes you watch, not on the size of your estate.

| | Small | Medium | Large |
|---|---|---|---|
| Assumed estate | 10 signals touching your estate | 50 | 150, with every feed on and every signal rated |
| **First month** (one-off backlog plus a normal month) | About 5,400 AI Builder credits, or 455 Copilot Credits | About 7,100, or 595 | About 19,100, or 1,600 |
| **Each month after** | About 2,200, or 185 | About 3,700, or 310 | About 9,100, or 760 |

- **The ceiling:** per-run caps (25 each by default) hold any month to about **12,400 AI Builder credits, or 1,035 Copilot Credits**, whatever happens. In the first fortnight a catch-up allowance raises the ceiling to about 29,700, or 2,480, so the backlog clears in about a week.
- **Capacity resets monthly** and doesn't roll over: allocate for the first month.
- **For scale:** a Copilot Credit pack is 25,000 credits a month, and a Power Automate Premium licence bought before 1 November 2026 includes 5,000 AI Builder credits a month until it renews.
- **Your own figures:** after a fortnight, `setup/Get-CreditEstimate.ps1` forecasts your use from your own data.

## 5. Optional extras

| Extra | Cost |
|---|---|
| Ask Change Radar | About **10 Copilot Credits a question**, unless the asker has a Microsoft 365 Copilot licence |
| Licensing guide text recognition | About 3 AI Builder credits each time Microsoft publishes a new guide (billing per page is **to verify**) |
| Email alerts | An Office 365 Outlook connection; no extra licence |

## 6. What to budget

| Item | Unit | Typical quantity |
|---|---|---|
| Power Automate Premium | Per user, per month | 1 |
| Premium Power Apps use rights | Per user, per month (or per app) | The platform team and anyone who opens the app |
| AI capacity | AI Builder credits or Copilot Credits, per month | From section 4; the first month is the peak |
| Dataverse database capacity | GB | 1 GB to create the environment |
| Azure Key Vault | Per operation and per certificate renewal | One vault, one certificate a year |
| People's time | Hours per week | About 10 minutes a day of triage, and a short weekly review (User Guide) |

The Requirements reference gives the evidence and the Learn links for every line here.
