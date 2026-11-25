---
title: Change Radar
subtitle: Prerequisites
document: CR-PRE-01
version: "0.3"
date: 24 November 2026
status: For review
audience: Whoever plans an install, and the people who must approve it or take part
owner: Simon Owen
release: Change Radar 0.3.0
intro: keep
breaks: none
---

# Prerequisites

> **For:** whoever plans an install, and the people who must approve it or take part. **Kind:** checklist.
> **Status:** from the development build and two clean installs (24 November 2026). This is the short list to clear before you start. The [Requirements](requirements.md) reference gives the reason and the evidence for each item: Microsoft Learn (with the date checked), measured, or still to verify.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=prerequisites) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=prerequisites)

Work through the six lists below before you book the install. Most of the waiting in an install is for other people: an Entra admin's consent, an Azure owner's Key Vault, a licence for the connection owner, capacity allocated to the environment. Line them up first and the install itself, in the Installation Guide, takes about half a day.

## 1. People and accounts

You need up to five roles. One person can hold several of them.

| Who | What they do | Role they need |
|---|---|---|
| **Power Platform admin** (the installer) | Creates the environment, imports the solutions, loads the starting data, turns on alerts, gives people access | **System Administrator** in the Change Radar environment. A Global Administrator or Power Platform administrator can give it to themselves |
| **Entra admin** | Creates the reader app registration, and grants admin consent for two read-only Microsoft Graph permissions (service health and Message Center) | Application Developer or Cloud Application Administrator to create the app; **Privileged Role Administrator** or Global Administrator for the consent |
| **Azure owner** | Provides a resource group for a Key Vault, in which the reader's certificate is generated and stays | Contributor on the subscription or resource group, plus Owner, User Access Administrator or Role Based Access Control Administrator to assign the vault's roles |
| **Connection owner** | The account every flow runs as. A named admin or a service account, not a person who may leave | **Global Reader** in Entra (read-only, the least that the Power Platform inventory accepts), and System Administrator in the Change Radar environment |
| **Teams admin** (optional) | Makes the Ask Change Radar agent available to the whole organisation. Sharing it with named people needs no admin | Teams administrator |

## 2. Licences

| Who | Licence | Why |
|---|---|---|
| Connection owner | **Power Automate Premium** (or Process licences on the flows) | The flows use premium connectors (Dataverse, HTTP) and AI Builder prompts |
| Everyone who opens the Change Radar app | A licence with **premium Power Apps** use rights: Power Apps Premium, Power Apps per app, or pay-as-you-go | Every user of a model-driven app needs one; Microsoft tightens enforcement from February 2027 |
| People who receive alert cards | A Teams account | Cards and the weekly digest are posted in Teams. Opening the app from a card needs the Power Apps licence above |
| People who use Ask Change Radar (optional) | Nothing more if they have a **Microsoft 365 Copilot** licence; otherwise each question is billed in Copilot Credits | See section 3 |

## 3. Capacity

| Capacity | How much | Notes |
|---|---|---|
| **Dataverse database** | At least **1 GB available** in the tenant to create the environment | Every new environment needs it (Learn). Change Radar's own data is small: a first night in the install test held 773 signals, 76 assets and 572 events. Its size after a year is **to verify** in the capacity report |
| **AI Builder credits or Copilot Credits**, allocated to the environment | First month: about **5,400 to 7,100 AI Builder credits, or 455 to 595 Copilot Credits**, for a small to medium estate; about half that each month after | The first month includes a one-off backlog. The per-run caps hold any month to about 12,400 AI Builder credits, or 1,035 Copilot Credits, at most. See Requirements section 3.1 for the formula and a large estate |
| Copilot Credits for Ask Change Radar (optional) | About **10 Copilot Credits a question**, unless the asker has a Microsoft 365 Copilot licence | Copilot Credits may be shared with other workloads in your tenant: check what's already committed |

Capacity is allocated per environment in the Power Platform admin centre (Licensing, Capacity add-ons). It resets monthly and doesn't roll over, so allocate for the first month. Without AI capacity the prompts are blocked: signals are still collected and matched by rules, but nothing is fingerprinted by the prompt or rated.

## 4. The environment and the tenant

| Item | What you need |
|---|---|
| **A dedicated environment** | With Dataverse. Production or Sandbox for real use; Developer for an evaluation (both clean installs used a Developer environment). Never the default environment |
| **Region** | One where AI Builder prompts are available for the model Change Radar uses: check Microsoft's *Prompt model availability by region*. Tested in the europe-uk region |
| **Cloud** | Microsoft commercial cloud. GCC, GCC High and DoD are untested, and offer a smaller set of prompt models |
| **Data policy** | Dataverse, HTTP with Microsoft Entra ID, HTTP, Power Platform for Admins V2 and AI Builder in the same data group in the environment's data loss prevention policy. For alerts, add Microsoft Teams, and Office 365 Outlook for email |
| **An Azure subscription** | For the Key Vault that holds the reader's certificate |
| **Outbound access** | If a proxy or firewall reviews outbound traffic, allow the Microsoft hosts listed in Requirements section 2 (Graph, sign-in, the Microsoft roadmap and Learn pages) |

## 5. The installing machine

| Tool | Tested with | Notes |
|---|---|---|
| **PowerShell 7** | 7.7.0 | Every setup script needs version 7 or later |
| **Az.Accounts** PowerShell module | 5.5.3 | For signing in (`Connect-AzAccount`); the scripts use it to call Dataverse and Azure |
| **Power Platform CLI** (`pac`) | 2.15.1 | For creating the environment and importing the solutions |
| **The release files** | Release 0.3.0 | The three managed solution zips and their SHA-256 checksums (Release Notes), and the repository's `setup/` and `seed/` folders |

Installers never need Python, Node or Visual Studio. Those are only for people who change Change Radar itself.

## 6. Decisions to make first

These don't block the install, but answering them beforehand saves a second visit. Each can be changed later.

| Decision | Options | Default |
|---|---|---|
| Who is the connection owner | A named admin or a service account | (none: you choose) |
| Where alerts go | A Teams chat, a Teams channel, an email address, or several (`alert_destinations`) | None: alerts are off until you choose |
| Which alerts to turn on | Teams cards, the Monday digest, and the same by email | All off |
| Which environments to read in detail | Environments whose solutions, prompts and callers Change Radar reads (`detail_environments`); each needs the reader added | None: the tenant-wide inventory only |
| Which extra sources to collect | 22 extra feeds (release notes, blogs, model retirement tables, licensing guides) | All off: Message Center, the roadmap and service health only |
| How much to rate | Only signals that are near or touch your estate (`window`), or every signal (`all`) | `window`, which costs less |
| Demo data | On for evaluation and training environments; never in production | Not loaded |
