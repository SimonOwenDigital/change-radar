---
title: Change Radar
subtitle: Accessibility Statement
document: CR-GOV-07
version: "0.3"
date: 24 November 2026
status: For review
audience: Accessibility leads, procurement and the service owner
owner: Simon Owen
release: Change Radar 0.3.0
intro: keep
breaks: none
---

# Accessibility statement

> **For:** accessibility leads, procurement and the service owner. **Kind:** reference.
> **Status:** describes release 0.3.0. Change Radar has not had a formal accessibility audit. This statement says what was designed for, what was checked, and the known gaps.
>
> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=accessibility) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=accessibility)

## 1. What Change Radar's interface is made of

| Part | Built by | Accessibility |
|---|---|---|
| The Radar page and the Fingerprint review page | Change Radar (generative pages: React with Microsoft's Fluent UI components) | Designed to WCAG 2.1 AA; partly checked (section 2) |
| Forms, views and navigation in the Change Radar app | Microsoft (model-driven app) | Microsoft's own conformance |
| Teams cards and the weekly digest | Microsoft (adaptive cards in Teams), content by Change Radar | Microsoft's own conformance for the card; Change Radar's text is plain and short |
| Email alerts (optional) | Change Radar's HTML, sent through Outlook | Simple HTML with headings and lists; not separately checked |
| Ask Change Radar (optional) | Microsoft (Copilot Studio in Teams and Microsoft 365 Copilot) | Microsoft's own conformance |

## 2. What was checked

On the two generative pages, in a walkthrough on 23 November 2026:

- **Keyboard:** the tiles, filters and buttons can all be reached with Tab, without a mouse.
- **Visible focus:** the keyboard focus is visible throughout.
- **Reflow:** at about half the browser's width, nothing overlaps and the page doesn't scroll sideways.
- **Plain language:** British English throughout; no jargon a colleague would need explained.

The pages were also built to these rules: accessible names (ARIA labels) on controls, semantic HTML, keyboard navigation, and a confirmation dialog for actions that close or widen matches, and the Fingerprint review page designed to announce the result of each change to screen readers (not yet checked with a screen reader).

## 3. Known gaps

- **No formal audit** against WCAG 2.1 AA has been done.
- **Screen reader testing** (NVDA, JAWS, VoiceOver, Narrator) has not been done.
- **Colour:** the priority matrix and timeline use colour for risk, opportunity and horizon. Each item also has a text label or badge, but colour contrast has not been measured.
- **Charts:** how the timeline and matrix read to a screen reader is **to verify**. The Imminent table and the lists hold the same items as text.
- **Zoom** beyond half width (for example 400%) has not been tested.

## 4. Reporting a problem

Open an issue in the GitHub repository with the label "accessibility", describing the page, what you tried, and the assistive technology you use. Don't include tenant data. Fixes ship in the next release.

## 5. If you adopt Change Radar

If your organisation must meet a legal accessibility standard, run your own check of the two generative pages with your usual tools and assistive technology before go-live, and report what you find.
