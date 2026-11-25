# Matching test results

Run with `pwsh -File engine/Invoke-MatchingTests.ps1`. 25 passed, 0 failed, 25 cases.

| File | Case | Kind | Expected match | Actual match | Result | Detail |
|---|---|---|---|---|---|---|
| engine-guards | guard-01 | near_miss | False | False | PASS |  |
| engine-guards | guard-02 | positive | True | True | PASS |  |
| engine-guards | guard-03 | positive | True | True | PASS |  |
| mc1548034-third-party-connections | thirdparty-01 | positive | True | True | PASS | facets [capability,harness,product] via R-CAPABILITY+R-HARNESS+R-PRODUCT |
| mc1548034-third-party-connections | thirdparty-02 | near_miss | False | False | PASS |  |
| mc1548034-third-party-connections | thirdparty-03 | near_miss | False | False | PASS |  |
| mc1550533-scheduled-prompts | schedprompt-01 | positive | True | True | PASS | facets [capability] via R-CAPABILITY |
| mc1550533-scheduled-prompts | schedprompt-02 | near_miss | False | False | PASS |  |
| mc1550533-scheduled-prompts | schedprompt-03 | near_miss | False | False | PASS |  |
| mc1551122-sharepoint-tempauth | tempauth-01 | positive | True | True | PASS | facets [capability,connector,product] via R-CAPABILITY+R-CONNECTOR+R-PRODUCT |
| mc1551122-sharepoint-tempauth | tempauth-02 | positive | True | True | PASS | facets [capability] via R-CAPABILITY |
| mc1551122-sharepoint-tempauth | tempauth-03 | near_miss | False | False | PASS |  |
| mc1551122-sharepoint-tempauth | tempauth-04 | near_miss | False | False | PASS |  |
| mc1551122-sharepoint-tempauth | tempauth-05 | near_miss | False | False | PASS |  |
| mc1557509-service-principal-auth | spauth-01 | positive | True | True | PASS | facets [auth_mode,product] via R-AUTHMODE+R-PRODUCT |
| mc1557509-service-principal-auth | spauth-02 | near_miss | False | False | PASS |  |
| mc1557509-service-principal-auth | spauth-03 | near_miss | False | False | PASS |  |
| mc1557509-service-principal-auth | spauth-04 | near_miss | False | False | PASS |  |
| mc1557509-service-principal-auth | spauth-05 | near_miss | False | False | PASS |  |
| mc1557754-copilot-credits-absent | credits-01 | positive | True | True | PASS | facets [setting] via R-SETTING |
| mc1557754-copilot-credits-absent | credits-02 | near_miss | False | False | PASS |  |
| mc1558033-copilot-credits-present | credits-03 | near_miss | False | False | PASS |  |
| rm570671-mcp-policies | mcp-01 | positive | True | True | PASS | facets [capability] via R-CAPABILITY |
| rm570671-mcp-policies | mcp-02 | near_miss | False | False | PASS |  |
| rm570671-mcp-policies | mcp-03 | near_miss | False | False | PASS |  |
