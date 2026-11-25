# Public samples

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=samples-public-readme) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=samples-public-readme)

Normalised samples from public Microsoft sources. No tenant data.

| File | Source | Produced by |
|---|---|---|
| `roadmap-powerplatform.json` | Microsoft Copilot Roadmap JSON endpoint, filtered to Power Platform products | `pwsh -File queries/roadmap-public.ps1` |

Descriptions are truncated to 400 characters. Each record carries `fingerprint` rows (product facets, `extractedBy = rule`) in the same shape as the test cases, so the file can be passed straight to `engine/Invoke-Matching.ps1`. Schema findings: `spikes/T3-roadmap-schema.md`.
