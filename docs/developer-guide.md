---
title: Change Radar
subtitle: Developer Guide
document: CR-DEV-01
version: "0.3"
date: 24 November 2026
status: For review
audience: People who build, test, change or release Change Radar from source
owner: Simon Owen
release: Change Radar 0.3.0
intro: keep
breaks: none
---

# Developer guide

> **For:** people who build, test, change or release Change Radar from source. **Kind:** explanation and how-to.
> **Status:** describes the repository at release 0.3.0. Adopters who only install Change Radar don't need this guide.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=developer-guide) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=developer-guide)

**In your organisation.** Change Radar was built test first: the expected cases came before the rules, and a reference engine was proved against them before any flow ran. For why that order matters with AI in the loop, see [Test before you Trust](https://www.empoweryour.world/modellibrary/13-test-before-you-trust?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=developer-guide) on Empower Your World.

## 1. The rules

1. **Cases before rules.** The expected cases, including near misses, are written before the rule, vocabulary value or flow that should satisfy them.
2. **The engine is the specification.** Matching, ratings, horizons, events, watches and credits are defined in PowerShell modules under `engine/` with test cases; the flows implement them, and parity checks prove the two agree.
3. **Generate, don't hand-edit.** Flow definitions come from a script. If someone saves in the designer, export and compare before changing anything.
4. **Read-only against the tenant.** Nothing is created beyond read permissions, and nothing outside the development environment, without agreement.
5. **No tenant identifiers or secrets in the repository:** no tenant ids, environment URLs, real names, user emails or client data, including in `samples/`.
6. **Nothing tenant-specific in solutions:** every value goes through environment variables, connection references or seed data.
7. **Decisions are ADRs** in `docs/decisions/` (context, decision, consequences). Platform facts are checked on Microsoft Learn and recorded with the date in `docs/decisions/verified-facts.md`.
8. **British English** in documents and user interface text.

## 2. Repository layout

| Folder | Holds |
|---|---|
| `docs/` | Documentation, `decisions/` (ADRs), `diagrams/`. Word and PDF are generated in `word/`, which is not tracked |
| `solutions/` | Unpacked solutions: `ChangeRadarCore`, `ChangeRadarHandlers`, `ChangeRadarAsk`, and `design/` (schema, flows, pages, roles, prompts the solutions are built from) |
| `engine/` | The reference engine and its test runners |
| `tests/` | Cases for every suite, and fixtures |
| `seed/` | Vocabulary, rules, config, subscriptions, feeds, watches and manual fingerprints, as CSV |
| `queries/` | Graph, inventory and Dataverse queries, one file each |
| `samples/` | Redacted sample responses; the synthetic demo estate |
| `setup/` | Install and operation scripts (used by adopters); `setup/dev/` is for the maintainer only |
| `spikes/` | Throwaway tests |
| `tools/` | The document and diagram builders |

## 3. Tools

| Tool | Needed for |
|---|---|
| PowerShell 7 | Every script and test runner |
| Power Platform CLI (`pac`) | Exporting, packing, checking and importing solutions |
| Az.Accounts module | Scripts that call Dataverse or Azure |
| Node.js | Only the generative pages' parity checks and the Word document builder (`tools/docbuild`, `npm install` first) |
| uv (Python 3.13) and Microsoft Edge | Only the diagrams (`tools/diagrams/render.ps1`) |
| Microsoft Word | Only finishing Word documents (`tools/docbuild/finish-docx.ps1`) |

Installers never need Node, Python or Word.

## 4. The engine and its tests

Each module in `engine/` has cases in `tests/` and a runner. All run locally, on files, with no tenant access:

| Runner | Proves | Cases |
|---|---|---|
| `Invoke-MatchingTests.ps1` | Vocabulary, rules, groups, near misses | `tests/cases/*.json`, `tests/base-estate.json` |
| `Invoke-AssessmentTests.ps1` | Ratings and overrides | `tests/assessment/` |
| `Invoke-EventTests.ps1` | Which events are raised | `tests/events/` |
| `Invoke-HandlerTests.ps1` | Handler plans and naming | `tests/handlers/` |
| `Invoke-ConfigTests.ps1` | Caps, catch-up, demo data | `tests/config/` |
| `Invoke-CreditTests.ps1` | The credit forecast | `tests/credits/` |
| `Invoke-FeedTests.ps1`, `Invoke-ModelTests.ps1` | Source profiles and model lifecycles | `tests/feeds/`, `tests/models/` |
| `Invoke-WatchTests.ps1` | Watch topics | `tests/watch/` |
| `Invoke-SolutionTests.ps1` | Grouping by solution | `tests/solutions/` |
| `Invoke-RadarTests.ps1`, `Invoke-TextTests.ps1`, `Invoke-ThemeTests.ps1` | Radar page figures, readable text, themes | `tests/radar/`, `tests/text/`, `tests/themes/` |

Run one with `pwsh -File engine/Invoke-MatchingTests.ps1`. Every runner reports pass or fail per case and exits with 1 on any failure. The release script refuses to build unless every suite passes.

**Parity checks** (`setup/dev/Test-*Parity.ps1`) compare what the flows wrote in the development environment with what the engine says: exposures, assessments, events, destinations, feeds, estate, solutions and the Radar. **Page parity** (`solutions/design/pages/<page>/Test-*Parity.mjs`, Node) runs a page's own functions against the same cases.

## 5. Flows: generate, don't hand-edit

`solutions/design/flows/New-CollectorFlows.ps1` generates every flow's definition (JSON in the same folder); each change is made in the script. `setup/dev/Deploy-CollectorsToDev.ps1` deploys them to the development environment, into the solution each belongs to. `setup/dev/Export-CoreSolution.ps1` exports the solutions back to `solutions/`, with checks: every flow matches the generator, Core holds no Teams or Outlook reference, handler flows are off.

The schema (`schema.json`, with `schema.md` generated from it), roles (`roles.json`) and prompts (`prompts.json`) are data in `solutions/design/`, deployed by `Deploy-SchemaToDev.ps1` and `Deploy-RolesToDev.ps1`. Prompts can't be created through an API: they are made once in the AI hub from the text in `prompts.json` and then exported.

## 6. The pages

The Radar page and the Fingerprint review page are Power Apps generative pages in `solutions/design/pages/` (one `.tsx` each). Logic shared with the engine sits between `// ENGINE:BEGIN` and `// ENGINE:END`, so the parity check can run it. Pages write only Change Radar's own tables: the review page writes a fingerprint's status; the Radar page writes the `demo_data` setting (admins only).

## 7. The maintainer's development scripts

`setup/dev/` is specific to the maintainer's development environment and isn't needed to install Change Radar. The main ones:

| Script | Does |
|---|---|
| `Deploy-SchemaToDev.ps1`, `Deploy-CollectorsToDev.ps1`, `Deploy-AppToDev.ps1`, `Deploy-RolesToDev.ps1` | Deploy the schema, flows, app and roles |
| `Export-CoreSolution.ps1` | Export the solutions and check them |
| `New-TestSignals.ps1`, `Remove-TestSignals.ps1` | Create and remove labelled test signals (choose rows by exact name, never with a `startswith` on `[TEST]`: Dataverse treats `[TEST]` as a wildcard) |
| `Test-UserRole.ps1` | Prove the User role with a real non-admin account |
| `Invoke-FlowRun.ps1`, `Measure-FlowActions.ps1` | Run a flow and measure its actions |
| `New-Release.ps1` | Build a release |

## 8. Releases

`setup/dev/New-Release.ps1 -Version <x.y.z>` plans by default and builds with `-Apply`. It refuses unless the working tree is clean, every engine suite passes, and the version is higher than every solution's. It sets the version, packs each solution as managed, runs the solution checker, writes `SHA256SUMS`, copies `LICENSE` and `NOTICE`, and prints the publish command. Record the release in `docs/releases.md`, commit, and publish with `gh release create`. Releases build three solutions: Core, Handlers and Ask, installed in that order. After writing "What's new", `setup/dev/New-DocsPack.ps1 -Version <x.y.z> -Apply` rebuilds every document, checks each file for identifiers, and adds `Change-Radar-Docs-<x.y.z>.zip` to the release. It refuses while the notes hold a placeholder.

## 9. Documents and diagrams

Documents are Markdown with front matter; the Word and PDF versions are generated, never edited by hand:

```powershell
pwsh -File tools/docbuild/build-all.ps1                 # diagrams, then every document
pwsh -File tools/docbuild/build-all.ps1 -Only install   # one document
```

Diagrams are drawn from code in `tools/diagrams/figures.py` and rendered to SVG and PNG. A new document is added to `build-all.ps1`'s list once it is written. Architecture facts come from the repository's generated artefacts, not from memory.

## 10. Contributing

Open an issue before a large change. A pull request includes its cases, the change, and an ADR if it makes a design decision. Contributions are accepted under the Apache License 2.0 (`CONTRIBUTING.md`).
