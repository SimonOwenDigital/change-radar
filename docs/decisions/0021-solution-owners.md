# 0021: Delegating exposures to solution owners

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0021-solution-owners) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0021-solution-owners)

Date: 2026-11-24. Status: **Proposed, on the backlog** (Simon's idea, 2026-11-24; backlog item B2). Depends on ADR 0020. Not to be built until Simon decides the questions below.

## Context

Change Radar is a platform owner's tool: one admin sees every exposure in the tenant. Simon sees it evolving into a tool that **delegates** management and remediation to each solution's owner: the owner sees their own solutions' exposures, decides what to do, and records it, while the platform owner keeps the overview.

That changes who the product is for. The spec (ADR 0005 and the spec's audience) assumes an admin audience, so this reopens a spec decision.

The SG Sizer (pp-lab experiment `2026-11-sg-sizer`) already assesses **whole solutions** (its Decision A, 2026-11-16), records a **named owner** (its flag 7 is "no named owner"), and gives each a **size**. ADR 0013 is waiting for a "risk-sizing source" so that "action required" can follow how much an asset matters. The sizer could be both the owner source and the risk source.

## Questions for Simon

1. **Who owns a solution?** Solutions have no owner field in Dataverse.
   - A. A mapping the platform owner keeps in Change Radar (solution to person or team).
   - B. Inferred from the owners of the solution's components (most common owner).
   - C. **From the SG Sizer**: a sized use case names its solution and owner. Default: C, with A as the override and B as a hint only.
2. **What owners see.** Filtering the page is not security: exposures describe how the tenant is configured. Default: Dataverse row-level security, an owner team per solution that owns its exposures and assessments, with the platform owner keeping organisation-wide read.
3. **What owners do.** Default: confirm or dismiss an exposure, and record remediation (status, note, due date) in Change Radar. The tenant stays read-only; Change Radar never changes the asset.
4. **Where their alerts go.** Default: each solution's owner gets its cards (alert destinations per solution, ADR 0011 addendum), and the platform owner keeps the digest.
5. **Licensing.** A solution owner using the model-driven app needs a Power Apps Premium (or per-app) licence. Teams cards plus Ask Change Radar may avoid that for owners who only read and respond, but whether an end user reading Dataverse through the agent needs a licence must be checked on Microsoft Learn before anything is decided.
6. **Risk tier from the sizer.** Should the sizer's size feed the rating (ADR 0013: action required by risk tier), or stay information only at first?

## What would follow

An ADR 0021 decision, then a spike on licensing and row-level security in pp-lab (cost measured), then the build. The SG Sizer link makes Change Radar and the sizer one story: size the solution, name its owner, then watch the changes that reach it.
