# 0006: Languages for local tooling

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0006-local-tooling-languages) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0006-local-tooling-languages)

Date: 2026-11-19. Status: **Accepted**, 2026-11-19 (Simon).

## Context

The overnight run had only PowerShell 7 installed. So the matching engine, test runner, synthetic estate generator, schema validator and roadmap collector were all written in PowerShell (QUESTIONS Q1). Python 3.15 (with uv) and Node 26 LTS (with fnm) have since been installed per-user on the dev machine.

The assets that matter are language-neutral: rules, vocabulary, asset signatures and config (CSV and JSON), test cases (JSON), and the estate file format (JSON, `docs/estate-file-format.md`). The local engine is a reference implementation checked against those test cases. The product's own matching runs in Power Platform.

Problems with PowerShell seen overnight:

- JSON quirks: single-item arrays collapsing to scalars, automatic date conversion, and StrictMode `.Count` on scalars.
- Old test tooling: Pester 3.4 is installed.
- Speed on large estates.

Installers are Power Platform admins who have PowerShell and `pac`, and may not have Python or Node.

## Options

| Option | For | Against |
|---|---|---|
| A. PowerShell everywhere | Works today (25/25 tests); one language; matches installers and `pac`; `pwsh` is on every CI runner | JSON quirks; weaker testing; slow at scale; thin ecosystem for evaluating LLM extraction |
| B. Rewrite local tooling in Python | pytest, jsonschema, Hypothesis; fast data handling; natural fit for phase 3 evaluation | Rewrite for identical outputs; two languages for contributors; installers less likely to have Python |
| C. Split by job | Each language where it is strongest; no rewrite now | Contributors may need more than one runtime depending on the area |

## Decision

**Option C: split by job, and don't rewrite.**

| Area | Language |
|---|---|
| `setup/`, `queries/` collectors, anything an installer runs | **PowerShell 7, always** |
| `engine/`, synthetic estate generator, schema validator | **PowerShell for now.** Port to Python only if JSON handling or speed becomes a real problem, and record that in a new ADR |
| Phase 3 evaluation of fingerprint extraction (precision and recall against a labelled set), data analysis, spikes | **Python**, managed with uv (`pyproject.toml` and `uv.lock` in the folder that needs them) |
| Generative pages, PCF components, any MCP server | **Node / TypeScript**, when that phase starts; pin the version with `.nvmrc` |
| Rules, vocabulary, test cases, estate format | **CSV and JSON.** Every implementation is checked against the same test cases |

Near-term improvement: move `engine/Invoke-MatchingTests.ps1` to Pester 5, installed per-user (`Install-Module Pester -Scope CurrentUser`). Keep the test cases as JSON data.

## Consequences

- Installers never need Python or Node. `docs/prerequisites.md` lists PowerShell 7 and `pac` only. Contributor docs list the extra runtimes for each area.
- CI needs `pwsh` now, adds Python and uv from phase 3, and Node when a front-end phase starts.
- Supersedes the assumption in QUESTIONS Q1.
