// Builds a client-facing Word document from one of the Markdown documents in docs/ (Simon, 2026-11-24: Markdown is the
// single source; Word is generated from it). Usage:
//   node tools/docbuild/build-docx.mjs docs/architecture.md docs/word/Change-Radar-Architecture.docx
// The Markdown's front matter (title, subtitle, document, version, date, status, audience, owner, release) fills the cover
// and document control page. The first H1 and the blockquote after it are the Markdown's own title block and are left
// out: the cover replaces them. Images are embedded as SVG with the PNG beside them as Word's fallback; an image's alt
// text is its caption. Run tools/docbuild/finish-docx.ps1 afterwards to fill the table of contents and check the pages.
import fs from 'node:fs';
import path from 'node:path';
import { marked } from 'marked';
import {
  AlignmentType, BorderStyle, Document, ExternalHyperlink, Footer, Header, HeadingLevel, ImageRun, LevelFormat, Packer,
  PageBreak, PageNumber, PageOrientation, Paragraph, ShadingType, Table, TableCell, TableLayoutType, TableOfContents, TableRow, TabStopType, TextRun,
  VerticalAlign, WidthType,
} from 'docx';

const [, , srcArg, outArg] = process.argv;
if (!srcArg || !outArg) { console.error('usage: build-docx.mjs <source.md> <output.docx>'); process.exit(2); }
const src = path.resolve(srcArg);
const out = path.resolve(outArg);
const baseDir = path.dirname(src);
const repo = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..', '..');

// ----- design tokens (match tools/diagrams/crdiagram.py) -----------------------------------------------------------------
const FONT = 'Segoe UI';
const MONO = 'Consolas';
const NAVY = '1F3A5F', TEAL = '1C7C7D', INK = '22303C', MUTED = '5B6773', RULE = 'D5DBE1', BAND = 'F4F6F8', CALLOUT = 'EAF4F4';
const PAGE_W = 11906, PAGE_H = 16838, MARGIN = 1134; // A4, 2 cm margins
const TEXT_W = PAGE_W - 2 * MARGIN; // 9638 DXA
const PX_PER_DXA = 96 / 1440;
const L_MARGIN = 851; // landscape figure pages: 1.5 cm margins
// Height left for the figure after the header, footer, caption and a lead-in heading and paragraph.
const L_TEXT_W = PAGE_H - 2 * L_MARGIN, L_TEXT_H = PAGE_W - 2 * L_MARGIN - 3200;

// ----- source -----------------------------------------------------------------------------------------------------------
let text = fs.readFileSync(src, 'utf8').replace(/\r\n/g, '\n').replaceAll('utm_source=github', 'utm_source=document');
const front = {};
const fm = /^---\n([\s\S]*?)\n---\n/.exec(text);
if (fm) {
  fm[1].split('\n').forEach((line) => { const m = /^(\w+):\s*(.*)$/.exec(line); if (m) front[m[1]] = m[2].replace(/^"(.*)"$/, '$1'); });
  text = text.slice(fm[0].length);
}
// The repository the source lives in (the nearest folder with .git): this one, or another that builds with these tools.
let srcRoot = path.dirname(src);
while (!fs.existsSync(path.join(srcRoot, '.git')) && path.dirname(srcRoot) !== srcRoot) srcRoot = path.dirname(srcRoot);
const tokens = marked.lexer(text);
// Drop the Markdown's own title block: the first H1 and the blockquote straight after it.
const firstH1 = tokens.findIndex((t) => t.type === 'heading' && t.depth === 1);
if (firstH1 >= 0) {
  tokens.splice(firstH1, 1);
  const next = tokens.findIndex((t, i) => i >= firstH1 && t.type !== 'space');
  if (next >= 0 && tokens[next].type === 'blockquote') {
    // intro: keep (front matter) keeps the title block's notes as a callout, less the "For:" line the cover already shows.
    const kept = front.intro === 'keep'
      ? tokens[next].raw.split(/\r?\n/).map((l) => l.replace(/^>\s?/, '')).filter((l) => l.trim() && !l.startsWith('**For:**') && !l.startsWith('**From:**')) : [];
    tokens.splice(next, 1, ...(kept.length ? marked.lexer(kept.map((l) => `> ${l}`).join('\n>\n')) : []));
  }
}

// ----- inline -----------------------------------------------------------------------------------------------------------
function decode(s) {
  return s.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'");
}
function inline(toks, style = {}) {
  const runs = [];
  for (const t of toks || []) {
    switch (t.type) {
      case 'strong': runs.push(...inline(t.tokens, { ...style, bold: true })); break;
      case 'em': runs.push(...inline(t.tokens, { ...style, italics: true })); break;
      case 'del': runs.push(...inline(t.tokens, { ...style, strike: true })); break;
      case 'codespan': runs.push(new TextRun({ text: decode(t.text), font: MONO, size: (style.size || 21) - 2, color: style.color || NAVY, bold: style.bold })); break;
      case 'br': runs.push(new TextRun({ break: 1 })); break;
      case 'link':
        if (/^https?:/.test(t.href)) {
          runs.push(new ExternalHyperlink({ link: t.href, children: inline(t.tokens, { ...style, color: TEAL, underline: {} }) }));
        } else {
          runs.push(...inline(t.tokens, style)); // links between repository documents read as plain text in Word
        }
        break;
      case 'text':
        if (t.tokens && t.tokens.length) runs.push(...inline(t.tokens, style));
        else runs.push(new TextRun({ text: decode(t.text), ...style }));
        break;
      case 'escape': runs.push(new TextRun({ text: decode(t.text), ...style })); break;
      case 'html': break;
      default: if (t.text) runs.push(new TextRun({ text: decode(t.text), ...style }));
    }
  }
  return runs;
}
const plain = (toks) => (toks || []).map((t) => (t.tokens ? plain(t.tokens) : decode(t.text || ''))).join('');

// ----- blocks -----------------------------------------------------------------------------------------------------------
let figureNo = 0;
let listInstance = 0;

function image(tok) {
  const file = path.resolve(baseDir, tok.href);
  const svg = fs.readFileSync(file);
  const png = fs.readFileSync(file.replace(/\.svg$/i, '.png'));
  const m = /width="(\d+)" height="(\d+)"/.exec(svg.toString('utf8'));
  const w = m ? +m[1] : 1600, h = m ? +m[2] : 900;
  const maxW = Math.round(L_TEXT_W * PX_PER_DXA), maxH = Math.round(L_TEXT_H * PX_PER_DXA);
  let dw = maxW, dh = Math.round((h * maxW) / w);
  if (dh > maxH) { dh = maxH; dw = Math.round((w * maxH) / h); }
  figureNo++;
  const caption = (tok.text || tok.title || '').trim();
  return { figure: [
    new Paragraph({ alignment: AlignmentType.CENTER, keepNext: true, spacing: { before: 0, after: 80 },
      children: [new ImageRun({ type: 'svg', data: svg, transformation: { width: dw, height: dh }, fallback: { type: 'png', data: png },
        altText: { title: caption, description: caption, name: path.basename(file) } })] }),
    new Paragraph({ style: 'Caption', alignment: AlignmentType.CENTER, children: [new TextRun({ text: caption })] }),
  ] };
}

function cellParas(toks, header) {
  const runs = inline(toks, header ? { bold: true, color: 'FFFFFF', size: 18 } : { size: 18, color: INK });
  return [new Paragraph({ spacing: { before: 40, after: 40, line: 252 }, children: runs })];
}

const cellLength = (toks) => (toks || []).reduce((n, t) => n + (t.type === 'codespan' ? decode(t.text).length * 1.35
  : t.tokens ? cellLength(t.tokens) : decode(t.text || '').length), 0);

function table(tok) {
  const cols = tok.header.length;
  // Column widths from content length, with a floor, scaled to the text width.
  const len = Array.from({ length: cols }, (_, c) => {
    // Code is set in a wider monospace face, so it counts for more. A single outlier (one very long default value)
    // should not take the column: use the 85th percentile, not the longest.
    const lens = [tok.header[c], ...tok.rows.map((r) => r[c])].map((cell) => cellLength(cell.tokens)).sort((a, b) => a - b);
    const longest = lens[Math.min(lens.length - 1, Math.floor(lens.length * 0.85))], avg = lens.reduce((a, b) => a + b, 0) / lens.length;
    return Math.min(60, Math.max(8, avg * 0.6 + longest * 0.4));
  });
  const total = len.reduce((a, b) => a + b, 0);
  let widths = len.map((l) => Math.max(1400, Math.round((l / total) * TEXT_W)));
  const scale = TEXT_W / widths.reduce((a, b) => a + b, 0);
  widths = widths.map((wv) => Math.floor(wv * scale));
  widths[widths.length - 1] += TEXT_W - widths.reduce((a, b) => a + b, 0);
  const border = { style: BorderStyle.SINGLE, size: 4, color: RULE };
  const borders = { top: border, bottom: border, left: border, right: border, insideHorizontal: border, insideVertical: border };
  const margins = { top: 60, bottom: 60, left: 100, right: 100 };
  const rows = [
    ...(tok.header.every((h) => plain(h.tokens).trim() === '') ? [] : [new TableRow({ tableHeader: true, cantSplit: true, children: tok.header.map((h, c) => new TableCell({
      width: { size: widths[c], type: WidthType.DXA }, shading: { type: ShadingType.CLEAR, color: 'auto', fill: NAVY },
      margins, verticalAlign: VerticalAlign.CENTER, children: cellParas(h.tokens, true) })) })]),
    ...tok.rows.map((r, i) => new TableRow({ cantSplit: true, children: r.map((cell, c) => new TableCell({
      width: { size: widths[c], type: WidthType.DXA }, margins,
      shading: { type: ShadingType.CLEAR, color: 'auto', fill: i % 2 ? BAND : 'FFFFFF' }, children: cellParas(cell.tokens, false) })) })),
  ];
  return [new Table({ width: { size: TEXT_W, type: WidthType.DXA }, columnWidths: widths, layout: TableLayoutType.FIXED, borders, rows }),
    new Paragraph({ spacing: { after: 120 }, children: [] })];
}

function list(tok, level = 0) {
  const ref = tok.ordered ? `num-${++listInstance}` : 'bullets';
  const paras = [];
  for (const item of tok.items) {
    const textToks = [];
    for (const t of item.tokens) {
      if (t.type === 'list') continue;
      if (t.type === 'text' || t.type === 'paragraph') textToks.push(...(t.tokens || [t]));
    }
    paras.push(new Paragraph({ numbering: { reference: tok.ordered ? 'numbers' : 'bullets', level, instance: tok.ordered ? listInstance : undefined },
      spacing: { after: 60 }, children: inline(textToks) }));
    for (const t of item.tokens) if (t.type === 'list') paras.push(...list(t, level + 1));
  }
  return paras;
}

function blocks(toks) {
  const outBlocks = [];
  for (const t of toks) {
    switch (t.type) {
      case 'heading': {
        const level = { 2: HeadingLevel.HEADING_1, 3: HeadingLevel.HEADING_2, 4: HeadingLevel.HEADING_3 }[t.depth] || HeadingLevel.HEADING_3;
        // Built during page assembly (bodySections), which knows whether the heading starts a page.
        outBlocks.push({ heading: { level, depth: t.depth, runs: inline(t.tokens) } });
        break;
      }
      case 'paragraph': {
        const imgs = (t.tokens || []).filter((x) => x.type === 'image');
        if (imgs.length === 1 && plain(t.tokens.filter((x) => x.type !== 'image')).trim() === '') outBlocks.push(image(imgs[0]));
        else outBlocks.push({ para: new Paragraph({ children: inline(t.tokens) }), length: plain(t.tokens).length });
        break;
      }
      case 'list': outBlocks.push(...list(t)); break;
      case 'table': outBlocks.push(...table(t)); break;
      case 'blockquote':
        for (const p of t.tokens.filter((x) => x.type === 'paragraph')) {
          outBlocks.push({ para: new Paragraph({ style: 'Callout', children: inline(p.tokens) }), length: plain(p.tokens).length });
        }
        break;
      case 'code':
        t.text.split('\n').forEach((line, i, all) => outBlocks.push(new Paragraph({ style: 'Code', spacing: { after: i === all.length - 1 ? 160 : 0 },
          children: [new TextRun({ text: line || ' ' })] })));
        break;
      case 'hr': outBlocks.push(new Paragraph({ border: { bottom: { style: BorderStyle.SINGLE, size: 6, color: RULE, space: 1 } }, children: [] })); break;
      default: break;
    }
  }
  return outBlocks;
}

// ----- cover and document control ---------------------------------------------------------------------------------------
const mark = { svg: fs.readFileSync(path.join(repo, 'docs', 'diagrams', '00-mark.svg')), png: fs.readFileSync(path.join(repo, 'docs', 'diagrams', '00-mark.png')) };
const markRun = (w) => new ImageRun({ type: 'svg', data: mark.svg, transformation: { width: w, height: Math.round(w * 150 / 240) }, fallback: { type: 'png', data: mark.png },
  altText: { title: 'Change Radar', description: 'Change Radar name mark', name: 'mark' } });
const docTitle = `${front.title || 'Change Radar'}: ${front.subtitle || ''}`.replace(/: $/, '');

function metaTable(pairs) {
  const none = { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' };
  const rule = { style: BorderStyle.SINGLE, size: 4, color: RULE };
  return new Table({
    width: { size: TEXT_W, type: WidthType.DXA }, columnWidths: [2400, TEXT_W - 2400],
    borders: { top: rule, bottom: rule, left: none, right: none, insideHorizontal: rule, insideVertical: none },
    rows: pairs.map(([k, v]) => new TableRow({ children: [
      new TableCell({ width: { size: 2400, type: WidthType.DXA }, margins: { top: 70, bottom: 70, left: 0, right: 100 },
        children: [new Paragraph({ children: [new TextRun({ text: k, bold: true, color: NAVY, size: 19 })] })] }),
      new TableCell({ width: { size: TEXT_W - 2400, type: WidthType.DXA }, margins: { top: 70, bottom: 70, left: 100, right: 0 },
        children: [new Paragraph({ children: [new TextRun({ text: v, color: INK, size: 19 })] })] }),
    ] })),
  });
}

const eywLink = (page, label) => new ExternalHyperlink({ children: [new TextRun({ text: label, color: TEAL, bold: true, underline: {}, size: 24 })],
  link: `https://www.empoweryour.world/${page}?utm_source=document&utm_medium=cover&utm_campaign=change-radar&utm_content=${path.basename(src, '.md')}` });

const cover = [
  new Paragraph({ spacing: { before: 1800, after: 200 }, children: [markRun(132)] }),
  new Paragraph({ spacing: { after: 60 }, children: [new TextRun({ text: (front.title || 'Change Radar').toUpperCase(), color: TEAL, bold: true, size: 26, characterSpacing: 60 })] }),
  new Paragraph({ spacing: { after: 160 }, children: [new TextRun({ text: front.subtitle || '', color: NAVY, bold: true, size: 60 })] }),
  new Paragraph({ spacing: { after: 2400 }, border: { bottom: { style: BorderStyle.SINGLE, size: 18, color: TEAL, space: 12 } },
    children: [new TextRun({ text: 'Change intelligence for Power Platform and Copilot', color: MUTED, size: 26 })] }),
  metaTable([['Document', front.document || ''], ['Version', front.version || ''], ['Date', front.date || ''], ['Status', front.status || ''],
    ['Release', front.release || ''], ['Owner', front.owner || ''], ['Audience', front.audience || '']].filter(([, v]) => v)),
  // Every document's front page links to Empower Your World (Simon, 2026-11-25).
  new Paragraph({ spacing: { before: 700, after: 60 }, children: [new TextRun({ text: 'From Empower Your World', color: NAVY, bold: true, size: 28 })] }),
  new Paragraph({ spacing: { after: 0 }, children: [eywLink('', 'www.empoweryour.world'), new TextRun({ text: '   ·   ', color: MUTED, size: 24 }), eywLink('blog/change-radar', 'The story behind Change Radar')] }),
];

const control = [
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('About this document')] }),
  new Paragraph({ children: [new TextRun(`This document is generated from the Markdown source ${path.relative(srcRoot, src).replace(/\\/g, '/')} in the ${front.repository || 'Change Radar repository'}, which is the authoritative version. The diagrams are drawn from code in tools/diagrams.`)] }),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('Version history')] }),
  ...table({ header: ['Version', 'Date', 'Change', 'Author'].map((s) => ({ tokens: [{ type: 'text', text: s }] })),
    rows: [[front.version || '', front.date || '', front.history || 'First edition, as built', front.owner || ''].map((s) => ({ tokens: [{ type: 'text', text: s }] }))] }),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('Licence and use')] }),
  new Paragraph({ children: [new TextRun(front.licence || 'Change Radar is open source under the Apache License 2.0: free to use, change and share, provided the licence and NOTICE file are kept with it. The Change Radar name is not licensed. This document may be shared freely; Microsoft product names are trademarks of Microsoft.')] }),
  new Paragraph({ children: [new PageBreak()] }),
  new Paragraph({ style: 'TocTitle', children: [new TextRun('Contents')] }),
  new TableOfContents('Contents', { hyperlink: true, headingStyleRange: '1-2' }),
];

// ----- document ---------------------------------------------------------------------------------------------------------
const header = new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT, border: { bottom: { style: BorderStyle.SINGLE, size: 4, color: RULE, space: 6 } },
  children: [new TextRun({ text: docTitle, color: MUTED, size: 16 })] })] });
const footer = new Footer({ children: [new Paragraph({ tabStops: [{ type: TabStopType.RIGHT, position: TEXT_W }],
  children: [new TextRun({ text: [front.document, front.version && `Version ${front.version}`, front.status].filter(Boolean).join('  ·  '), color: MUTED, size: 16 }),
    new TextRun({ text: '\tPage ', color: MUTED, size: 16 }), new TextRun({ children: [PageNumber.CURRENT], color: MUTED, size: 16 }),
    new TextRun({ text: ' of ', color: MUTED, size: 16 }), new TextRun({ children: [PageNumber.TOTAL_PAGES], color: MUTED, size: 16 })] })] });

const landscapeFooter = new Footer({ children: [new Paragraph({ tabStops: [{ type: TabStopType.RIGHT, position: L_TEXT_W }],
  children: [new TextRun({ text: [front.document, front.version && `Version ${front.version}`, front.status].filter(Boolean).join('  ·  '), color: MUTED, size: 16 }),
    new TextRun({ text: '\tPage ', color: MUTED, size: 16 }), new TextRun({ children: [PageNumber.CURRENT], color: MUTED, size: 16 }),
    new TextRun({ text: ' of ', color: MUTED, size: 16 }), new TextRun({ children: [PageNumber.TOTAL_PAGES], color: MUTED, size: 16 })] })] });
const landscape = { size: { width: PAGE_W, height: PAGE_H, orientation: PageOrientation.LANDSCAPE }, margin: { top: L_MARGIN, bottom: L_MARGIN, left: L_MARGIN, right: L_MARGIN, header: 420, footer: 420 } };
// Text in portrait sections; each figure on a landscape page of its own, so its labels stay legible in print.
function bodySections(items) {
  const secs = [];
  let current = [];
  // A top-level heading starts a new page, unless it already starts one (a new section) or the front matter says breaks: none.
  const head = (h, first) => new Paragraph({ heading: h.level, pageBreakBefore: h.depth === 2 && !first && front.breaks !== 'none', children: h.runs });
  const flush = () => {
    // A short introduction (paragraphs only) shares the first page with the heading that follows it.
    const firstHeading = current.findIndex((x) => x.heading);
    const introLength = firstHeading > 0 && current.slice(0, firstHeading).every((x) => x.para) && !secs.length
      ? current.slice(0, firstHeading).reduce((n, x) => n + x.length, 0) : Infinity;
    if (current.length) secs.push({ properties: { page }, headers: { default: header }, footers: { default: footer },
      children: current.map((x, i) => (x.heading ? head(x.heading, i === 0 || (i === firstHeading && introLength < 700)) : x.para ? x.para : x)) });
    current = [];
  };
  for (const it of items) {
    if (it && it.figure) {
      // Headings leading straight into a figure go onto the figure's page, never alone on a page.
      // So does one short paragraph between such a heading and the figure.
      const lead = [];
      const n = current.length;
      if (n >= 2 && current[n - 1].para && current[n - 1].length < 400 && current[n - 2].heading) lead.unshift(current.pop());
      while (current.length && current[current.length - 1].heading) lead.unshift(current.pop());
      // A short introduction with no heading before the first figure goes onto the figure's page too, not alone on a page.
      if (!secs.length && current.length && current.length <= 3 && current.every((x) => x.para)
        && current.reduce((n, x) => n + x.length, 0) < 700) lead.unshift(...current.splice(0));
      flush();
      secs.push({ properties: { page: landscape }, headers: { default: header }, footers: { default: landscapeFooter },
        children: [...lead.map((h, i) => (h.heading ? head(h.heading, i === 0) : h.para)), ...it.figure] });
    } else current.push(it);
  }
  flush();
  return secs;
}
const page = { size: { width: PAGE_W, height: PAGE_H }, margin: { top: MARGIN, bottom: MARGIN, left: MARGIN, right: MARGIN, header: 560, footer: 560 } };
const heading = (size, color, before, after) => ({ run: { font: FONT, size, bold: true, color }, paragraph: { spacing: { before, after }, keepNext: true, keepLines: true } });

const doc = new Document({
  creator: front.owner || 'Change Radar', title: docTitle, description: front.audience || '',
  features: { updateFields: true },
  styles: {
    default: {
      document: { run: { font: FONT, size: 21, color: INK }, paragraph: { spacing: { after: 140, line: 288 } } },
      heading1: heading(36, NAVY, 0, 240),
      heading2: heading(26, TEAL, 320, 120),
      heading3: heading(22, NAVY, 240, 80),
    },
    paragraphStyles: [
      { id: 'Caption', name: 'Caption', basedOn: 'Normal', run: { font: FONT, size: 17, italics: true, color: MUTED }, paragraph: { spacing: { before: 40, after: 260 } } },
      { id: 'Callout', name: 'Callout', basedOn: 'Normal', run: { font: FONT, size: 20, color: INK },
        paragraph: { shading: { type: ShadingType.CLEAR, color: 'auto', fill: CALLOUT }, indent: { left: 200, right: 200 }, spacing: { before: 80, after: 120 },
          border: { left: { style: BorderStyle.SINGLE, size: 24, color: TEAL, space: 8 } } } },
      { id: 'Code', name: 'Code', basedOn: 'Normal', run: { font: MONO, size: 18, color: INK },
        paragraph: { shading: { type: ShadingType.CLEAR, color: 'auto', fill: BAND }, spacing: { after: 0, line: 240 }, indent: { left: 200 } } },
      { id: 'TocTitle', name: 'TOC Title', basedOn: 'Normal', run: { font: FONT, size: 36, bold: true, color: NAVY }, paragraph: { spacing: { after: 240 } } },
    ],
  },
  numbering: { config: [
    { reference: 'bullets', levels: [0, 1, 2].map((l) => ({ level: l, format: LevelFormat.BULLET, text: ['•', '–', '·'][l], alignment: AlignmentType.LEFT,
      style: { paragraph: { indent: { left: 360 + l * 360, hanging: 260 } }, run: { color: TEAL } } })) },
    { reference: 'numbers', levels: [0, 1].map((l) => ({ level: l, format: l ? LevelFormat.LOWER_LETTER : LevelFormat.DECIMAL, text: `%${l + 1}.`, alignment: AlignmentType.LEFT,
      style: { paragraph: { indent: { left: 360 + l * 360, hanging: 300 } } } })) },
  ] },
  sections: [
    { properties: { page }, children: cover },
    { properties: { page }, headers: { default: header }, footers: { default: footer }, children: control },
    ...bodySections(blocks(tokens)),
  ],
});

fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, await Packer.toBuffer(doc));
console.log(`wrote ${path.relative(repo, out)}: ${figureNo} figures`);
