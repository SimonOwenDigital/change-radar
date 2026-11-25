# 0003: Publisher and table prefix

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0003-publisher-and-prefix) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0003-publisher-and-prefix)

Date: 2026-11-18. Status: **Accepted**, 2026-11-19 (Simon). Option B: publisher Change Radar, prefix `crdr`.

## Context

Every Dataverse table, column, relationship and choice carries the publisher's customisation prefix, and the prefix can't sensibly be changed after a managed release (spec §13.6). The spec uses `mw_` as a placeholder, left over from the rejected "Microsoft Watch" name (§13.1). The app registration name `mw-reader` (§8) has the same problem.

Verified on Microsoft Learn, 2026-11-18 ([Publisher table reference](https://learn.microsoft.com/power-apps/developer/data-platform/reference/entities/publisher)):

- `customizationprefix` is a required text column with a maximum length of 8.
- `customizationoptionvalueprefix` is an integer between 10000 and 99999 and is generated from the prefix; choice values are built from it.

Assumed, not re-verified tonight: the prefix must start with a letter, be alphanumeric, and can't start with `mscrm`.

## Options

| Option | Publisher | Prefix | Tables read | For | Against |
|---|---|---|---|---|---|
| A | Empower Your World (shared by all EYW open-source tools) | `eyw` | `eyw_signal`, `eyw_asset` | One publisher across tools builds the EYW brand; installers see one publisher in their solution list | Collision risk if a future EYW tool also wants a `signal` or `asset` table; Change Radar can't be handed over cleanly without its tables still saying `eyw` |
| B | Change Radar (product publisher) | `crdr` | `crdr_signal`, `crdr_asset` | Stands alone; can move to another maintainer or organisation; no name collisions with other EYW tools | Brand link to EYW is only in docs and the README |
| C | EYW publisher, product-scoped prefix | `eywcr` | `eywcr_signal` | Brand plus collision safety | Longer, less readable; still hard to hand over |

## Recommendation

**Option A (`eyw`)**, matching the spec's own recommendation, **if** Change Radar is expected to stay an EYW-maintained tool. If there is any realistic chance of co-maintenance outside EYW within a year, choose **B (`crdr`)**: the prefix outlives every other naming choice.

Either way:

- Rename the app registration to match (`eyw-changeradar-reader` or `crdr-reader`), not `mw-reader`.
- Record the generated option value prefix in this ADR once the publisher is created.
- Table names in `solutions/design/schema.json` are unprefixed and rendered with whatever prefix is accepted here, so the overnight schema needs no rework.

## Decision

**Option B.** Publisher **Change Radar**, customisation prefix **`crdr`** (so `crdr_signal`, `crdr_asset`, and so on). The app registration is named **`crdr-reader`**, replacing `mw-reader`.

The prefix outlives every other naming choice, and `crdr` keeps the option open for co-maintenance or handover outside EYW. The EYW link lives in the README and docs.

Created in pp-lab on 2026-11-19: publisher unique name `ChangeRadar`, display name "Change Radar", prefix `crdr`, **option value prefix 16989**. Choice values therefore start at 169890000. Every `Solution.xml` must carry 16989: `pac solution init` generates a random value, which has to be corrected by hand.

## Consequences

- Phase 0 can't create tables until this is accepted.
- Changing the prefix after the first managed release means a new set of tables and a data migration for every installer.
- The spec's `mw_` table names and `mw-reader` (§4, §8, §9) read as `crdr_` and `crdr-reader`. `solutions/design/schema.json` now carries `crdr`.
