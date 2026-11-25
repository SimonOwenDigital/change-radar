# Exposures

> **Demo data:** synthetic estate for Harbourline Group (synthetic). Not a real organisation.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=samples-synthetic-mid-size-enterprise-exposures-readme) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=samples-synthetic-mid-size-enterprise-exposures-readme)

Estate: `samples/synthetic/mid-size-enterprise/estate.json` (912 assets, as of 2026-11-18T00:00:00Z).

| Signal | Title | Exposures | Settings | Rejected facets | In review | Notes |
|---|---|---|---|---|---|---|
| MC1548034 | Third-party connections in agent chat | 9 |  | 0 | 0 |  |
| MC1550533 | Copilot scheduled prompts move off Power Platform | 15 |  | 0 | 0 |  |
| MC1551122 | SharePoint temporary-auth URLs: end of support | 5 |  | 0 | 0 |  |
| MC1557509 | Copilot Studio workflows: service principal authentication | 9 |  | 0 | 0 |  |
| MC1557754 | Copilot Credits: spending policies | 1 | setting:copilot_spending_policy=absent | 0 | 0 | Group A: scope facets only (product); no asset exposures by design. |
| MC1558033 | Copilot Credits: billing changes | 1 | setting:copilot_spending_policy=absent | 0 | 0 | Group A: scope facets only (product); no asset exposures by design. |
| ML-CSM-claude-sonnet-4-6 | Claude Sonnet 4.6 retires from Copilot Studio (Microsoft Copilot harness) on 15 February 2027 | 2 |  | 0 | 0 |  |
| RM570671 | Work IQ: granular MCP policies | 5 |  | 0 | 0 | Group A: 32 agent(s) have no Agent Inventory (Kit) row, so 'uses_mcp' is unknown for them and they weren't matched. |

## MC1548034: Third-party connections in agent chat

By environment type: default 1, developer 3, production 5.

| Asset | Type | Env type | Matched facets | Evidence |
|---|---|---|---|---|
| Procurement agent | copilotstudio/agents | default | capability, harness, product | R-CAPABILITY: inventory.properties.channels contains 'Custom website' [placeholder: channel display name not verified]<br>R-HARNESS: inventory.properties.harness = 'Standard'<br>R-PRODUCT: inventory.type = 'microsoft.copilotstudio/agents' |
| Sales assistant agent | copilotstudio/agents | developer | capability, harness, product | R-CAPABILITY: inventory.properties.channels contains 'Custom website' [placeholder: channel display name not verified]<br>R-HARNESS: inventory.properties.harness = 'Standard'<br>R-PRODUCT: inventory.type = 'microsoft.copilotstudio/agents' |
| Procurement agent | copilotstudio/agents | production | capability, harness, product | R-CAPABILITY: inventory.properties.channels contains 'Custom website' [placeholder: channel display name not verified]<br>R-HARNESS: inventory.properties.harness = 'Standard'<br>R-PRODUCT: inventory.type = 'microsoft.copilotstudio/agents' |
| Procurement agent | copilotstudio/agents | production | capability, harness, product | R-CAPABILITY: inventory.properties.channels contains 'Custom website' [placeholder: channel display name not verified]<br>R-HARNESS: inventory.properties.harness = 'Standard'<br>R-PRODUCT: inventory.type = 'microsoft.copilotstudio/agents' |
| IT help agent | copilotstudio/agents | developer | capability, harness, product | R-CAPABILITY: inventory.properties.channels contains 'Custom website' [placeholder: channel display name not verified]<br>R-HARNESS: inventory.properties.harness = 'Standard'<br>R-PRODUCT: inventory.type = 'microsoft.copilotstudio/agents' |

…and 4 more in `exposures.json`.

## MC1550533: Copilot scheduled prompts move off Power Platform

By environment type: default 15.

| Asset | Type | Env type | Matched facets | Evidence |
|---|---|---|---|---|
| Scheduled prompt: Monday priorities | powerautomate/cloudflows | default | capability | R-CAPABILITY: inventory.properties.trigger.operationId = 'Recurrence' and connector 'shared_m365copilotautomations' |
| Scheduled prompt: Monday priorities | powerautomate/cloudflows | default | capability | R-CAPABILITY: inventory.properties.trigger.operationId = 'Recurrence' and connector 'shared_m365copilotautomations' |
| Scheduled prompt: Meeting prep | powerautomate/cloudflows | default | capability | R-CAPABILITY: inventory.properties.trigger.operationId = 'Recurrence' and connector 'shared_m365copilotautomations' |
| Scheduled prompt: Monday priorities | powerautomate/cloudflows | default | capability | R-CAPABILITY: inventory.properties.trigger.operationId = 'Recurrence' and connector 'shared_m365copilotautomations' |
| Scheduled prompt: Team news | powerautomate/cloudflows | default | capability | R-CAPABILITY: inventory.properties.trigger.operationId = 'Recurrence' and connector 'shared_m365copilotautomations' |

…and 10 more in `exposures.json`.

## MC1551122: SharePoint temporary-auth URLs: end of support

By environment type: default 1, production 4.

| Asset | Type | Env type | Matched facets | Evidence |
|---|---|---|---|---|
| Budget request | powerapps/canvasapps | production | capability, connector, product | R-CAPABILITY: codeComponents: syn_FileViewer<br>R-CONNECTOR: inventory.properties.powerPlatformConnectors[].connectorId = 'shared_sharepointonline'<br>R-PRODUCT: inventory.type = 'microsoft.powerapps/canvasapps' |
| Document loader 2 (custom) | powerplatformconnector/connectors | default | capability | R-CAPABILITY: connectorDefinitions.hosts = 'harbourline.sharepoint.example' [placeholder: .example is for synthetic data only] |
| Document loader 8 (custom) | powerplatformconnector/connectors | production | capability | R-CAPABILITY: connectorDefinitions.hosts = 'harbourline.sharepoint.example' [placeholder: .example is for synthetic data only] |
| Document loader 9 (custom) | powerplatformconnector/connectors | production | capability | R-CAPABILITY: connectorDefinitions.hosts = 'harbourline.sharepoint.example' [placeholder: .example is for synthetic data only] |
| Document loader 10 (custom) | powerplatformconnector/connectors | production | capability | R-CAPABILITY: connectorDefinitions.hosts = 'harbourline.sharepoint.example' [placeholder: .example is for synthetic data only] |

## MC1557509: Copilot Studio workflows: service principal authentication

By environment type: production 9.

| Asset | Type | Env type | Matched facets | Evidence |
|---|---|---|---|---|
| Finance close agent flow | powerautomate/agentflows | production | auth_mode, product | R-AUTHMODE: inventory.properties.ownerId is user 'Maker 016' and environment type is 'production'<br>R-PRODUCT: inventory.type = 'microsoft.powerautomate/agentflows' |
| Knowledge finder agent flow | powerautomate/agentflows | production | auth_mode, product | R-AUTHMODE: inventory.properties.ownerId is user 'Maker 002' and environment type is 'production'<br>R-PRODUCT: inventory.type = 'microsoft.powerautomate/agentflows' |
| Travel agent flow | powerautomate/agentflows | production | auth_mode, product | R-AUTHMODE: inventory.properties.ownerId is user 'Maker 003' and environment type is 'production'<br>R-PRODUCT: inventory.type = 'microsoft.powerautomate/agentflows' |
| Fleet booking agent flow | powerautomate/agentflows | production | auth_mode, product | R-AUTHMODE: inventory.properties.ownerId is user 'Maker 001' and environment type is 'production'<br>R-PRODUCT: inventory.type = 'microsoft.powerautomate/agentflows' |
| Finance close agent flow | powerautomate/agentflows | production | auth_mode, product | R-AUTHMODE: inventory.properties.ownerId is user 'Maker 001' and environment type is 'production'<br>R-PRODUCT: inventory.type = 'microsoft.powerautomate/agentflows' |

…and 4 more in `exposures.json`.

## MC1557754: Copilot Credits: spending policies

By environment type: n/a 1.

| Asset | Type | Env type | Matched facets | Evidence |
|---|---|---|---|---|
| copilot_spending_policy | tenant setting |  | setting | R-SETTING: no enabled tenantSettings row for 'copilot_spending_policy' |

## MC1558033: Copilot Credits: billing changes

By environment type: n/a 1.

| Asset | Type | Env type | Matched facets | Evidence |
|---|---|---|---|---|
| copilot_spending_policy | tenant setting |  | setting | R-SETTING: no enabled tenantSettings row for 'copilot_spending_policy' |

## ML-CSM-claude-sonnet-4-6: Claude Sonnet 4.6 retires from Copilot Studio (Microsoft Copilot harness) on 15 February 2027

By environment type: default 1, production 1.

| Asset | Type | Env type | Matched facets | Evidence |
|---|---|---|---|---|
| Onboarding buddy agent | copilotstudio/agents | default | harness, model, resource_type | R-HARNESS: inventory.properties.harness = 'Copilot Chat'<br>R-MODEL: inventory.properties.model = 'Claude Sonnet 4.6'<br>R-RTYPE: inventory.type = 'microsoft.copilotstudio/agents' |
| Model retirement demo agent (synthetic) | copilotstudio/agents | production | harness, model, resource_type | R-HARNESS: inventory.properties.harness = 'Microsoft Copilot'<br>R-MODEL: inventory.properties.model = 'Claude Sonnet 4.6'<br>R-RTYPE: inventory.type = 'microsoft.copilotstudio/agents' |

## RM570671: Work IQ: granular MCP policies

By environment type: default 2, developer 2, production 1.

| Asset | Type | Env type | Matched facets | Evidence |
|---|---|---|---|---|
| Safety agent | copilotstudio/agents | developer | capability | R-CAPABILITY: agentKit.usesMcp = true |
| Procurement agent | copilotstudio/agents | default | capability | R-CAPABILITY: agentKit.usesMcp = true |
| Finance close agent | copilotstudio/agents | default | capability | R-CAPABILITY: agentKit.usesMcp = true |
| Sales assistant agent | copilotstudio/agents | developer | capability | R-CAPABILITY: agentKit.usesMcp = true |
| HR policy agent | copilotstudio/agents | production | capability | R-CAPABILITY: agentKit.usesMcp = true |
