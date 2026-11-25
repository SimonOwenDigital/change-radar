---
title: Change Radar
subtitle: Business Case Kit
document: CR-BUS-01
version: "0.3"
date: 24 November 2026
status: For review
audience: Sponsors, platform owners and whoever writes the case for adopting Change Radar
owner: Simon Owen
release: Change Radar 0.3.0
intro: keep
breaks: none
---

# Business case kit

> **For:** sponsors, platform owners and whoever writes the case for adopting Change Radar. **Kind:** a template with a worked example.
> **Status:** costs come from measured credit use (Requirements, section 3.1). **Benefit figures in the worked example are assumptions**, marked as such, with the formula shown so you can put in your own. No licence prices are given: use your own.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=business-case) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=business-case)

**In your organisation.** A business case for a governance tool is usually a case about risk: what it costs when nobody notices a change in time. That cost is real but hard to count, so this kit keeps the arithmetic visible and the assumptions labelled. For a way to judge any AI use case against its risks before committing, see the [Make AI Adoption Safe](https://www.empoweryour.world/journeys/make-ai-adoption-safe?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=business-case) journey on Empower Your World.

## How to use this kit

1. Copy the template (section 1) into your organisation's business case format.
2. Fill each section, using the worked example (section 2) as a guide.
3. Replace every figure marked **assumed** with your own. Keep the formulas, so a reviewer can follow the arithmetic.
4. After a fortnight in a test environment, replace the credit forecast with your own (`setup/Get-CreditEstimate.ps1`).

## 1. The template

### 1.1 The problem

Describe, in your organisation's terms:

- how many Power Platform and Copilot assets you run, and in how many environments;
- who reads Microsoft's change announcements today, and how long it takes them;
- recent changes that caught you out: a retirement, a licensing change, an incident nobody heard about, a model change that altered an agent's answers.

### 1.2 The options

| Option | Describe |
|---|---|
| A. Do nothing | Changes are noticed when something breaks or someone happens to read about it |
| B. Manual | Someone reads Message Center, the roadmap and the blogs, and works out what touches your estate by hand |
| C. Change Radar | Collection, matching and rating are automated; people triage, decide and act |

### 1.3 Costs

| Cost | Unit | Quantity | Your price | Total |
|---|---|---|---|---|
| Power Automate Premium (the connection owner) | Per user per month | 1 | | |
| Premium Power Apps use rights | Per user per month, or per app | Your platform team and app users | | |
| AI capacity | AI Builder credits or Copilot Credits per month | From the credit estimate | | |
| Dataverse database capacity | GB | 1 to create the environment | | |
| Azure Key Vault | Operations and certificate renewals | One vault, one certificate a year | | |
| Install | Person-days | About half a day, plus one consent and one Key Vault from other teams | | |
| Running it | Hours per week | Triage and review (section 1.4) | | |

### 1.4 Benefits

For each benefit, write the formula, then the figures.

| Benefit | Formula |
|---|---|
| **Reading time saved** | (hours a week reading announcements today − hours a week triaging with Change Radar) × 52 × your hourly cost |
| **Disruption avoided** | breaking changes a year that would have been missed × hours of disruption each × the cost of an hour of disruption |
| **Deadlines met** | deadlines a year that would have been missed × the cost of missing one (an emergency fix, a lapsed feature, a licence surprise) |
| **Faster incident awareness** | incidents a year affecting your solutions × hours sooner the owners know × the cost of an hour of an unexplained outage |
| **Not countable, still real** | owners told about their own assets; a weekly picture for leadership; evidence for audit of how platform change is managed |

### 1.5 Risks

Copy the relevant lines from the Risk Register, with your own likelihood and impact, and the controls you'll add.

### 1.6 Recommendation

State the option, the cost for the first year, the benefits you counted, and the conditions (for example: a test environment first; a named service owner; a review after three months).

## 2. Worked example: a fictional medium organisation

**Northwind Services** (fictional) runs about 1,000 Power Platform assets across 30 environments. Two admins share the reading of Message Center and the roadmap.

### 2.1 The problem (assumed)

The admins spend about **4 hours a week** between them reading announcements. In the last year, two changes were missed: a connector retirement that broke three flows for a day, and a deadline that led to a weekend fix.

### 2.2 Costs (credits measured; licences priced by you)

Credits, from the Requirements estimate for a medium estate (50 signals touching the estate):

| | AI Builder credits | or Copilot Credits |
|---|---|---|
| First month (backlog plus a normal month) | About 7,100 | About 595 |
| Each month after | About 3,700 | About 310 |
| **First year** (first month + 11 × a normal month) | **About 47,800** | **About 4,000** |
| Ceiling, whatever happens (caps × 30 nights) | 12,400 a month | 1,035 a month |

| Cost | Quantity | Note |
|---|---|---|
| Power Automate Premium | 1 user | Use your own price |
| Premium Power Apps use rights | The two admins (already licensed at Northwind, **assumed**) | Use your own price |
| AI capacity | About 47,800 AI Builder credits, or 4,000 Copilot Credits, in year one | Use your own price per credit or pack |
| Install | Half a day of an admin, plus about an hour each from Entra and Azure owners | |

### 2.3 Benefits (all figures assumed)

| Benefit | Formula with Northwind's assumed figures | Hours a year |
|---|---|---|
| Reading time saved | (4 hours − 1.2 hours: ten minutes a day plus a 20-minute Monday review) × 52 | **About 145 hours** |
| Disruption avoided | 2 missed changes a year × 3 flows × 8 hours of disruption | **About 48 hours** of business disruption |
| Deadlines met | 1 missed deadline a year × 16 hours of weekend fix | **About 16 hours**, at overtime rates |
| Faster incident awareness | 6 incidents a year × 2 hours sooner × the people affected | Count your own |

Multiply the hours by your own hourly costs to set them against the costs in 2.2.

### 2.4 Risks

The main risks for Northwind are R05 (the connection owner leaves), R13 (no vendor support) and R10 (alert fatigue). Controls: a service account with a named deputy, a named internal service owner, and a review of card types after the first month.

### 2.5 Recommendation

Option C. Install in a test environment first; run it for a fortnight alongside the current manual reading; compare what each finds; then decide on production. Review after three months against the benefits counted in 2.3.

## 3. Evidence to attach

- The Licensing and Cost Summary.
- The Governance Approval Checklist.
- After a fortnight in a test environment: the output of `setup/Get-CreditEstimate.ps1`, and a note of what Change Radar found that manual reading missed.
