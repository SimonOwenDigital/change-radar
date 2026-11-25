# Estate file format (v0.2)

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=estate-file-format) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=estate-file-format)

The file-based estate adapter (spec §15.1 layer A) reads one JSON file per estate. It mirrors what the live collectors will return, so nothing downstream knows whether data came from a tenant, a fixture or the synthetic generator. Field names under `environments` and `inventory` were checked against live inventory on 2026-11-19 (`docs/decisions/verified-facts.md`). In v0.2, `environmentSku` became `environmentType`, and a flow's `trigger` became an object. The engine still reads the v0.1 names. `connectorDefinitions`, `agentKit`, `flowActivity` and `tenantSettings` are still proposals.

```jsonc
{
  "schemaVersion": "0.2",
  "meta": {
    "source": "synthetic",            // live | fixture | synthetic. One value per file; the engine refuses mixed input
    "syntheticOrg": "Harbourline Group (synthetic)",
    "profile": "mid-size-enterprise", "seed": 4242,
    "asOf": "2026-11-18T00:00:00Z"   // reference date; generator never uses the clock
  },
  "environments": [                    // inventory type microsoft.powerplatform/environments
    { "name": "<id>", "type": "microsoft.powerplatform/environments",
      "properties": { "displayName": "...", "environmentType": "Production|Sandbox|Developer|Default|Trial",
                      "isDefault": false, "isManaged": true } }
  ],
  "principals": [                      // Entra objects referenced by ownerId/createdBy (from Graph, later)
    { "id": "<id>", "kind": "user|servicePrincipal", "displayName": "Maker 017",
      "department": "Finance", "accountEnabled": true }
  ],
  "inventory": [                       // PowerPlatformResources rows, same field paths as the real table
    { "name": "<id>", "type": "microsoft.powerapps/canvasapps", "location": "europe",
      "properties": { "displayName": "...", "environmentId": "<env id>", "createdAt": "...", "createdBy": "<id>",
                      "ownerId": "<id>", "lastModifiedAt": "...",
                      "powerPlatformConnectors": [ { "connectorId": "shared_sharepointonline",
                                                     "operations": [ { "operationId": "GetItems" } ] } ],
                      "trigger": { "connectorId": "...", "operationId": "..." }, // flows only; empty connectorId for Recurrence/manual
                      "harness": "Standard", "orchestration": "Generative",  // agents only
                      "channels": ["Teams"], "createdIn": "Copilot Studio", "lastPublishedAt": "...",
                      "componentsCounts": { "knowledge": 1, "knowledgeByType": { "sharepointSites": 1 }, "tools": 0 }, // agents; verified 2026-11-19
                      "isCustom": true } }                                    // connectors only (assumed field)
  ],
  "codeComponents":       [ { "resourceId": "<app id>", "controlName": "...", "evidence": "..." } ], // maker-built controls per app: queries/dataverse-detail.ps1 (verified 2026-11-20)
  "connectorDefinitions": [ { "resourceId": "<connector id>", "hosts": ["..."] } ],          // Dataverse connector.openapidefinition
  "agentKit":             [ { "resourceId": "<agent id>", "usesMcp": true,
                              "hasAutonomousTriggers": false, "hasHttpActions": false } ],  // Copilot Studio Kit Agent Inventory
  "flowActivity":         [ { "resourceId": "<flow id>", "state": "Started|Stopped|Suspended",
                              "lastRunAt": "..." } ],                                         // Dataverse workflow + run history
  "solutionMembership":   [ { "resourceId": "<id>", "uniqueName": "hlg_InvoiceApprovals", "displayName": "Invoice approvals",
                              "publisher": "harbourline", "managed": false, "microsoft": false } ],      // ADR 0020; one row per resource and solution
  "tenantSettings":       [ { "key": "copilot_spending_policy", "enabled": true,
                              "scope": ["M365 Copilot"], "evidence": "manual entry" } ]
}
```

Rules:

- Every id in `connectorDefinitions`, `agentKit` and `flowActivity` must exist in `inventory`.
- `tenantSettings` with no row for a key means "not configured" (absent), not "unknown".
- Agents with no `agentKit` row have unknown MCP/HTTP/trigger capabilities; the engine treats unknown as "doesn't have it" and says so in the run summary.
