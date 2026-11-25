# Contributing

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=contributing) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=contributing)

Issues, ideas and pull requests are welcome.

## Ground rules

- British English in documents and app text.
- No tenant identifiers, environment addresses, real names or secrets anywhere, including samples and issues.
- Nothing tenant-specific in solutions: use environment variables, connection references or seed data.
- Change Radar only reads. Anything that writes outside its own tables ships switched off and says what it writes, where and as whom.

## Proposing a change

Open an issue first for anything beyond a small fix. Significant decisions are recorded in [`docs/decisions/`](docs/decisions/).

**How pull requests are handled.** This repository is published from a private development repository, one commit for each release. An accepted pull request is applied there and arrives here with the next release, so your pull request is closed rather than merged, and you're credited in the release notes.

## Rules and vocabulary

Write the expected cases before the rule, then run `pwsh -File engine/Invoke-MatchingTests.ps1`. See [Extend](docs/extend.md) and the [developer guide](docs/developer-guide.md).

## Licence

Apache License 2.0. Contributions are accepted under the same licence (its section 5); no separate contributor agreement is needed.
