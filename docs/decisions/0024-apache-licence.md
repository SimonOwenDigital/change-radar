# 0024: Apache License 2.0

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0024-apache-licence) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0024-apache-licence)

Date: 2026-11-24. Status: **Accepted** (Simon, 2026-11-24). Supersedes the MIT choice in spec §10 item 5, ADR 0001 and ADR 0022 decision 2.

## Context

The repository has carried the MIT licence since the first commit, chosen as the Power Platform community norm. Before the repository goes public, Simon asked for MIT and the Apache License 2.0 to be compared. Both let anyone use, change, share and sell Change Radar, and both disclaim warranty. Apache 2.0 adds:

- a NOTICE file that every copy and derivative must carry, so attribution survives a fork or a rebrand;
- no trademark rights (section 6), so the name "Change Radar" and the Empower Your World name stay with the author;
- an explicit patent grant from every contributor, which some enterprise legal teams look for;
- contributions arrive under the same licence by default (section 5), with no separate contributor agreement.

## Decision

Change Radar is open source under the **Apache License 2.0**. `LICENSE` holds the licence text unchanged (from apache.org, 11,358 bytes); `NOTICE` credits Change Radar and Empower Your World, with one link to empoweryour.world (ADR 0022: link, never reproduce), and says the names aren't licensed.

## Consequences

- Distributions, including the managed solution zips attached to a release, ship with `LICENSE` and `NOTICE`.
- Contributions are accepted under Apache 2.0 (CONTRIBUTING.md).
- The Word documents' control page states the licence; the generated documents are rebuilt.
- Files that someone else changes must say so (section 4b); nothing is needed for Change Radar's own files, and per-file licence headers are optional and not used.
- The licence change is made before the repository goes public, so no MIT release exists to reconcile.
