---
title: Change Radar
subtitle: Learning Path
document: CR-LRN-01
version: "0.3"
date: 24 November 2026
status: For review
audience: People new to Change Radar, including those who don't build apps or flows themselves
owner: Simon Owen
release: Change Radar 0.3.1
intro: keep
breaks: none
---

# Learning path

> **For:** people new to Change Radar, including those who don't build apps or flows themselves. **Kind:** tutorial: six short modules, about two hours in all.
> **Status:** written for release 0.3.0. The labs use **demo data only**, in an **evaluation or training environment**, never production. Names in the labs come from the demo organisation, Harbourline Group (synthetic), so what you see may differ slightly from the examples.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=learning-path) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=learning-path)

**In your organisation.** Most people who look after Power Platform didn't train as developers. They need to understand what a change means for the apps and agents their colleagues depend on, without reading Microsoft's announcements line by line. This path teaches the ideas first, then lets you practise on a made-up organisation where nothing you do can break anything. For why testing on safe data before trusting a tool matters, see [Test before you Trust](https://www.empoweryour.world/modellibrary/13-test-before-you-trust?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=learning-path) on Empower Your World.

## Before you start

| You need | Why |
|---|---|
| Access to an **evaluation or training** environment with Change Radar installed and **demo data loaded and switched on** | The labs change exposures, ratings and fingerprints. Do them only where the data is made up |
| The **Change Radar User** role (labs 3 to 6); the **Change Radar Admin** role for the optional topic step in lab 6 | What each role can do is in the User Guide, section 4 |
| A licence with premium Power Apps use rights | Every user of the app needs one |

**Never do these labs in production.** Demo data is refused in a Production environment, and the labs assume it is on. If the Radar page doesn't show a "Showing the demo organisation" banner, stop and ask your platform team.

## Module 1. The ideas (20 minutes, no computer needed)

### 1.1 Why platform change matters

Microsoft changes Power Platform and Copilot every week. Most changes are harmless. Some retire a feature, change a connector, or move an AI model, and an app or flow that worked yesterday behaves differently tomorrow. The hard part isn't reading the announcements: it's knowing **which of our things** each one touches, and **when**.

### 1.2 The words, in plain language

| Word | Think of it as |
|---|---|
| **Signal** | A note from Microsoft saying something is changing: a Message Center post, a roadmap item, a service incident, a retirement, a blog or licensing update |
| **Horizon** | When it lands. **Now**: act soon. **Imminent**: within about three months. **Future**: later |
| **Fingerprint** | A short description of what a signal touches, in a fixed vocabulary: which product, connector, capability or AI model |
| **Asset** | One of your organisation's apps, flows, agents or prompts |
| **Exposure** | A link between one signal and one asset: "this change touches this thing". It always shows its evidence |
| **Rating** | How much a change matters, from Low to Critical. **Generic**: to anyone. **For your estate**: to you, with extra weight if the asset is in production or action is due within 30 days |
| **Demo data** | A made-up organisation for learning. While it's on, the Radar shows the demo estate instead of yours, under a banner. The two are never mixed |

### 1.3 What the AI does, and what it doesn't

- **The AI reads Microsoft's announcement** and proposes its fingerprint, with a confidence. If it isn't sure, a person reviews it.
- **Rules, not AI, decide what's affected.** Matching a fingerprint to your assets is done by rules, so the same inputs always give the same exposures.
- **The AI proposes a generic rating** and writes the reason and the recommended action. Rules add the weight for your estate. A person can override any rating, with a reason.
- **The AI never sees your asset, owner or environment names.**

### 1.4 A worked story: a model retirement

Follow one made-up change from start to finish.

1. **Microsoft announces** that an AI model used by prompts will retire on a date about six weeks away. Change Radar collects the announcement from Microsoft Learn's retirement table that night. It is a **signal**, and its **horizon** is Imminent.
2. **It is fingerprinted by rule:** retirement tables are structured, so no AI is needed. The fingerprint says "model: the retiring model".
3. **Overnight, the estate is refreshed.** Change Radar knows the demo organisation has a prompt that summarises expense claims and uses that model, and a flow that calls the prompt.
4. **Matching links them.** The signal's fingerprint meets the prompt's model, so there is an **exposure** for the prompt, and one for the flow that calls it. Each shows the evidence: "model matches".
5. **It is rated.** The AI proposes a generic impact, Medium, because Microsoft moves prompts to a replacement model automatically. Rules add one because the flow runs in production. The estate rating is High.
6. **The platform owner sees it** in the priority matrix and receives a Teams card for the High rating. They **confirm** the exposures and ask the prompt's owner to test the prompt on the replacement model.
7. **Fourteen days before the date,** a deadline card arrives as a reminder.
8. **The owner moves the prompt to a supported model.** At the next nightly match, the prompt no longer matches, and its exposure closes as **No longer matches**. Nobody had to close it by hand.

**Check your understanding (answers at the end)**

- Q1. Which step used AI, and which used rules?
- Q2. Why was the estate rating higher than the generic one?
- Q3. Who closed the exposure?

## Module 2. A tour of the Radar page (15 minutes)

Open the Change Radar app. The **Radar** page is the first entry in the menu. Confirm the banner says **Showing the demo organisation**.

Find each part, top to bottom:

1. **The header:** the title, a line saying which sources were read and when, and **Refresh**.
2. **The headline:** one sentence with three numbers: changes needing action, high-impact changes, the next deadline.
3. **Five tiles:** Active incidents, Action required, High impact, Retiring, Future. Click **Retiring**: the page filters. Click it again, or **Clear filters**, to undo.
4. **The priority matrix:** rows are impact (High, Medium, Low); columns are time (next 30 days, 1 to 3 months, 3 to 6 months, later or landed).
5. **Patterns across the items:** themes with counts, for the last 90 days.
6. **What lands when:** a timeline with a Today line. Try **Next 90 days**, **Next 12 months** and **Past 90 days**.
7. **Imminent:** a table; the "Risk and opportunity" column is the AI's assessment, labelled as such.
8. **Your estate** and **By solution:** the changes that touch the demo organisation's assets and solutions.

Section headings collapse and expand; **Expand all** and **Collapse all** sit above the matrix.

**Check your understanding**

- Q4. Where would you look first for something urgent and important?
- Q5. How can you tell which text the AI wrote?

## Module 3. Lab: triage exposures (20 minutes)

**Goal:** decide whether changes really touch the demo organisation's assets.

1. On the Radar page, open **Your estate**, or open the **Exposures** view from the menu.
2. Open an exposure with status **New**.
3. Read the evidence: which asset, which rule, which facet matched.
4. Open the signal (its link on the exposure) and read the summary. Use **Open source** if you want Microsoft's own page.
5. Decide: does this change really affect this asset? Set **Status** to **Confirmed** or **Dismissed**, and save.
6. Repeat for two more.

**What you should see:** the status changes and is saved; the Radar page shows the change after **Refresh**.

**Check your understanding**

- Q6. What happens to an exposure if the asset is changed so it no longer matches?
- Q7. Does dismissing an exposure delete it?

## Module 4. Lab: override a rating (15 minutes)

**Goal:** correct a rating that's wrong for the organisation.

1. Open the **Assessments** view and pick a rating for the demo organisation.
2. Read the generic impact, the estate impact, the rationale and the recommended action.
3. Suppose you know better: set **Override impact** to a different level and write an **Override reason** (it is required).
4. Save. Note that Change Radar records who overrode it and when.
5. Find the signal on the Radar page: its placement now follows your override.
6. To leave the training data as it was, clear the override and the reason, and save.

**Check your understanding**

- Q8. Will the next night's run replace your override?
- Q9. Why is a reason required?

## Module 5. Lab: review a fingerprint (20 minutes)

**Goal:** see how a person keeps the AI in check.

1. Open the **Fingerprint review** page from the menu.
2. Look at the header: the counts and the confidence threshold (0.7 by default). Note that changes take effect at the next match run, 06:00 UTC.
3. If **To review** is empty, use **Check accepted LLM fingerprints** to see fingerprints the AI proposed.
4. Pick a signal with two groups. Read the line explaining AND and OR: within a group every facet must hold; groups are alternatives.
5. Under one fingerprint's buttons, read the **preview line**: it says what the choice would do at the next match, for example "Reject: Group A stops matching assets".
6. **Reject** it. If the preview says it would close exposures or widen a group, you're asked to confirm.
7. Now **Accept** it again, so the training data is left as it was.

**Check your understanding**

- Q10. Why might rejecting one value *widen* a group instead of narrowing it?
- Q11. When does your decision change the exposures?

## Module 6. Lab: watch, cards, digest and asking (30 minutes)

**Goal:** follow a change, and understand how news reaches people.

**Watch a signal.**

1. Open any signal. Switch on **Watched** and save.
2. Open the **Watched signals** view: it's there.
3. Switch **Watched** off again when you're done.

**Watch a topic (Admin role only; optional).**

1. Open the **Watch list** view. Open the example topic "Copilot Autopilot in the UK".
2. Read its parts: words to find (any of), also one of (regions), words to ignore ("Windows Autopilot", a different product).
3. Leave it as it is: an active topic sends real cards.

**Read a card and a digest.** Demo data never sends cards or email, so this part uses a real card in your platform team's channel, if there is one, or the description in the User Guide, section 3.7. Find on the card: the title, the key date, up to five affected assets, the recommended action, and the **Open in Change Radar** and **Open source** buttons.

**Ask Change Radar (if your organisation uses it).** In Teams, ask "Which changes are rated High?" Then ask it to change something, such as "Dismiss that exposure". It should refuse: it can read, never change.

**Check your understanding**

- Q12. Why don't you get cards for the demo organisation?
- Q13. What can Ask Change Radar see?

## Answers

| Q | Answer |
|---|---|
| 1 | Fingerprinting was by rule here (a retirement table); matching was by rules; only the generic rating and its text came from the AI |
| 2 | Rules added weight because an affected asset was in production |
| 3 | Change Radar, at the next nightly match, after the owner fixed the prompt |
| 4 | The priority matrix, top left: high impact, next 30 days. Or the **Action required** tile |
| 5 | It is labelled: "Risk and opportunity (LLM assessment)" in the Imminent table, and assessments are labelled as AI assessments |
| 6 | It closes as **No longer matches** at the next match |
| 7 | No. It is kept, with its status |
| 8 | No. Change Radar never overwrites an override |
| 9 | So the next reader knows why the AI was overruled: it is part of the audit trail |
| 10 | Some values describe *where* a change applies (a scope, such as a product or environment type). Removing a scope condition makes the group match more assets |
| 11 | At the next match run, 06:00 UTC |
| 12 | Demo and test data is never posted or sent, so learning can't reach real people |
| 13 | Only what your Change Radar role lets you read. Without a role, nothing |

## Where next

- The **User Guide** describes every screen and the routine for each role.
- The **Quick Reference Cards** give each role one page to keep.
- The User Guide's "Words you'll see" table is the glossary.
