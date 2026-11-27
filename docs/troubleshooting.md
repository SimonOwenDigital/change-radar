---
title: Change Radar
subtitle: Troubleshooting
document: CR-OPS-03
version: "0.3"
date: 24 November 2026
status: For review
audience: Installers and the platform team who run Change Radar
owner: Simon Owen
release: Change Radar 0.3.1
intro: keep
breaks: none
---

# Troubleshooting

> **For:** installers and the platform team who run Change Radar. **Kind:** reference: symptom, cause, fix.
> **Status:** built from the two clean installs of 24 November 2026 (the install test log) and from what the build found. The Operations Runbook's section 4 covers day-to-day failures; this guide adds install-time problems and the less obvious causes.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=troubleshooting) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=troubleshooting)

**First, run the check.** `setup/Test-Install.ps1` checks the install in one read-only run: solutions, flows, connections, variables, settings, seed data, each collector's last run, signals, the reader and its role, handlers and queued runs. It names most of the problems below.

## 1. Install

| Symptom | Cause | Fix |
|---|---|---|
| `pac admin create` rejects `--region unitedkingdom` | It takes a **macro-region** (`europe-uk`, `eu-efta`, `north-america` and so on) | Use the macro-region form |
| Import fails with "connection forcibly closed" | A long synchronous import dropped its connection | Import with `--async` |
| After import, most flows are on but fail at their first run | The flows were imported before their connections existed | Create the connections first (Installation Guide, step 3.1), bind the connection references, then turn the flows on |
| An upgrade leaves components the new release no longer contains | A plain import of a higher version never removes components | Upgrade Core with `--stage-and-upgrade` |
| Upgrading from 0.2.0 to 0.3.0 or later loses the alert flows | Core was upgraded before Handlers was imported | Import ChangeRadarHandlers first, then upgrade Core (Installation Guide, Upgrade) |
| No feed signals after the first night | New feeds load **switched off**, so nothing is collected or spent until you choose | Switch feeds on (Operations, Feeds, Active), or import with `Import-Feeds.ps1 -UseSeedActive` |
| The manual fingerprints from the seed are skipped | Their signals don't exist until the first collection | Run `Import-MatchingData.ps1` again after the first night |
| A thin first Radar: few exposures after the first night | The prompts are capped per run, and Microsoft's backlog is several hundred signals | Expected. Catch-up (100 a night for 14 nights) clears it in about a week; see the Admin Tuning Guide, section 7 |
| `Test-Install.ps1` fails "subscriptions: none" on an older copy of the script | Subscriptions are now seeded disabled; an older check counted enabled ones | Use the script from the same release |

## 2. Identity and permissions

| Symptom | Cause | Fix |
|---|---|---|
| `New-ReaderIdentity.ps1` refuses: "solution 'ChangeRadarCore' doesn't exist" | The Reader role ships in the solution, so the Dataverse part runs after the import | Run it with `-SkipDataverse` before the import (Azure and Entra only), then again after |
| Key Vault creation fails with HTTP 409, "not registered to use namespace 'Microsoft.KeyVault'" | The subscription has never used Key Vault | The script registers the provider as its own step; rerun it with `-Apply` |
| Role assignment on the vault fails for a Contributor | Contributor can't create role assignments | Have an Owner, User Access Administrator or Role Based Access Control Administrator assign the vault's roles |
| A role was just granted but calls still return 403 | The access token was issued before the grant | Sign in again (`Connect-AzAccount`) |
| Graph consent fails for an Application Administrator | Only a Privileged Role Administrator or Global Administrator can consent to Microsoft Graph application permissions | Ask one of them to grant consent |
| The estate inventory returns 403 | The inventory accepts only a signed-in user, never a service principal; or the connection owner isn't a Global Reader or Power Platform administrator | Use the delegated Power Platform for Admins V2 connection, owned by a Global Reader |
| You removed your own System Administrator role and can't save changes | Saving a role change needs the role you're removing | Add the new role and save **before** removing System Administrator; to recover, use the environment's **Membership**, **Add me** |
| The Reader role shows privileges as missing on a managed install | The role is managed and can't be fixed in place | Re-import the release; the script reports, never changes, a managed role |

## 3. Collection

| Symptom | Cause | Fix |
|---|---|---|
| Service health or Message Center: 401 or 403 | The reader's certificate expired, or consent was removed | Renew the certificate (Operations Runbook, 5.6); check the consent |
| Nothing collected for a service | Its name in `graph_services` doesn't exactly match Microsoft's | Copy the exact name from the admin centre's service health list |
| A public source returns no rows or a parse error | Microsoft changed the page's layout | Check the page and adjust the feed's profile (Adding a Signal Source) |
| The Book of News collector gets HTTP 403 | The site blocks requests without normal headers | The collector sends `Accept` headers and an honest user agent; if it still fails, leave the feed off. Change Radar never imitates a browser |
| Dataverse detail: 403 in one environment | The reader's application user doesn't exist there | Run `New-ReaderIdentity.ps1` for that environment, and add its URL to `detail_environments` |
| The Radar header shows an old date or a lower access tier | A collector hasn't run, or ran with reduced access | Read the collection runs' gaps column |

## 4. AI steps

| Symptom | Cause | Fix |
|---|---|---|
| Fingerprint or assess runs fail; no new ratings | AI capacity used up or not allocated | Allocate AI Builder credits or Copilot Credits to the environment; the next night continues |
| Deferred estate assessments every night | `assessment_max_per_run` is lower than your estate needs | Raise it (Admin Tuning Guide, section 7) |
| Ratings change wording or level after a date in Microsoft's calendar | Microsoft migrated the prompt model (for example on 2 December 2026) | Expected; rerun the fingerprint test set and review overrides |
| The same change is rated Medium one night and Low another | The generic impact is the AI's judgement and can vary | Override the rating, with a reason; it stays |

## 5. Matching and ratings

| Symptom | Cause | Fix |
|---|---|---|
| A change you know touches you shows no exposure | Its fingerprint is waiting for review, uses only scope facets (which never expose alone), or the asset isn't in the inventory | Check the signal's fingerprint and the Review page; check the asset in the Assets view |
| An exposure you fixed is still open | Matching runs once a night | Wait for the 06:00 UTC run: it becomes **No longer matches** |
| A Microsoft system component shows as an exposure | Some components Microsoft ships are matched before their solution is known | These are labelled and not rated; dismiss if they recur |
| Exposures change after you reject a fingerprint | Expected: rejecting can close or widen a group | Read the effect preview on the Fingerprint review page before you click |

## 6. Alerts

| Symptom | Cause | Fix |
|---|---|---|
| No cards at all | Handlers ship off; or no destination is set; or the Teams connection broke | `Set-Handlers.ps1` lists each handler's state and warns about a missing connection or destination |
| Handler runs fail with "no destination" | `alert_destinations` and `alert_recipient` are both empty | Set a destination (Config) |
| One destination gets nothing, others do | A bad entry: wrong user name or channel id | The handler run names the bad entry; fix it |
| Dozens of incident cards on the first night | An older release raised a card for incidents already over | Fixed: an incident already over when first seen raises no card. Upgrade |
| Runs queued for more than a day | Their handler is off | Expected while it's off; `Test-Install.ps1` reports them |
| Email alerts don't arrive | Email handlers ship off, and need an Office 365 Outlook connection the data policy allows | Turn on Notify-Email and Digest-Email with `Set-Handlers.ps1`; check the data policy |

## 7. The app and the pages

| Symptom | Cause | Fix |
|---|---|---|
| A new menu entry doesn't appear | The app's menu can lag a change by over an hour | Wait; or open the view directly |
| A column added recently is missing from a page | The page uses the app's cached table metadata | Reload the page once |
| The **Demo data** switch is refused | Only Change Radar Admins can change settings | Ask an admin |
| The Radar shows the demo organisation | Demo data is on: every view shows the demo estate under a banner | Switch it off in the header (Admin) |
| Someone can't open the app | No Change Radar role, or no premium Power Apps licence | Assign the role and licence (User Guide, section 4) |

## 8. Ask Change Radar

| Symptom | Cause | Fix |
|---|---|---|
| The agent answers but shows no data | The person asking has no Change Radar role: the agent reads as them | Assign a Change Radar role |
| The agent refuses to change something | By design: it has no tool that writes | Use the app |
| The agent isn't in Teams | It hasn't been added to the Teams and Microsoft 365 Copilot channel, or shared | Installation Guide, step 8 |
