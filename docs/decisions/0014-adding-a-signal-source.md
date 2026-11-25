# 0014: Adding a signal source

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0014-adding-a-signal-source) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0014-adding-a-signal-source)

Date: 2026-11-22. Status: **Accepted**, 2026-11-22 (Simon: option B, generic feeds as data; feeds on at start: Copilot Studio blog, Microsoft 365 Copilot blog, the three Learn model pages; blog items stay unrated until fingerprinting widens, per ADR 0013 question 4).

## Context

Simon, 2026-11-22: it should be simple to bring in new signal sources, through a documented mechanism, and repeatable steps should later become skills.

Today there are three sources: Message Center and service health through Graph, and the public roadmap JSON. Each is hand-written in `solutions/design/flows/New-CollectorFlows.ps1`. Everything **after** collection is already source-agnostic: fingerprinting, matching, assessment, events, alerts and the Radar page all work on `crdr_signal`.

Adding a source today touches seven places:

1. a new value in the `signalsource` choice, which is a schema change, plus a deploy;
2. a fetch, an in-scope filter and a field mapping (the "shape") in the flow generator;
3. its horizon rule in RecomputeHorizons, whose fall-through branch applies roadmap rules to any source other than Message Center;
4. source names inside the radar engine and the Radar page: incidents and the Future tile;
5. the source labels on the Radar page;
6. configuration and seed rows;
7. tests and a parity check.

Most of that is code, and two of the steps are schema changes. ADR 0013 needs at least two new sources straight away: the Learn model pages, and perhaps blog feeds.

What new sources mostly look like (verified 2026-11-22, see ADR 0013):
- RSS or Atom feeds: the Copilot Studio blog, the Microsoft 365 Copilot Tech Community blog, Azure updates, and Learn search RSS;
- public JSON: the roadmap;
- Learn pages whose `git_commit_id` meta tag changes when they are edited.

Few new sources need authentication or paging the way Graph does.

## Options

| | What a new source needs | Effort per source | Risk |
|---|---|---|---|
| A. Keep one hand-written collector per source, and document it | Generator code, a schema value, horizon code, tests | Medium to high | Low; the familiar route, but every source is a code change |
| **B. Two generic adapters, configured by data** | One `crdr_feed` row: kind, URL, field mapping, filter, products, horizon rule. No code | Low | The mapping language must cover real feeds. Odd sources still need A |
| C. Let an LLM read any page and decide | A URL | Lowest | Credits on every poll, accuracy hard to test, against ADR 0004's "LLM only where needed" |

## Proposal: option B, with A kept for sources that need it

1. **A new table, `crdr_feed`, seeded from `seed/feeds.csv`.** It's data, so nothing tenant-specific is in the solution. Each row has:
   - `key` (prefix for external ids), `name` and `active`;
   - `kind`: `rss`, `atom`, `json` or `learnpage`;
   - `url`, and the item path for JSON;
   - a field mapping (`id`, `title`, `summary`, `link`, `published`, and optionally `keydate` and `status`);
   - a filter on title and summary keywords;
   - default `products`;
   - a horizon rule chosen from a fixed list: `published-informational`, `keydate-thresholds` or `status-roadmap`;
   - the last-seen marker: ETag, last item date or `git_commit_id`.
2. **One generic flow for RSS, Atom and JSON: Collect feeds.** It loops over the active rows of these kinds, fetches each one, and converts RSS or Atom XML to JSON. It then applies the mapping and filter and reuses the existing upsert and run log, unchanged. So version rows, events and fingerprinting all follow automatically.
3. **One generic flow for watched pages: Collect Learn pages.** It does nothing unless the commit id changed. Row extraction is defined per page as a "table profile": which table and which columns. This is what ADR 0013's lifecycle collector is built on.
4. **Schema:** one new `signalsource` value, `feed`, plus a `crdr_feed` lookup on the signal. New feeds then never need a schema change.
5. **Horizon rules by name, not by source.** RecomputeHorizons reads each feed's rule. The current Message Center and roadmap logic becomes two named rules, which also removes the roadmap fall-through.
6. **Tests:** `tests/feeds/` holds saved, redacted sample responses for each kind, with the expected shaped signals. A small engine module, `ChangeRadar.Feeds.psm1`, is the reference for the mapping. Parity compares what the flow wrote with the engine.
7. **The runbook, `docs/add-a-signal-source.md`.** It is written against the real mechanism once the first two feeds are live. It covers:
   - deciding the kind;
   - writing the row;
   - capturing a sample;
   - writing the expected cases;
   - turning the feed on in pp-lab;
   - checking the first run and the parity check.

   It also covers when to fall back to option A: authentication, paging, or nothing to map.
8. **Skills, later.** Once the runbook has been used twice for real, `add-signal-source` becomes a skill. Related skills follow after phase 7:
   - add a matching rule with its test cases;
   - regenerate and deploy the flows;
   - run the parity checks;
   - update a generative page.

## Done when (proposed)

- Two real feeds run from data alone, with no generator change for the second:
  - the ADR 0013 Learn model pages (`learnpage`);
  - the Copilot Studio blog (`rss`).
- A third feed is added by following the runbook and nothing else.

## Questions for Simon (answered 2026-11-22)


1. **Option B, with A kept for odd sources?** (Recommended.)
2. **Which feeds start switched on?** These are proposed and all verified to respond:
   - the Copilot Studio blog RSS;
   - the Microsoft 365 Copilot Tech Community blog RSS;
   - the three Learn model pages from ADR 0013.

   Azure updates and Learn search RSS would be seeded but switched off.
3. **Blog posts carry no fingerprint until fingerprinting goes beyond the test signals** (ADR 0013 question 4). Until then they appear on the radar unrated and unmatched. Is that acceptable for v1?

## Changes after acceptance (Simon, 2026-11-22)

- The Microsoft 365 Copilot Tech Community blog feed returns valid RSS with no items in every URL form, so it's replaced by the **Microsoft 365 Copilot release notes** page, read in dated sections (`learnpage_sections`). It keeps Copilot Chat, extensibility (Agent Builder) and Copilot Studio items, plus any item whose title mentions a model. JSON feeds aren't needed yet, so v1 has three kinds: `learnpage_tables`, `learnpage_sections` and `rss`.
- Lifecycle rows retired more than 90 days ago are skipped (`retiredWithinDays` in each profile).
- Schema deployed to pp-lab: `crdr_feed` (key is the alternate key), choices `feedkind` and `horizonrule`, source value `feed`, lookup `crdr_signal.crdr_feed`. The five feeds are loaded by `setup/dev/Import-FeedsToDev.ps1`, switched off until the collectors are tested.

**Built and checked, 2026-11-22.**

- **The flows.** There are three collector flows, one per kind:
  - Collect Learn page tables;
  - Collect Learn page sections;
  - Collect RSS feeds.

  Each loops over the active feeds of its kind and shares one save-and-log step. It writes one collection run per feed, and one failing feed doesn't stop the rest.
- **Parity.** `setup/dev/Test-FeedParity.ps1` compares the stored signals with the engine on the live sources. All five feeds match: 8, 10, 9, 44 and 10 signals.
- **Found while building:**
  - **The release notes have markup faults.** Sub-bullets break out of their feature into top-level list items. A feature is therefore an item whose first paragraph *starts* with a bold title (`p[1]/node()[1][self::strong]`). The case is in `tests/feeds` (feed-10).
  - **The blog's server serves two cached copies at random,** one built 24 September and one built 27 October. An RSS feed therefore only moves forward: it counts as changed only when its newest item is later than the stored marker. The parity check re-fetches until it gets a copy at least that new.
  - **Workflow expressions are limited to 8,192 characters.** Slugs, ids and de-duplication are worked out in stages, a Select per step, rather than in one expression.

## Consequences

- Two schema changes: the `crdr_feed` table, and the `feed` source value with its lookup. After that, a new feed is a CSV row and a sample file.
- The radar engine and page treat `feed` as a single source. Correction (2026-11-23): the page did not yet know the `feed` value and filed feed signals under Manual (found in the phase 6 walkthrough). It now shows them as one source, "Feeds (Learn pages and blogs)". Listing each feed by name in the filter is still open.
- Hand-written collectors stay where they earn their keep: Graph, and the estate inventory.

## Outcome against "done when" (2026-11-22, confirmed by Simon 2026-11-23)

- **Two real feeds from data alone:** shown. Five feeds run from `seed/feeds.csv` and their profiles: three Learn model tables (`learnpage_tables`), the Microsoft 365 Copilot release notes (`learnpage_sections`) and the Copilot Studio blog (`rss`). The second and later feeds of each kind needed no generator change. Feed parity: all five match the engine.
- **A third feed added by following the runbook alone:** open. `docs/add-a-signal-source.md` is written; which source to add is Simon's choice. Candidates that fit an existing kind with no code are the Power Platform blog's RSS feed and a Learn "what's new" page.
- **Update, 2026-11-22: the third feed, added by following the runbook (Simon chose the Power Platform blog).** `PPBLOG` (`rss`, `published`) needed a row, a one-line profile, a trimmed sample (four items, article bodies and author fields removed) and one expected case, `feed-11`. It needed no engine, profile-key or generator change for collecting: 10 signals, feed parity matches. Following the runbook for real found three things, all fixed:
  - **the runbook:** step 5 now says new feeds are created switched off, and to use `-Activate`;
  - **the runbook:** RSS has no near miss to write;
  - **a latent engine and flow gap:** numeric HTML entities (`&#8217;` and others), which WordPress feeds use, weren't decoded in readable summaries. Case `text-11` was added; the flow now takes the engine's entity table, so they can't drift. Three summaries were rewritten, and all 525 match.
  - Done-when 2 is shown: the feed went live by following the runbook, with the one engine fix that the runbook's own checks caught.
