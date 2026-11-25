# 0015: Watch list (alerts on items and topics you follow)

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0015-watch-list) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0015-watch-list)

Date: 2026-11-23. Status: **Accepted**, 2026-11-23 (Simon's idea; design by Claude; Simon chose the recommended option for all four choices). Build after phase 6 is accepted, before packaging.

## Context

Change Radar alerts by **impact on the estate**: incidents, High or Critical ratings, deadlines and model changes (ADR 0011, ADR 0013). Some changes matter for another reason: interest. Simon's example is Copilot Autopilot. He wants to know when anything says when it will land in his region or his tenant, and to be told when items he has already read are updated.

Today, an update to a signal raises `signal.changed`, and a new signal raises `signal.new`. Both go only to the Monday digest, among everything else. Nothing lets a person say "this one matters to me".

## Proposal

Two kinds of watch. Both use events and handlers that already exist.

1. **Watch an item.** You mark a signal you've read as watched. From then on, any change to it raises a card:
   - its date, wording, status or horizon (`signal.changed`);
   - a new exposure;
   - a new rating.

   The card says what changed, for example "Rollout moved from December to February".
2. **Watch a topic.** A named watch, such as "Copilot Autopilot in the UK", with:
   - **any of** these words, such as `Autopilot`;
   - optionally, **also one of** these words, such as `UK`, `United Kingdom`, `Europe`, `EU`, `region`, `rollout` or `general availability`;
   - optionally, **none of** these words, such as `Windows Autopilot`, the Intune device feature that shares the name;
   - optionally, products.

   Every new or changed signal is checked against the topics by word match on its title and readable summary. This costs no credits. A match raises a card, and the signal is then watched automatically, so its later updates arrive too.

**Events:**
- `watch.matched`: a signal matched a topic for the first time;
- `watch.updated`: a watched signal changed.

Both go to Notify-Teams and to a new "Watch list" section in the Monday digest. Where cards go follows the alert destinations proposal (ADR 0011 addendum).

### What "lands in my tenant" can and can't mean

- **It's coming to your tenant:** Message Center posts are sent only to tenants they apply to. So a Message Center post matching the topic is the tenant-specific signal. A roadmap item is generic.
- **When:** rollout dates and status changes on a watched item are `watch.updated` cards.
- **It has arrived:** this can only be detected when the feature shows up as something Change Radar reads, such as a new admin setting or a new kind of asset in the inventory. A topic can name a setting key, and a setting exposure appearing is then reported as "landed". Each feature needs checking against Microsoft Learn first. For Copilot Autopilot, that research hasn't been done.

## Options (decided by Simon, 2026-11-23: the recommended option each time)

1. **Scope:** both kinds (recommended), or watched items only first.
2. **Where you mark a watch:**
   - a Watched switch on the signal form, and topic rows in a Watch list view (recommended to start; no new page);
   - or also a Watch button on the Radar page, which would make the page write one column, as the Fingerprint review page does.
3. **Card timing:** one card per change (recommended; watched items are few), or one bundle a day.
4. **Whose watch:** one shared watch list for the install (recommended for v1, matching the single alert recipient), or per person. Per person follows the alert destinations work.

## Build outline (once decided)

1. Expected cases first, in `tests/watch/`:
   - matches and near misses, including Windows Autopilot;
   - a word inside another word;
   - British and American spellings;
   - an update to a watched item, and an update that changes nothing visible.
2. Engine: `Test-WatchMatch` and the card text, in `engine/`.
3. Schema:
   - a `crdr_watch` table (name, any-of, also-one-of, none-of, products, setting key, active);
   - on `crdr_signal`, a Watched flag and a "watched because" lookup to the watch;
   - the two event types.
4. Flows:
   - topic check in the collectors' change step;
   - the Notify-Teams and digest branches;
   - the subscriptions.
5. Parity checks, and a done-when on a labelled test topic.

**Done when (proposed):**
- A test topic matches a labelled test signal and raises one card.
- An update to a watched item raises one card that says what changed.
- A Windows Autopilot near miss raises nothing.

## Consequences

- No credits are used: matching is by words, not the LLM. The cost of that is that a topic needs good words. The "none of" list is how near misses are handled.
- It adds one table, two event types and two handler branches. It's read-only against the tenant, as now.
- Suggested placement: after phase 6 is accepted, before packaging, because packaging docs should describe it.

## Built, 2026-11-23 (Simon: carry on while the Monday checks run)

**What changed from the proposal, and why:**
- **"None of" became "ignore these phrases".** The phrases are removed from the text before the check, rather than ruling the signal out. A post about Windows Autopilot alone doesn't match. A post that mentions both Windows Autopilot and Copilot Autopilot still does (case `wm-03`). Ruling it out would have hidden that post.
- **Opted out stays out.** Switching Watched off on a signal that a topic matched keeps the "Watched because of" link, and the flow never re-adds it (case `we-08`). Without this, the next change to the signal would put it straight back.
- **What raises watch.updated:** any change the collectors record on a watched signal: title, horizon, status (date label), action required, key date, or only its wording. The card names the fields, or "wording". A new exposure or rating on a watched signal is **not yet** a watch card. High and Critical ratings already send their own card, and the rest go to the digest. Adding them would touch the match and assess flows, the largest ones (ADR 0016); left for later if wanted.
- **The setting key for "landed" is not built.** It waits until a feature's admin setting is known (see "What lands in my tenant" above).
- **What "words" means:** the text is the title plus the readable summary, lower-cased, with punctuation turned into spaces. A term matches whole words only: "UK" doesn't match "Ukrainian" (`wm-05`). A phrase matches across a hyphen (`wm-11`). There are no automatic spelling variants, so list both "organisation" and "organization" if you want both (`wm-09`, `wm-10`).

**Built:**
- **Engine:** `engine/ChangeRadar.Watch.psm1`:
  - `Test-WatchMatch`, `Get-WatchEvents` and `Format-WatchChange`;
  - the punctuation table, which the flow generator reads, so the two can't drift;
  - the watch cards and digest lines in `ChangeRadar.Events.psm1`.
- **Cases, all passing:**
  - `tests/watch/watch.json`: 17 match cases, 8 event cases, 5 change-wording cases;
  - `tests/events`: `card-wm-01`, `card-wu-01`, `card-wu-02`, `digest-wm-01` and `digest-wu-01`.
- **Schema (pp-lab):**
  - a `crdr_watch` table: name, any of, and one of, ignore these phrases, products, active, description;
  - on `crdr_signal`: `crdr_watched`, `crdr_watch` (lookup, "Watched because of") and `crdr_watchedon`;
  - event types `watch.matched` and `watch.updated`.

  Dataverse names the entity set `crdr_watchs` (`verified-facts.md`).
- **Flows:**
  - **raise signal events** (one per signal version row) now also:
    - reads the readable text, using the same steps as the readable summary flow, now a shared generator function;
    - checks the active topics by name;
    - puts a match on the watch list and raises `watch.matched`;
    - raises `watch.updated` for a watched signal that changed.
  - **Notify-Teams** has both cards. The **digest** has the "Added to your watch list" and "Watched items updated" sections. There are four new subscriptions in `seed/subscriptions.csv`.
- **App:**
  - the Radar menu has **Watched signals** and **Watch list** (topics);
  - the signal form has a Watch list section, where **Watched** can be switched on or off by hand;
  - a watch form describes each field.
- **Seed:** `seed/watches.csv` holds "Copilot Autopilot in the UK" as an example. `setup/dev/Import-WatchesToDev.ps1` creates a watch only when it's missing, never edits one, and creates it switched off unless `-Activate` is given. In pp-lab it is on.
- **Dev scripts:**
  - `Test-WatchList.ps1` checks the stored watch list against the engine. `-Backfill` puts older matching signals on the list without events or cards, because the flow only checks signals when they arrive or change.
  - `New-TestSignals.ps1 -Scenario watch | watchupdate` runs the done-when on a made-up word ("Zephyrpilot"), so no real topic or signal is involved. `Remove-TestSignals.ps1` also removes the test topic.

**Backfill in pp-lab:** eight existing signals match "Copilot Autopilot in the UK" and are now watched, without cards:
- MC1557730 "Autopilot availability in Frontier";
- MC1530609 "Engage plugin for Copilot Cowork and Autopilot: General availability";
- MC1546354 "Discover usage-based billing (UBB) experiences like Cowork, Code, and Autopilot";
- MC1479277, MC1484008, MC1492151, MC1511052 and MC1557727.

## Outcome against "done when" (2026-11-23)

**Confirmed by Simon, 2026-11-23.**

| Done when | Evidence | Status |
| --- | --- | --- |
| A test topic matches a labelled test signal and raises one card | Test topic "[TEST] Zephyrpilot in the UK". TEST-WATCH-0001 raised `watch.matched` and Notify-Teams posted the card ("On your watch list: …"). | Shown |
| An update to a watched item raises one card that says what changed | TEST-WATCH-0001's key date moved, and one `watch.updated` card read "TEST-WATCH-0001 changed: key date." | Shown |
| A Windows Autopilot near miss raises nothing | TEST-WATCH-0002, "Windows Zephyrpilot device preparation in the UK", raised only its normal `signal.new` (digest), with no watch event (case `wm-02` for the real wording). | Shown |

- **Event parity:** passes. The `watch.updated` card matches the engine field by field. The `watch.matched` card is listed as skipped, because its signal changed after it was sent. Its first comparison differed only in the key date, which had moved, and in the watch name, which the parity script didn't yet pass to the engine (fixed).
- **Test rows:** removed afterwards.
- **No new permissions:** everything writes only Change Radar's own tables in pp-lab. The reader role gains read on `crdr_watch` the next time `New-ReaderIdentity.ps1` runs. It isn't needed, because the flows run under their own connection.
