# Local matching engine

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=engine-readme) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=engine-readme)

A PowerShell 7 reference implementation of spec §5: deterministic matching of signal fingerprints against asset fingerprints, with evidence. Runs locally on files only, with no tenant access and no network. It's the executable specification for the matching that phase 3 will build in flows and Dataverse. It isn't shipped in the solution.

| File | Purpose |
|---|---|
| `ChangeRadar.Matching.psm1` | Loads seed data, fingerprints assets, validates signal fingerprints, finds exposures |
| `Invoke-MatchingTests.ps1` | Runs `tests/cases/*.json`, reports pass/fail per case, exit code 1 on any failure |
| `Invoke-Matching.ps1` | Matches signals against an estate file; writes `exposures.json` and a Markdown summary |
| `ChangeRadar.Watch.psm1`, `Invoke-WatchTests.ps1` | The watch list (ADR 0015): which signals a topic matches, the watch events a signal version raises, and the words a watch.updated card uses. Cases: `tests/watch/watch.json` |
| `ChangeRadar.Solutions.psm1`, `Invoke-SolutionTests.ps1` | See the estate by solution (ADR 0020): an asset's object id, which solutions count, membership, grouping and the per-solution summary. Cases: `tests/solutions/solutions.json` |
| `ChangeRadar.Config.psm1`, `Invoke-ConfigTests.ps1` | Configuration switches shared by flows and the Radar page: `demo_data` (ADR 0022); `Get-AssessmentStep`, the `assessment_max_per_run` prompt/defer/rescore rule; `Get-EffectiveCap`, the first-weeks catch-up. Cases: `tests/config/config.json` |
| `ChangeRadar.Credits.psm1`, `Invoke-CreditTests.ps1` | `Get-CreditForecast`: the credit estimate in `docs/requirements.md` 3.1, used by `setup/Get-CreditEstimate.ps1`. Cases: `tests/credits/credits.json` (the doc's worked examples) |

## Data it reads (all in `seed/`)

- `vocabulary.csv`: the allowed facet values. Signal facets outside it are **rejected**.
- `rules.csv`: facet joins (`signal_facet` → `asset_facet`, `condition`, `role`). Same shape as the proposed `rule` table.
- `config.csv`: `fingerprint_confidence_threshold` (below it, facets go to the **review** queue).
- `asset-signatures.json`: how estate fields become asset facets (type → product, SKU → environment type, the T5 scheduled-prompt placeholder, and so on).

## Matching semantics

1. Signal fingerprint rows are validated: out-of-vocabulary → rejected; low confidence → review; the rest are accepted.
2. Accepted rows are grouped by `group`. Groups are alternatives (OR).
3. Within a group, every facet must be satisfied by the asset (AND); any value within a facet will do (OR).
4. Rules with `role = scope` (product, resource type, environment type, harness) narrow matches but never create one alone. A group needs at least one `trigger` facet (connector, capability, auth mode) to expose assets.
5. `role = setting` rules check `tenantSettings`: missing, disabled or not covering the signal's products → a setting exposure; otherwise an all-clear finding.
6. Every exposure lists the rules and, for each, the estate field and value that satisfied it.
7. The engine refuses an estate with more than one `meta.source`, or a non-live estate without `meta.syntheticOrg`.

## Run

```powershell
pwsh -File engine/Invoke-MatchingTests.ps1 -ReportPath tests/results.md
pwsh -File engine/Invoke-Matching.ps1 -EstatePath samples/synthetic/mid-size-enterprise/estate.json `
     -SignalPaths "tests/cases/[mr]*.json" -OutDir samples/synthetic/mid-size-enterprise/exposures
```

`-SeedDir` on the test runner points at an alternative seed folder, which is how rule changes can be tried (and how the suite was mutation-checked overnight).
