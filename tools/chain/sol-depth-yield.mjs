// sol-depth-yield.mjs — RECORDER-SOLANA CXP-SOL-5: THE YIELD OF FORWARD-CHAINED CAPTURE
// AS A FUNCTION OF DEPTH, FROM WHOLE CAPTURED WINDOWS.
//
//   node tools/chain/sol-depth-yield.mjs <capture dir>... [--out <json>]
//
// Each argument is a `capture-sol-window.mjs --out` directory taken with `--depth D`
// (D slots below the head the capture read its accounts at; 0 is a live capture). The
// output is `blocktracer/sol-depth-yield@1`: per window, every transaction accounted
// for, and the curve classified against the charter's prediction.
//
// ── WHAT "DEPTH" MEANS ON THIS ROUTE ───────────────────────────────────────────────────
//
// No RPC serves an account at a past slot (sol-capability-matrix.json). An account read
// now reflects the head, and the replay may use it only once it has passed that slot.
// A window opened D slots below the head therefore holds nothing it did not read before
// the window and cannot use any read for its first D slots. That lag is the depth that
// can bind on this route. Depth below the CHAIN's tip does not: a window already captured
// replays from its own bundles at any later date (`nix build .#sol-capture-tree`).
//
// ── THE FOUR POPULATIONS, AND WHICH ONE IS YIELD ───────────────────────────────────────
//
// Of the transactions that name a program in the capture's scope:
//   match       executed, and every fact the chain recorded agreed. THE YIELD.
//   divergent   executed, and a fact disagreed. Counted AGAINST the yield: a divergent
//               trace is not a delivered product (CXP-SOL-4).
//   refused     not executed, with the recorder's reason (prestate-unavailable or any
//               other), counted per reason class.
//   absent      in scope and never put to the recorder at all. Structurally missing
//               from the measurement. It should be 0; a nonzero count is reported, not
//               dropped.
// `unchecked` is its own count: the check did not run, so it cannot be yield either.
// Votes and out-of-scope transactions are reported beside the populations, never in them.
//
// ── THE PREDICTION, AS A FUNCTION ──────────────────────────────────────────────────────
//
// `classify` is the one predicate, and the selftest drives it rather than a copy
// (Verification-Harness-Traps: "two copies of one predicate let the control agree with
// itself"). It CONFIRMS only when yield is monotone non-increasing in depth, the shallowest
// window yields something, and at least one window yields EXACTLY zero (the floor). A
// flat curve, a deeper window beating a shallower one, or no zero window each REFUTE it,
// by name. A set without both a yielding and a zero window cannot test the prediction
// and is reported as `untestable`, not as confirmed.

import { readFileSync, readdirSync, existsSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

/** One window's accounting, from its blocks.jsonl and results.jsonl. */
export function windowPopulations(dir) {
  const capture = JSON.parse(readFileSync(join(dir, 'capture.json'), 'utf8'));
  const reasonOf = new Map();
  for (const line of readFileSync(join(dir, 'results.jsonl'), 'utf8').split('\n')) {
    if (!line) continue;
    const r = JSON.parse(line);
    if (r.op === 'tx' && r.executed === false) reasonOf.set(r.signature, String(r.reason ?? '').split(':')[0]);
  }
  const w = { transactions: 0, votes: 0, outOfScope: 0, inScope: 0,
    match: 0, divergent: 0, unchecked: 0, refused: {}, absent: 0, t2: 0 };
  for (const line of readFileSync(join(dir, 'blocks.jsonl'), 'utf8').split('\n')) {
    if (!line) continue;
    for (const t of JSON.parse(line).transactions) {
      w.transactions++;
      if (t.vote) { w.votes++; continue; }
      if (!t.inScope) { w.outOfScope++; continue; }
      w.inScope++;
      if (t.result === 'match') {
        w.match++;
        if (isSourceLevel(join(dir, 'traces', t.signature))) w.t2++;
      } else if (t.result === 'divergent') w.divergent++;
      else if (t.result === 'unchecked') w.unchecked++;
      else if (t.result === 'not-executed') {
        const why = reasonOf.get(t.signature) || 'unstated';
        w.refused[why] = (w.refused[why] ?? 0) + 1;
      } else w.absent++;
    }
  }
  return {
    depth: capture.depth?.requested ?? 0,
    window: capture.window,
    headAtOpen: capture.depth?.headAtOpen ?? null,
    capturedAt: capture.capturedAt,
    wallSeconds: capture.wallSeconds,
    scope: capture.scope,
    skippedSlots: capture.counts.skipped,
    ...w,
    ...yieldOf(w),
  };
}

/** A trace steps at source level only if a listing other than SBF disassembly exists. */
function isSourceLevel(traceDir) {
  const listings = join(traceDir, 'listings');
  if (!existsSync(listings)) return false;
  return readdirSync(listings).some((f) => !f.endsWith('.sbf'));
}

/** Yield and its complements, over the in-scope population; divergent counts against. */
export function yieldOf(w) {
  const refusedTotal = Object.values(w.refused).reduce((a, b) => a + b, 0);
  const accounted = w.match + w.divergent + w.unchecked + refusedTotal + w.absent;
  if (accounted !== w.inScope) {
    throw new Error(`window does not account for its in-scope transactions: ${accounted} of ${w.inScope}`);
  }
  return {
    refusedTotal,
    yield: w.inScope ? w.match / w.inScope : null,
    t2Fraction: w.match ? w.t2 / w.match : null,
  };
}

/** The charter's prediction, judged. The ONE predicate; the selftest drives it. */
export function classify(points) {
  const curve = [...points].filter((p) => p.yield !== null).sort((a, b) => a.depth - b.depth);
  if (curve.length < 2) return { verdict: 'untestable', why: 'fewer than two windows with an in-scope transaction' };
  const nonMonotone = [];
  for (let i = 1; i < curve.length; i++) {
    if (curve[i].yield > curve[i - 1].yield) nonMonotone.push(`${curve[i].depth} > ${curve[i - 1].depth}`);
  }
  const zeros = curve.filter((p) => p.yield === 0);
  const shallow = curve[0];
  const spread = Math.max(...curve.map((p) => p.yield)) - Math.min(...curve.map((p) => p.yield));
  if (nonMonotone.length) return { verdict: 'refuted', why: `not monotone in depth: a deeper window yields more at ${nonMonotone.join(', ')}` };
  if (shallow.yield === 0) return { verdict: 'untestable', why: 'the shallowest window yields nothing, so no decline can be seen' };
  if (spread === 0) return { verdict: 'refuted', why: `flat: every window yields ${shallow.yield}` };
  if (zeros.length === 0) return { verdict: 'refuted', why: 'no window reaches zero: the predicted floor was not found in the measured range' };
  return { verdict: 'confirmed',
    why: `monotone non-increasing from ${shallow.yield.toFixed(3)} at depth ${shallow.depth} to 0 from depth ${zeros[0].depth}`,
    floorDepth: zeros[0].depth };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  let out = null;
  const dirs = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--out') out = args[++i];
    else dirs.push(args[i]);
  }
  if (dirs.length === 0) { console.error('usage: sol-depth-yield.mjs <capture dir>... [--out <json>]'); process.exit(2); }
  const windows = dirs.map(windowPopulations).sort((a, b) => a.depth - b.depth);
  const result = {
    format: 'blocktracer/sol-depth-yield@1',
    tool: 'tools/chain/sol-depth-yield.mjs',
    windows,
    prediction: classify(windows),
  };
  const text = JSON.stringify(result, null, 2) + '\n';
  if (out) writeFileSync(out, text); else process.stdout.write(text);
  for (const w of windows) {
    console.error(`depth ${String(w.depth).padStart(5)}: ${w.match}/${w.inScope} match (${w.yield === null ? '-' : (100 * w.yield).toFixed(1) + '%'}), ` +
      `${w.divergent} divergent, ${w.refusedTotal} refused, ${w.absent} absent, T2 ${w.t2}`);
  }
  console.error(`prediction: ${result.prediction.verdict} — ${result.prediction.why}`);
}
