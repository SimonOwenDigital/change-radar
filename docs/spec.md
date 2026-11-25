# Change Radar for Power Platform & Copilot: build spec

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=spec) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=spec)

Status: draft v0.4, 18 Nov 2026. Written for Claude Code working in the `change-radar` repo (§13.5).

**Changes in v0.4:** synthetic and demo estates added (§15), including a file-based estate adapter, a fixture estate and a matching test suite.

**Changes in v0.3:** name accepted (Change Radar). Access tiers added so people without tenant admin rights can still use it with public sources (§3.1). Repo decision: dedicated repo under an EYW GitHub organisation, private until release (§13.5). Publisher and table prefix flagged as an early decision (§13.6).

**Changes in v0.2:** linking to the risk-sizing app moved to a later enhancement (E1). Added backlog matching (E2), packaging for public distribution (§13) and an event layer so changes can trigger other activities (§12). Working name flagged for review (§13.1).
Prototype: the "Change Radar: Power Platform & Copilot" dashboard built in Claude (snapshot data, generic impact ratings).

This spec separates **verified** platform facts (checked against Microsoft Learn on 18 Nov 2026) from **design proposals** and **things to test in pp-lab**. Do not treat the proposals as settled.

---

## 1. Purpose

Answer three questions continuously, for Simon's own tenant first:

1. **What is changing?** Incidents now, Message Center changes coming soon, roadmap items further out.
2. **Does it touch anything I run?** Match each change against the actual estate: environments, solutions, apps, flows, Copilot Studio agents, connectors and settings.
3. **So what?** Rate the impact *on this estate* (not a generic estate), name the affected assets with evidence, and say what to do.

The prototype answers question 1 and gives a generic answer to question 3. The build adds question 2, which is the part that's actually new.

### Principles

- **Read-only.** Nothing in this build changes the tenant. Every identity gets read permissions only.
- **Evidence before interpretation.** Every exposure links to the asset, the field that matched, and the rule that matched it. LLM output is labelled as assessment, not fact.
- **Don't rebuild what Microsoft ships.** Use Power Platform inventory and the Copilot Studio Kit's Agent Inventory where they already give the data.
- **Estate metadata stays in the tenant by default.** See §8 for the decision on where the LLM runs.
- **Built to be installed by others.** Nothing tenant-specific in the solution. Every identity, threshold, vocabulary term, rule and channel is configuration, not code (§13).
- **Act through events, not hard-wired steps.** Every meaningful change raises an event that other flows can subscribe to. Actions that write anything are opt-in and off by default (§12).
- **Official sources first, public fallbacks second.** With admin rights, everything comes from Graph and Microsoft's public roadmap API. Without them, Change Radar falls back to public sources and says plainly what it can't see (§3.1).

---

## 2. Architecture

```
 SIGNALS (what is changing)                ESTATE (what I run)
 ┌───────────────────────────┐            ┌───────────────────────────────┐
 │ Graph: service health      │            │ Power Platform inventory       │
 │ Graph: Message Center      │            │   (apps, flows, agents,        │
 │ AI at Work roadmap (RSS/API)│           │    connectors, environments)   │
 │ Blogs (RSS), manual signals │           │ Dataverse per environment      │
 └─────────────┬─────────────┘            │   (solutions, bot, botcomponent,│
               │                           │    connection refs, PCF, flows) │
               ▼                           │ Agent Inventory (Copilot Kit)   │
      ┌──────────────────┐                 └───────────────┬───────────────┘
      │ 1. COLLECT        │◄───────────────────────────────┘
      │ flows → Dataverse │
      └────────┬─────────┘
               ▼
      ┌──────────────────┐   signal fingerprint   ┌──────────────────┐
      │ 2. FINGERPRINT    │──────────────────────►│ 3. MATCH          │
      │ signals + assets  │   asset fingerprint   │ exposure records  │
      │ → shared vocabulary│─────────────────────►│ with evidence     │
      └──────────────────┘                        └────────┬─────────┘
                                                           ▼
                                                  ┌──────────────────┐
                                                  │ 4. ASSESS         │
                                                  │ estate-specific   │
                                                  │ impact + action   │
                                                  └────────┬─────────┘
                                                           ▼
                                         ┌───────────────────────────────┐
                                         │ 5. PRESENT & ALERT             │
                                         │ dashboard, Teams cards, digest │
                                         └───────────────────────────────┘
```

---

## 3. Sources and access

### Verified (Microsoft Learn, 18 Nov 2026)

| Source | What it gives | Auth | Notes |
|---|---|---|---|
| Graph `/admin/serviceAnnouncement/issues`, `healthOverviews` | Tenant incidents and advisories | `ServiceHealth.Read.All`, delegated or application | Covers Power Platform, Dataverse, Copilot services |
| Graph `/admin/serviceAnnouncement/messages` | Message Center posts for the tenant | `ServiceMessage.Read.All`, delegated or application | Only shows services the tenant subscribes to |
| Power Platform inventory (`PowerPlatformResources`) | Canvas, model-driven, code and managed apps; cloud, agent and workflow agent flows; Copilot Studio agents; Power Pages; connectors; environments | **Inventory API and "Query Power Platform resources" action: delegated user only.** Service principal or managed identity returns HTTP 403 | Also reachable via `pac resource-query query-resources` (preview) and Azure Resource Graph |
| Connector inventory (within the above) | Connectors and connector operations per resource, plus the trigger connector for flows | As above | Covers apps, flows, Copilot Studio agents and Agent Builder agents |
| Dataverse Web API, per environment | `solution`, `solutioncomponent`, `bot`, `botcomponent`, `workflow`/`processes`, `connectionreference`, `customcontrol`, `environmentvariabledefinition` | Application user (service principal) with a read-only security role | Needed for component-level detail inventory doesn't give |
| Copilot Studio Kit: Agent Inventory | `cat_agentdetails`: orchestration type, uses MCP, maker vs invoker auth, autonomous triggers, HTTP actions, prompts, knowledge sources | Kit's connection references (Power Platform admin, plus system admin per environment for full detail) | Already derives most of the agent fingerprint this build needs. Install it rather than rebuild it |
| Power Platform API, other endpoints | Environment management, settings | Delegated permissions, or service principal plus a Power Platform RBAC role (RBAC is preview) | Service principals are treated like a Power Platform Administrator and can't be scoped further |

### 3.1 Access tiers

Not everyone who wants to try Change Radar can grant tenant-wide permissions. It detects what the installer can reach and runs in the richest tier available, showing the tier on the dashboard so nobody mistakes partial coverage for full coverage.

| Tier | Who it's for | Signals | Estate | What's missing |
|---|---|---|---|---|
| **Full** | Global/Power Platform admin able to consent to an app registration | Graph service health + Message Center, roadmap API, blogs | Tenant-wide inventory + Dataverse detail + Agent Inventory | Nothing |
| **Reader** | Someone with a lesser admin role, e.g. Message center reader (and Service support admin or Global reader for service health), but no app consent | Graph Message Center (and service health if role allows) under the user's delegated connection, roadmap API, blogs | Only environments where the user has access | Tenant-wide estate; unattended running |
| **Maker** | A maker with no admin role | Public sources only (below) | Environments, apps, flows and agents the user owns or can see, via their own connections | Tenant-specific Message Center, tenant service health, other people's assets |
| **Public** | Anyone, no tenant connection | Public sources only | None, so generic impact only (as in the prototype) | All estate matching |

**Public sources (fallback) and how to use them responsibly**

| Source | Covers | Use |
|---|---|---|
| AI at Work roadmap RSS/API | Roadmap, including Power Platform since Sept 2026 | Official; available in every tier |
| Azure status RSS; status.cloud.microsoft link | Major outages | RSS official; the M365 status page is JavaScript-only, so link to it |
| Community Message Center archives (msmessagecenter.com, mc.merill.net, others) | Every tenant's Message Center posts | Use only their published feeds or APIs, never HTML scraping. Check each site's terms, credit the source on every item, and contact the maintainers before shipping an adapter (both are MVP community projects). Each adapter ships disabled until the installer turns it on |
| Official blogs (Power Platform, Copilot Studio, M365 Copilot) | Announcements and context | RSS |

Community-sourced items are tagged with their source and lower confidence, and the dashboard labels them "community archive".

### To test in pp-lab before committing

- **T1.** Can a service principal with Azure `Reader` query `PowerPlatformResources` *directly* in Azure Resource Graph, bypassing the delegated-only inventory API? If yes, collection can run unattended. If no, use the delegated pattern in §8.
- **T2.** Does Graph expose an inventory of M365 Copilot agents (Agent Builder and declarative agents) outside Power Platform inventory? Inventory already includes Agent Builder agents, so this may be unnecessary.
- **T3.** Roadmap JSON API schema since the AI at Work rename: field names for products and tags, and whether Power Platform items carry consistent tags.
- **T4.** Copilot Credits reporting API (preview, Message Center MC1558020): endpoint, auth model and granularity. It's a candidate source for consumption exposure.

---

## 4. Dataverse data model (proposal)

Publisher prefix `mw_`. *(Superseded 2026-11-19 by ADR 0003: prefix `crdr`, app registration `crdr-reader`. Read `mw_` in this spec as `crdr_`.)* All tables live in one unmanaged solution, `ChangeRadar`, in the pp-lab environment.

| Table | Purpose | Key columns |
|---|---|---|
| `mw_signal` | One row per external change | source (Graph MC / Graph health / roadmap / blog / manual), external id (MC…, RM…, MO…), title, summary, product, horizon, key date, date label, action required, url, first seen, last changed |
| `mw_signalversion` | History, for change tracking | signal, snapshot JSON, captured on, changed fields |
| `mw_signalfingerprint` | What a signal touches, in the shared vocabulary | signal, facet (see §5), value, extracted by (rule / LLM), confidence |
| `mw_asset` | One row per estate resource | type, name, environment, environment type (prod/sandbox/dev/default), solution, managed, owner, last modified, source id, source (live / fixture / synthetic), synthetic org, criticality (optional; populated by E1 later) |
| `mw_assetfingerprint` | What an asset uses, in the shared vocabulary | asset, facet, value, evidence (source field) |
| `mw_exposure` | Signal × asset match | signal, asset, matched facets, rule, evidence text, status (new / confirmed / dismissed) |
| `mw_assessment` | Estate-specific rating per signal | signal, generic impact, estate impact, nature, affected count, rationale, recommended action, model/version, assessed on, Simon override, override reason |
| `mw_rule` | Deterministic matching rules | name, signal facet, asset facet, condition, active |
| `mw_alertlog` | What was sent where | signal, channel, sent on, severity |
| `mw_event` | Events raised for subscribers (§12) | event type, signal, exposure, assessment, payload JSON, raised on, correlation id |
| `mw_subscription` | Which handler runs for which events | event type, filter (product, minimum estate impact, nature), handler (flow name), enabled, writes (yes/no) |
| `mw_config` | Installer-editable settings | key, value, description (poll intervals, thresholds, products in scope, digest day) |

Design note for E1 (later): keep `mw_asset` keyed on stable source ids (environment id + resource id + solution unique name), so a later link to the risk-sizing app needs no rework. Don't build the link in v1.

---

## 5. Matching: the shared vocabulary

The core design move: describe signals and assets **in the same small vocabulary**, then match deterministically. Use the LLM only for the hard part, which is turning a Message Center post into facets.

### Facets (v1)

| Facet | Example values | Asset source |
|---|---|---|
| `product` | Power Apps, Power Automate, Copilot Studio, Dataverse, Power Pages, M365 Copilot, Power BI | inventory `type` |
| `resource_type` | canvas app, model-driven app, code app, cloud flow, agent flow, desktop flow, agent | inventory `type` |
| `connector` | shared_sharepointonline, shared_office365, shared_commondataserviceforapps, custom | connector inventory |
| `capability` | uses_mcp, generative_orchestration, autonomous_trigger, http_action, ai_prompt, custom_knowledge, file_input, pcf_control, scheduled_prompt, sharepoint_tempauth | Agent Inventory booleans, `customcontrol`, flow definitions |
| `auth_mode` | maker, invoker, service_principal, user_owned_production | Agent Inventory auth context, flow owner type |
| `harness` | standard, microsoft_copilot | inventory/agent properties |
| `setting` | anthropic_subprocessor, copilot_in_power_bi, copilot_spending_policy | tenant settings (manual at first) |
| `environment_type` | production, sandbox, developer, default | inventory environment |

### Worked examples from the prototype's current items

| Signal | Signal fingerprint | Matches assets where… |
|---|---|---|
| MC1551122 SharePoint tempauth end of support | product=Power Apps/Power Automate; capability=pcf_control; connector=shared_sharepointonline | canvas apps with a custom PCF control **and** SharePoint connector; custom connectors loading SharePoint content |
| MC1557509 Copilot Studio service principal auth | product=Copilot Studio; auth_mode=user_owned_production | Copilot Studio workflows in production environments owned by a named user |
| MC1548034 third-party connections in agent chat | product=Copilot Studio; harness=standard; capability=custom_web_ui | agents on the Standard harness published to a custom web channel |
| RM570671 Work IQ granular MCP policies | capability=uses_mcp | agents where Agent Inventory `UsesMCP = true` |
| MC1550533 scheduled prompts move off Power Platform | capability=scheduled_prompt | flows created by Copilot scheduled prompts (identify the pattern in T5) |
| MC1557754 / MC1558033 Copilot Credits | setting=copilot_spending_policy; product=M365 Copilot | tenant has, or lacks, a spending policy covering the service. This is a setting check, not an asset match |

- **T5.** Find a reliable signature for Copilot scheduled-prompt flows in Dataverse (trigger and connector pattern).

### Rules

1. **Deterministic first.** `mw_rule` rows express facet joins. Each exposure records the rule and the evidence field, so it can be checked.
2. **LLM for fingerprinting signals only.** Given a Message Center post, return facets from the fixed vocabulary as JSON, with a confidence for each. Reject values outside the vocabulary. Anything below the confidence threshold goes to a review queue, not straight to matching.
3. **Never let the LLM invent assets.** It never sees free text about the estate when proposing a match. It sees facets and returns facets.

---

## 6. Assessment: generic versus estate impact

Keep both ratings. They answer different questions.

- **Generic impact** (as in the prototype): how much this matters to a typical enterprise. It feeds content and advisory opportunity.
- **Estate impact**: how much this matters to *this* tenant. Proposed scoring, to be calibrated:

```
estate_impact =
  if no exposure and no setting match      → None (shown greyed, kept for content value)
  else max over exposed assets of
       generic_impact
     + 1 if environment_type = production
     + 1 if asset criticality ≥ high   (only once E1 exists; ignored in v1)
     + 1 if action_required and key date ≤ 30 days
  mapped to Low / Medium / High / Critical
```

- The LLM writes the **rationale and recommended action** from structured inputs: signal, exposures and evidence. It doesn't produce the score.
- **Override.** Simon can raise, lower or dismiss any assessment, with a reason. Overrides are stored and become calibration data for the rules and the prompt.
- **Opportunity lens.** Keep the prototype's opportunity line. Add a facet linking signals to EYW assets (journey, pattern, talk) when they're relevant.

---

## 7. Alerting

| Trigger | Channel | Timing |
|---|---|---|
| Service incident on Power Platform, Dataverse or Copilot services, any severity | Teams adaptive card to a private channel | Within 15 minutes of the poll |
| New or changed Message Center post with estate impact High or Critical | Teams adaptive card listing the affected assets | Next poll |
| Action-required key date in 14 days or 3 days, with estate exposure | Teams card | Daily check |
| Roadmap item changed date or status, with estate exposure | Weekly digest | Monday morning |
| Everything else | Weekly digest | Monday morning |

Adaptive card: the title, why it matters to you (the affected assets, max 5, with links), key date, recommended action, and buttons for **Acknowledge**, **Dismiss** and **Open dashboard**.

---

## 8. Identity, security and the LLM decision

### Identities (proposal)

| Job | Identity | Why |
|---|---|---|
| Graph service health and Message Center | App registration `mw-reader`, application permissions `ServiceHealth.Read.All`, `ServiceMessage.Read.All` | Unattended, least privilege |
| Power Platform inventory | **Delegated** connection under Simon's admin account (or a dedicated read-only admin account) in Power Automate | The inventory API rejects service principals (verified). Re-test with T1 |
| Dataverse component detail | `mw-reader` as an application user in each environment, with a custom read-only security role | Service principals are supported for Dataverse |
| Agent Inventory (Copilot Studio Kit) | The kit's own connection references | Follow the kit's documented permission model |

Secrets go in environment variables backed by Key Vault, or certificate auth. Never in flow definitions or the repo.

### Decision needed: where does the assessment LLM run?

| Option | Data boundary | Cost | Fit |
|---|---|---|---|
| A. Prompt actions in Power Automate (AI Builder/Copilot credits) | Stays in the Microsoft tenant boundary | Copilot credits (the EYW MVP pack) | Dogfooding; good EYW story |
| B. Claude via API, called from a flow or a script | Estate metadata (names, facets) leaves the tenant for Anthropic | Per-token | Stronger reasoning; adds a data-processing decision |
| C. Hybrid: A for fingerprinting and routine ratings, Claude Code on demand for deep analysis on exported, minimised data | Mostly in the tenant | Low | Recommended starting point |

Asset names may reveal client or project names in some environments. Minimise what goes to any LLM: send facets, not descriptions.

---

## 9. Build phases

Each phase ends with a working, demonstrable increment.

| Phase | Scope | Done when |
|---|---|---|
| 0. Foundations | Publisher and prefix (§13.6), solution, tables, `mw-reader` app registration, application user in pp-lab, secrets | Solution exports cleanly to the repo; app can read Graph |
| 1. Signals live | Tier detection (§3.1); flows: Graph service health (15 min), Graph Message Center (hourly), roadmap API (daily) → `mw_signal` + `mw_signalversion` | The prototype's "Now" and "Imminent" tabs work from live tenant data |
| 1b. Synthetic estate | File-based estate adapter + generated synthetic estate (§15) | Matching can be developed and demonstrated before the real estate is large enough |
| 2. Estate inventory | Delegated inventory query flow → `mw_asset` + connector facets; Dataverse detail per environment; Agent Inventory read | Every app, flow and agent in the tenant appears with facets and evidence |
| 3. Matching | Fingerprint signals (LLM, fixed vocabulary, review queue); `mw_rule` joins → `mw_exposure` | The six worked examples in §5 produce correct exposures (or a correct "none") |
| 4. Assessment | Estate impact scoring; LLM rationale; override UI | Each exposed signal has an estate rating, a rationale and an action; overrides persist |
| 5. Alerts and events | Teams cards and weekly digest per §7; `mw_event` raised for every new signal, exposure and assessment; two read-only reference handlers (§12) | A test incident and a test Message Center post each trigger the right card and the right events |
| 6. Dashboard | Model-driven app or Power BI over `mw_` tables, mirroring the prototype layout plus an "Affected assets" view | Simon uses it instead of the prototype |
| 7. Package and publish | Managed solution release, deployment settings template, setup script, docs (§13), GitHub repo with Actions | A clean test tenant installs from the README alone, without help, in under an hour |

Phases 0–6 run in Simon's tenant. Phase 7 proves someone else can repeat it.

---

## 10. Open decisions for Simon

1. Which tenant is v1: EYW only, or also a second tenant with broader licences?
2. LLM option A, B or C (§8).
3. Dashboard surface: model-driven app (editable, overrides are easy) or Power BI (better visuals, read-only)?
4. Alert channel: Teams private channel, Teams chat, or email digest only?
5. Open-source licence (MIT is the usual choice for Power Platform community projects). **Decided:** Apache License 2.0 (ADR 0024).
6. Publisher and prefix (§13.6).
7. Which public fallback adapters to ship in v1, after checking terms with their maintainers (§3.1).

---

## 11. Notes for Claude Code

- Use the `power-automate-lessons` skill when generating flow JSON or packing solutions with `pac`.
- Keep the solution unpacked in the repo under `solutions/ChangeRadar/`; flows as source.
- Write every Graph and Dataverse query as a separate, testable file under `queries/`, with a sample response under `samples/` (no tenant identifiers committed).
- Build phase by phase. Do not start phase N+1 until phase N's "done when" is demonstrated.
- Ask before creating anything outside the pp-lab environment, and before granting any permission beyond read.

---

## 12. Events and downstream automation

Change Radar should be a **source of triggers**, not only a screen. Design it as publish/subscribe inside Dataverse.

### Event types (v1)

| Event | Raised when | Typical subscribers |
|---|---|---|
| `signal.new` | A signal is first seen | Content-ideas capture, weekly digest |
| `signal.changed` | Key date, status or wording changes (from `mw_signalversion`) | Re-assessment, "roadmap slipped" note |
| `incident.opened` / `incident.resolved` | Service health issue state changes | Teams alert, incident log |
| `exposure.found` | A signal matches one or more assets | Notify asset owners, create remediation task |
| `assessment.rated` | Estate impact is set or overridden | Escalation if High/Critical |
| `deadline.approaching` | Action-required key date is 14 or 3 days away and exposure exists | Reminder, task due-date update |
| `idea.enabled` | A signal enables, simplifies or makes obsolete a backlog idea (E2) | Backlog update, idea review |

### Mechanics

- **Raise:** each pipeline step writes a row to `mw_event` (event type, references, compact JSON payload, correlation id).
- **Dispatch:** one dispatcher flow triggers on new `mw_event` rows, looks up enabled `mw_subscription` rows whose filter matches, and calls each handler as a child flow, passing the event id.
- **Handlers are separate, optional flows** in their own solution layer (`ChangeRadarHandlers`). Installers enable the ones they want and can add their own without touching the core solution.
- **Idempotent and logged.** Each handler records what it did against the event id, so a re-run doesn't duplicate work.
- **Writes are opt-in.** Any handler that creates or changes something outside Change Radar has `writes = yes`, ships disabled, and its documentation says exactly what it writes, where and under which identity.

### Reference handlers to ship

| Handler | Writes? | Does |
|---|---|---|
| `Notify-Teams` | No (posts a message only) | Adaptive card per §7 |
| `Digest-Weekly` | No | Monday digest |
| `Notify-AssetOwners` | Sends messages to others | Tells owners of affected assets what changed and what to do. Off by default |
| `Create-PlannerTask` | Yes | Creates a remediation task with due date = key date − buffer |
| `Create-BacklogItem` | Yes | Adds an item to a backlog (Planner, Azure DevOps or GitHub Issues adapter) |
| `Create-GitHubIssue` | Yes | Opens an issue with the event payload; a repo can route labelled issues to Claude Code or another agent for analysis or a draft fix |
| `Capture-ContentIdea` | Yes | Logs high-opportunity signals as talk, post or case-study ideas |

Simon's own instance can wire `Create-BacklogItem` to the EYW Backlog in Planner and `Capture-ContentIdea` to his content pipeline. Those are configuration choices, not part of the distributed core.

---

## 13. Packaging and distribution

### 13.1 Name (decided)

**Change Radar for Power Platform & Copilot.** Reason for not using "Microsoft Watch":

"Change Radar" works internally. A public project should avoid "Microsoft" at the start of its name: Microsoft's trademark guidance discourages third-party product names that could imply Microsoft made them. Something like *Change Radar for Power Platform & Copilot* is clearer about what it does and safer. Decide before phase 7, since the name flows into the publisher, solution and repo names.

### 13.2 What ships

| Artefact | Content |
|---|---|
| `ChangeRadarCore` managed solution | Tables, core flows (collect, fingerprint, match, assess, dispatch), security roles, environment variables, connection references, model-driven app |
| `ChangeRadarHandlers` managed solution | Reference handlers, all disabled by default |
| Unmanaged source | Both solutions unpacked in the repo, for people who want to customise |
| `deploymentSettings.template.json` | Every environment variable and connection reference, with descriptions and no values |
| `setup/` scripts | PowerShell + PAC CLI: create the app registration with read-only permissions, create the application user and read-only role, import the solutions, apply deployment settings. Prints every permission it's about to grant and asks for confirmation |
| Seed data | Default facet vocabulary, default `mw_rule` set, default `mw_config`, as CSV, imported by the setup script and editable afterwards |
| Optional dependency notes | Copilot Studio Kit Agent Inventory adds richer agent facets; the core works without it, with fewer facets |

### 13.3 Configuration, not code

- Environment variables: tenant id, products in scope, poll intervals, alert thresholds, Teams channel, digest day, LLM mode (A/B/C from §8).
- Connection references: Graph (via HTTP with Entra ID or a custom connector), Dataverse, Power Platform for Admins V2, Teams, optional backlog targets.
- **LLM provider is pluggable.** Fingerprinting and rationale run through one child flow with a fixed input and output contract (JSON in, facets or rationale out). The default implementation uses in-tenant prompt actions. Alternatives are documented, not bundled.
- The vocabulary and rules are data. Installers can add facets and rules for their own estate without editing flows.

### 13.4 Documentation set (`docs/`)

1. `README.md`: what it does, a screenshot, a 10-line quick start, what it reads and what it never writes.
2. `prerequisites.md`: roles needed (who must run setup), licences (Dataverse and premium connectors need Power Apps/Automate premium; prompt actions consume Copilot credits), supported clouds.
3. `install.md`: step by step, with the setup script and the manual alternative.
4. `configure.md`: every environment variable, the vocabulary, the rules and subscriptions.
5. `permissions-and-data.md`: every identity, every permission, the reason for each, where data is stored, what (if anything) leaves the tenant. Written for a security reviewer.
6. `extend.md`: adding a facet, a rule, a source adapter or a handler.
7. `architecture.md`: the diagram in §2, the data model, the event model.
8. `troubleshooting.md`: the delegated-inventory 403, consent issues, throttling.
9. `CHANGELOG.md`, `LICENSE`, `SECURITY.md`, `CONTRIBUTING.md`.

### 13.5 Repo and release

**Decision: a dedicated repo from day one, not pp-lab.**

- **Where:** `change-radar` under an EYW GitHub organisation (e.g. `github.com/<eyw-org>/change-radar`). Private while building; switch to public at phase 7.
- **Why not build in pp-lab and extract later:** the git history goes public with the code. Tenant ids, environment URLs, sample responses with real names or a stray secret in any old commit would be published, and scrubbing history afterwards is error-prone. Mixing in other experiments also clutters the history, issues and releases.
- **Why not inside one big Empower-your-world repo:** a product needs its own issues, releases, GitHub Actions, licence and README. Code here is MIT, while EYW materials carry delivery-licensing terms, so mixing the two in one repo blurs which licence applies to what. Link to Change Radar from the EYW repo and website instead.
- **pp-lab's role:** throwaway spikes for the tests in §3 (T1–T5), whose findings feed into `change-radar` as documented decisions, not copied code.
- **Environments are separate from repos:** develop in the pp-lab Power Platform environment (or a dedicated dev environment), and test installs in a clean developer environment or tenant.

- GitHub Actions: on pull request, `pac solution pack` + Solution Checker; on tag, build managed solutions and attach them to a GitHub release with the deployment settings template.
- Semantic versioning. Solution version = release tag.
- No tenant ids, environment URLs, sample responses with real names, or secrets in the repo. Add a secret-scanning check.

### 13.6 Publisher and prefix (decide in phase 0)

The Dataverse publisher prefix is baked into every table, column and component and can't sensibly be changed after release. `mw_` in this spec is a working placeholder. Options:

- **EYW publisher (e.g. prefix `eyw`)**: every EYW open-source tool shares one publisher, which builds the EYW brand; tables read `eyw_signal`, `eyw_asset`.
- **Product publisher (e.g. prefix `crdr`)**: Change Radar stands alone and could move to another maintainer or organisation cleanly.

Recommendation: EYW publisher, unless Change Radar is likely to be handed over or co-maintained outside EYW.

---

## 14. Enhancements (not in v1)

### E1. Link to the risk-sizing app

Weigh estate impact by the risk tier of the affected solution, using the Scalable Governance risk-sizing app. `mw_asset` keeps stable source ids (§4) so this link needs no rework later. It moves impact from "touches a production asset" to "touches a high-risk production asset".

### E2. Match changes against a backlog of ideas and use cases

Today matching asks "what could this break?". E2 asks "what could this enable?".

- **Ideas get facets too.** Each backlog idea or use case records what it **needs**: capabilities, connectors, controls or licensing that are missing, awkward or expensive today. Example: "governed agent access to internal tools" needs `capability=mcp_policy_control`.
- **Signals are fingerprinted for what they provide** as well as what they touch.
- **Match types:**

| Relationship | Meaning | Example from current items |
|---|---|---|
| Unblocks | Provides something the idea was waiting for | Work IQ granular MCP policies → ideas that needed governed MCP access |
| Simplifies | Makes the idea cheaper or easier to build | Copilot Studio service principal auth → production agent workflows without service accounts |
| Changes the approach | The idea should now be built differently | Model-driven apps from Cowork → requirements-to-app ideas |
| Makes obsolete | Microsoft is shipping the idea natively | A planned scheduled-prompt tool vs native Copilot scheduling |

- **"Makes obsolete" is the most valuable signal.** It stops investment in something about to become a product feature.
- **Source adapters:** a generic `mw_idea` table in the core, plus import adapters for Planner, Azure DevOps, GitHub Issues and CSV. Simon's instance reads the EYW Backlog in Planner.
- Raises `idea.enabled` events (§12), so a handler can comment on or update the backlog item.

### E3. Multi-tenant mode for client estates

A "change impact" service run across client tenants. It needs per-client consent, data isolation, a processing agreement and probably one installation per tenant, not a central collector. It's commercially interesting and should be a separate decision.

### E4. Consumption exposure

Add Copilot Credits consumption (reporting API, T4) as an asset facet, so changes to billing or limits are matched against where credits are actually spent.

---

## 15. Synthetic and demo estates

A small real estate (as in the EYW tenant today) can't show most matching rules firing. Synthetic data fixes that, if it's designed so it can never be mistaken for, or mixed with, real assessments.

### 15.1 Three layers, each with a different job

| Layer | What it is | Tests | Ships to others? |
|---|---|---|---|
| **A. Synthetic estate file** | Generated JSON/CSV in exactly the shape the live collectors produce, loaded through a **file-based estate adapter** | Fingerprinting, matching, assessment, dashboard, alerts, at realistic scale | Yes, as the default demo for the Public and Maker tiers |
| **B. Fixture estate** | A small solution of real but trivial resources, each built to trigger (or deliberately not trigger) one rule | The full pipeline end to end, including live collection | Yes, as an optional `ChangeRadarDemo` solution for a sandbox |
| **C. Matching test suite** | Signal × asset pairs with the expected outcome (match / no match / which facets) | Regression: every rule change is checked against known cases | Yes, in `tests/` |

### 15.2 Design rules

- **Always labelled.** Every synthetic or fixture asset carries `source = synthetic` or `fixture` and a synthetic organisation name. The dashboard shows a "Demo data" badge whenever any is present, and estate impact never mixes live and synthetic assets in one rating.
- **Same shape as live data.** The file adapter loads the same structures as the inventory and Dataverse collectors, so nothing downstream knows or cares where data came from. That also proves the adapter boundary works.
- **Positive and negative cases.** For every rule, at least one asset that should match and one near miss that shouldn't. Examples:
  - tempauth: canvas app with a PCF control **and** the SharePoint connector (match); PCF control without SharePoint (no match).
  - service principal workflows: user-owned workflow in production (match); the same in a developer environment (no match).
- **Realistic distributions, not just happy paths.** Default-environment sprawl, a few makers owning most resources, a long tail of abandoned flows, a handful of premium connectors, a mix of classic and generative agents. That's what makes the demo credible to an admin audience.
- **Generated, not hand-written.** A script (`setup/generate-synthetic-estate`) builds the estate from a profile: organisation size, sector, number of environments, maturity. One profile can produce a small charity or a large regulated enterprise. Fixed random seeds keep outputs reproducible.
- **Never written into a live tenant by accident.** The synthetic adapter writes to Change Radar's own tables only. The fixture solution goes into a sandbox, and the setup script refuses a production environment.

### 15.3 Link to EYW synthetic organisations

Base the generator's profiles on EYW's existing synthetic organisations, so the estate tells the same story as the workshops and FCO material. For example, "here is what this month's changes mean for [synthetic org]'s Power Platform estate" is ready-made demo, talk and LinkedIn content. Keep the published profiles generic, and hold EYW-specific organisations in a private profile file if their detail is EYW IP.

### 15.4 Build order

1. Matching test suite (C) for the six worked examples in §5. It defines "correct" before any code exists.
2. Synthetic estate file + adapter (A). It unblocks phases 3–6 without waiting for the real estate.
3. Fixture estate (B) once live collection (phase 2) works, to prove the pipeline end to end.
