# Security policy

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=security) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=security)

## Supported versions

The latest release only, until version 1.0. Each release's notes are in [`docs/releases.md`](docs/releases.md).

## Reporting a vulnerability

Please report security issues **privately**, using GitHub's private vulnerability reporting on this repository (**Security**, **Report a vulnerability**). Don't open a public issue, and never include tenant data (tenant ids, environment URLs, names or email addresses) in any report: describe the problem with redacted examples.

You'll get an acknowledgement within five working days. This is a community project with no service level, so a fix ships in the next release and is noted in its release notes.

## Scope

In scope: Change Radar's solutions (`ChangeRadarCore`, `ChangeRadarHandlers`, `ChangeRadarAsk`), the setup scripts and the seed data. Microsoft's services and APIs are out of scope: report those to Microsoft.

## Design commitments

- Read-only against the tenant: Change Radar writes only to its own tables, and handlers that send anything ship switched off.
- Least privilege for every identity, proved by `setup/Test-ReaderIdentity.ps1`.
- No secrets in code or settings: the reader authenticates with a certificate held in Azure Key Vault.
- No tenant identifiers in the repository, checked before every release.
- No telemetry and no external services.

The governance pack in [`docs/governance/`](docs/governance/) describes every identity, permission and data flow.
