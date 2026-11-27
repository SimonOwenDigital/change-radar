---
title: Change Radar
subtitle: Quick Reference Cards
document: CR-USE-02
version: "0.3"
date: 24 November 2026
status: For review
audience: Platform owners and admins, solution owners and makers, leadership, and Change Radar admins
owner: Simon Owen
release: Change Radar 0.3.1
intro: keep
---

# Quick reference cards

> **For:** platform owners and admins, solution owners and makers, leadership, and Change Radar admins. **Kind:** reference, one printed page per role.
> **Status:** describes release 0.3.0. Each card is a summary of the User Guide and the Operations Runbook; where they differ, those documents win.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=cards) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=cards)

## Card 1. Platform owner and admins: daily triage (10 minutes)

| Step | Where | What to do |
|---|---|---|
| 1. Cards | Teams | Read any card: incident, High or Critical rating, deadline at 14 or 3 days, model change, watch match. **Open in Change Radar** or **Open source** |
| 2. Headline | Radar page | Changes needing action, high impact, next deadline |
| 3. Matrix | Radar page, priority matrix | Start top left: high impact, next 30 days |
| 4. Exposures | Radar page or **Exposures** view | Set **Status**: Confirmed if real, Dismissed if not |
| 5. Ratings | **Assessments** view | Wrong for your estate? Set **Override impact** and the required **Override reason** |
| 6. Fingerprints | **Fingerprint review** page | Accept or Reject what's waiting. Read the preview line first. Takes effect at 06:00 UTC |
| 7. Decide | Your own change or ticket process | Who acts, by when. Change Radar doesn't assign work |

**Monday (20 minutes):** read the digest (08:00 UTC); check **What lands when** for the next 90 days; scan **Patterns across the items**; review the **Watch list**.

**Exposure statuses:** New (found, not looked at) · Confirmed (you agree) · Dismissed (not relevant) · No longer matches (closed by the next match).

## Card 2. Solution owners and makers

| When | Do |
|---|---|
| You're told a change touches your solution | Open the link, or the Radar page with the **Solution** filter set to your solution |
| You want to know why | Open the **exposure**: which asset, which rule, what evidence |
| You want the detail | Open the signal, then **Open source** for Microsoft's page. Read the rating's **recommended action** |
| You fix it | Update the flow, move the prompt to a supported model, change the connector or setting |
| You've fixed it | Nothing to close. At the next nightly match the exposure becomes **No longer matches** |
| You're not sure what it means | Ask **Ask Change Radar** in Teams, if your organisation uses it: "What changes affect my solution this month?" |
| You want to follow a change | Switch on **Watched** on the signal: a card arrives when it changes |

**Remember:** a rating's generic impact is the AI's judgement. If it's wrong for your solution, tell your platform team, who can override it.

## Card 3. Leadership: the weekly read (5 minutes)

| Read | It tells you |
|---|---|
| The Monday digest (Teams, 08:00 UTC) | The week's new and changed changes, newly affected assets, ratings, model changes and watched items |
| The Radar page headline | How many changes need action, how many are high impact, the next deadline |
| The priority matrix | What matters most (rows: High, Medium, Low) and when it lands (columns: 30 days, 1 to 3 months, 3 to 6 months, later) |
| What lands when | The next 90 days by week, or 12 months by month. A red ring means action is required |

**Questions worth asking each week:**

- Is anything High impact in the next 30 days without an owner?
- Are any deadlines in the next two weeks?
- Has a model change affected anything we rely on?

## Card 4. Change Radar Admin: configuration and health

| Task | Where |
|---|---|
| Check last night's runs | Operations, **Collection runs**: each collector Succeeded; read **Gaps** |
| Check alerts can go out | `./setup/Set-Handlers.ps1` (no `-Apply`): lists each handler, whether it's on, and any missing connection or destination |
| Who gets alerts | Config: `alert_destinations` (`chat:`, `channel:`, `email:`) and `alert_recipient` |
| Turn a handler on or off | `./setup/Set-Handlers.ps1 ... -On <name> -Apply` (or `-Off`) |
| Credit caps | Config: `fingerprint_max_per_run`, `rating_max_per_run`, `assessment_max_per_run` |
| Credit forecast | `./setup/Get-CreditEstimate.ps1` (read-only) |
| Full health check | `./setup/Test-Install.ps1` (read-only) |
| Sources | Operations, **Feeds**: the **Active** column |
| Watch topics | Radar, **Watch list**: words to find, also one of, words to ignore, Active |
| Demo data | The **Demo data** switch in the Radar page header. Never in production |
| Settings Change Radar can't read | Operations, **Tenant settings** |

**Yearly:** renew the reader's certificate before it expires (Key Vault emails 30 days before; Operations Runbook 5.6). **Quarterly:** review who holds the User and Admin roles and who receives alerts.
