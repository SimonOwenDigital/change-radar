# 0019: Licensing guide changes as a signal source

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0019-licensing-guides) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0019-licensing-guides)

Date: 2026-11-23. Status: **Accepted**, 2026-11-23 (Simon: option C with A; the three guides plus Dynamics 365; unrated; keep all history). Options and recommendation by Claude.

## Context

Licensing changes rarely come as Message Center posts with dates. They first appear in the monthly licensing guides: AI Builder end of sale, agent flows becoming workflows, Copilot Chat usage-based billing. Change Radar's nature choice already has `licensing`, but no source feeds it directly.

### Verified (2026-11-23, by fetching the guides; nothing was stored in the repo)

| Guide | fwlink | Resolves to | Last-Modified | Pages | Change log |
|---|---|---|---|---|---|
| Power Platform Licensing Guide | `go.microsoft.com/fwlink/?linkid=2085130` | `cdn-dynmedia-1.microsoft.com/…/bizapps/PowerPlatformLicensingGuide.pdf` | 29 Oct 2026 | 30 | Appendix C, last page |
| Microsoft Copilot Studio Licensing Guide | `…?linkid=2320995` | `…/ai/MicrosoftCopilotStudioLicensingGuide.pdf` | 14 Nov 2026 | 22 | Appendix D, last page |
| Microsoft Copilot Credits Guide | `…?linkid=2368800` | `…/ai/CopilotCreditsGuide.pdf` | 18 Nov 2026 | 40 | Appendix B, last pages |
| Dynamics 365 Licensing Guide | `…?LinkId=866544` | `…/bizapps/Dynamics365LicensingGuide.pdf` | 2 Nov 2026 | 95 | Appendix K, last pages |

- **Stable addresses.** Each fwlink redirects to a fixed PDF address. The file is replaced in place each month, and the cover says the month ("November 2026").
- **Cheap change detection.** An HTTP HEAD on the address returns `Last-Modified`. No download is needed to know whether a guide changed.
- **A structured change log** ends each guide. It's a table with page(s), topic, change, action (New, Update, Remove) and month, newest first. For example, in the Copilot Studio guide:
  - "4 | Copilot Studio | GitHub Copilot harness rebranded as Microsoft Copilot harness | Update | November 2026";
  - "Various | AI Builder | AI Builder End of Sale | Remove | November 2025" (Power Platform guide).
- **Extraction:** text extraction outside Power Platform (pypdf) reads the tables cleanly, though some rows wrap across lines.
- **Inside a flow, two routes:**
  - AI Builder text recognition (OCR), at 0.1 Copilot credit per page;
  - a prompt with the PDF as input (under 50 pages and 25 MB; Learn warns that tables in large documents may be read inaccurately).

  Neither route has been tried in a flow yet.
- **Learn licensing pages** (for example Copilot Studio "Billing rates and management", AI Builder "Licensing and Copilot Credits") are Learn pages, but **not dated**: they're reference pages edited in place. *Correction (2026-11-23): this ADR first said the existing Learn page sections collector could watch them with feed rows only. It can't. That collector needs dated sections, and the tables collector needs dated rows (`docs/add-a-signal-source.md`). These pages need "which section changed", which is the section-hash mechanism of ADR 0018's `webpage_sections` collector.*

## Options

| | What it needs | Pros | Cons |
|---|---|---|---|
| A. Learn licensing pages only | Feed rows for the existing Learn sections collector; no build | Free, today, uses the runbook | Learn pages cover rates and rules, not the guides' offers, end-of-sale and rebrands |
| B. "Guide updated" signal only | A new feed kind that HEADs each guide; on a new `Last-Modified`, one signal "Copilot Studio Licensing Guide updated (November 2026)" linking to the PDF | Simple, deterministic, no credits | A person must read the change log; no detail for matching, the watch list or "Ask Change Radar" |
| **C. One signal per change log row (recommended)** | B, plus: on change, read the PDF's change log and create one signal per new row (external id from guide, topic, change and month) | Each licensing change becomes a signal with its month, product and action, so the watch list, "Ask Change Radar" and (if chosen) matching can use it. Rows are already summarised by Microsoft | PDF reading in a flow needs a spike; about 3 to 4 credits a guide per month (OCR); row wording sometimes wraps or changes |
| D. Compare whole guides | Diff the full text month to month and let an LLM summarise | Catches changes missing from the change log | Costly, noisy and hard to test; against ADR 0004's "LLM only where needed" |

## Proposal: C, with A alongside

1. **A:** the Learn licensing and billing pages (see "The Learn pages" below), through ADR 0018's `webpage_sections` collector.
2. **Spike T12** (read-only, `spikes/T12/`):
   - in a test flow in pp-lab, read the change log from all three guides with AI Builder text recognition, and with a prompt given the PDF;
   - compare both with the pypdf reading;
   - record row accuracy, run time and credits;
   - check the guides' terms for automated reading.
3. **If T12 holds up, build a `pdf_changelog` feed kind** through the runbook:
   - **the row:** URL, the change log heading text and the column order;
   - **the run:** HEAD daily, and read only when `Last-Modified` changes;
   - **the signal:** one per row not seen before. External id `LIC-<guide>-<hash of topic, change, month>`, nature `licensing`, products from the topic, horizon rule `published`, key date the first of the row's month;
   - **tests** in `tests/feeds/` first, from the three guides' November 2026 change logs.
4. **First run:** the change logs go back to 2025. The first run backfills existing rows silently (no events), as watch topics do; later runs raise `signal.new` for new rows only.

## Questions for Simon

1. C with A? Or B only (a "guide updated" alert, read by hand)?
2. Which guides: these three, and also the Microsoft 365 / Microsoft Copilot licensing material (the Copilot Credits guide covers Microsoft Copilot, Copilot Chat and agents) or Dynamics 365?
3. Rated or not: should licensing rows be fingerprinted and rated against the estate (for example "AI Builder End of Sale" against flows that use AI Builder), or stay unrated like announcements (ADR 0018)?
4. Backfill: the silent first run brings in about 15 to 40 rows per guide, back to 2025. Keep them all, or only from a cut-off month?

## Decisions (Simon, 2026-11-23)

1. **Option C with A.**
2. **Guides:** Power Platform, Copilot Studio, Copilot Credits and **Dynamics 365**, checked the same day. Dynamics 365 has 95 pages, over the prompt's 50-page limit, so for that guide only text recognition (OCR) works: about 9.5 credits a read. Spike T12 must test OCR on all four. Other candidates are suggested below for Simon to pick.
3. **Unrated:** licensing rows aren't fingerprinted or rated, like announcements (ADR 0018). They have nature `licensing` and feed the watch list and "Ask Change Radar".
4. **Keep all history:** the silent first run brings in every row in each change log.

### Suggested additions (for Simon to pick; not yet verified)

For A, as Learn pages through the existing collector, data rows only:
- **Copilot Studio:** billing rates and management, and licensing requirements;
- **AI Builder:** licensing and credits, and the capability rate table;
- **Power Platform:** request limits and allocations, pay-as-you-go, Dataverse capacity, and Managed Environments licensing;
- **Power BI and Fabric:** licensing. Power BI changes already reach Change Radar, for example MC1546429.

Later, with ADR 0018's web page collector: the **Microsoft Product Terms** site, the legal source behind the guides. It lists its changes each month.

## The Learn pages (Simon: add all, 2026-11-23)

Checked 2026-11-23: each page resolves, and its title, `ms.date` and `git_commit_id` were read. Samples are saved in `tests/feeds/samples/licensing/`, with the author, reviewer and contributor meta tags removed (they name people).

| Key | Page | Last edited (`ms.date`) |
|---|---|---|
| CS-BILLING | Copilot Studio: Billing rates and management | 30 Oct 2026 |
| CS-LICENSING | Copilot Studio: Get access to Copilot Studio | 27 Oct 2026 |
| AIB-CREDITS | AI Builder: Licensing and AI Builder credits | 8 Oct 2026 |
| AIB-COPILOTCREDITS | AI Builder: Licensing and Copilot Credits | 16 Jun 2026 |
| AIB-RATES | AI Builder: Overview of licensing (capability rate table) | 8 Sep 2026 |
| PP-REQUESTLIMITS | Power Platform: Requests limits and allocations | 10 Nov 2026 |
| PP-PAYG | Power Platform: Pay-as-you-go plan overview | 29 May 2025 |
| PP-CAPACITY | Power Platform: Dataverse capacity-based storage details | 19 Nov 2026 |
| PP-MANAGEDENV | Power Platform: Licensing requirements for managed environments | 31 Aug 2026 |
| PBI-LICENSING | Power BI: service features by license type | 24 Aug 2026 |
| FABRIC-LICENSES | Fabric: Understand Microsoft Fabric licenses and capacity | 15 Jun 2026 |

**Approach:**
- **The collector:** these pages use ADR 0018's `webpage_sections` collector, so spike T11 covers both. Its splitter must work on the Book of News pages and on these Learn pages.
- **Change detection:** on Learn pages, the cheap check is `git_commit_id`; only when it changes are the sections compared.
- **The signal:** one per changed section, for example "Copilot Studio billing rates: 'Copilot Credits billing rates' changed". It is unrated, has nature `licensing` and horizon rule `published`.
- **First run:** records each section's hash silently. Changes raise signals from the second run on.
- **Seed:** the rows are added to `seed/feeds.csv` when the collector exists, not before. An unknown kind would break `Import-FeedsToDev.ps1`.

## Spike T12 outcome (2026-11-23)

Write-up: `spikes/T12/README.md`.
- **The route:** text recognition reads all four guides in a flow, in 3 to 15 seconds each.
- **Accuracy:** 100% of change log words recognised.
- **Rows:** rebuilt by position, 65 of 65 for Power Platform, Copilot Studio and Copilot Credits, and 29 of 33 for Dynamics 365. Its misses are date cells that wrap, a known fix.
- **Cost:** 3 AI Builder credits a guide per read, and 0 Copilot credits while AI Builder credits last.
- **Two flow facts:**
  - the HTTP action doesn't follow the fwlink redirect, so the collector reads `Location`;
  - the `pages` range is ignored, so the collector reads the whole guide.
- **Chosen:** text recognition. The prompt route isn't needed.

## Build outcome (2026-11-23, overnight; confirmed by Simon 2026-11-24)

**Learn pages (A).** All 11 pages are live through `CollectWebSections`: 221 section signals, unrated, nature `licensing`, and parity 11 of 11.
- **Change detection:** a forced re-read of the unchanged pages changed nothing. A simulated changed section (Pay-as-you-go "Next step") updated its signal once, with one version row, one `signal.changed` event and one queued digest run. The test event and run were removed afterwards.
- **Design change from this ADR:** a changed section **updates its signal** rather than creating a new one. That avoids duplicates, and the history is kept in version rows.

**Guides (C).** The `pdf_changelog` feed kind:
- **What was built:**
  - engine `Get-PdfChangeLogSignals`, cases feed-30 to 33;
  - flow `CollectPdfChangeLogs`, daily 05:40 UTC;
  - parity against the saved recognition output.
- **Feeds live in pp-lab:** `LIC-PP` 15 rows, `LIC-CS` 26, `LIC-CC` 24 and `LIC-D365` 32, all from a silent first run, so no events.
- **Later runs:** a second run found every guide unchanged in 10 seconds, so no text recognition and no credits.
- **Model id:** the text recognition model is looked up by template (`TextRecognition`) at run time, not stored.
- **Correction:** the Dynamics 365 count was first written as 33 from a reference extraction that counted a page footer as a row. 32 is right.

**A real changed guide (2026-11-24).** Microsoft updated the Power Platform guide overnight (Last-Modified Tue, 24 Nov 2026 00:57:09 GMT). The scheduled 05:40 UTC run read it once, with one text recognition call; the other three guides were unchanged and skipped.
- **Result:** 5 new signals, all November 2026 rows, each with one `signal.new` event. The 15 existing rows weren't touched.
- **A reworded row:** the October 2026 row "Business Application tools, including Model Context Protocol" reappears as a November "…generally available" row. The new row is a new signal and the October signal is kept, as "keep all" intends.
- **Parity:** the run's recognition output was saved as the new `LIC-PP.json` sample; engine 19 rows, flow "in scope 19, new or changed 5". The 23 November sample is kept as `LIC-PP-2026-11-23.json` for case feed-31; new case feed-34 covers the updated guide.
- **Parity script:** a stored signal the source no longer lists is now reported as kept history, not a difference. That covers pdf_changelog (keep all), entries older than a Learn page's window (M365RN's 25 August entries aged out of `sinceDays` 90 today) and RSS items older than the feed's oldest item. Parity passes on every feed.

**Done-when:**
1. Spike T12: done.
2. Cases pass (21 of 21, with feed-34), with parity 4 of 4.
3. An unchanged guide creates nothing, and a changed guide creates signals only for rows not seen before: shown by Microsoft's real update on 2026-11-24, so no simulation was needed.
4. "Ask Change Radar": **passed on 2026-11-24** (case ask-24). Asked "What changed in Copilot Studio licensing this month?", it named the three November Copilot Studio guide rows, added two Copilot Studio billing page sections updated this month, gave no rating and no prices, and used only `read_query`.

## Done-when

1. Spike T12 records accuracy, run time and credits for both reading routes, with the date checked, and picks one.
2. `tests/feeds/` cases from the November 2026 change logs pass in the engine, and the flow matches the engine (feed parity).
3. In pp-lab, a forced re-read of an unchanged guide creates no signals. A changed guide (simulated by clearing the stored `Last-Modified`) creates signals only for rows not seen before.
4. "Ask Change Radar", asked "What changed in Copilot Studio licensing this month?", answers from those signals (a new case in `tests/ask/`).

## Consequences

- One new adapter (`pdf_changelog`) and one choice value. Each further guide is a data row.
- Credits: about 0.1 Copilot credit per page read with OCR, only when a guide changes (about 9 credits a month for the first three, plus about 9.5 when the Dynamics 365 guide changes). A prompt route, if chosen, would cost a little more. No rating credits: licensing rows are unrated (decision 3).
- A dependency on Microsoft keeping the change log appendix. If it disappears, the feed falls back to B ("guide updated") and says so in the collection run.
