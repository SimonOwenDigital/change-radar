---
title: Change Radar
subtitle: ALM and Deployment
document: CR-ALM-01
version: "0.3"
date: 24 November 2026
status: For review
audience: Platform admins who deploy and upgrade Change Radar, and maintainers who build releases
owner: Simon Owen
release: Change Radar 0.3.0
intro: keep
breaks: none
---

# ALM and deployment

> **For:** platform admins who deploy and upgrade Change Radar, and maintainers who build releases. **Kind:** explanation and how-to.
> **Status:** describes release 0.3.0. Install and upgrade were proved in two install test runs on 24 November 2026 (`install-test-log.md`). Rollback has **not** been tested: section 7 says what Microsoft documents and what is still to verify.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=alm) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=alm)

## 1. How Change Radar is distributed

Change Radar is shared as **managed solutions plus setup scripts**. Solutions carry everything Power Platform can package. Scripts do what a solution can't.

| Part | What it carries | Who uses it |
|---|---|---|
| **Managed solution zips** (a GitHub release) | Tables, flows, prompts, the app and its pages, roles, the agent | Every installer |
| **`setup/` scripts** | The reader's app registration and Key Vault certificate; seed data and settings; switching handlers; checks | Every installer |
| **`seed/`** | Settings, vocabulary, rules, subscriptions, feeds and watch topics, as CSV and JSON | The setup scripts |
| **`setup/dev/` scripts** | Building and testing in the development environment; building releases | Maintainers only |
| **Package Deployer package** | One-step import of the solutions and seed data | Not built: a later option |

An installer needs the release files and a copy of the repository at the same release. Nothing needs compiling.

## 2. Environments

| Environment | Holds | Solutions | Demo data |
|---|---|---|---|
| **Development** (maintainers, or an organisation that changes Change Radar) | The editable source | Unmanaged | Allowed |
| **Test** | Each release before production | Managed | Allowed |
| **Production** | The live service | Managed | Never: the import script refuses |

- Most organisations need **test and production** only. A small one can start with production alone and add test before its first upgrade.
- Each environment has its own settings, connections and data. Nothing is copied between them.
- One reader app serves every environment in the tenant. Its Key Vault values are reused; only the application user is added per environment.
- A test environment collects the same signals, so it uses AI capacity too. Keep its caps low, or turn its AI flows off between tests.

## 3. What a release contains

| File | What it is |
|---|---|
| `ChangeRadarCore_<version>_managed.zip` | The core: required |
| `ChangeRadarHandlers_<version>_managed.zip` | The alerts: optional, every handler off on a new install |
| `ChangeRadarAsk_<version>_managed.zip` | The Ask Change Radar agent: optional |
| `Change-Radar-Docs-<version>.zip` | The documentation: every document as Word and PDF, by stage |
| `SHA256SUMS` | A checksum for each zip |
| `LICENSE`, `NOTICE` | The Apache License 2.0 and its notice. Keep both with any copy |

Check each zip before importing: `(Get-FileHash <zip>).Hash` must match `SHA256SUMS`. The Release Notes list the same checksums and the solution checker's findings.

The release script started copying `LICENSE` and `NOTICE` after release 0.3.0 was built, so they are added to 0.3.0 by hand when it is published.

## 4. Settings for each environment

| What | Where | Rule |
|---|---|---|
| Environment variables (three) and Core's connections | `deploymentSettings.json`, from `deploymentSettings.template.json` | One file per environment, kept out of source control |
| The handlers' connections | `deploymentSettings.handlers.json`, from `deploymentSettings.handlers.template.json` | As above |
| Settings, such as caps and alert destinations | The Config table, loaded by `setup/Import-Config.ps1` | Loading adds missing settings and never overwrites one you've changed |
| Vocabulary, rules, subscriptions | `seed/*.csv`, loaded by `setup/Import-MatchingData.ps1` | To keep your own changes under source control, keep your copy of the CSVs and load from it. A plain run adds missing rows; `-UpdateToSeed` also changes existing ones |
| Feeds and watch topics | `seed/feeds.csv`, `seed/feed-profiles/`, `seed/watches.csv` | Feeds and topics load switched off |

The setup scripts take `-EnvironmentUrl` and `-ExpectedEnvironmentName` and refuse any other environment. Those that write plan by default and write only with `-Apply`.

## 5. Install order

1. Create the reader app (once per tenant).
2. Import **ChangeRadarCore**.
3. Add the reader's application user to the environment.
4. Load the starting data.
5. Import **ChangeRadarHandlers** and switch on the handlers you want (optional).
6. Import **ChangeRadarAsk** (optional).
7. Run `setup/Test-Install.ps1`.

The Installation Guide has the commands. Core never depends on Handlers or Ask, so either can be left out.

## 6. Upgrades

1. Read the Release Notes and check the checksums.
2. **Take a manual backup** of the environment (production and sandbox environments support one).
3. Upgrade **test** first, then production.
4. Import in this order, each with `--async`:
   - **ChangeRadarHandlers** (if you use it), as a normal import;
   - **ChangeRadarCore**, with `--stage-and-upgrade`;
   - **ChangeRadarAsk** (if you use it).
5. Run `setup/Import-Config.ps1 -Apply` for any new settings, then `setup/Test-Install.ps1`.

```powershell
pac solution import --environment https://<org>.crm.dynamics.com --path ChangeRadarHandlers_<version>_managed.zip --settings-file deploymentSettings.handlers.json --async
pac solution import --environment https://<org>.crm.dynamics.com --path ChangeRadarCore_<version>_managed.zip --settings-file deploymentSettings.json --stage-and-upgrade --async
```

**Why the order matters.** Release 0.3.0 moved the handler flows out of Core. With Handlers imported first, both solutions hold the same flows, so Core's upgrade can let go of them without deleting them.

**What was proved** (install test run 2, 0.2.0 to 0.3.0): the handler flows kept their ids, their on or off state and all 572 handler runs; Core's upgrade took two minutes; the check script passed 55 checks. A plain import never removes components that a release has dropped, which is why Core uses `--stage-and-upgrade`.

**Don't edit managed components in test or production.** An edit creates an unmanaged layer that hides later updates. `Test-Install.ps1` warns about one on the Reader role.

## 7. Rollback

There is no one-step rollback. Plan for the options below before an upgrade.

| Option | What it does | Known |
|---|---|---|
| **Switch off** | Turn the handlers off (`Set-Handlers.ps1 -Off`), or turn off the Core flows. Data stays | Handlers: proved in run 2 |
| **Fix forward** | Import a corrected, higher version | The normal route |
| **Re-import the older zip** | Microsoft's guidance is that only higher versions can be imported, unless a pipeline allows redeploying older ones | Not tested with Change Radar: to verify |
| **Restore a backup** | Puts an environment back to a point in time, **including its data**. Backups are kept seven days by default. The restore target must be a sandbox, developer or Teams environment | Microsoft Learn, 2026-11-24; not tested with Change Radar |
| **Uninstall and reinstall** | Deleting ChangeRadarCore **deletes its tables and data** | A last resort. Export what you need first |

Because Change Radar never writes to the estate, switching it off has no effect on the apps and flows it watches. That makes switching off and fixing forward the safe choice.

Sources: [Back up and restore environments](https://learn.microsoft.com/power-platform/admin/backup-restore-environments), [Roll back releases](https://learn.microsoft.com/power-platform/alm/power-pages/rollback-hotfix) (written for Power Pages; it states the version rule for solution imports). Both checked 2026-11-24.

## 8. How a release is built (maintainers)

1. **Change the source.** Flows, tables, roles and pages are generated or kept as code under `solutions/design/` and deployed to the development environment by `setup/dev/` scripts.
2. **Export** with `setup/dev/Export-CoreSolution.ps1`. It scans for tenant ids, environment URLs and email addresses, compares every flow with its generated definition, checks the roles and that Core holds no handler parts, then unpacks to `solutions/`.
3. **Commit,** then run `setup/dev/New-Release.ps1 -Version <x.y.z> ...`. It plans by default. It refuses unless the working tree is clean, every engine test suite passes and the version is higher than the current one.
4. With `-Apply` it sets the version, packs the three managed zips to `out/release/<version>/`, runs Microsoft's solution checker on each, and writes the checksums, `LICENSE`, `NOTICE` and a Release Notes entry.
5. **A person** writes "What's new", commits, and publishes the release with the `gh` command the script prints. The script never publishes.

The zips aren't kept in source control: they are attached to the GitHub release.

## 9. If you change Change Radar

- Prefer **data** changes, which survive upgrades: settings, vocabulary, rules, feeds, watch topics.
- Add a handler in **your own solution**, from the Handler template (the Extend guide).
- For anything deeper, fork the repository, work in your own development environment with unmanaged solutions, and build your own managed release. You then merge upstream releases yourself.
