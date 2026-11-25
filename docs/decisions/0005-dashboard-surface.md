# 0005: Dashboard surface

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0005-dashboard-surface) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=0005-dashboard-surface)

Date: 2026-11-18. Status: **Accepted**, 2026-11-21 (option C; Simon, at the start of phase 6). Drafted in the overnight run.

## Context

Phase 6 replaces the Claude prototype with a dashboard over the Change Radar tables, mirroring the prototype layout (Now / Imminent / Future tabs) plus an "Affected assets" view. Assessments must be overridable with a reason (spec §6), and the dashboard must show the access tier (§3.1) and a "Demo data" badge whenever synthetic or fixture assets are present (§15.2). Spec §10 asks: model-driven app or Power BI?

Verified on Microsoft Learn, 2026-11-18:

- Model-driven apps can host **generative pages**: React/TypeScript pages generated from natural language or by code-generation tools, bound to up to six Dataverse tables, deployable with PAC CLI. ([Generate a page using natural language](https://learn.microsoft.com/power-apps/maker/model-driven-apps/generative-pages); [AI code generation tools](https://learn.microsoft.com/power-apps/maker/model-driven-apps/generative-page-external-tools))
- Model-driven apps can embed **Power BI** dashboards and reports as pages. ([Add a Power BI visual to a model-driven app](https://learn.microsoft.com/power-apps/maker/model-driven-apps/add-powerbi-visual))

## Options

| Option | Overrides | Visuals | Installer burden | Ships in a solution |
|---|---|---|---|---|
| A. Model-driven app with standard views, forms and dashboards | Native (forms, business rules, audit) | Basic charts | Low: Dataverse licence only | Yes |
| B. Power BI report | Read-only; overrides need a separate app | Strong | Power BI Pro/PPU for viewers, a workspace, a gateway-free Dataverse connector; harder to package | Partly (report via Power BI, not the solution) |
| C. Model-driven app with a generative page as the home "radar" view, standard forms for drill-down and overrides | Native | Good: custom layout close to the prototype | Low; generative pages are newer, so check their ALM and preview status | Yes |
| D. A or C plus an optional embedded Power BI report | Native | Strong, for those who have Power BI | Optional | Core yes; report optional |

## Recommendation

**C, with D as a later option.** A model-driven app is the only choice where overrides, the tier banner and the demo badge are first-class and everything ships in `ChangeRadarCore`. A generative page gets close to the prototype's look without Power BI licensing. Keep a Power BI template as an optional extra once the data model settles.

## Consequences

- Phase 6 needs a check on generative page solution-awareness and whether any part is preview; if they can't be packaged cleanly, fall back to A (standard dashboards) without changing tables.
- Views needed: signals by horizon, exposures by signal, exposures by asset, assessments awaiting review, fingerprints in the review queue.
- The "Demo data" badge needs a cheap query (any asset with `source <> live`); the schema keeps `source` as a choice column on asset to make that indexable.

## Requirement from the phase 1 demonstration, 2026-11-19 (Simon)

The phase 1 surface (standard dashboard, ADR 0007) showed live data, but its chart drill-down isn't useful. A standard chart asks which column to break a bar down by, and today's columns (status, source, action required) give flat, single-value breakdowns.

The phase 6 home view must therefore:

- **Filter in place.** Selecting a horizon, source, product or workload filters the list on the same page. It doesn't open a second chart.
- **Drill down by meaningful dimensions.** Use product, workload and area of impact, from signal fingerprints (phase 3), not status columns.
- **Show readable items.** Each item needs its full title, date label and key date, and opens the signal in one click.

Interactive experience dashboards (charts as visual filters on a stream) were considered as an interim step and not built. Their form XML isn't documented for API creation, and phase 3 facets are needed before any drill-down is useful.


## Requirement from the phase 2 demonstration, 2026-11-20 (Simon)

- **Horizons read near to far, left to right: Now, Imminent, Future.** The classic "Signals by horizon" chart can't be made to do this. It draws choice categories as Future, Imminent, Now whatever the chart query or its view sorts by. Two attempts made no difference: a descending order on the chart's `groupby` alias, and an unsorted view for the charts (observed 2026-11-20). The phase 6 generative page must order horizons by option value, not by label.
- The Assets area (Estate assets view plus the asset form's facets and evidence) served the phase 2 demo well. Keep the "what we found, and why we think so" pairing in the phase 6 asset drill-down.


## Phase 6 decisions (Simon, 2026-11-21)

**Generative pages, checked on Microsoft Learn on 2026-11-21:**
- They're solution-aware. They export with the app as "UX Agent Project" rows that hang off the site map, and only the first prompt and the published code travel.
- Dataverse-backed pages aren't preview. Connectors, custom APIs and Application Insights telemetry are.
- The maker-portal designer is limited to US, GB, AU and SG environments. The AI code-generation route (PAC CLI plus Claude Code) is available worldwide.
- The generated code isn't guaranteed production-ready, so we review and test it.

([Generative pages](https://learn.microsoft.com/power-apps/maker/model-driven-apps/generative-pages), [AI code generation tools](https://learn.microsoft.com/power-apps/maker/model-driven-apps/generative-page-external-tools), [FAQ](https://learn.microsoft.com/power-apps/maker/common/faq-generative-pages-model-driven))

**Decisions:**
1. **Option C.** The home "radar" view is a generative page in the Change Radar app. Standard forms stay for drill-down and overrides.
2. **The layout mirrors Simon's prototype mock-up,** which he supplies as a PDF with example visuals. It carries the phase 1 and phase 2 requirements above:
   - filter in place, by meaningful dimensions;
   - readable items;
   - horizons near to far, ordered by option value;
   - findings shown with their evidence.
3. **Fingerprint Accept and Reject** (deferred from phase 3) go on a second generative page, a review queue with buttons on each row.
4. **"Done when" test:** a walkthrough against a checklist, then a week in which Simon uses it for his Monday check without opening the prototype.

**Also in phase 6:**
- the "Affected assets" view;
- the tier banner and the "Demo data" badge;
- friendly labels for Copilot-generated flow names;
- digest capitalisation;
- the app's table components, needed before phase 7 (see ADR 0010).
