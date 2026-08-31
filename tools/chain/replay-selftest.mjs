#!/usr/bin/env node
// replay-selftest.mjs — proof that the verdict rule in `lib/replay.mjs` bites.
//
//   node tools/chain/replay-selftest.mjs
//
// WHY THIS EXISTS AND WHY IT DOES NOT TALK TO A CHAIN.
//
// The follower's headline claim — "it never publishes a container the driver did not
// reproduce, and it never files a divergence as a refusal" — is a UNIVERSAL statement over
// the transactions it caught. Verification-Harness-Traps §4: universal quantification over
// an empty set is a pass, and it is the cheapest false green in the harness. While the
// follower has caught nothing, every such claim about it is vacuously true, and a suite
// that only ran the follower against a live node would report green for exactly that
// reason on a chain that produces a transaction every two hours.
//
// So the verdict rule is driven here with RECORDED DRIVER OUTPUT instead: every branch is
// reachable without a node, an AVM or a chain, and every branch is reached on every run.
// The set of outcomes is knowable, so its SIZE is asserted rather than its non-emptiness
// (§4b: an "at least one" control was satisfied by one member of three).
//
// Each case carries a CONTROL arm and a MUTATION arm, and every mutation is checked to
// redden the assertion written for it (§4a: the pairing is the control — a negative
// assertion with no positive twin running through the same code path has nothing to fail).

import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { decideOutcome, refusalName, refusalDetail } from './lib/replay.mjs';

let asserted = 0;
let failed = 0;
const ck = (label, cond) => {
  asserted++;
  if (!cond) { failed++; console.error(`  FAIL  ${label}`); }
  else console.error(`  ok    ${label}`);
};
/** A mutation arm is only evidence if it REDDENS. `bite` asserts the mutated input
 *  produces the wrong answer, which is what proves the control arm was measuring
 *  something rather than agreeing with everything. */
const bite = (label, cond) => {
  asserted++;
  if (!cond) { failed++; console.error(`  FAIL  MUTATION DID NOT BITE  ${label}`); }
  else console.error(`  bite  ${label}`);
};
const expectCount = (expected) => {
  if (asserted !== expected) {
    failed++;
    console.error(`\nASSERTION COUNT IS ${asserted}, EXPECTED ${expected} — a case was `
      + `added, removed or silently skipped.`);
  } else {
    console.error(`\nassertion count: ${asserted} (as declared)`);
  }
};

// ── recorded driver output ────────────────────────────────────────────────────────────
// Shaped exactly as `replay_settled_transaction.mjs --json` prints it. Trimmed to the
// fields `decideOutcome` reads, plus the ones it copies through.

const reproducedReport = {
  l2BlockNumber: 63675, txIndexInBlock: 0, preStateReadAt: 63674,
  contractReferenceBlock: 63674, rounds: 3, seedSize: 4096,
  instructionsExecuted: 128_311,
  published: { revertCode: 0 }, replayed: { revertCode: 0 },
  verdict: { reproduced: true, matched: 13, mismatched: 0 },
  mismatches: [],
  recording: { steps: 41_233, declaredRung: 3, stepsPositioned: 0 },
  roots: { noteHash: '0xaa', nullifier: '0xbb' }, rootsAnyAgree: false, skipped: [],
};

const divergentReport = {
  ...reproducedReport,
  verdict: { reproduced: false, matched: 11, mismatched: 2 },
  mismatches: [{ kind: 'transactionFee' }, { kind: 'publicDataWrite' }],
};

// A run that COMPARED NOTHING. `reproduced` is false and `matched` is 0, which is the
// shape `effects.reproduced` alone would hide.
const comparedNothingReport = {
  ...reproducedReport,
  verdict: { reproduced: false, matched: 0, mismatched: 0 },
  mismatches: [],
};

const REFUSAL_STDERR =
  'reading block 63675\n  IntraBlockPredecessorsUnavailable: replaying tx 1 needs the '
  + 'state after tx 0 and the node does not serve it\n';

async function main() {
  const dir = await mkdtemp(join(tmpdir(), 'bt-replay-selftest-'));
  const ctPath = join(dir, 'present.ct');
  await writeFile(ctPath, Buffer.alloc(188_416, 7));
  const REL = 'ct/0xdeadbeef.ct';
  const outcomes = [];

  const decide = (r, onDisk = true, bytes = 188_416) =>
    decideOutcome(r, REL, onDisk, bytes);

  // ── CASE 1 — a reproduced run is `replayed`, and it publishes its container ─────────
  console.error('\ncase 1 — a reproduced run is `replayed` and publishes its container');
  {
    const d = decide({ code: 0, out: JSON.stringify(reproducedReport), err: '' });
    outcomes.push(d.outcome);
    ck('control: outcome is `replayed`', d.outcome === 'replayed');
    ck('control: it is marked replayed', d.replayed === true);
    ck('control: the container is published', d.container === REL);
    ck('control: effects.reproduced is true', d.effects.reproduced === true);
    ck('control: the whole comparison travels, not just the verdict',
       d.effects.matched === 13 && d.effects.mismatched === 0);
    ck('control: the recording facts travel', d.recording.steps === 41_233
       && d.recording.declaredRung === 3);
    ck('control: the disagreeing roots travel rather than being dropped',
       d.rootsAnyAgree === false && d.roots.noteHash === '0xaa');

    // MUTATION: the driver did not reproduce. The SAME report, one boolean moved.
    const m = decide({ code: 1, out: JSON.stringify(divergentReport), err: '' });
    bite('mutation: a non-reproduced report is NOT `replayed`', m.outcome !== 'replayed');
  }

  // ── CASE 2 — a divergence is `divergent`, NOT a refusal, and it keeps its container ─
  // The positive twin of case 3's "a refusal publishes nothing": both run through
  // `decideOutcome`, so a rule that started refusing everything would redden case 2 and a
  // rule that started publishing everything would redden case 3.
  console.error('\ncase 2 — a divergence is a recording, not a refusal');
  {
    const d = decide({ code: 1, out: JSON.stringify(divergentReport), err: '' });
    outcomes.push(d.outcome);
    ck('control: outcome is `divergent`', d.outcome === 'divergent');
    ck('control: it is NOT a refusal', d.outcome !== 'refused' && d.refusal === undefined);
    ck('control: it IS marked replayed — the recording is real and it steps',
       d.replayed === true);
    ck('control: the container is published', d.container === REL);
    ck('control: effects.reproduced is false', d.effects.reproduced === false);
    ck('control: the mismatches travel so the page can name them',
       d.effects.mismatches.length === 2);

    // MUTATION: the driver reported, and wrote nothing. A report pointing at a container
    // that is not there must become a refusal rather than a row naming a missing file.
    const m = decide({ code: 1, out: JSON.stringify(divergentReport), err: '' }, false, 0);
    bite('mutation: no container on disk turns the same report into a refusal',
         m.outcome === 'refused' && m.refusal === 'no-container-written');
    bite('mutation: and it publishes no container', m.container === undefined);
  }

  // ── CASE 3 — no report is a refusal, BY NAME ───────────────────────────────────────
  console.error('\ncase 3 — no report is a refusal, and it keeps the runtime\'s name');
  {
    const d = decide({ code: 1, out: 'not json at all', err: REFUSAL_STDERR }, false, 0);
    outcomes.push(d.outcome);
    ck('control: outcome is `refused`', d.outcome === 'refused');
    ck('control: the refusal keeps the runtime\'s own name',
       d.refusal === 'IntraBlockPredecessorsUnavailable');
    ck('control: it is not marked replayed', d.replayed === false);
    ck('control: it publishes NO container', d.container === undefined);
    ck('control: the reason names the refusal so a page can state it',
       d.reason.includes('IntraBlockPredecessorsUnavailable'));

    // MUTATION: strip the name out of stderr. The refusal must degrade to `unknown`,
    // which proves the extraction is load-bearing rather than decorative.
    const m = decide({ code: 1, out: 'not json', err: 'something went wrong\n' }, false, 0);
    bite('mutation: an unnamed stderr degrades the refusal to `unknown`',
         m.refusal === 'unknown');
    // And the extractor itself, directly — a positive twin for the negative above.
    ck('refusalName finds a named refusal', refusalName(REFUSAL_STDERR)
       === 'IntraBlockPredecessorsUnavailable');
    ck('refusalName reports `unknown` rather than throwing on unnamed output',
       refusalName('no name here') === 'unknown');
  }

  // ── CASE 4 — THE EXIT-CODE TRAP ────────────────────────────────────────────────────
  // The regression this rule was written for: the driver exits 1 on a divergence AND
  // still prints its report. Deciding by exit code filed a transaction that matched 11
  // of 13 effects as `refusal: unknown`. This case pins that the report wins.
  console.error('\ncase 4 — a non-zero exit with a report is still a replay');
  {
    const d = decide({ code: 1, out: JSON.stringify(divergentReport), err: 'exit 1\n' });
    ck('control: exit 1 + a report is a REPLAY, not a refusal',
       d.replayed === true && d.outcome === 'divergent');
    ck('control: it did not pick up a refusal name from the stderr',
       d.refusal === undefined);

    // The mutation is the OLD RULE, evaluated over the same input, asserted to give the
    // wrong answer — the shape `test_chain_provenance.nim`'s MUTATION BITE arms use.
    const byExitCode = ({ code }) => (code === 0 ? 'replayed' : 'refused');
    bite('mutation: deciding by exit code calls this same run a refusal',
         byExitCode({ code: 1 }) === 'refused' && d.outcome !== 'refused');

    // And the other direction: exit 0 with no report is still a refusal, so the rule is
    // not merely "ignore the exit code when it is 1".
    const z = decide({ code: 0, out: '', err: 'Nothing: quiet failure\n' }, false, 0);
    ck('control: exit 0 with NO report is still a refusal', z.outcome === 'refused');
  }

  // ── CASE 5 — `reproduced` is READ, never inferred from an empty mismatch list ───────
  console.error('\ncase 5 — a run that compared nothing is not a clean reproduction');
  {
    const d = decide({ code: 1, out: JSON.stringify(comparedNothingReport), err: '' });
    outcomes.push(d.outcome);
    ck('control: zero mismatches does NOT make it `replayed`', d.outcome === 'divergent');
    ck('control: the zero match count is visible rather than hidden',
       d.effects.matched === 0 && d.effects.mismatched === 0);

    // MUTATION: infer the verdict from the mismatch list, as a careless reading would.
    const inferred = (rep) => (rep.mismatches.length === 0 ? 'replayed' : 'divergent');
    bite('mutation: inferring from the mismatch list calls this a reproduction',
         inferred(comparedNothingReport) === 'replayed' && d.outcome === 'divergent');

    // Positive twin: a genuinely reproduced report ALSO has an empty mismatch list, so
    // the two are only tellable apart by reading `verdict.reproduced`. Without this arm
    // the assertion above could be satisfied by a rule that called everything divergent.
    const good = decide({ code: 0, out: JSON.stringify(reproducedReport), err: '' });
    ck('twin: the same empty mismatch list with reproduced=true IS `replayed`',
       good.outcome === 'replayed');
  }

  // ── CASE 6 — a malformed report is a refusal, not a crash ──────────────────────────
  console.error('\ncase 6 — a report with no verdict is a refusal, not an exception');
  {
    const d = decide({ code: 0, out: JSON.stringify({ hello: 'world' }), err: 'Weird: x\n' },
                     false, 0);
    outcomes.push(d.outcome);
    ck('control: a JSON object with no verdict is a refusal', d.outcome === 'refused');
    ck('control: it publishes no container', d.container === undefined);
  }

  // ── the outcome set, by SIZE ───────────────────────────────────────────────────────
  // §4b: assert the size when the size is knowable. Five cases pushed an outcome and the
  // three legal values must all be present — a rule that collapsed to one answer would
  // still satisfy "every outcome is one of the three".
  console.error('\nthe outcome set');
  {
    const distinct = [...new Set(outcomes)].sort();
    ck('every branch was reached: 5 outcomes recorded', outcomes.length === 5);
    ck('all three legal outcomes occur, none collapsed away',
       distinct.length === 3
       && distinct.join(',') === 'divergent,refused,replayed');
    ck('no outcome outside the three the ingest switches on',
       outcomes.every((o) => ['replayed', 'divergent', 'refused'].includes(o)));
  }

  // ── the container invariant, stated as the follower's headline claim ───────────────
  // The claim is universal, so it is stated over a set whose size is asserted first —
  // otherwise it is the empty-set pass trap 4 is about.
  console.error('\nthe headline invariant');
  {
    const table = [
      decide({ code: 0, out: JSON.stringify(reproducedReport), err: '' }),
      decide({ code: 1, out: JSON.stringify(divergentReport), err: '' }),
      decide({ code: 1, out: 'nope', err: REFUSAL_STDERR }, false, 0),
      decide({ code: 1, out: JSON.stringify(divergentReport), err: '' }, false, 0),
    ];
    ck('the invariant is asserted over a NON-EMPTY set of known size', table.length === 4);
    const published = table.filter((d) => d.container !== undefined);
    ck('exactly two of the four publish a container', published.length === 2);
    ck('every published container came from a driver that WROTE one',
       published.every((d) => d.replayed === true));
    ck('no refusal publishes a container',
       table.filter((d) => d.outcome === 'refused').every((d) => d.container === undefined));
    ck('and the refusals are a non-empty set, so the line above is not vacuous',
       table.filter((d) => d.outcome === 'refused').length === 2);
  }

  // ── CASE 7 — a refusal's DETAIL carries the message, not the Node banner ───────────
  // The two mainnet catches of 2026-08-31 recorded `detail: "}  Node.js v24.19.0"` because
  // the extraction took the LAST three lines of a stack trace. The name survived, so the
  // row was not wrong — it was useless in the one field that explains the loss.
  console.error('\ncase 7 — a refusal detail says what went wrong');
  {
    // Shaped as node really prints an uncaught throw: message first, frames, then banner.
    const realStderr = [
      'file:///rt/node-host/src/loader.ts:110',
      '    throw new AvmToolchainRegression(',
      '          ^',
      '',
      'AvmToolchainRegression: /rt/vm2wasm/avm.wasm imports no memory. This host is for',
      '--import-memory modules, which is how barretenberg links every wasm artefact.',
      '    at compileAvm (file:///rt/node-host/src/loader.ts:110:11)',
      '    at async main (file:///rt/replay/tools/replay_settled_transaction.mjs:88:3)',
      '',
      'Node.js v24.19.0',
      '',
    ].join('\n');

    const d = decide({ code: 1, out: 'not json', err: realStderr }, false, 0);
    ck('control: the refusal is named', d.refusal === 'AvmToolchainRegression');
    ck('control: the detail names the module that was refused',
       d.detail.includes('imports no memory'));
    ck('control: the detail does NOT end at the Node banner',
       !d.detail.includes('Node.js v24'));
    ck('control: the detail carries no stack frames', !d.detail.includes('    at '));
    ck('control: the detail is non-empty', d.detail.length > 20);

    // MUTATION BITE: the pre-fix extraction over the SAME stderr, asserted to reproduce
    // exactly the useless string that shipped.
    const oldWay = realStderr.trim().split('\n').slice(-3).join(' ').slice(0, 400);
    bite('mutation: the old last-three-lines rule yields the Node banner',
         oldWay.includes('Node.js v24') && !oldWay.includes('imports no memory'));

    // A positive twin for "no frames": stderr that is ONLY frames still yields something
    // rather than an empty field, so the negative above cannot be met by returning "".
    const onlyFrames = '    at a (x.ts:1:1)\n    at b (y.ts:2:2)\nNode.js v24.19.0\n';
    ck('twin: an all-noise stderr still yields a (possibly empty) string, never a throw',
       typeof refusalDetail(onlyFrames, 'unknown') === 'string');
    ck('refusalDetail prefers the named line when there is one',
       refusalDetail(realStderr, 'AvmToolchainRegression').startsWith('AvmToolchainRegression:'));
  }

  await rm(dir, { recursive: true, force: true });
  ck('the temp container was cleaned up', !existsSync(ctPath));

  // 51: 7 cases (7+1, 6+2, 5+1+2, 3+1, 3+1, 2, 7+1) = 42, plus 3 outcome-set, 5 invariant,
  // 1 cleanup. Declared rather than derived, so adding a case without updating this
  // number is a failure — which is the whole point of counting.
  expectCount(51);
  if (failed) {
    console.error(`\nFAIL — ${failed} problem(s)`);
    return 1;
  }
  console.error('\nPASS — the verdict rule bites on every arm');
  return 0;
}

main().then((c) => process.exit(c)).catch((e) => {
  console.error(`replay-selftest: ${e.stack ?? e.message}`);
  process.exit(2);
});
