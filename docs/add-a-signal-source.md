---
title: Change Radar
subtitle: Adding a Signal Source
document: CR-SRC-01
version: "0.3"
date: 24 November 2026
status: For review
audience: The maintainer adding a new public source of change signals
owner: Simon Owen
release: Change Radar 0.3.1
intro: keep
breaks: none
---
# Add a signal source

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=add-a-signal-source) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=add-a-signal-source)

How to add a new public source of change signals to Change Radar, such as a Learn page, a release-notes page or an RSS feed, without writing a new flow. This follows ADR 0014: sources are data (a `crdr_feed` row and a feed profile), and three generic collectors read them.

Allow about an hour for a source that fits one of the three kinds. A source that doesn't fit needs its own adapter: see "When none of the kinds fits" at the end.

## Before you start

- Work in your development environment. Nothing here touches the tenant beyond reading a public URL.
- The source must be **public** and must **not need sign-in**. Community sources ship with `active = false` until someone has reviewed them.
- Have the engine tests passing: `pwsh -File engine/Invoke-FeedTests.ps1`.

## 1. Decide the kind

| Kind (`crdr_feed.crdr_kind`) | Use it for | One signal per | Example in `seed/feeds.csv` |
|---|---|---|---|
| `learnpage_tables` | a Learn page whose table lists dated rows, such as retirements or lifecycle states | table row | `ML-CS`, `ML-CSM`, `ML-PR` |
| `learnpage_sections` | a Learn page of dated sections, each listing items, such as release notes | item in a section | `M365RN` |
| `rss` | an RSS or Atom feed | feed item | `CSBLOG` |
| `webpage_sections` | an undated page edited in place (a Learn licensing page), or an event's Book of News | heading section | `CS-BILLING`, `BON-IGNITE26` |
| `pdf_changelog` | a PDF with a change log table at the end (a licensing guide) | change log row | `LIC-CS` |

Then choose the **horizon rule** (`crdr_horizonrule`), which says how a signal's date places it on the radar:

- `lifecycle`: the date is when something happens, such as a retirement. Future dates are Imminent or Future, and past ones are Shipped.
- `released`: the date is when something shipped. The signal is Now on the day and Shipped after it.
- `published`: the date is when it was written, such as a blog post. These are informational and never need action.

Learn pages are watched by their `git_commit_id`. A collector only reparses a page when that id changes, and records it as the feed's marker. RSS feeds are **forward-only**: the marker is the newest item date seen, because Microsoft's CDN can serve stale copies of a feed (observed 2026-11-22). An item older than the marker is never re-added.

## 2. Write the row and the profile

Add one row to `seed/feeds.csv`:

| Column | Notes |
|---|---|
| `key` | Short and unique, upper case, such as `PPRN`. It prefixes every signal's external id, so never change it after the first run. |
| `name` | What people see, in British English. |
| `kind`, `horizon_rule` | From step 1. |
| `url` | The public page or feed. |
| `products` | Semicolon-separated product names for the signals, such as `Microsoft Copilot Studio`. |
| `active` | `false` until step 5. |
| `profile` | The profile file name in `seed/feed-profiles/`, usually `<key>.json`. |
| `description` | One line, with the ADR or reason. |

Then write the profile, `seed/feed-profiles/<key>.json`. The keys it can use depend on the kind:

**`learnpage_tables`**
- `surface`: where the change happens, used in titles ("retires from *prompts in Copilot Studio, Power Automate and Power Apps*").
- `retiredWithinDays`: rows already retired more than this many days ago are skipped.
- `tables`: one entry per table shape:
  - `requires`: the header texts that identify the table. Tables are matched by their headers, never by position.
  - `columns`: which header holds `model`, `date`, `status`, `replacement` and so on.
  - `status`: a fixed status when the table has no status column.
  - Optional: `dateFrom: "heading"` with `headingPrefix`, when the date is in the heading above the table; and `split`, when one cell lists several items.
- `fingerprintScope`: facets added to every rule fingerprint, such as `{"resource_type": ["prompt"]}`.
- `migrationNote` (model feeds): one sentence on what Microsoft does on the date, added to rating and deadline cards.

**`learnpage_sections`**
- `sinceDays`: only sections dated in the last N days.
- `areas`: section areas in scope; `areaProducts` maps an area to a product name.
- `titleKeywords`: an item outside those areas is still kept if its title contains one of these words.

**`rss`**
- `label`: a short label shown with each signal, such as `Blog`.

**`webpage_sections`** (ADR 0018, ADR 0019, spike T11)
- **Which page and marker:**
  - `marker`: `git_commit_id` (Learn) or `dateModified` (a page's `ld+json`, as on the Book of News).
  - `contentStart` and `contentEnd`: plain text that bounds the content, usually `<main` and `</main>`.
- **Which sections count:**
  - `unit`: `all` (every section, for Learn pages) or `leaf` (only the deepest headings with a body, for the Book of News).
  - `minChars`: the shortest section body, in characters of HTML.
  - `skipTitles`: headings that are page furniture, such as `In this article`, `Feedback` and `Try Instant Summaries`.
  - `scopeHead` and `scopeBody`: up to 12 words each. A section is in scope when its heading path or its body contains one. Leave both out to keep everything.
- **How signals look:**
  - `idFrom`: `title` or `path` (the parent headings and the title). Use `path` when titles repeat across the page.
  - `titlePrefix`, `label`, `keydate` (a fixed date; otherwise Learn's `updated_at`), `confidenceLabel` and `nature`.
- **Summary and changes:** the summary is the section's HTML, and the Readable summary flow makes the text. A changed section updates its signal, which raises `signal.changed`.
- **Unrated:** set `unrated` to `true` in `seed/feeds.csv` when the source's signals shouldn't go to the LLM.
- **First run:** a feed's first run is silent: no version rows, so no events or cards.

**`pdf_changelog`** (ADR 0019, spike T12)
- `guideName`, `label`, `nature` and `confidenceLabel`.
- `rowAlign`: `top` when the cells line up with the top of the date cell, or `middle` when the date sits in the middle of the row (the Power Platform guide).
- **How it reads the guide:** it follows the fwlink's `Location`, HEADs the PDF, and runs AI Builder text recognition only when `Last-Modified` changes.
- **How rows are rebuilt:** from the "Appendix X: Change Log" page to the end. Columns come from the Page, Change, Action and Date header positions, and a row ends at its date cell.
- **Saved recognition output:** keep the output (trimmed to the change log pages) in `tests/feeds/samples/licensing-guides/`. Parity uses it, because reading again costs credits.

If every signal from the source belongs to one theme, or has a fixed nature (such as a retirement that Microsoft migrates automatically), add a row to `seed/theme-rules.csv`. The columns are `match` (`feed`), `value` (the key), `theme` (from `seed/themes.csv`), an optional `nature` and a `description`. A rule wins over the LLM's rating. Leave the source out of the rules if its signals vary.

## 3. Capture a sample

Save the page or feed as it is today into `tests/feeds/samples/` (or `tests/models/pages/` for model tables), for example `tests/feeds/samples/<key>.html`.

- Keep it as fetched. Don't tidy the HTML: the oddities are what the tests protect against. For example, the release notes once had an item whose title was not the first bold text (test `feed-10`).
- Public Microsoft pages hold no tenant data, but check anyway. Remove anything that names a person or an organisation.

## 4. Write the expected cases first

Add cases to `tests/feeds/cases.json` **before** turning the feed on (tests before rules). Each case names the feed, the sample and what the engine must produce:

```json
{ "id": "feed-11", "note": "What this case protects", "feed": "PPRN", "sample": "samples/pprn.html",
  "expect": { "count": 12, "gaps": [],
    "signals": { "PPRN-some-item": { "title": "...", "keydate": "2026-12-01", "horizon": "imminent", "actionrequired": false,
                                     "datelabel": "...", "products": "...", "url": "..." } } } }
```

- Check the **count** against the page by eye, and list at least two signals in full: one ordinary, and one edge case (a missing date, a cell with two items, a retired row).
- Add a **near miss**: a row or item that must not become a signal (out of scope, too old, the wrong table). An RSS feed has none, because every item is a signal; its "must not happen" is an old item coming back, which the forward-only marker prevents and the parity check in step 6 shows.
- For a model source, also add lifecycle fingerprint cases to `tests/models/models.json`. Every model spelling on the page must map to a row in `seed/vocabulary.csv` (`allMapped`, expected gaps 0). An unknown model is a gap, never a guess: add the model with its spellings to the vocabulary.

Run `pwsh -File engine/Invoke-FeedTests.ps1` (and `Invoke-ModelTests.ps1` for models). Fix the **profile** until the cases pass. Change the engine only if the source needs something no profile key can express, and then add a case for the new behaviour as well.

## 5. Turn it on in your development environment

1. Set `active` to `true` in `seed/feeds.csv`. That records your intent for future installs.
2. Load the feeds: `pwsh -File setup/Import-Feeds.ps1 -EnvironmentUrl <url> -ExpectedEnvironmentName '<name>'`, then again with `-Apply`. It upserts by key and writes the profile JSON into `crdr_feed.crdr_profile`.
   - A **new** feed is always created switched **off**, whatever the seed says, and an existing feed's on or off state is never changed. Both are installer choices. To switch it on, run the import again with `-Activate <key> -Apply` (or `-Deactivate <key>` to switch one off).
3. No flow changes are needed: the collector for its kind picks the row up on its next daily run (Learn tables 05:15, Learn sections 05:20, RSS 05:25 UTC). To run it now, use `setup/dev/Invoke-FlowRun.ps1` with the collector's workflow id.
4. If you added a theme rule, the assess flow applies it at 06:30 UTC. To apply it now: `pwsh -File setup/dev/Test-RuleThemes.ps1 -EnvironmentUrl <dev url> -Backfill`.

## 6. Check the first run

- **Collection run:** the feed's row in the Collection runs view shows the item count, and lists any **gaps** (unmapped models, tables not found). A gap is a reason to fix the profile or vocabulary, never to ignore it.
- **Parity:** `pwsh -File setup/dev/Test-FeedParity.ps1 -EnvironmentUrl <dev url> -Feed <key>` compares the stored signals with the engine on today's page. It must report no differences. For an RSS feed, a retry may be needed if the CDN served a stale copy.
- **Model sources:** `pwsh -File setup/dev/Test-ModelFingerprints.ps1 -EnvironmentUrl <dev url>` checks the rule fingerprints. Then `Test-ExposureParity.ps1` checks the exposures after the 06:00 match.
- **Look at it:** open two or three of the new signals in the app. Check that the title reads well, the date and horizon are right, and the readable summary makes sense.
- **Readable summaries:** `pwsh -File setup/dev/Test-ReadableSummaries.ps1 -EnvironmentUrl <dev url>` must report no differences. A new source can bring HTML the readable text doesn't yet handle. For example, the Power Platform blog uses numeric entities such as `&#8217;` for a curly apostrophe. Add a case to `tests/text/readable.json`, extend the table in `engine/ChangeRadar.Text.psm1` (the flow takes it from there), regenerate and deploy the flows, then rewrite the stored text with `-Rewrite`.

New signals raise `signal.new` events, which go into the Monday digest. Ratings and fingerprints follow on the next daily runs, within the per-run caps (`rating_max_per_run`, `fingerprint_max_per_run`).

## 7. Record it

- If the source needed a decision (scope, a new kind of profile key, a theme rule), add a short note to the relevant ADR, or a new one in `docs/decisions/`.
- Commit the row, the profile, the sample and the cases together.

## When none of the kinds fits

Some sources aren't tables, dated sections or feeds: a JSON API, a page that needs a different reading, or a service that needs a token. These need their own adapter (ADR 0014, option A):

- an engine function in `engine/ChangeRadar.Feeds.psm1`, written against expected cases first;
- a collector flow generated by `solutions/design/flows/New-CollectorFlows.ps1`, and a parity check;
- for an authenticated source, the permissions it needs, recorded in `docs/governance/permissions-and-data.md` and agreed before anything is created.

Once this runbook has been used twice for real, it becomes a Claude Code skill (`add-signal-source`; ADR 0014, point 8).
