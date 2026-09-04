#!/usr/bin/env node
// The fold policy's own self-test — and the proof that it can go red.
//
// `node tools/chain/calltrace-fold-selftest.mjs`
//
// ── What this checks, and why it does not need a container ──────────────────
//
// `derive-calltrace.mjs` needs `ct-print` and a `.ct`; neither is available to
// CI, which is exactly how `chain-selftest`'s three suites came to be referenced
// by nothing. So this drives the part that is arithmetic —
// `lib/calltrace_frames.mjs` — over an event stream RECONSTRUCTED from the
// committed sidecars, and needs nothing but node.
//
// The reconstruction is mechanical and it is itself asserted: §1 rebuilds the
// container's `Path`/`Function`/`Call`/`Return`/`Step` stream from the UNFOLDED
// sidecar's forty-six frames, runs the real policy over it, and requires the
// answer to equal the FOLDED sidecar field for field. Two committed files, one
// derivation, and a round trip between them — so a policy that drifted from the
// bytes on disk fails here rather than at some later reader.
//
// ── §2 IS THE POINT: EVERY GATE ABOVE IS SHOWN TO FAIL ──────────────────────
//
// A check nobody has watched go red is a check whose only evidence is that
// someone once watched it go green. Each arm below mutates ONE thing — the rule,
// the tree, the clock — re-runs the same gate, and requires it to fail AND to
// name what it found. An arm that does not kill is itself a failure here, which
// is what stops this file from becoming a list of mutations that stopped biting.

import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import process from 'node:process';

import { DEFAULT_FOLD_RULES, foldRuleFor } from './fold_rules.mjs';
import { buildFrames, MalformedCallStream } from './lib/calltrace_frames.mjs';

const here = dirname(new URL(import.meta.url).pathname);
const repo = resolve(here, '..', '..');
const TX = '0x20ed5b91fae2fc7e564a062434b305d1c250ecad93da70e8e46e7f124d26185f';
const fixtures = join(repo, 'client', 'fixtures', 'noir-frames');
const read = (p) => JSON.parse(readFileSync(p, 'utf8'));

const folded = read(join(fixtures, 'calltrace', `${TX}.json`));
const unfolded = read(join(fixtures, 'calltrace-unfolded', `${TX}.json`));

// ── THE CONTROL IS NO LONGER `TX`, AND THAT IS THE POINT ────────────────────
//
// `TX` used to be its own control: the published capture held the OLD recorder's
// two-frame container for it, so one hash served as both the frames subject (out
// of `client/fixtures/noir-frames/`) and the frameless one (out of the capture).
// That coincidence ended when the frames container was published for `TX` — the
// capture now carries forty-six frames for it, and a control read from there
// would be asserting the subject against itself.
//
// So the control is chosen FROM THE CORPUS rather than named: the published
// aztec-testnet capture's two-frame containers, of which there are many, taken in
// sorted order so the pick is stable across runs and machines. §3 asserts the
// population it was drawn from, because "the majority shape" is the control's
// whole premise and a premise nobody counts is a premise that quietly stops
// being true — the corpus going all-frames would otherwise leave this suite
// green with no control at all.
const captureCalltrace = join(repo, 'client', 'fixtures', 'chain', 'aztec-testnet',
  'calltrace');
const corpus = readdirSync(captureCalltrace).filter((f) => f.endsWith('.json')).sort()
  .map((f) => ({ tx: f.slice(0, -5), doc: read(join(captureCalltrace, f)) }));
const frameless = corpus.filter((c) => c.doc.frames === 2);
const withFrames = corpus.filter((c) => c.doc.frames > 2);
const CONTROL_TX = frameless.length > 0 ? frameless[0].tx : null;
const control = CONTROL_TX === null ? null : frameless[0].doc;

let asserted = 0;
let failed = 0;
const eq = (what, got, want) => {
  asserted += 1;
  const g = JSON.stringify(got);
  const w = JSON.stringify(want);
  if (g === w) return true;
  failed += 1;
  console.error(`  FAIL ${what}\n    got  ${g}\n    want ${w}`);
  return false;
};
const ok = (what, cond, detail = '') => {
  asserted += 1;
  if (cond) return true;
  failed += 1;
  console.error(`  FAIL ${what}${detail ? `\n    ${detail}` : ''}`);
  return false;
};

/**
 * Turn a sidecar's flat frame list back into the container event stream it was
 * read out of.
 *
 * Frames arrive in call order with a `depth`, which is enough to replay the
 * opens and closes exactly: a frame at depth <= the top of the stack closes
 * everything at or below it first. `Step` events are emitted between calls so
 * that each frame's step charge comes out where the recording put it — the step
 * a frame opened at is `step`, and it closes at `endStep`.
 */
function streamOf(sidecar) {
  const paths = ['/aztec/pseudo.avm'];
  const pathId = new Map();
  const functions = [];
  const functionId = new Map();
  const events = [];

  const internPath = (p) => {
    if (p === null) return 0;
    if (!pathId.has(p)) { pathId.set(p, paths.length); paths.push(p); }
    return pathId.get(p);
  };
  const internFn = (f) => {
    const key = `${f.name}#${f.path}#${f.line}`;
    if (!functionId.has(key)) {
      functionId.set(key, functions.length);
      functions.push({
        type: 'Function', path_id: internPath(f.path), line: f.line ?? 1, name: f.name,
      });
    }
    return functionId.get(key);
  };

  // Order the opens and closes on one timeline, then walk it emitting Steps in
  // between so the step clock lands where the sidecar says it does.
  // A FRAME WITH `endStep: null` IS NEVER CLOSED, AND THAT IS THE CONTAINER'S
  // OWN SHAPE RATHER THAN A GAP IN THE DATA.
  //
  // Every container this repository holds carries exactly one more `Call` than
  // `Return`: the session root, `function_id 0`, the synthetic `<toplevel>` the
  // trace writer emits on open and that `ct_calls_opened()` does not count. It
  // has no closing `Return`, which is why `derive-calltrace.mjs` writes
  // `endStep: null` for it and why `ingest.nim`'s refusal reads
  // `calls == callsOpened + 1`. Measured on both the published container (2
  // Call, 1 Return) and the frames fixture (46 Call, 45 Return).
  //
  // Closing it here produced the ONLY field that differed on the round trip —
  // `<toplevel>`'s endStep came back 108 against the committed `null` — which is
  // this reconstruction being wrong about the container, not the derivation
  // being wrong about the frame. Corrected here.
  const marks = [];
  const stack = [];
  const frames = sidecar.frame;
  const closeAt = (i) => frames[i].endStep;
  for (let i = 0; i < frames.length; i++) {
    const f = frames[i];
    while (stack.length > 0 && frames[stack[stack.length - 1]].depth >= f.depth) {
      const c = stack.pop();
      if (closeAt(c) !== null) marks.push({ at: closeAt(c), kind: 'return', i: c });
    }
    marks.push({ at: f.step, kind: 'call', i });
    stack.push(i);
  }
  while (stack.length > 0) {
    const c = stack.pop();
    if (closeAt(c) !== null) marks.push({ at: closeAt(c), kind: 'return', i: c });
  }

  for (const p of paths) events.push({ type: 'Path', name: p });
  // Function definitions are interned on first use, so they are collected by the
  // walk below and spliced in at the front afterwards — which is where a
  // container puts them.
  const body = [];
  let step = 0;
  let m = 0;
  const total = sidecar.steps ?? 0;
  const flushTo = (target) => {
    while (step < target) { body.push({ type: 'Step', path_id: 0, line: step }); step += 1; }
  };
  // Stable order at one step index: returns before calls, and among returns the
  // deepest first — the LIFO a container writes.
  marks.sort((a, b) => (a.at - b.at)
    || (a.kind === b.kind ? 0 : (a.kind === 'return' ? -1 : 1))
    || (a.kind === 'return' ? frames[b.i].depth - frames[a.i].depth
      : frames[a.i].depth - frames[b.i].depth));
  while (m < marks.length) {
    flushTo(marks[m].at);
    const mk = marks[m];
    if (mk.kind === 'call') {
      body.push({ type: 'Call', function_id: internFn(frames[mk.i]), args: [] });
    } else {
      body.push({ type: 'Return' });
    }
    m += 1;
  }
  flushTo(total);

  // `paths` grew while functions were interned, so the Path events are rebuilt
  // now that the table is complete.
  const head = paths.map((p) => ({ type: 'Path', name: p }));
  return [...head, ...functions, ...body];
}

const stream = streamOf(unfolded);

// ---------------------------------------------------------------------------
console.log('== 1. the reconstruction round-trips, and the policy reproduces the folded sidecar');
// ---------------------------------------------------------------------------
const rebuilt = buildFrames(stream, { rules: DEFAULT_FOLD_RULES, foldRuleFor });

eq('the stream carries the sidecar\'s own step count', rebuilt.steps, unfolded.steps);
eq('…and its frame count', rebuilt.frames.length, unfolded.frames);
eq('…and one Call per frame', rebuilt.calls, unfolded.frames);

const key = (f) => [f.name, f.depth, f.step, f.path, f.line, f.endStep,
  f.foldedBy, f.hiddenDescendants, f.hiddenSteps];
eq('every frame matches the committed FOLDED sidecar, field for field',
  rebuilt.frames.map(key), folded.frame.map(key));

const foldPoints = rebuilt.frames.filter((f) => f.foldedBy !== null);
eq('two fold points', foldPoints.length, 2);
eq('…both Poseidon2::hash', foldPoints.map((f) => f.name),
  ['Poseidon2::hash', 'Poseidon2::hash']);
eq('…both by the vendored-crate rule', foldPoints.map((f) => f.foldedBy),
  ['vendored-crate', 'vendored-crate']);
// THE NUMBER THE OTHER REPOSITORY MEASURED. `aztec-avm-runtime`'s own arm, a
// different implementation in a different language over the same artifact,
// reports two fold points hiding 22 and 6. If the two rules ever drift, this is
// where it shows.
eq('…hiding 22 and 6 steps, which is 28', foldPoints.map((f) => f.hiddenSteps), [22, 6]);
eq('…and two frames each', foldPoints.map((f) => f.hiddenDescendants), [2, 2]);

// ---------------------------------------------------------------------------
console.log('== 2. THE ARMS — every gate above, shown to fail');
// ---------------------------------------------------------------------------
/**
 * Run an arm and require it to KILL. `run` must throw, or return a reading that
 * differs from the unmutated one; an arm that changes nothing is reported as a
 * failure of this file, not as a pass.
 */
function arm(name, why, run, expect) {
  let outcome;
  try {
    outcome = { kind: 'value', value: run() };
  } catch (err) {
    outcome = { kind: 'threw', message: err.message, isRefusal: err instanceof MalformedCallStream };
  }
  const verdict = expect(outcome);
  asserted += 1;
  if (verdict.killed) {
    console.log(`  KILLED  ${name} — ${verdict.found}`);
  } else {
    failed += 1;
    console.error(`  SURVIVED ${name} (${why})\n    ${verdict.found}`);
  }
}

arm('rule-matches-nothing',
  'the default fold rule, replaced by one that claims no path at all',
  () => buildFrames(stream, {
    rules: [{ id: 'never', why: 'matches nothing', matches: () => false }],
    foldRuleFor,
  }),
  (o) => {
    if (o.kind === 'threw') return { killed: false, found: `threw: ${o.message}` };
    const pts = o.value.frames.filter((f) => f.foldedBy !== null);
    const steps = pts.reduce((a, f) => a + f.hiddenSteps, 0);
    // The §1 gate, re-run against this arm's tree. It must not hold.
    const killed = !(pts.length === 2 && steps === 28);
    return {
      killed,
      found: `${pts.length} fold point(s) hiding ${steps} step(s), against the gate's `
        + '2 hiding 28 — and all 46 frames still present, none of them closed',
    };
  });

arm('rule-matches-everything',
  'a rule that claims every path, so the fold lands at the outermost Noir frame',
  () => buildFrames(stream, {
    rules: [{ id: 'always', why: 'matches everything', matches: () => true }],
    foldRuleFor,
  }),
  (o) => {
    if (o.kind === 'threw') return { killed: false, found: `threw: ${o.message}` };
    const pts = o.value.frames.filter((f) => f.foldedBy !== null);
    const killed = !(pts.length === 2 && pts.every((f) => f.name === 'Poseidon2::hash'));
    return {
      killed,
      found: `${pts.length} fold point(s), outermost is '${pts[0]?.name}' hiding `
        + `${pts[0]?.hiddenSteps} step(s) — not the hash`,
    };
  });

arm('leaf-marked-folded',
  'the never-fold-a-leaf rule: a policy claiming a childless frame',
  () => {
    // `derive_eq` in `std/cmp.nr` is a leaf on this recording and matches
    // `noir-stdlib`. It must NOT come back folded.
    const built = buildFrames(stream, { rules: DEFAULT_FOLD_RULES, foldRuleFor });
    return built.frames.filter((f) => f.foldedBy !== null && f.hiddenDescendants === 0);
  },
  (o) => {
    if (o.kind === 'threw') return { killed: false, found: `threw: ${o.message}` };
    // This arm inverts: the gate is "no leaf is ever marked", and it is shown to
    // be a real constraint by the fact that a leaf IS matched by the rule.
    const leavesMatched = buildFrames(stream, { rules: DEFAULT_FOLD_RULES, foldRuleFor })
      .frames.filter((f) => f.path !== null
        && foldRuleFor(f.path, DEFAULT_FOLD_RULES) !== null
        && f.foldedBy === null);
    return {
      killed: o.value.length === 0 && leavesMatched.length > 0,
      found: `${o.value.length} folded frame(s) with no descendants, and `
        + `${leavesMatched.length} frame(s) the rule matches but does not fold `
        + `(e.g. '${leavesMatched[0]?.name}' in ${leavesMatched[0]?.path}) — so the `
        + 'never-fold-a-leaf rule is load-bearing rather than vacuous',
    };
  });

// AN ARM THAT SURVIVED, AND WHAT IT COST THE CODE RATHER THAN THIS FILE.
//
// `step-clock-disagrees` moved a fold point's `endStep` by three and required
// `foldSubtrees`'s cross-check — `hiddenSteps` by charge against `endStep - step`
// by the recording's clock — to refuse. IT SURVIVED, and the reason is that the
// two quantities were never two producers: both come off the same single walk,
// and every Step between a frame's Call and its Return is charged inside that
// frame's subtree by construction. The check could not fail on a well-formed
// stream and the nesting refusals fire first on a malformed one.
//
// The check was REMOVED rather than the arm quietly dropped. See the comment
// where it used to live in `lib/calltrace_frames.mjs`. What replaces it here is
// an arm against a gate that does bite: the summary a sidecar publishes about
// its own rows, which is what `ingest.nim` refuses on.
arm('summary-contradicts-the-rows',
  'the sidecar\'s declared fold totals, moved away from what its frames carry',
  () => {
    const built = buildFrames(stream, { rules: DEFAULT_FOLD_RULES, foldRuleFor });
    const marked = built.frames.filter((f) => f.foldedBy !== null);
    // The gate, as `derive-calltrace.mjs` writes it and `ingest.nim` re-checks
    // it: the declared totals must equal what the rows carry.
    const declaredFrames = folded.foldedFrames + 1;      // ← the mutation
    const declaredSteps = folded.foldedSteps;
    return {
      agrees: marked.length === declaredFrames
        && marked.reduce((a, f) => a + f.hiddenSteps, 0) === declaredSteps,
      marked: marked.length,
      declaredFrames,
    };
  },
  (o) => {
    if (o.kind === 'threw') return { killed: false, found: `threw: ${o.message}` };
    return {
      killed: !o.value.agrees,
      found: `the rows carry ${o.value.marked} folded frame(s) against a declared `
        + `${o.value.declaredFrames}; ingest.nim refuses to publish a summary the rows contradict`,
    };
  });

arm('path-id-past-the-table',
  'a frame placed on an interned path the container does not declare',
  () => {
    const s = stream.map((e) => (e.type === 'Function' && e.name === 'Poseidon2::hash'
      ? { ...e, path_id: 999 } : e));
    return buildFrames(s, { rules: DEFAULT_FOLD_RULES, foldRuleFor });
  },
  (o) => ({
    killed: o.kind === 'threw' && o.isRefusal && /quotes interned path 999/.test(o.message),
    found: o.kind === 'threw' ? o.message : 'no refusal — a frame was placed on a path that does not exist',
  }));

// THE FORMAT BOUNDARY. `path-id-past-the-table` above covers an id that is
// PRESENT AND WRONG. This covers the other side — an id that is ABSENT, which is
// what a container format with no per-function path field produces, and which
// used to be folded into the pseudo-path by `?? 0` and then silently reported as
// `foldedFrames: 0`. Two arms, because the refusal is only half the claim: the
// second shows what the sidecar WOULD have said, so the ambiguity being closed
// is visible rather than asserted.
arm('path-id-missing',
  'a container whose functions carry no path_id at all — a format that cannot say',
  () => {
    const s = stream.map((e) => {
      if (e.type !== 'Function') return e;
      const { path_id, ...rest } = e;
      return rest;
    });
    return buildFrames(s, { rules: DEFAULT_FOLD_RULES, foldRuleFor });
  },
  (o) => ({
    killed: o.kind === 'threw' && o.isRefusal && /declares no path_id at all/.test(o.message),
    found: o.kind === 'threw' ? o.message
      : 'no refusal — every frame was placed on the pseudo-path, nothing could fold, '
        + 'and the sidecar would have published foldedFrames: 0',
  }));

// WHAT THE AMBIGUITY ACTUALLY LOOKS LIKE, measured on the same stream with the
// refusal stepped around. This does not exercise the guard; it establishes the
// fact the guard exists for — that the unfoldable container and a container with
// no library code produce the SAME NUMBER — so the refusal above is protecting
// something real rather than restating its own message.
arm('unfoldable-and-library-free-agree-on-zero',
  'the two causes of foldedFrames: 0, shown to be indistinguishable by the count alone',
  () => {
    // Path ids present, but every path rewritten to contract-owned source: real
    // paths, no rule matches. "Nothing qualified."
    const contractOnly = stream.map((e) => (e.type === 'Path'
      ? { ...e, name: e.name.startsWith('/aztec/') ? e.name : 'fee_juice_contract/src/main.nr' }
      : e));
    const libraryFree = buildFrames(contractOnly, { rules: DEFAULT_FOLD_RULES, foldRuleFor });
    const libraryFreeFolds = libraryFree.frames.filter((f) => f.foldedBy !== null).length;
    // The unfoldable shape, under the REAL rules. `path_id: 0` on every function
    // is exactly what the old `fn.path_id ?? 0` produced for a container that
    // carried no path field: the pseudo-path, which resolves to `path === null`,
    // which no rule can match. So this is the pre-fix behaviour reproduced
    // faithfully, not folding switched off — an arm that passed `rules: []`
    // would be asserting that no rules fold nothing, which is a different and
    // much weaker claim than the sentence above it.
    const pseudoPathed = stream.map((e) => (e.type === 'Function'
      ? { ...e, path_id: 0 } : e));
    const unfoldableFolds = buildFrames(pseudoPathed,
      { rules: DEFAULT_FOLD_RULES, foldRuleFor })
      .frames.filter((f) => f.foldedBy !== null).length;
    return { libraryFreeFolds, unfoldableFolds };
  },
  (o) => {
    if (o.kind === 'threw') return { killed: false, found: `threw: ${o.message}` };
    const { libraryFreeFolds, unfoldableFolds } = o.value;
    return {
      killed: libraryFreeFolds === 0 && unfoldableFolds === 0,
      found: `a library-free container folds ${libraryFreeFolds} and an unfoldable one folds `
        + `${unfoldableFolds} — the same number, which is why the count alone cannot tell them `
        + 'apart and the refusal has to happen before the sidecar is written',
    };
  });

arm('return-with-nothing-open',
  'a Return event with an empty stack',
  () => buildFrames([...stream, { type: 'Return' }, { type: 'Return' }],
    { rules: DEFAULT_FOLD_RULES, foldRuleFor }),
  (o) => ({
    killed: o.kind === 'threw' && o.isRefusal && /never opened/.test(o.message),
    found: o.kind === 'threw' ? o.message : 'no refusal — a malformed stream was accepted',
  }));

// ---------------------------------------------------------------------------
console.log('== 3. the control: a container with no Noir frames is untouched by all of it');
// ---------------------------------------------------------------------------
// The published corpus's own shape, and still the majority one. The policy must
// not invent a fold where there is no library code, and must not disturb the two
// rows the pane has always shown.
//
// THE POPULATION IS ASSERTED BEFORE THE CONTROL IS USED. A suite that picked its
// control out of a list could be handed an empty list and report nothing wrong;
// counting both halves means the day the corpus stops carrying a frameless
// container is the day this says so, rather than the day it silently stops
// controlling anything.
ok('the published capture still carries a frameless container to control against',
  CONTROL_TX !== null,
  `${corpus.length} published calltrace sidecar(s), none of them two-frame`);
ok(`corpus split: ${frameless.length} frameless, ${withFrames.length} with Noir frames`,
  frameless.length > 0 && withFrames.length > 0,
  `${frameless.length} frameless / ${withFrames.length} with frames — the suite needs one of each`);
ok(`the frames container in the corpus is ${TX.slice(0, 14)}…`,
  withFrames.some((c) => c.tx === TX),
  `containers with frames: ${withFrames.map((c) => `${c.tx.slice(0, 14)}…`).join(', ') || '(none)'}`);
// NO CONTROL IS A HARD STOP, not a skipped section. The three assertions above
// have already been counted as failures; running on would throw a TypeError and
// bury them under a stack trace, so this reports and exits with the count intact.
if (CONTROL_TX === null) {
  console.log(`\ncalltrace-fold-selftest: ${asserted} assertion(s), ${failed} failure(s)`);
  process.exit(1);
}
console.log(`  control is ${CONTROL_TX.slice(0, 14)}…, drawn from `
  + `${frameless.length} frameless container(s) in the published capture`);

const controlStream = streamOf(control);
const controlBuilt = buildFrames(controlStream, { rules: DEFAULT_FOLD_RULES, foldRuleFor });
eq('two frames', controlBuilt.frames.map((f) => f.name), ['<toplevel>', 'enqueued-call-0']);
eq('…on the pseudo-path, so no path and no line',
  controlBuilt.frames.map((f) => [f.path, f.line]), [[null, null], [null, null]]);
eq('…and nothing folded', controlBuilt.frames.filter((f) => f.foldedBy !== null).length, 0);

// An empty stream is a valid container as far as this is concerned: 957 of the
// 1,356 published rows carry no frame records at all, and that is the shape the
// live page is mostly made of.
const empty = buildFrames([{ type: 'Path', name: '/aztec/x.avm' }],
  { rules: DEFAULT_FOLD_RULES, foldRuleFor });
eq('a container with no frames yields no frames, and does not throw',
  [empty.frames.length, empty.calls, empty.returns], [0, 0, 0]);

console.log(`\ncalltrace-fold-selftest: ${asserted} assertion(s), ${failed} failure(s)`);
process.exit(failed === 0 ? 0 : 1);
