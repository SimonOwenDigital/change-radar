# Synthetic estate: Harbourline Group (synthetic)

> **Synthetic data.** Generated from a profile; it doesn't describe any real organisation. Never mix with live assets.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=samples-synthetic-mid-size-enterprise-readme) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=samples-synthetic-mid-size-enterprise-readme)

Profile `mid-size-enterprise`, seed 4242, as of 2026-11-18. Regenerate with:

```powershell
pwsh -File setup/generate-synthetic-estate.ps1 -ProfilePath setup/profiles/mid-size-enterprise.json -OutDir samples/synthetic/mid-size-enterprise
```

## Shape

| Measure | Value |
|---|---|
| Environments | 19 |
| Principals (makers + service principals) | 143 |
| Inventory resources | 912 |
| Resources in the default environment | 474 (52%) |
| Share of user-owned resources held by the top 10 of 140 makers | 65% |
| Resources owned by departed makers (account disabled) | 90 |
| Flows that look abandoned (not started, never run, or no run in 180 days) | 268 of 577 |
| Copilot Studio agents: generative / classic / Agent Builder (Copilot Studio Lite) | 23 / 16 / 26 |
| Agents with Agent Inventory (Kit) coverage | 33 |
| Agents using MCP (Kit) | 5 |
| Apps with code components (PCF) | 10 |
| Custom connectors (SharePoint-hosted) | 12 (4) |
| Solutions / resources in at least one solution | 16 / 305 |

## Resources by type

| Type | Count |
|---|---|
| `microsoft.copilotstudio/agents` | 65 |
| `microsoft.powerapps/canvasapps` | 230 |
| `microsoft.powerapps/codeapps` | 4 |
| `microsoft.powerapps/modeldrivenapps` | 24 |
| `microsoft.powerautomate/agentflows` | 28 |
| `microsoft.powerautomate/cloudflows` | 535 |
| `microsoft.powerautomate/m365agentflows` | 14 |
| `microsoft.powerplatformconnector/connectors` | 12 |
