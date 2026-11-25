# Change Radar for Power Platform & Copilot

> **Status: release 0.3.0, the first public release, proven by two clean installs.**
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=readme) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=readme)

Microsoft changes Power Platform, Copilot Studio and Microsoft 365 Copilot every week. Change Radar collects those changes and tells you **what each one means for your own estate**:

- **Now:** service incidents and outages, within 15 minutes
- **Imminent:** Message Center changes, retirements and deadlines
- **Future:** the roadmap, release notes and licensing changes
- **So what:** which of your apps, flows, agents and prompts each change touches, with the evidence, an impact rating and a recommended action

It reads; it never changes your tenant. Alerts are optional handlers that ship switched off.

## How it works

1. **Collect** Microsoft's changes (Graph service health and Message Center, the roadmap, Learn, blogs, licensing guides) and your estate (the Power Platform inventory, and solution and prompt detail where you allow it).
2. **Fingerprint** each change in a shared vocabulary: products, connectors, capabilities, models.
3. **Match** changes to your assets with deterministic rules, recording the evidence.
4. **Rate** the impact for your estate, with a rationale you can override.
5. **Show and alert:** a Radar page in a model-driven app, Teams cards, a weekly digest, and an optional agent you can ask questions.

Everything runs in your own tenant: a Dataverse environment, Power Automate flows and AI Builder prompts. Nothing is sent outside Microsoft's cloud, and there is no telemetry.

## Getting it

A release has two parts:

| Part | What | Why |
|---|---|---|
| **Managed solutions** | `ChangeRadarCore` (tables, flows, app, roles), `ChangeRadarHandlers` (alerts, all off) and `ChangeRadarAsk` (optional agent), with SHA-256 checksums | Everything a solution can carry, imported the standard way |
| **Setup scripts** (`setup/`) | The reader identity (Entra app, Key Vault certificate, admin consent), starting data, switching alerts on, a read-only health check and a credit forecast | What a solution can't carry: identities outside Dataverse, and data |

Start with the [Prerequisites](docs/prerequisites.md), then the [Installation Guide](docs/install.md). Plan for about half a day.

## Documentation

Every document is Markdown here. Each release also has them as Word and PDF, in `Change-Radar-Docs-<version>.zip`.

| Stage | Documents |
|---|---|
| **Understand and decide** | [Solution brief](docs/overview.md) · [Business case kit](docs/business-case.md) · [Licensing and costs](docs/costs-and-licensing.md) · [Architecture Definition](docs/architecture.md) |
| **Govern** | [Approval checklist](docs/governance/approval-checklist.md) · [Security and data handling](docs/governance/permissions-and-data.md) · [Data protection screening](docs/governance/data-protection.md) · [AI use statement](docs/governance/ai-use.md) · [Risk register](docs/governance/risk-register.md) · [Open source and support](docs/governance/open-source-and-support.md) · [Accessibility](docs/governance/accessibility.md) |
| **Install** | [Prerequisites](docs/prerequisites.md) · [Requirements](docs/requirements.md) · [Installation Guide](docs/install.md) · [Configuration Reference](docs/configure.md) · [ALM and deployment](docs/alm.md) · [Acceptance pack](docs/acceptance.md) · [Technical reference](docs/reference/technical-reference.md) |
| **Use and learn** | [User guide](docs/guide/user-guide.md) · [Quick reference cards](docs/guide/cards.md) · [Learning path](docs/learn/learning-path.md) · [Operating model](docs/operating-model.md) |
| **Run** | [Operations runbook](docs/operate/runbook.md) · [Tuning guide](docs/operate/tuning.md) · [Troubleshooting](docs/troubleshooting.md) · [Service description template](docs/operate/service-description.md) |
| **Extend and contribute** | [Extend](docs/extend.md) · [Add a signal source](docs/add-a-signal-source.md) · [Developer guide](docs/developer-guide.md) · [Release notes](docs/releases.md) · [Roadmap](docs/roadmap.md) · [Design decisions](docs/decisions/) |

## About the author

Change Radar is built by Simon Owen, who writes about governing AI and the Power Platform at [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=readme). Stories of how you use it, and issues and ideas, are welcome in this repository.

## Licence

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE): keep both with any copy or derivative. The licence doesn't cover the Change Radar name (ADR 0024).

Change Radar is an independent community project. It is not made, endorsed or supported by Microsoft, and it isn't affiliated with its author's employer.
