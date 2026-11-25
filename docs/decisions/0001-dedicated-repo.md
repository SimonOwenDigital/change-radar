# 0001: Dedicated repo, private until release

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0001-dedicated-repo) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0001-dedicated-repo)

Date: 2026-11-18. Status: accepted.

## Context
Change Radar was prototyped in Claude. Options were to build in the pp-lab experiments repo and extract later, to publish inside the Empower-your-world repo, or to use a dedicated repo.

## Decision
A dedicated `change-radar` repo under the EYW GitHub organisation, private while building and public from phase 7. pp-lab hosts throwaway spikes only. Linked from the EYW repo and website.

## Consequences
- The public history starts clean, with no risk of tenant ids or secrets in old commits.
- Its own issues, releases, Actions and MIT licence, kept separate from EYW material licensing.
- Spike findings move across as written decisions, not copied code.
