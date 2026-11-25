# 0007: Signal horizons and the phase 1 demonstration

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0007-signal-horizons) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0007-signal-horizons)

Date: 2026-11-19. Status: **Accepted**, 2026-11-19 (Simon).

## Context

Phase 1 is done when "the prototype's Now and Imminent tabs work from live tenant data" (spec §9). The prototype isn't in the repo, so its horizon rules can't be copied. `crdr_signal.horizon` is a choice with the values `now`, `imminent` and `future`.

The inputs differ by source:

- **Service health issues:** open or resolved, with a start time and a classification (incident or advisory).
- **Message Center posts:** `actionRequiredByDateTime` is optional, and `startDateTime` and `endDateTime` are always present.
- **Roadmap items:** dates are month precision only (spike T3), with a `status` of In development, Rolling out, Launched or Cancelled.

## Decision

The horizon is computed by rule, at collection time and again daily, so items move from Imminent to Now as their dates approach.

| Horizon | Rule |
|---|---|
| **Now** | Service health issue that isn't resolved (incident or advisory). Message Center post whose action-required date is in the past or within `horizon_now_days`. |
| **Imminent** | Message Center post whose action-required date (or start date if there's none) is within `horizon_imminent_days`. Roadmap item with status Rolling out, or a GA month within `horizon_imminent_days`. |
| **Future** | Everything else, including resolved incidents (kept for history and the digest). |

Thresholds are installer-editable `crdr_config` rows:

- `horizon_now_days` = 14
- `horizon_imminent_days` = 90

**Demonstration surface for phase 1:**

- A minimal model-driven app, "Change Radar", in `ChangeRadarCore`, with "Now" and "Imminent" system views on Signals.
- An example clickable dashboard: a standard Dataverse dashboard with charts by horizon and source, and lists that drill into the signals behind them.

Phase 6 builds on this app. ADR 0005 (generative page as the home view) is still the plan for phase 6.

## Amendment, 2026-11-19 (Simon): Message Center Imminent rule

The first live collection put 221 of 224 in-scope Message Center posts in Imminent. A post's `startDateTime` is its **publish date**, not a rollout date, so it's almost always in the past and always "within 90 days". Only 7 of 224 posts carry `actionRequiredByDateTime`. Rollout dates appear only in the body text, which phase 3 extraction can handle.

The rule for Message Center posts is now:

| Horizon | Rule |
|---|---|
| **Now** | Action-required date in the past or within `horizon_now_days` (unchanged) |
| **Imminent** | Action-required date within `horizon_imminent_days`, **or** a `planForChange` post published within `horizon_recent_days` (new config row, 30) |
| **Future** | Everything else, including `stayInformed` posts |

On live data this gives 5 Now and about 27 Imminent. The date label records the category ("Plan for change · published", "Stay informed · published") so that the daily recompute can apply the same rule from stored columns.

## Amendment, 2026-11-19 (Simon): roadmap Imminent window

At the phase 1 demonstration, roadmap items were 69 of 91 Imminent signals, which crowded out Message Center. Roadmap items now use their own window, `horizon_roadmap_days` (new config row, 45), in place of `horizon_imminent_days`, which now applies to Message Center action dates only.

On live data this moves only 5 items. GA dates are month precision, stored as the first of the month, so a 45-day window still covers the next two months. And 39 of the 62 remaining "In development" items have a GA month that has already passed (slipped items), which any forward window counts as due.

**Slipped items (Simon, 2026-11-19).** A roadmap item still "In development" whose GA month started before the current month is **slipped**. Its date label becomes "Slipped · In development · GA <month>" and it stays in **Future**. The roadmap collector applies this when it writes an item. The daily recompute applies it as months roll over, because Microsoft doesn't always edit an item when its date slips. On live data, roadmap Imminent drops from 69 to about 25.

## Consequences

- A daily recompute is needed, because a horizon depends on today's date and not only on the item. It runs in the roadmap flow or as a small scheduled flow.
- Resolved incidents leave Now automatically once the health flow sees them resolved.
- The rules are assumptions until Simon compares the Now and Imminent views against his experience of the prototype at the phase 1 demonstration. Tune the thresholds before changing the rules.
