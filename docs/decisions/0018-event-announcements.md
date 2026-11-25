# 0018: Event announcements (Book of News) as a signal source

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0018-event-announcements) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0018-event-announcements)

Date: 2026-11-23. Status: **Accepted**, 2026-11-23 (Simon: option B with watch topics now; Ignite and Build; announcements unrated; kept separate from Message Center posts). Options and recommendation by Claude.

## Context

In spike T10, "Ask Change Radar" was asked what Microsoft will announce at Ignite 2027 and rightly said it didn't know. Simon asked whether Ignite and other Microsoft events with session catalogues could be a source.

What Change Radar sees of events today: one signal in pp-lab mentions Ignite, a Power Platform blog post (checked 2026-11-23). Most announcements reach Change Radar weeks or months later, as Message Center posts and roadmap items. Those carry the dates and the formal wording.

### What's known (2026-11-23)

- **Book of News.** For each major event Microsoft publishes one page listing all the announcements: Ignite 2025 is at `news.microsoft.com/ignite-2025-book-of-news/`, Build uses the same pattern. Verified by web search: the page exists and is the official list of the event's announcements. **Not yet verified:** its HTML structure (headings per product area and per announcement), whether it changes after publication, and whether there's an RSS feed for it.
- **Session catalogues** (Ignite, Build). There is no documented feed or API (web search, 2026-11-23); the session pages load undocumented JSON. Session titles hint at what's coming, but they aren't announcements and they change every year.
- **Change Radar's feed adapters** (ADR 0014) read RSS or Atom, Learn page tables and Learn page sections. A Learn page is detected by its `git_commit_id`. None reads a general web page.

## Options

| | What it needs | Pros | Cons |
|---|---|---|---|
| A. Watch topics only | A watch topic per event ("Ignite", "Build"); no new collector | Nothing to build; uses ADR 0015 | Only catches what already reaches Change Radar (blogs, Message Center); misses the Book of News itself |
| **B. A Book of News collector (recommended)** | A new feed kind, `webpage_sections`: fetch a page, split it into sections by headings, one signal per announcement, detect changes by a hash of each section's text. One `crdr_feed` row per event | Announcements arrive on the day, as signals that fingerprinting, watch topics and "Ask Change Radar" can use. Data, not code, for each new event. Follows the ADR 0014 runbook | A new adapter and choice value; HTML layouts change between events, so each event's row may need a new selector; announcements duplicate later Message Center posts |
| C. Session catalogues | An adapter for the undocumented session JSON | Earliest hints, months before the event | Unofficial, may break or be blocked each year; titles aren't changes; high noise. **Not recommended** |
| D. Do nothing | | | Event news arrives only when Microsoft posts it to Message Center or the roadmap |

## Proposal: option B, with A as an immediate stopgap

1. **Now (no build):** add watch topics "Microsoft Ignite" and "Microsoft Build" in pp-lab, so blog and Message Center items that mention them go on the watch list.
2. **Spike T11** (in `spikes/T11/`, read-only):
   - fetch the Ignite 2025 and Build 2025 Book of News pages;
   - record their structure (headings, anchors, product labels), whether an RSS feed or a structured data block exists, and their terms of use for automated reading;
   - try the section splitter on both, and count the announcements that mention Power Platform or Copilot.
3. **If T11 holds up, build the `webpage_sections` feed kind** (unrated: no fingerprinting, per decision 3) through the runbook:
   - a `feedkind` choice value;
   - a feed profile with the page URL, a CSS-like heading selector, an in-scope filter on product words, and the external id pattern `BON-<event>-<anchor>`;
   - horizon rule `published`;
   - the confidence label "announcement" (spec §3.1);
   - tests in `tests/feeds/` for both pages before the adapter (CLAUDE.md).
4. **Feed rows** for the next events are added by hand when each Book of News is published: Build in May, Ignite in November. Polling is daily for 14 days, then the row is switched off; the page rarely changes after the event week.
5. **Duplicates:** a Book of News signal and the later Message Center post for the same change stay as separate signals in v1. Linking them is a later question (see questions).

## Questions for Simon

1. Option B, with A now? Or A only?
2. Which events: Ignite and Build only, or also others with a Book of News (for example partner events)?
3. Should announcements be fingerprinted and rated like other signals, or stay unrated (as blog items do until fingerprinting widens, ADR 0014) and only feed the watch list and "Ask Change Radar"?
4. Later: link an announcement to the Message Center post that implements it (by title similarity or a manual link), or leave them separate?

## Decisions (Simon, 2026-11-23)

1. **Option B, with the watch topics now.** Done the same day: "Microsoft Ignite" (any of: Microsoft Ignite; at Ignite) and "Microsoft Build" (Microsoft Build only, because "at Build" also matches "fails at build time") are in `seed/watches.csv`, created switched off for new installs, and switched on in pp-lab. Backfill put one older signal on the watch list without a card: the Power Platform blog post that mentions Ignite.
2. **Events:** Ignite and Build only. *Update (Simon, 2026-11-23, after spike T11): Build dropped for now, because no Build Book of News was found for 2025 or 2026. The "Microsoft Build" watch topic stays on, so a new one will show up on the watch list.*
3. **Unrated:** announcement signals are not fingerprinted or rated. They feed the watch list and "Ask Change Radar".
4. **Separate:** an announcement and the later Message Center post stay separate signals.

Spike T11 done (2026-11-23, `spikes/T11/README.md`): the page can be read as an honest client and split reliably (2025: 31 in-scope announcements, 2026: 21), and section hashes are stable. The address pattern changed in 2026, so rows stay hand-added per event. No Build Book of News was found for 2025 or 2026. The same collector covers the Learn licensing pages of ADR 0019. Simon, 2026-11-23: Build dropped for now; reading the pages on the basis of robots.txt (no disallow, 10-second crawl delay) and no specific prohibition is accepted.

## Build outcome (2026-11-23, overnight; confirmed by Simon 2026-11-24)

- **Built:** the `webpage_sections` feed kind. This covers the engine (`Get-WebSectionSignals`, cases feed-20 to 24), the flow (`CollectWebSections`, daily 05:35 UTC) and parity (`Test-FeedParity.ps1`).
- **Feed:** `BON-IGNITE26` is live in pp-lab: 20 in-scope announcements, unrated, with confidence label "announcement".
- **Schema:** feed kinds `webpage_sections` and `pdf_changelog`, and the column `crdr_feed.unrated`. The fingerprint and assess flows skip signals from unrated feeds; this was checked with a run, and 0 unrated signals were picked.
- **Done-when:**
  1. Spike T11: done.
  2. Feed cases pass (20 of 20), and the flow matches the engine on the live page.
  3. One signal per in-scope announcement. A forced second read created no signals and no versions. The first run was silent: 0 events.
  4. "Ask Change Radar": **passed on 2026-11-24** (case ask-23). Asked "What did Microsoft announce at Ignite about Copilot Studio?", it named all three Book of News signals that mention Copilot Studio, including the Windows 365 for Agents item that names it only in the body. It gave no rating, said they are announcements rather than dated changes, and used only `describe` and `read_query`.
- **First scheduled run (2026-11-24, 05:35 UTC):** unchanged, and parity still 20 of 20.

## Done-when

1. Spike T11 records both pages' structure and terms, with the date checked.
2. `tests/feeds/` cases for both pages pass in the engine, and the flow matches the engine (feed parity).
3. A Book of News feed row in pp-lab creates one labelled signal per in-scope announcement, and a second run creates no duplicates.
4. "Ask Change Radar", asked "What did Microsoft announce at Ignite about Copilot Studio?", answers from those signals (a new case in `tests/ask/`).

## Consequences

- One new adapter and one choice value; each later event is a data row.
- Announcements are intentions, not dated changes. Cards and ratings must say so: the "announcement" label and horizon `published` keep them out of the Now and Imminent tiles until a dated Message Center or roadmap item follows.
- Credits: none for collection. Fingerprinting and rating, if chosen in question 3, cost the same as for other signals.
