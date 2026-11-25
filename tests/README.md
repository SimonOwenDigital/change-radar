# Matching test suite

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=tests-readme) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=tests-readme)

Signal × asset cases with expected outcomes (spec §15.1 layer C). Every rule has at least one positive case and one near miss. Written before the engine, so they define "correct".

## Layout

- `base-estate.json`: shared fixture environments and principals, merged into every case file's estate.
- `cases/<signal-or-rule>.json`: one file per worked example (spec §5), plus `engine-guards.json` for the vocabulary and confidence guards.

## Case file format

```jsonc
{
  "id": "mc1551122-sharepoint-tempauth",
  "signal": {
    "id": "MC1551122", "source": "graph_mc", "title": "...",
    "fingerprint": [   // same shape as mw_signalfingerprint rows, plus "group"
      { "group": "A", "facet": "capability", "value": "pcf_control", "confidence": 0.9, "extractedBy": "manual" }
    ]
  },
  "estate": { /* fragment in docs/estate-file-format.md shape; arrays are appended to base-estate.json */ },
  "cases": [
    { "id": "tempauth-01", "kind": "positive|near_miss", "assetId": "app-pcf-sp",
      "expect": { "match": true, "matchedFacets": ["capability", "connector", "product"] } },
    { "id": "credits-01", "kind": "positive", "target": "setting:copilot_spending_policy", "expect": { "match": true } }
  ]
}
```

- **Groups** are alternatives: a signal matches an asset if any group matches. Within a group, every facet must be satisfied (AND); within a facet, any listed value will do (OR). See `docs/overnight/QUESTIONS.md` Q4.
- `matchedFacets` lists every facet of the matching group the asset satisfied, scope facets included, sorted.
- `target` replaces `assetId` for non-asset outcomes: `setting:<key>`, `rejected:<facet>=<value>`, `review:<facet>=<value>`.
- The runner also fails a file if the engine exposes any asset that has no case, so near misses can't silently turn into matches.

## Running

```powershell
pwsh -File engine/Invoke-MatchingTests.ps1
```

## Coverage (worked examples in spec §5)

| Signal | Positive | Near misses |
|---|---|---|
| MC1551122 tempauth | 2 (PCF + SharePoint app; SharePoint custom connector) | 3 |
| MC1557509 service principal auth | 1 | 4 (dev env, SPN-owned, cloud flow, default env) |
| MC1548034 third-party connections | 1 | 2 |
| RM570671 MCP policies | 1 | 2 (no MCP, no Agent Inventory row) |
| MC1550533 scheduled prompts | 1 (T5 placeholder signature) | 2 |
| MC1557754 / MC1558033 Copilot Credits | 1 (policy absent) | 2 (policy present; Copilot agent exists) |
| TEST-KNOWLEDGE agent knowledge (inventory) | 2 (SharePoint; public websites) | 3 (zero knowledge; not reported; canvas app on SharePoint) |
| Engine guards | 2 (rejected value, review queue) | 1 |
