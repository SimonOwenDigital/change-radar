---
title: Change Radar
subtitle: User Guide
document: CR-USE-01
version: "0.3"
date: 24 November 2026
status: For review
audience: Platform owners and admins, solution owners and makers, and leadership
owner: Simon Owen
release: Change Radar 0.3.1
intro: keep
breaks: none
---

# User guide

> **For:** platform owners and admins, solution owners and makers, and leadership. **Kind:** how-to, by role, then a reference to each screen.
> **Status:** describes release 0.3.0. Screens are described in words; all names and examples come from the demo organisation, never a real tenant.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=user-guide) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=user-guide)

**In your organisation.** Microsoft changes Power Platform and Copilot every week, and the work of keeping up usually falls on a few admins reading Message Center by hand. Change Radar turns that into a short daily routine: one page that shows what touches your estate and when, cards for what's urgent, and a digest for everyone else. For how this kind of routine lets governance scale without a bottleneck, see [Scalable Governance](https://www.empoweryour.world/modellibrary/01-scalable-governance?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=user-guide) on Empower Your World.

## 1. Words you'll see

| Word | Means |
|---|---|
| **Signal** | One change Microsoft is making: a Message Center post, a roadmap item, a service incident, a retirement, a blog or licensing update |
| **Horizon** | When a signal lands: **Now** (action needed soon), **Imminent** (within about three months), **Future** |
| **Fingerprint** | What a signal touches, in a shared vocabulary: products, connectors, capabilities, models and so on |
| **Asset** | One of your apps, flows, agents or prompts |
| **Exposure** | This change touches this asset. It shows the evidence: which rule matched what |
| **Rating** | How much a change matters: **generic** (to anyone) and **for your estate**, from Low to Critical. The generic rating is the AI's judgement; the estate rating adds weight for production assets and near deadlines. Labelled as an assessment, and overridable |
| **Watch** | A signal or topic you follow, so you're told when it changes |
| **Demo data** | A made-up organisation for training and evaluation. When it's on, the Radar shows the demo estate instead of yours, under a banner |

## 2. Your routine, by role

### 2.1 Platform owner and admins: each working day (10 minutes)

1. **Check Teams** for cards: a service incident, a High or Critical rating, a deadline 14 or 3 days away, a model change, or a watch match. Each card has **Open in Change Radar** and **Open source** buttons.
2. **Open the Radar page** in the Change Radar app. Read the headline: how many changes need action, how many are high impact, and the next deadline.
3. **Look at the priority matrix:** start with the top-left cell (high impact, within 30 days).
4. **Triage new exposures** (section 3.3): confirm the ones that are real, dismiss the ones that aren't.
5. **Override a rating** where the AI is wrong for your estate (section 3.4).
6. **Review fingerprints** waiting on the Fingerprint review page (section 3.5). Usually none or a few.
7. **Decide who acts** on anything confirmed, using your own change or ticketing process. Change Radar doesn't assign work.

### 2.2 Platform owner: each Monday (20 minutes)

1. Read the **weekly digest** in Teams (08:00 UTC): new and changed signals, newly exposed assets, ratings, model changes and the watch list.
2. On the Radar page, open **What lands when** for the next 90 days and check nothing important is unowned.
3. Look at **Patterns across the items** for themes building up.
4. Skim the **Watch list** and add a topic if something new is worth following.

### 2.3 Solution owners and makers: when told a change touches your solution

1. Open the link you were sent, or the Radar page with the **Solution** filter set to your solution: every section narrows to your solution's assets and the changes that touch them.
2. Open the **exposure** to see the evidence: which of your assets, and why.
3. Read the signal and Microsoft's page (**Open source**), and the rating's **recommended action**.
4. Make the change in your solution: update the flow, move the prompt to a supported model, change a connector or a setting.
5. **Nothing to close by hand:** at the next nightly match, an exposure whose asset no longer matches closes as **No longer matches**.
6. Not sure what a change means for you? Ask **Ask Change Radar** in Teams (section 3.8).

### 2.4 Leadership: each week

Read the Monday digest. To see the bigger picture, open the Radar page: the headline, the **priority matrix** (what matters most, and when) and **What lands when** (the next 90 days or 12 months) are designed to be read in a minute.

## 3. The screens

### 3.1 The Radar page

The Radar page is the first entry in the app menu. From top to bottom:

| Part | What it shows | What you can do |
|---|---|---|
| **Header** | The title, and a line saying which sources were read and how recently ("Full access: every source is read, and the estate covers the whole tenant") | **Refresh**. An admin also sees the **Demo data** switch |
| **Headline** | One sentence: changes needing action, high-impact changes, the next deadline | |
| **Five tiles** | Active incidents, Action required, High impact, Retiring, Future | Click a tile to filter the page |
| **Filters** | Product, source, horizon, theme, impact type, and **Solution** | Combine filters; **Clear filters** brings everything back |
| **Priority matrix** | Rows: High, Medium, Low impact. Columns: next 30 days, 1 to 3 months, 3 to 6 months, later or landed. Each item has a colour bar (risk or opportunity) and a marker if action is required | Click an item to open the signal. A rating for your estate wins over the generic rating for placement |
| **Patterns across the items** | Nine themes, with counts and item ids, for the last 90 days | **Show older items** widens it |
| **What lands when** | A timeline with a Today line. Dots are coloured for Imminent, Retiring, Shipped and Future; a red ring means action required | **Next 90 days** (by week), **Next 12 months** (by month), **Past 90 days** |
| **Imminent** | A table: when (with an Action badge), product, item and summary, impact, risk and opportunity (the AI's assessment, labelled), and a reference | **Ref** opens the signal |
| **Your estate** | The changes that touch your assets, with the estate rating, rationale and recommended action | Open an exposure or assessment |
| **By solution** | Your solutions and the changes that touch each one | Set the Solution filter from here |

Each section heading collapses or expands its section; **Expand all** and **Collapse all** sit above the matrix. By default only What lands when and Your estate are open, and your choice is remembered in your browser.

**Demo data.** When an admin switches demo data on, every count, chart and list shows the demo organisation instead of your estate, under a "Showing the demo organisation" banner. Switch it off to see your own estate again. The two are never mixed.

### 3.2 A signal

Open a signal from the Radar page, a card or the **Signals** view.

- **Summary, dates and horizon**, and **Open source** for Microsoft's own page.
- **Fingerprint:** what it touches, in groups. Within a group every facet must hold (AND); groups are alternatives (OR).
- **Exposures and assessments** for this signal.
- **Watched:** switch it on to get a card whenever this signal changes: its date, wording, status, horizon, a new exposure or a new rating.

### 3.3 Exposures: confirm or dismiss

An exposure says a change touches an asset. Open it from the Radar page or the **Exposures** view, read the evidence, and set its **Status**:

| Status | Meaning | Set by |
|---|---|---|
| New | Found by the nightly match, not yet looked at | Change Radar |
| Confirmed | A person agrees this asset is affected | You |
| Dismissed | Not relevant here | You |
| No longer matches | The asset no longer matches (fixed, changed or removed) | Change Radar, at the next match |

### 3.4 Ratings: override

Open the assessment (from the Radar page or the **Assessments** view). If the AI's rating is wrong for your estate, set **Override impact** (raise, lower or dismiss) and write the **Override reason**, which is required. Change Radar records who overrode it and when, and never overwrites your override.

### 3.5 Fingerprint review

When the AI isn't sure what a change touches (confidence below the threshold, 0.7 by default), the fingerprint waits for a person on the **Fingerprint review** page.

1. The tabs show **To review**, **Accepted** and **Rejected**; a filter shows who proposed each value (AI, manual or rule).
2. Each signal shows its groups, with a line explaining AND and OR.
3. Under each fingerprint's buttons, a line says what the choice will do at the next match, for example "Reject: Group A stops matching assets". If it would close exposures or widen a group, you're asked to confirm.
4. **Accept** or **Reject**. Changes take effect at the next match run (06:00 UTC).

When nothing is waiting, the page offers to check the accepted AI fingerprints instead.

### 3.6 Watch list

- **Watch a signal:** the **Watched** switch on the signal form.
- **Watch a topic:** an admin adds a row to the **Watch list** view: words to look for (any of), optionally also one of a second set (such as a region), and words to exclude (such as "Windows Autopilot" when you mean Copilot Autopilot). Every new or changed signal is checked against the topics by word, at no cost. A match sends a card and watches the signal from then on.
- The **Watched signals** view lists everything being watched.

### 3.7 Teams cards and the weekly digest

| Card | When |
|---|---|
| Service incident | A new incident in one of the services Change Radar monitors (the `graph_services` setting), not one already over |
| High or Critical rating | A change is rated High or Critical for your estate |
| Deadline | An action date with an exposure in your estate is 14 or 3 days away |
| Model change | An agent's or prompt's model changed without anyone editing it |
| Watch | A signal matched a watched topic, or a watched signal changed |
| Weekly digest | Each Monday at 08:00 UTC: the week's new and changed signals, exposures, ratings, model changes and watch list items |

A card shows the signal's title, key date, up to five affected assets and the recommended action. The same can be sent as email if your admin has switched it on.

### 3.8 Ask Change Radar (if your organisation uses it)

Ask questions in Teams or Microsoft 365 Copilot, for example:

- "What changes affect the Expenses solution this month?"
- "Which of our prompts use a model that's retiring?"
- "What does MC1234567 mean for our flows?"

It answers from Change Radar's data, reading as you: it sees only what your Change Radar role allows, and it can't change anything. To change something, use the app.

## 4. Who can do what

| Action | Change Radar User | Change Radar Admin |
|---|---|---|
| Read everything | Yes | Yes |
| Confirm or dismiss an exposure; override a rating; watch a signal; review fingerprints | Yes | Yes |
| Switch demo data on or off; change settings, rules, vocabulary, feeds, subscriptions and watch topics | No | Yes |

If you can't open the app, ask your platform team for a Change Radar role (and a licence with premium Power Apps use rights).
