# Document build

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=tools-docbuild-readme) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=tools-docbuild-readme)

Builds the client-facing Word documents from the Markdown in `docs/` (Simon, 2026-11-24: the Markdown is the single source; the Word document is generated from it, never edited by hand).

| Step | Command | Does |
|---|---|---|
| 1. Diagrams | `pwsh -File tools/diagrams/render.ps1` | Draws every figure (`tools/diagrams/figures.py`, one visual language in `crdiagram.py`) to SVG, and renders a 2x PNG fallback with Microsoft Edge |
| 2. Word | `node tools/docbuild/build-docx.mjs docs/architecture.md docs/word/Change-Radar-Architecture.docx` | Cover and document control from the front matter, contents, styled headings and tables, callouts, and each figure on a landscape page |
| 3. Finish | `pwsh -File tools/docbuild/finish-docx.ps1 -Docx docs/word/Change-Radar-Architecture.docx [-PagesDir <folder>]` | Uses Word to fill the contents and page numbers, saves, exports a PDF beside it, and optionally renders every page to PNG for checking |

**The whole set in one go:** `pwsh -File tools/docbuild/build-all.ps1 [-PagesDir <folder>] [-Only install,configure]` draws the diagrams once, then builds and finishes each document it lists (`documents.csv`: source, file name, and stage in the docs pack). Add a document to its list once it is written, not while it is a skeleton.

**Sensitivity labels.** Word adds the signed-in tenant's default sensitivity label, with the tenant id, to every file it saves or exports. `clean-output.py` (run by step 3) removes it from the Word file and the PDF and fails the build if any is left. Never save these documents from Word by hand into the repository: rebuild them.

First time only: `npm install` in `tools/docbuild` (the `docx` and `marked` libraries). Step 1 needs `uv` and Microsoft Edge; step 3 needs Microsoft Word.

**Front matter** (top of the Markdown): `title`, `subtitle`, `document`, `version`, `date`, `status`, `audience`, `owner`, `release`, and optionally `history` (the version history line), `intro: keep` (keep the notes under the Markdown's title as a callout, less the "For:" line the cover already shows) and `breaks: none` (sections don't start a new page: for short how-to and reference documents). Two more let another repository build with these tools: `repository` (named on the control page in place of "Change Radar repository") and `licence` (replaces the Apache 2.0 paragraph; the private delivery kit uses it).

**Conventions in the Markdown:** `##` sections start a new page (unless `breaks: none`); `###` and `####` are sub-headings; an image on its own line becomes a numbered figure whose caption is its alt text; a blockquote becomes a callout box; a short introduction before the first figure, with no heading, goes onto the figure's page; links to other repository documents read as plain text in Word.
