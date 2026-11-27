---
title: Change Radar
subtitle: Acceptance Pack
document: CR-ACC-01
version: "0.3"
date: 24 November 2026
status: For review
audience: The service owner, testers and the platform admin who accept an install or upgrade
owner: Simon Owen
release: Change Radar 0.3.1
intro: keep
breaks: none
---

# Acceptance pack

> **For:** the service owner, testers and the platform admin who accept an install or upgrade. **Kind:** checklist.
> **Status:** for release 0.3.0. The checks come from the install test and the scripts in the repository. Run it in a test environment first, then repeat the parts marked *live* in production.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=acceptance) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=acceptance)

Allow one night for the first collection, then about two hours. For an upgrade, run sections 2, 3 and 5.

## 1. Acceptance criteria

| Area | Accepted when | Pass or fail |
|---|---|---|
| Install | `Test-Install.ps1` reports no FAIL, and every WARN is understood and recorded | ☐ |
| Collection | Every collector that is switched on has a successful run in the last day | ☐ |
| Access | A user with the User role can do their job and nothing more; someone without a role sees nothing | ☐ |
| Radar page | It loads, shows your estate, and its numbers agree with the app's views | ☐ |
| Alerts | A card arrives at the right destination, and nothing arrives when a handler is off | ☐ |
| Demo data | Off by default; refused in production; never mixed with live data | ☐ |
| AI and cost | Credits used are close enough to the forecast for the service owner, and the caps are set | ☐ |
| Governance | The Governance Approval Checklist is signed | ☐ |
| Operations | The platform team has run the daily check from the runbook unaided | ☐ |

## 2. Installer: the check script

```powershell
./setup/Test-Install.ps1 -EnvironmentUrl https://<org>.crm.dynamics.com -ExpectedEnvironmentName '<environment name>'
```

It only reads. Record the totals and keep the output. In the fresh install test, Core alone gave 52 passes and Core with the handlers gave 58.

| Check | Expected | Pass or fail |
|---|---|---|
| Solution | Core installed, managed, at the release's version | ☐ |
| Flows | All 19 Core flows on | ☐ |
| Handlers | Each handler reported on or off as you chose; none queued for a handler that is off | ☐ |
| Connections | Each needed connection reference bound | ☐ |
| Variables | All three have a value | ☐ |
| Settings | All present; alert destination set if a handler is on; `app_url` set; caps set | ☐ |
| Seed data | Vocabulary, rules and subscriptions loaded; feeds loaded, and the ones you chose on | ☐ |
| Collection | Each collector ran, with the access tier you expect | ☐ |
| Signals | Signals and accepted fingerprints exist | ☐ |
| Reader | Role complete, no unmanaged layer, application user enabled and holding only that role | ☐ |
| Roles | User and Admin roles present | ☐ |
| Alerts | No failures since the alert settings were last changed | ☐ |
| Status | Demo data off in production; catch-up as expected | ☐ |
| `./setup/Test-ReaderIdentity.ps1` | Passes: the reader reads and can't write | ☐ |

## 3. User role

Use a real account that holds only **Basic User** and **Change Radar User**. Not an admin: an admin passes everything. `setup/dev/Test-UserRole.ps1` runs these 32 checks, signed in as that account with the Azure CLI. It writes values back unchanged. By hand:

### 3.1 Reading (21 checks)

| Test | Expected | Pass or fail |
|---|---|---|
| Open the Change Radar app (1 check) | The app appears and opens | ☐ |
| Read the signal tables: signal, signal version, signal fingerprint, feed, watch (5) | Rows, or an empty view without an error | ☐ |
| Read the estate tables: asset, asset fingerprint, solution, solution member, tenant setting (5) | As above | ☐ |
| Read the matching and rating tables: vocabulary, rule, exposure, assessment (4) | As above | ☐ |
| Read the event tables: event, subscription, handler run, alert log (4) | As above | ☐ |
| Read the running tables: config, collection run (2) | As above | ☐ |

Tables without a place in the app's menu (versions, fingerprints of assets, events, handler runs, alert log, solutions and members) are easiest to check with the script.

### 3.2 Allowed changes (4 checks)

| Test | Expected | Pass or fail |
|---|---|---|
| Change an exposure's status, then change it back | Saved | ☐ |
| Set an assessment's override and reason, then clear it | Saved, with who and when recorded | ☐ |
| Switch a signal's Watched flag on, then off | Saved | ☐ |
| Accept or reject a fingerprint, then set it back | Saved | ☐ |

### 3.3 Refused changes (7 checks)

| Test | Expected | Pass or fail |
|---|---|---|
| Change a setting (Config) | Refused | ☐ |
| Change a feed | Refused | ☐ |
| Change a rule | Refused | ☐ |
| Create a rule | Refused | ☐ |
| Create a subscription | Refused | ☐ |
| Create a vocabulary value | Refused | ☐ |
| Create a signal | Refused | ☐ |

### 3.4 No role

| Test | Expected | Pass or fail |
|---|---|---|
| An account without a Change Radar role opens the app | No access to the app or its data | ☐ |

## 4. Platform owner and admin

| Test | Expected | Pass or fail |
|---|---|---|
| Open the Radar page | It loads without an error; the header shows the access tier and when sources were read | ☐ |
| Compare a tile with the matching view | The numbers agree | ☐ |
| Use a filter, then Clear filters | The page narrows, then everything returns | ☐ |
| Set the Solution filter | Every section narrows to that solution | ☐ |
| Open a signal and choose Open source | Microsoft's page opens | ☐ |
| Open an exposure | The evidence says which rule matched what | ☐ |
| Open Fingerprint review | Counts and threshold shown; the line under the buttons says what each choice will do | ☐ |
| As an Admin, change a setting and change it back | Saved | ☐ |
| As an Admin, add a watch topic and remove it | Saved | ☐ |

## 5. Alerts (live)

Agree the time with whoever receives them.

| Test | Expected | Pass or fail |
|---|---|---|
| `Set-Handlers.ps1` with no changes | Lists each handler, its state, and any missing connection or destination | ☐ |
| Turn Notify-Teams on (`-On Notify-Teams -Apply`) | The flow is on and its subscriptions enabled | ☐ |
| Wait for a real High or Critical rating, incident or deadline | One card at each destination, naming the change and up to five assets | ☐ |
| Choose both buttons on the card | The signal opens in the app; Microsoft's page opens | ☐ |
| Turn Notify-Teams off, and wait for another event | No card, and no Notify-Teams run queued | ☐ |
| Monday, 08:00 UTC, with Digest-Weekly on | The digest arrives | ☐ |
| Email, if used | The same content, from the connection owner's mailbox | ☐ |

In a maintainer's development environment, `setup/dev/New-TestSignals.ps1` raises a test incident and `setup/dev/Remove-TestSignals.ps1` removes it. Don't use them in production.

## 6. Demo data (test environments only)

| Test | Expected | Pass or fail |
|---|---|---|
| Run `setup/Import-DemoData.ps1` against production, without `-Apply` | It refuses | ☐ |
| Load it in test with `-Apply` | Demo assets and solutions appear, and the setting is on | ☐ |
| Open the Radar page after the next match and assess runs | A banner says it is showing the demo organisation | ☐ |
| As an Admin, switch Demo data off | Your own estate returns | ☐ |
| As a User, try to change the switch | Refused | ☐ |
| Run `setup/Remove-DemoData.ps1 -Apply` | Every demo row is deleted and the setting is off | ☐ |

## 7. Ask Change Radar (optional)

| Test | Expected | Pass or fail |
|---|---|---|
| A user with a role asks "What changes affect us this month?" | An answer from your data | ☐ |
| The same user asks it to change a setting | It declines, and nothing changes | ☐ |
| An account with no Change Radar role asks | No signals, titles or counts | ☐ |

## 8. Evidence to keep

| Evidence | From |
|---|---|
| `Test-Install.ps1` and `Test-ReaderIdentity.ps1` output | Section 2 |
| `Test-UserRole.ps1` output, or this checklist completed | Section 3 |
| A picture of the Radar page and one card | Sections 4 and 5. They show asset names: store them with the same care as the data |
| The credit forecast (`Get-CreditEstimate.ps1`), and the capacity report after the first fortnight | Requirements, section 3 |
| The release's checksums, as verified | Release Notes |
| The signed Governance Approval Checklist | Governance pack |

## 9. Result

| Role | Name | Decision | Conditions | Date |
|---|---|---|---|---|
| Tester | | | | |
| Platform admin | | | | |
| Service owner | | | | |
