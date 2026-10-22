#!/usr/bin/env node
// sui-yield-reading.mjs — the `blocktracer/historic-replay-yield@1` reading for Sui
// mainnet's pinned windows, assembled from one produced snapshot per window.
//
//   node tools/chain/sui-yield-reading.mjs --windows DIR --runtime-commit SHA --out FILE
//
// DIR holds `w<from>/tree/snapshot.json` and `w<from>/acquisition.json` for every window
// `yield-method.json` pins under `pinned.sui`, as `capture-sui-range.mjs` writes them with
// `--from <from> --to <to>` and no transaction left out (every row of every checkpoint is
// attempted). The Sui twin of `starknet-yield-reading.mjs`, a concrete duplicate.
//
// The reading is checked by `lib/yield.mjs` `checkReading` and the tool exits 1 on any
// finding. The era analysis is COMPUTED from the rows and from the committed endpoint
// reading (`measurements/sui-endpoint-horizon.json`); no verdict sentence is written by
// hand, because the declared variable is the one the measurement has to be able to refute.

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { checkReading, pinnedFor, yieldMethod } from './lib/yield.mjs';
import { CHAIN_SLUG, MIN_TRACED_PROTOCOL } from './lib/sui-producer-facts.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const flag = (n, d) => { const i = argv.indexOf(`--${n}`); return i === -1 ? d : argv[i + 1]; };
const dir = flag('windows');
const out = flag('out');
const runtimeCommit = flag('runtime-commit', '');
if (!dir || !out || !/^[0-9a-f]{40}$/.test(runtimeCommit)) {
  console.error('usage: --windows DIR --runtime-commit SHA(40 hex) --out FILE');
  process.exit(2);
}

const method = yieldMethod();
const pinned = pinnedFor(CHAIN_SLUG, method);
if (!pinned) { console.error(`no pinned entry for ${CHAIN_SLUG}`); process.exit(2); }
const horizon = JSON.parse(readFileSync(join(HERE, 'measurements', 'sui-endpoint-horizon.json'), 'utf8'));

const load = (from, file) => {
  const p = join(dir, `w${from}`, file);
  if (!existsSync(p)) { console.error(`pinned window ${from} has no ${file} at ${p}`); process.exit(1); }
  return JSON.parse(readFileSync(p, 'utf8'));
};

const mismatchFields = {};
let endpoint = '';
let tipAtRun = 0;
let floorAtRun = null;
const windows = pinned.windows.map(([from, to]) => {
  const snap = load(from, 'tree/snapshot.json');
  const acq = load(from, 'acquisition.json');
  endpoint = acq.endpoint;
  tipAtRun = Math.max(tipAtRun, acq.tip.sequenceNumber);
  floorAtRun = acq.tracedFloor.checkpoint;
  const inWindow = snap.transactions.filter((t) => t.blockNumber >= from && t.blockNumber <= to);
  const enumerated = acq.checkpoints.reduce((n, cp) => n + cp.transactions.length, 0);
  if (inWindow.length !== enumerated || acq.window.from !== from || acq.window.to !== to) {
    console.error(`window ${from}-${to}: ${inWindow.length} rows against ${enumerated} enumerated `
      + `(acquisition window ${acq.window.from}-${acq.window.to}); a window is whole or absent`);
    process.exit(1);
  }
  const w = { from, to, blocks: to - from + 1, transactions: 0, firstInBlock: 0,
              notFirstInBlock: 0, replayed: 0, divergent: 0, traced: 0, refused: 0,
              bodyUnavailable: 0, notAttempted: 0, transactionsByBlock: {}, rows: [],
              protocolVersions: {}, epochs: {} };
  for (const cp of acq.checkpoints) {
    w.transactionsByBlock[cp.sequenceNumber] = cp.transactions.length;
    w.protocolVersions[cp.sequenceNumber] = cp.protocolVersion;
    w.epochs[cp.sequenceNumber] = cp.epoch;
  }
  for (const r of inWindow) {
    w.transactions++;
    if (r.txIndexInBlock === 0) w.firstInBlock++; else w.notFirstInBlock++;
    const o = r.outcome;
    if (o === 'replayed') w.replayed++;
    else if (o === 'divergent') w.divergent++;
    else if (o === 'refused') w.refused++;
    else w.notAttempted++;
    const bad = (r.effects?.mismatches ?? []).map((f) => f.field);
    for (const f of bad) mismatchFields[f] = (mismatchFields[f] ?? 0) + 1;
    w.rows.push({ tx: r.txHash, block: r.blockNumber, index: r.txIndexInBlock, outcome: o,
                  kind: r.transactionKind,
                  ...(bad.length ? { mismatched: bad } : {}),
                  ...(o === 'refused' ? { refusal: String(r.refusal ?? r.refusalReason) } : {}),
                  steps: r.recording?.steps ?? 0 });
  }
  w.traced = w.replayed + w.divergent;
  w.observable = w.transactions;
  w.blocksBelowTip = acq.tip.sequenceNumber - to;
  w.ledger = { replay: { at: snap.provenance.capturedAt,
                         attempted: w.transactions - w.notAttempted, replayed: w.replayed,
                         divergent: w.divergent, refused: w.refused,
                         notAttempted: w.notAttempted, stoppedBy: null, runtimeCommit } };
  return w;
});

const sum = (k) => windows.reduce((n, w) => n + w[k], 0);
const totals = {};
for (const k of ['transactions', 'firstInBlock', 'notFirstInBlock', 'replayed', 'divergent',
                 'traced', 'refused', 'bodyUnavailable', 'notAttempted', 'observable']) {
  totals[k] = sum(k);
}
const pct = (a, b) => (b === 0 ? 0 : Math.round((1000 * a) / b) / 10);
const t = (ws, k) => ws.reduce((n, w) => n + w[k], 0);

// THE ERA ANALYSIS, COMPUTED. The declared variable is `endpoint-retention`: yield follows
// what the endpoint serves. The committed horizon reading says what it serves; the rows say
// what traced. An edge where the endpoint still serves is an edge at something else.
const below = windows.filter((w) => w.to < floorAtRun);
const above = windows.filter((w) => w.from >= floorAtRun);
const deepestServed = horizon.deepestServed;
const belowServed = below.every((w) => deepestServed !== null && w.from >= deepestServed);
const belowTraced = t(below, 'traced');
const aboveRate = pct(t(above, 'traced'), t(above, 'transactions'));
const edgeAtProtocol = below.length > 0 && belowTraced === 0 && aboveRate >= 90;
const doc = {
  format: 'blocktracer/historic-replay-yield@1',
  chain: CHAIN_SLUG,
  measuredAt: new Date().toISOString(),
  chainTipAtRun: tipAtRun,
  finalizedAtRun: tipAtRun,
  endpoint,
  toolchain: { recorder: `codetracer-move-recorder ${runtimeCommit}`,
               replay: load(pinned.windows[0][0], 'acquisition.json').replayRuntime },
  windows,
  totals,
  yield: {
    tracedOverAllTransactions: pct(totals.traced, totals.transactions),
    tracedOverObservable: pct(totals.traced, totals.observable),
    replayedOverAllTransactions: pct(totals.replayed, totals.transactions),
  },
  mismatchedFields: mismatchFields,
  eraAnalysis: {
    boundary: floorAtRun,
    boundaryWhat: `the first checkpoint at protocol ${MIN_TRACED_PROTOCOL}, the first execution layer with trace hooks, as the capture measured it`,
    endpointHorizon: { reading: 'tools/chain/measurements/sui-endpoint-horizon.json',
                       measuredAt: horizon.measuredAt, deepestServed },
    below: { transactions: t(below, 'transactions'), traced: belowTraced, refused: t(below, 'refused'),
             objectVersionsServed: belowServed },
    atOrAbove: { transactions: t(above, 'transactions'), replayed: t(above, 'replayed'),
                 divergent: t(above, 'divergent'), tracedPercent: aboveRate },
    prediction: 'endpoint-retention: yield near-total wherever the endpoint serves the consumed object versions, near-zero below its horizon (pinned.sui, the charter\'s declaration)',
    verdict: edgeAtProtocol && belowServed
      ? `REFUTED: below checkpoint ${floorAtRun} ${belowTraced} of ${t(below, 'transactions')} traced while the endpoint serves those object versions (deepest served ${deepestServed}); above it ${aboveRate}% traced. The edge is at the protocol boundary, not at an endpoint horizon — the dominant variable is era.`
      : edgeAtProtocol
        ? `NOT DECIDED: the edge is at checkpoint ${floorAtRun}, but the endpoint's service of the below-floor versions is not established by the horizon reading (deepest served ${deepestServed}).`
        : `NO EDGE AT THE PROTOCOL BOUNDARY: below ${floorAtRun} ${belowTraced} of ${t(below, 'transactions')} traced; above it ${aboveRate}%.`,
  },
};

const { findings, notMeasured } = checkReading(doc, method);
if (findings.length) {
  for (const f of findings) console.error(`  ${f.rule}: ${f.what ?? f.message ?? JSON.stringify(f)}`);
  console.error('refusing to write a reading with findings');
  process.exit(1);
}
writeFileSync(out, `${JSON.stringify(doc, null, 1)}\n`);
console.log(`wrote ${out}: ${totals.transactions} transactions, traced ${totals.traced} `
            + `(replayed ${totals.replayed}, divergent ${totals.divergent}), refused ${totals.refused}`);
for (const w of windows) {
  console.log(`  ${w.from}-${w.to} protocol ${[...new Set(Object.values(w.protocolVersions))].join('/')}: `
              + `${w.transactions} tx, ${w.replayed} replayed, ${w.divergent} divergent, ${w.refused} refused`);
}
console.log(`verdict: ${doc.eraAnalysis.verdict}`);
console.log(`checkReading: 0 findings, ${notMeasured.length} not measured`);
for (const n of notMeasured) console.log(`  NOT MEASURED ${JSON.stringify(n)}`);
