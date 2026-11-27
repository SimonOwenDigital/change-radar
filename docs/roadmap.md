---
title: Change Radar
subtitle: Roadmap
document: CR-RMP-01
version: "0.3"
date: 24 November 2026
status: For review
audience: Adopters deciding whether Change Radar is heading where they need, and contributors
owner: Simon Owen
release: Change Radar 0.3.1
intro: keep
breaks: none
---

# Roadmap

> **For:** adopters deciding whether Change Radar is heading where they need, and contributors. **Kind:** explanation.
> **Status:** **not committed.** These are directions, drawn from the backlog, the specification's enhancements (section 14) and the design decisions (ADRs). Nothing here has a date, and anything may change or be dropped. What exists today is in the Architecture Definition and the release notes.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=roadmap) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=roadmap)

## Near term

| Item | What it would do | Where it stands |
|---|---|---|
| One-step install | A Package Deployer package alongside the manual install, so connections, environment variables and seed data are set in one guided run | Idea; the manual install stays the reference |

## Later (proposed, not decided or scheduled)

| Item | What it would do | Where it stands |
|---|---|---|
| **Solution owners** (ADR 0021, backlog B2) | Solution owners see and manage their own solutions' exposures, get their own alerts, and record remediation; the platform owner keeps the overview | Proposed; open questions on ownership, row-level security and licensing |
| **Risk-sized ratings** (spec E1) | Weigh a change's impact by the risk tier of the solution it touches, from a risk-sizing source | Idea; asset ids already stable for it |
| **Owner facets** | Match changes by who owns an asset (a user or a service principal) | Not collected today; needs principals from the inventory |

## Ideas

| Item | What it would do | Where it stands |
|---|---|---|
| **Match changes to ideas and use cases** (spec E2) | Not only "what could this break?" but "what could this enable?": a change that unblocks, simplifies, changes or makes obsolete an idea on your backlog. "Makes obsolete" is the most valuable: it stops investment in something Microsoft is about to ship | Idea |
| **Consumption exposure** (spec E4) | Match billing and limit changes against where credits are actually spent | Idea |
| **Many tenants** (spec E3) | One change-impact service across organisations. Probably one installation per tenant, not a central collector, with consent, isolation and a processing agreement | Idea; a separate decision |
| **An open signal model** (backlog B3) | Publish the signal and fingerprint data (which changes touch which kinds of component), without anything from a tenant, so other tools can use it. Message Center text needs checking against Microsoft's terms first | Idea |
| **Other models for prompts** (ADR 0004, option A+) | Claude as a Microsoft subprocessor, opt-in | Deferred: may process data outside the EU Data Boundary |
| **Copilot Studio Kit inventory** | More agent facets (MCP use, autonomous triggers, HTTP actions) | Optional source; names not yet verified |

## How to influence it

Open an issue on the repository: describe the change you'd like to see in your own words, and what it would let you do. Contributions are welcome (Developer Guide, section 10).
