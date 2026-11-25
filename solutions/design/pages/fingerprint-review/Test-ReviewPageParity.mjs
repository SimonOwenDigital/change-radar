// Runs the review page's pure functions (between ENGINE:BEGIN and ENGINE:END in fingerprint-review.tsx) against
// tests/review/review.json (hand-written expected effects) and tests/review/engine-scenarios.json (what engine
// Find-Exposures actually did when each accepted fingerprint of the matching test cases was removed). Node 22.6+.
// Usage, from the repo root: node solutions/design/pages/fingerprint-review/Test-ReviewPageParity.mjs
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const page = readFileSync(join(here, 'fingerprint-review.tsx'), 'utf8');
const m = /\/\/ ENGINE:BEGIN\r?\n([\s\S]*?)\/\/ ENGINE:END/.exec(page);
if (!m) { console.error('ENGINE markers not found in fingerprint-review.tsx'); process.exit(2); }
const dir = mkdtempSync(join(tmpdir(), 'review-parity-'));
const mod = join(dir, 'engine.mts');
writeFileSync(mod, m[1] + '\nexport { previewEffect, buildClauses };\n');
const e = await import(pathToFileURL(mod).href);

const testsDir = join(here, '..', '..', '..', '..', 'tests', 'review');
const fails = [];
let n = 0;

// 1. Hand-written expected effects.
const spec = JSON.parse(readFileSync(join(testsDir, 'review.json'), 'utf8'));
for (const c of spec.cases) {
  n++;
  const got = e.previewEffect({
    rows: c.rows,
    rules: c.rules || spec.defaults.rules,
    vocabulary: c.vocabulary || spec.defaults.vocabulary,
    exposures: c.exposures || [],
    target: c.target,
    decision: c.decision,
  });
  const a = JSON.stringify(got), x = JSON.stringify(c.expected);
  if (a !== x) fails.push(`${c.name}: expected ${x}, got ${a}`);
}

// 2. Agreement with the engine: the predicted kind must hold for how the exposed targets actually changed.
//    closes: the group exposes nothing afterwards. widens: nothing lost. narrows / setting-removed: nothing gained.
//    none: nothing lost or gained. (A narrowing can also empty a group in a small estate; that is still a narrowing.)
const holds = {
  closes: (x) => x.afterGroup === 0 && x.gained === 0,
  widens: (x) => x.lost === 0,
  narrows: (x) => x.gained === 0,
  'setting-removed': (x) => x.gained === 0,
  none: (x) => x.lost === 0 && x.gained === 0,
};
const eng = JSON.parse(readFileSync(join(testsDir, 'engine-scenarios.json'), 'utf8'));
for (const s of eng.scenarios) {
  n++;
  const got = e.previewEffect({ rows: s.rows, rules: eng.rules, vocabulary: [], exposures: [], target: s.target, decision: s.decision });
  const ok = !!holds[got.kind] && holds[got.kind](s.engine);
  if (!ok) fails.push(`engine: ${s.name}: page predicts '${got.kind}', engine '${s.engine.change}' (${JSON.stringify(s.engine)})`);
}

for (const f of fails) console.log('FAIL ' + f);
console.log(`${n - fails.length} of ${n} passed (${spec.cases.length} expected cases, ${eng.scenarios.length} engine scenarios).`);
process.exit(fails.length ? 1 : 0);
