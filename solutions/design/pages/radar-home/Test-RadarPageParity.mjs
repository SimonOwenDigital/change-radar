// Runs the radar page's pure functions (between ENGINE:BEGIN and ENGINE:END in radar-home.tsx) against
// tests/radar/radar.json, the same cases engine/ChangeRadar.Radar.psm1 passes. Node 22.6+ (type stripping).
// Usage: node Test-RadarPageParity.mjs
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const page = readFileSync(join(here, 'radar-home.tsx'), 'utf8');
const m = /\/\/ ENGINE:BEGIN\r?\n([\s\S]*?)\/\/ ENGINE:END/.exec(page);
if (!m) { console.error('ENGINE markers not found in radar-home.tsx'); process.exit(2); }
const dir = mkdtempSync(join(tmpdir(), 'radar-parity-'));
const mod = join(dir, 'engine.mts');
writeFileSync(mod, m[1] + '\nexport { estateShown, demoDataValue, getTimeBucket, getItemImpact, getTimelineRow, formatRadarHeadline, getRadarSummary, getTimelineBin, getTimelineWindow, getTimelineBins, inPatternWindow, getSolutionGroups, getSolutionSummary, getRelatedSignals, isDemoDataOn };\n');
const e = await import(pathToFileURL(mod).href);

const spec = JSON.parse(readFileSync(join(here, '..', '..', '..', '..', 'tests', 'radar', 'radar.json'), 'utf8'));
const [y, mo, d] = spec.today.split('-').map(Number);
const today = Date.UTC(y, mo - 1, d);
const fails = [];
let n = 0;
const check = (id, actual, expected) => {
  n++;
  const a = JSON.stringify(actual), x = JSON.stringify(expected);
  if (a !== x) fails.push(`${id}: expected ${x}, got ${a}`);
};
for (const c of spec.buckets) check(c.id, e.getTimeBucket(c.keyDate, today), c.expected);
for (const c of spec.impact) check(c.id, e.getItemImpact(c.signal, c.live), c.expected);
for (const c of spec.timeline) check(c.id, e.getTimelineRow(c.signal, today), c.expected);
const s = e.getRadarSummary(spec.summary.signals, today);
for (const k of Object.keys(spec.summary.expected)) check(`summary.${k}`, s[k], spec.summary.expected[k]);
for (const c of spec.headlines) check(c.id, e.formatRadarHeadline(c.counts.actionRequired, c.counts.highImpact, c.next), c.expected);
const iso = (ms) => new Date(ms).toISOString().slice(0, 10);
const dayOf = (s) => { const [a, b, c] = s.split('-').map(Number); return Date.UTC(a, b - 1, c); };
for (const c of spec.bins || []) check(c.id, iso(e.getTimelineBin(dayOf(c.day), c.granularity)), c.expected);
for (const c of spec.patternWindow || []) check(c.id, e.inPatternWindow(c.keyDate, today, c.showOlder), c.expected);
for (const c of spec.windows || []) {
  const w = e.getTimelineWindow(c.preset, today);
  const bins = e.getTimelineBins(w);
  check(c.id, { from: iso(w.from), to: iso(w.to), granularity: w.granularity, bins: bins.length, firstBin: iso(bins[0]), lastBin: iso(bins[bins.length - 1]) }, c.expected);
}
// Solution view (ADR 0020): the page's grouping and per-solution summary against tests/solutions/solutions.json, the
// cases engine/ChangeRadar.Solutions.psm1 passes. Membership itself is decided by the detail flow, not the page.
const sol = JSON.parse(readFileSync(join(here, '..', '..', '..', '..', 'tests', 'solutions', 'solutions.json'), 'utf8'));
for (const c of sol.groups) check(c.id, e.getSolutionGroups(c.assets, c.membership, c.detailEnvironments), c.expected);
for (const c of sol.related || []) check(c.id, e.getRelatedSignals(c.solutionAssets, c.assetFingerprints, c.signalFingerprints, c.affects, sol.relatedFacets), c.expected);
const solToday = dayOf(sol.today);
for (const c of sol.summary) {
  const rows = e.getSolutionSummary(c.solutions, c.membership, c.exposures, solToday)
    .map((r) => ({ uniquename: r.uniquename, assets: r.assets, items: r.items, highest: r.highest, nextDeadline: r.nextDeadline, action: r.action }));
  check(c.id, rows, c.expected);
}
// demo_data switch (ADR 0022): the same cases engine/ChangeRadar.Config.psm1 passes.
const cfg = JSON.parse(readFileSync(join(here, '..', '..', '..', '..', 'tests', 'config', 'config.json'), 'utf8'));
for (const c of cfg.demoData) check(c.id, e.isDemoDataOn(c.value), c.expected);
// The header's demo data switch: what it writes reads back the same way (Simon 2026-11-24).
for (const c of cfg.estateShown) check(c.id, e.estateShown(c.value, c.loaded), c.expected);
for (const c of cfg.demoToggle) check(c.id, [e.demoDataValue(c.on), e.isDemoDataOn(e.demoDataValue(c.on))], [c.writes, c.on]);
for (const f of fails) console.log('FAIL ' + f);
console.log(`${n - fails.length} of ${n} passed.`);
process.exit(fails.length ? 1 : 0);
