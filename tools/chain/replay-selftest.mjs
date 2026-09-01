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

import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { decideOutcome, refusalName, refusalDetail, completeBlockCount,
         completeBlockNumbers, preflightToolchain, resolverPresence, RESOLVER_PATH }
  from './lib/replay.mjs';

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

  // ── CASE 8 — A REFUSAL NAME IS A SHAPE, NOT A MEMBERSHIP ───────────────────────────
  //
  // Both halves of this case are driven by the same recorded artefact: the stderr of a
  // REAL mainnet replay, captured on 2026-09-01 from tx 0x2a1cd76f at block 68048 while
  // its body was still served. Nothing here is invented.
  //
  // The defects it pins cost two mainnet transactions. 0x09a4747d (block 67798) and
  // 0x2dd44ab6 (block 67802) were caught inside the window with their bodies retained,
  // ran 5.7s and 6.6s — deep into public execution — and were filed as
  // `refusal: "unknown"` with a `detail` that was three lines of Node preamble. Both have
  // since pruned. What refused them cannot now be recovered, which is the whole cost.
  console.error('\ncase 8 — the refusal name is recognised by shape, and the detail '
    + 'outlives the preamble');
  {
    // Names the SUFFIX ALLOWLIST dropped. Every one is a class the replay runtime really
    // defines; none ends in Error/Unavailable/NotFound/Unsupported/Regression/Exceeded.
    const dropped = [
      'AvmTrap', 'AvmRevertReason', 'AvmInstancePoisoned', 'HydrationDidNotConverge',
      'RecordingPassDiverged', 'TxSimAppLogicRevert', 'TxSimTeardownRevert',
      'TxSimRevertibleInsertionsRevert', 'WasiProcExit', 'ModuleRefusedReplay',
      'NodeUnreachable', 'ProtocolVersionMismatch',
    ];
    const named = (n) => refusalName(`${n}: it went wrong in a way this class describes\n`);
    const classified = dropped.filter((n) => named(n) === n);
    // The SIZE is asserted, not "at least one": the set is knowable, and an "at least one"
    // control has already been satisfied by one member of three in this harness before.
    ck(`control: all ${dropped.length} names the old allowlist dropped are classified now`,
       classified.length === dropped.length && dropped.length === 12);

    // MUTATION: the pre-fix rule, applied to the same twelve. It must classify NONE of
    // them — that is what makes the control above a measurement rather than a tautology.
    const OLD_NAME_RULE =
      /^\s*([A-Z][A-Za-z]+(?:Error|Unavailable|NotFound|Unsupported|Regression|Exceeded)):?.*$/m;
    const oldNamed = dropped.filter((n) => {
      const m = `${n}: it went wrong in a way this class describes\n`.match(OLD_NAME_RULE);
      return m && m[1] === n;
    });
    bite('mutation: the old suffix allowlist classified none of those twelve',
         oldNamed.length === 0);

    // A six-suffix name still has to work: the fix widened the rule and must not have
    // moved it. `AvmToolchainRegression` is the name the preflight exists for.
    ck('control: a name the old rule DID accept is still accepted',
       refusalName('  AvmToolchainRegression: imports no memory\n')
         === 'AvmToolchainRegression');

    // The recorded mainnet stderr, verbatim.
    const MAINNET_TYPEERROR_STDERR = [
      '(node:87500) ExperimentalWarning: WASI is an experimental feature and might change at any time',
      '(Use `node --trace-warnings ...` to show where the warning was created)',
      'replay: 0x2a1cd76f262f23a4bb7609f7cb1b5b4b967256c73da9c7bae6dc386003ba2d6e via https://aztec.drpc.org',
      'file:///Users/z/aztec-avm-runtime/replay/node_modules/@aztec/stdlib/dest/avm/avm.js:558',
      '            noteHashes: tx.data.forPublic.nonRevertibleAccumulatedData.noteHashes.filter((x)=>!x.isZero()),',
      '                                          ^',
      '',
      "TypeError: Cannot read properties of undefined (reading 'nonRevertibleAccumulatedData')",
      '    at AvmTxHint.fromTx (file:///Users/z/aztec-avm-runtime/replay/node_modules/@aztec/stdlib/dest/avm/avm.js:558:43)',
      '    at encodeWith (file:///Users/z/aztec-avm-runtime/replay/src/replay_inputs.ts:116:15)',
      '',
      'Node.js v24.19.0',
      '',
    ].join('\n');

    const n8 = refusalName(MAINNET_TYPEERROR_STDERR);
    ck('control: the recorded mainnet refusal is named', n8 === 'TypeError');
    ck('control: the detail is the message the runtime printed',
       refusalDetail(MAINNET_TYPEERROR_STDERR, n8)
         .includes("Cannot read properties of undefined (reading 'nonRevertibleAccumulatedData')"));

    // ── THE FALLBACK PATH, which is the one that actually lost the two transactions ──
    //
    // `refusalDetail` only falls back when the name is `unknown`, so a fixture whose name
    // IS classified never exercises it — the case above runs the anchored path and would
    // stay green with the old noise rule. The loss happened on the other path, so it has
    // to be driven with a refusal that is genuinely unnamed. The driver's own early-exit
    // diagnoses are lowercase and therefore unnamed by construction, which is exactly the
    // shape: a real message, no class, three lines of preamble in front of it.
    const UNNAMED_STDERR = [
      '(node:87500) ExperimentalWarning: WASI is an experimental feature and might change at any time',
      '(Use `node --trace-warnings ...` to show where the warning was created)',
      'replay: 0x2a1cd76f262f23a4bb7609f7cb1b5b4b967256c73da9c7bae6dc386003ba2d6e via https://aztec.drpc.org',
      'replay: no first-in-block transaction with a retained body above the finalized tip',
      '',
    ].join('\n');

    ck('control: a genuinely unnamed refusal is still reported as `unknown`',
       refusalName(UNNAMED_STDERR) === 'unknown');
    const dFall = refusalDetail(UNNAMED_STDERR, 'unknown');
    ck('control: the fallback reaches the diagnosis PAST the three-line preamble',
       dFall.includes('no first-in-block transaction with a retained body'));
    ck('control: and carries none of the preamble it had to step over',
       !dFall.includes('ExperimentalWarning') && !dFall.includes('trace-warnings')
         && !dFall.includes('via https://'));

    // MUTATION: the pre-fix NOISE rule over the same stderr. It must reproduce exactly the
    // useless shape the two lost transactions recorded — all preamble, no diagnosis —
    // which is what proves the three controls above are measuring the repair.
    const oldIsNoise = (l) =>
      l.trim().length === 0 || /^Node\.js v\d/.test(l.trim())
      || /^\s*at\s/.test(l) || /^[{}\s]*$/.test(l);
    const oldPicked = [];
    for (const l of UNNAMED_STDERR.split('\n').map((l) => l.trimEnd())) {
      if (oldPicked.length >= 3) break;
      if (!oldIsNoise(l)) oldPicked.push(l.trim());
    }
    const oldDetail = oldPicked.join(' ').slice(0, 400);
    bite('mutation: the old noise rule spends its whole budget on preamble and drops the diagnosis',
         oldDetail.includes('ExperimentalWarning')
           && !oldDetail.includes('no first-in-block transaction'));

    // A warning is not a refusal, and a source echo shaped like a message is not a name.
    ck('control: a bare Node warning line is not taken as a refusal name',
       refusalName('(node:1) ExperimentalWarning: WASI is experimental\n') === 'unknown');
    ck('twin: a source echo `Foo: bar,` is skipped and the real message below it wins',
       refusalName('    Foo: bar,\nAvmTrap: the trap fired\n') === 'AvmTrap');
  }

  // ── CASE 9 — A BLOCK IS COMPLETE OR IT IS NOT ──────────────────────────────────────
  //
  // The capture target is 2-3 COMPLETE blocks per network — blocks in which every
  // transaction the chain published has a reproduced replay — and not 2-3 transactions.
  // The two targets are satisfiable by different snapshots, and the difference is an
  // overclaim: a block page that lists three transactions and can step one of them.
  console.error('\ncase 9 — completeness is counted over the chain\'s list, not ours');
  {
    const snap = {
      blocks: [
        { number: 300, transactions: ['0xa'] },                 // 1/1 replayed  -> complete
        { number: 299, transactions: ['0xb', '0xc', '0xd'] },   // 3/3 replayed  -> complete
        { number: 298, transactions: ['0xe', '0xf', '0xg'] },   // 1/3 replayed  -> NOT
        { number: 297, transactions: [] },                      // empty         -> NOT
        { number: 296, transactions: ['0xh'] },                 // divergent     -> NOT
        { number: 295, transactions: ['0xi', '0xj'] },          // one not-first -> NOT
      ],
      transactions: [
        { txHash: '0xa', outcome: 'replayed' },
        { txHash: '0xb', outcome: 'replayed' },
        { txHash: '0xc', outcome: 'replayed' },
        { txHash: '0xd', outcome: 'replayed' },
        { txHash: '0xe', outcome: 'replayed' },
        { txHash: '0xf', outcome: 'refused' },
        { txHash: '0xg', outcome: 'pruned' },
        { txHash: '0xh', outcome: 'divergent' },
        { txHash: '0xi', outcome: 'replayed' },
        { txHash: '0xj', outcome: 'not-first-in-block' },
      ],
    };

    ck('control: exactly two blocks are complete', completeBlockCount(snap) === 2);
    ck('control: and they are named, newest first',
       JSON.stringify(completeBlockNumbers(snap)) === JSON.stringify([300, 299]));
    ck('control: a block with 1 of 3 replayed is NOT complete',
       !completeBlockNumbers(snap).includes(298));
    ck('control: an empty block is not a captured block',
       !completeBlockNumbers(snap).includes(297));
    ck('control: a divergent recording does not complete its block',
       !completeBlockNumbers(snap).includes(296));
    ck('control: a `not-first-in-block` sibling leaves its block incomplete',
       !completeBlockNumbers(snap).includes(295));

    // MUTATION: the target as a COUNT OF REPLAYS, over the same snapshot. It reports 6 —
    // enough to declare "3 blocks captured" twice over — while completeness reports 2.
    // That gap is the overclaim the bar exists to prevent, and it is why the stop
    // condition counts blocks.
    const replayCount = snap.transactions.filter((t) => t.outcome === 'replayed').length;
    bite('mutation: counting replays reports 6 where completeness reports 2',
         replayCount === 6 && completeBlockCount(snap) === 2);

    // A snapshot whose replays are spread one-per-block across half-covered blocks would
    // satisfy a replay count of 3 with ZERO complete blocks. The strongest form of the trap.
    const spread = {
      blocks: [
        { number: 10, transactions: ['0x1', '0x2'] },
        { number: 11, transactions: ['0x3', '0x4'] },
        { number: 12, transactions: ['0x5', '0x6'] },
      ],
      transactions: [
        { txHash: '0x1', outcome: 'replayed' }, { txHash: '0x2', outcome: 'pruned' },
        { txHash: '0x3', outcome: 'replayed' }, { txHash: '0x4', outcome: 'pruned' },
        { txHash: '0x5', outcome: 'replayed' }, { txHash: '0x6', outcome: 'pruned' },
      ],
    };
    bite('mutation: three replays across three half-covered blocks is ZERO complete blocks',
         spread.transactions.filter((t) => t.outcome === 'replayed').length === 3
           && completeBlockCount(spread) === 0);
  }

  // ── CASE 10 — "NOBODY LOOKED" IS NOT "WE LOOKED AND FOUND NOTHING" ─────────────────
  //
  // `artifacts` has THREE states and the rule used to have two. An array with entries is
  // "we looked, and here is what each contract answered"; an empty array is "we looked,
  // and the transaction executed no contract"; and NO ARRAY is "the runtime that produced
  // this report cannot resolve artifacts at all, so nobody looked". `?? []` folded the
  // third onto the second.
  //
  // This is not hypothetical. The eight transactions frozen into this repository on
  // 2026-09-01 were captured with runtime 86c36ad, which predates `artifacts`, so their
  // driver reports carry no such key. Under the old rule a capture would have written
  // `artifacts: []` beside them — a committed fixture asserting that a resolution had been
  // performed and had found no contract, for a transaction that executed one. Measured
  // afterwards against the same resolver, one of those eight (testnet 0x12525d6d…,
  // FeeJuice class 0x1f85d8b9…) RESOLVES, so the `[]` would have been false and not merely
  // imprecise.
  console.error('\ncase 10 — three states for `artifacts`, and `null` is one of them');
  {
    const resolvedEntry = {
      address: '0x0000000000000000000000000000000000000000000000000000000000000003',
      contractClassId: '0x1f85d8b901a87b3fa9b93a44ab569ca2f5eb62412dfd58c894fdfff218be11a4',
      resolved: true, origin: 'npm:@aztec/protocol-contracts@5.3.0-nightly.20260819 FeeJuice',
      corroboration: 'single-distributor', sourceFiles: 32, rejected: [],
    };
    const rejectedEntry = {
      address: '0x2a9a1d0e8f1974267536abefa565e7a7351f92ddbe95ec13c57c79b70664f7c8',
      contractClassId: '0x2b6749411979b61926b6f8836c3a1a28c39e9c0c3fb3322ed6e776f2f02cb6dc',
      resolved: false, candidatesConsidered: 1,
      rejected: [{ origin: 'npm:@aztec/protocol-contracts@5.0.0-rc.2 FeeJuice',
                   fault: 'artifact-hash-mismatch' }],
    };

    // (a) a report that looked and proved something copies the whole array through.
    const dLooked = decide({ code: 0, err: '',
      out: JSON.stringify({ ...reproducedReport, artifacts: [resolvedEntry, rejectedEntry] }) });
    ck('control: a populated resolution travels whole', Array.isArray(dLooked.artifacts)
       && dLooked.artifacts.length === 2);
    ck('control: and the REJECTION travels with it — a rejection with a reason is a result',
       dLooked.artifacts[1].resolved === false
         && dLooked.artifacts[1].rejected[0].fault === 'artifact-hash-mismatch');

    // (b) a report that looked and had nothing to look at stays the EMPTY ARRAY.
    const dEmpty = decide({ code: 0, err: '',
      out: JSON.stringify({ ...reproducedReport, artifacts: [] }) });
    ck('control: "we looked and the transaction executed no contract" stays `[]`',
       Array.isArray(dEmpty.artifacts) && dEmpty.artifacts.length === 0);

    // (c) a report from a runtime that cannot resolve at all is `null`, not `[]`.
    //     `reproducedReport` carries no `artifacts` key, which is the shape of every
    //     driver report the frozen captures were taken from.
    const dNever = decide({ code: 0, out: JSON.stringify(reproducedReport), err: '' });
    ck('control: an absent `artifacts` key becomes `null` — nobody looked',
       dNever.artifacts === null);
    ck('twin: an explicit `artifacts: null` is the same statement and stays null',
       decide({ code: 0, err: '',
                out: JSON.stringify({ ...reproducedReport, artifacts: null }) })
         .artifacts === null);

    // The three states are DISTINGUISHABLE, which is the whole claim. Asserted as one
    // proposition so it cannot pass by two of the three happening to agree.
    ck('control: the three states are three different values',
       dLooked.artifacts !== null && dEmpty.artifacts !== null
         && dNever.artifacts === null && dEmpty.artifacts.length !== dLooked.artifacts.length);

    // MUTATION: the pre-fix rule, over the SAME report. It must produce `[]` for the
    // never-looked case — indistinguishable from (b) — which is what proves (c) measures
    // the repair rather than agreeing with everything.
    const oldRule = (facts) => facts.artifacts ?? [];
    const oldNever = oldRule(reproducedReport);
    bite('mutation: `?? []` makes "nobody looked" identical to "looked, nothing to look at"',
         Array.isArray(oldNever) && oldNever.length === 0
           && JSON.stringify(oldNever) === JSON.stringify(dEmpty.artifacts));
    // And it must NOT bite on the populated case, or the mutation would be proving that
    // the old rule was broken everywhere rather than in exactly this one state.
    bite('mutation: …and only there — `?? []` is correct for a report that DID resolve',
         JSON.stringify(oldRule({ ...reproducedReport, artifacts: [resolvedEntry] }))
           === JSON.stringify([resolvedEntry]));
  }

  // ── CASE 11 — A RUNTIME THAT CANNOT RESOLVE IS REFUSED BEFORE IT CAPTURES ──────────
  //
  // The `--avm` lesson, applied to the failure that came after it. A bad `--avm` path
  // REFUSES: the run dies, the operator sees it, the transaction is lost but the reason is on
  // the screen. A runtime that predates artifact resolution does something worse — it replays
  // perfectly, reproduces the block's effects, writes a container that steps, and records
  // rung 3 with no `artifacts` key. Nothing looks wrong at any point. The eight transactions
  // frozen into this repository are that capture, and one of the eight contracts (FeeJuice at
  // 0x…03) resolves outright when asked with a runtime that can ask.
  //
  // A capture is unrepeatable, so this is REFUSED and not warned about, and the test is a
  // fixture-directory test rather than a mock because the rule is "does this file exist".
  console.error('\ncase 11 — a runtime with no resolver is refused before a watch starts');
  {
    const good = join(dir, 'runtime-good');
    const stale = join(dir, 'runtime-stale');
    await mkdir(join(good, 'replay', 'src'), { recursive: true });
    await writeFile(join(good, 'replay', 'src', 'artifact_resolution.ts'), '// present\n');
    // The stale runtime is a COMPLETE checkout apart from the one module — it has the replay
    // directory and the loader, exactly like 86c36ad. A test whose "stale" case was an empty
    // directory would pass against a rule that merely checked the runtime path existed.
    await mkdir(join(stale, 'replay', 'src'), { recursive: true });
    await writeFile(join(stale, 'replay', 'src', 'settled_transaction.ts'), '// replays fine\n');
    await mkdir(join(stale, 'node-host', 'src'), { recursive: true });
    await writeFile(join(stale, 'node-host', 'src', 'loader.ts'), '// loads fine\n');

    const okR = resolverPresence(good);
    ck('control: a runtime carrying artifact_resolution.ts is accepted', okR.ok === true);
    ck('control: and it names the path it looked at', okR.path.endsWith(RESOLVER_PATH));

    const badR = resolverPresence(stale);
    ck('control: a runtime WITHOUT it is refused', badR.ok === false);
    ck('control: and the refusal says the capture would look normal, not broken',
       /rung 3 with NO artifacts array/.test(badR.problem)
         && /replay and write containers exactly as normal/.test(badR.problem));
    ck('control: …and names the remedy and the commit that is this state',
       /86c36ad/.test(badR.problem) && /pull the runtime checkout/.test(badR.problem));

    // The preflight FAILS on it, which is the thing a watch consults. Driven with avm and
    // ct-writer paths that DO exist, so the only reason it can fail is the resolver.
    const pf = await preflightToolchain({
      nodeBin: process.execPath, runtime: stale, avm: ctPath, ctWriter: ctPath,
    });
    ck('control: preflightToolchain refuses that runtime', pf.ok === false);
    ck('control: …for the resolver, not for a missing wasm',
       pf.problems.length === 1 && /cannot resolve contract artifacts/.test(pf.problems[0]));

    // MUTATION: the pre-fix preflight over the SAME inputs — paths exist, so it had nothing to
    // object to and would have started the watch. That is the silent success this case closes.
    const oldPreflightWouldPass =
      existsSync(ctPath) && existsSync(ctPath) && existsSync(stale);
    bite('mutation: the old path-existence preflight passes the stale runtime and starts a watch',
         oldPreflightWouldPass === true && pf.ok === false);
    // And it must NOT refuse a good runtime, or the gate would be refusing everything.
    const pfGood = await preflightToolchain({
      nodeBin: process.execPath, runtime: good, avm: ctPath, ctWriter: ctPath,
    });
    bite('mutation: …and the same gate still ACCEPTS a runtime that can resolve',
         pfGood.ok === true);
  }

  await rm(dir, { recursive: true, force: true });
  ck('the temp container was cleaned up', !existsSync(ctPath));

  // 87: 11 cases (7+1, 6+2, 5+1+2, 3+1, 3+1, 2, 7+1, 8+2, 6+2, 6+2, 7+2) = 78, plus 3
  // outcome-set, 5 invariant, 1 cleanup. Declared rather than derived, so adding a case
  // without updating this number is a failure — which is the whole point of counting.
  expectCount(87);
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
