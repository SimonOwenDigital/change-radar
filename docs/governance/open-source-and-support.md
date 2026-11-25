---
title: Change Radar
subtitle: Open Source and Support
document: CR-GOV-06
version: "0.3"
date: 24 November 2026
status: For review
audience: Procurement, third-party risk, architecture review, and the service owner
owner: Simon Owen
release: Change Radar 0.3.0
intro: keep
breaks: none
---

# Open source and support

> **For:** procurement, third-party risk, architecture review, and the service owner. **Kind:** reference.
> **Status:** describes release 0.3.0 and the project as of 24 November 2026.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=open-source-and-support) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=open-source-and-support)

## 1. What you are adopting

| Item | Answer |
|---|---|
| Licence | **Apache License 2.0.** Free to use, change and share, including commercially, provided the licence and NOTICE file are kept with any copy. The licence grants no right to use the Change Radar name for a derived product |
| Warranty | None. The software is provided as is (Apache 2.0, sections 7 and 8) |
| Cost of the software | None. You pay only for the Microsoft licences and capacity it uses (Prerequisites) |
| Where it runs | Entirely in your own Microsoft tenant: your Dataverse environment, your flows, your AI Builder capacity. Nothing runs on the author's or anyone else's systems |
| Status | An independent community project. Not made, endorsed or supported by Microsoft |
| Source | The public GitHub repository: code, solution source, tests, design decisions (ADRs) and documentation |

## 2. Support model

| Kind | Provided | How |
|---|---|---|
| Community support | Best effort, no service level | GitHub issues and discussions in the repository |
| Security issues | Private reporting | GitHub private vulnerability reporting (see `SECURITY.md`) |
| Supported versions | The latest release only, until version 1.0 | Release notes |
| Your own support | Your platform team, as for any internally run solution | The Operations Runbook and Troubleshooting guide |

Plan to run Change Radar as an internal service with a named owner. Its flows, tables and settings are ordinary Power Platform components that your platform team already knows how to support.

## 3. Release integrity

Each release:

- is built from a named commit in the repository;
- passes Microsoft's solution checker, with any findings reviewed and recorded in the release notes;
- comes from solution source that is scanned for tenant identifiers when it is exported;
- ships managed solutions with SHA-256 checksums, the licence and the NOTICE file.

Check a download against its checksum before importing it (Installation Guide, step 3). Or build it from source: the repository holds everything needed.

## 4. Dependencies

| Dependency | Kind | If it changes |
|---|---|---|
| Microsoft Graph service communications API | Microsoft API, generally available | A collector records the failure; a release follows |
| Power Platform inventory (Power Platform for Admins V2) | Microsoft API, generally available | As above |
| Microsoft Learn pages, the roadmap and blogs | Public web pages | Sources are data: a changed page is fixed by editing its feed profile |
| AI Builder prompts and text recognition | Microsoft service | Microsoft migrates models on its own schedule (AI Use Statement) |
| Copilot Studio (Ask Change Radar, optional) | Microsoft service | Optional: remove the Ask solution |
| Installer tools: PowerShell 7, Az.Accounts, Power Platform CLI | Microsoft tools | Tested versions are listed in Prerequisites |

Change Radar has no third-party runtime code: no external services, no custom connectors, no plug-ins. Its generative pages are built on Microsoft's own framework.

## 5. Taking ownership

If you need to change Change Radar, or the project stops:

- **Fork it.** Apache 2.0 lets you maintain your own copy. Keep the licence and NOTICE file.
- **Build it.** The solution source is unpacked in the repository and packs with the Power Platform CLI; the release script builds managed solutions.
- **Understand it.** The Architecture Definition, the design decisions (ADRs) and the test suites explain why it works the way it does.

## 6. Exit plan

Change Radar is designed to leave cleanly.

1. **Keep what you need.** Export the tables you want to keep (signals, exposures, assessments, the alert log) to Excel or CSV from the app's views, or with Dataverse export.
2. **Switch it off.** Turn off the handlers (`Set-Handlers.ps1 -Off`), then the flows.
3. **Remove it.** Delete the `ChangeRadarAsk`, `ChangeRadarHandlers` and `ChangeRadarCore` solutions in that order. Deleting Core removes its tables and data.
4. **Revoke access.** Remove the reader's application user from each detail environment, delete the reader app registration (which removes its Graph consent), and delete its Key Vault or certificate.
5. **Delete the connections** made for it, and the environment if it was dedicated to Change Radar.

Nothing in the estate needs undoing: Change Radar never wrote to it.
