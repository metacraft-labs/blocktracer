#!/usr/bin/env node
// starknet-readset-roundtrip.mjs — the MINED-transaction read-set round trip, with the
// block-N echo control, measured on a fixed ladder of depths.
//
//   node tools/chain/starknet-readset-roundtrip.mjs [--endpoint URL] [--out FILE]
//                                                   [--plant-defect NAME]
//
// ── WHAT THIS CLOSES, AND WHY A HAND-BUILT TRANSACTION DID NOT ────────────────────────
//
// Chain-Delivery DEL-6 records that `RETURN_INITIAL_READS` is a real `simulation_flag` on
// `starknet_simulateTransactions`, measured against api.cartridge.gg — and records, in as
// many words, the step the claim rests on as NOT MEASURED: that probe drove a HAND-BUILT
// INVOKE v3, not a mined transaction re-supplied at its parent block. A hand-built
// transaction cannot tell a prestate from an echo, because nothing it reads was ever
// written by it. This file runs the round trip the claim needs:
//
//     starknet_getTransactionByHash(H)              the mined transaction, as the node has it
//  -> starknet_simulateTransactions(N-1, [tx], ...) its parent block's state
//  -> initial_reads.storage                         the read set, (contract, key, value)
//
// ── THE CONTROL IS THE WHOLE POINT, AND IT IS TWO-SIDED ───────────────────────────────
//
// §3.1's trap: a read set returned at the WRONG height still looks like a read set. So the
// same transaction is simulated at block **N** as well, and the two readings are compared
// against the block's own `starknet_getStateUpdate` diff — the values the transaction's
// block actually wrote:
//
//   * V1 PRESTATE. For every (contract, key) that block N wrote and the N-1 read set also
//     read, the N-1 value must DIFFER from the written value. A reading that matched would
//     be an echo of the transaction's own effect, not the state it ran against.
//   * V2 ECHO. The same keys read at block N must EQUAL the written value. This is the
//     positive control: it shows the instrument does echo when pointed at N, so V1 is a
//     property of the height asked for and not of the method always disagreeing.
//   * V3 NODE AGREES. `starknet_getStorageAt` at N-1 and at N, on the same keys, must
//     return the N-1 and N readings respectively — a second, unrelated instrument, so
//     "prestate" does not rest on `simulateTransactions` alone.
//   * V4 FLAG RECOGNISED. `["THIS_FLAG_DOES_NOT_EXIST"]` must be refused `-32602
//     {"reason":"Invalid simulation flag"}`, so a 200 with a read set is a flag that was
//     acted on rather than a field a blind proxy always returns.
//   * V5 DEPTH. Every rung of the ladder below must serve a read set at its parent block.
//     This is the verdict DEL-6 asks for and the one that can bound the answer: where the
//     ladder stops answering is the depth the read set is served to.
//
// ── THE THREE DEVIATIONS FROM A LITERAL RE-SUPPLY, EACH MEASURED RATHER THAN ASSUMED ──
//
//   1. `transaction_hash` is dropped. It is not a member of `BROADCASTED_INVOKE_TXN`.
//   2. `SKIP_FEE_CHARGE` is needed. The unmodified transaction at its own parent block is
//      refused `code 41` "Resources bounds (…) exceed balance (…)" — the wallet sized its
//      bounds against the balance it had, and the pre-validation fee check re-reads that
//      balance. The `literal` arm below records what the unmodified re-supply does at
//      every rung, so this is a reading and not a workaround taken on trust.
//   3. For the ECHO arm only, `nonce` is advanced by one. blockifier's nonce precheck runs
//      even under `SKIP_VALIDATE` ("Invalid transaction nonce of contract at address …"),
//      and at block N the account's nonce has moved. The account's nonce at each height is
//      read with `starknet_getNonce` and recorded, so the bump is checked, not guessed.
//
// Both answering arms carry the SAME flag set, so the only difference between them is the
// block asked for.
//
// ── THE DEPTH LADDER ──────────────────────────────────────────────────────────────────
//
// Fixed rungs, each with the reason it is on the ladder. The question DEL-6 asks is
// whether the read set is served at ARBITRARY depth, because Recorder-Cairo CXP-CAIRO-1's
// premise — fold state diffs forward, measure the floor, build a gap-list registry member
// — changes if it is. So the ladder straddles both documented boundaries and the
// documented hole, and a rung that is refused is as much of a reading as one that answers.
//
// A rung's block may hold no INVOKE transaction. The ladder then walks FORWARD, at most
// `SCAN_LIMIT` blocks, and records the block it actually used; the rung is never silently
// moved.
//
// ── CONTROL ARMS THIS FILE CAN BE DRIVEN RED WITH ─────────────────────────────────────
//
// `--plant-defect NAME` breaks one verdict on purpose, so each is known to be able to
// fail rather than asserted to pass:
//
//   prestate-is-echo   the round-trip arm is simulated at N      -> V1 red
//   echo-is-prestate   the echo arm is simulated at N-1          -> V2 red
//   crosscheck-swap    getStorageAt@N compared to the parent read -> V3 red
//   flag-accepted      the bogus flag slot gets a valid flag      -> V4 red
//   beyond-tip         rung 1 becomes tip+1,000,000               -> V5 red
//
// `beyond-tip` is driven by a REAL refusal from the real endpoint rather than a mocked
// one, which is what makes V5 a reading about this endpoint and not about this file.
//
// Exit status: 0 every verdict holds, 1 a verdict failed, 2 the run could not be made
// (usage, or no rung produced a reading).

import { readFileSync, writeFileSync } from 'node:fs';

const DEFAULT_ENDPOINT = 'https://api.cartridge.gg/x/starknet/mainnet';
const SCAN_LIMIT = 25;
const CROSSCHECK_KEYS = 3;

// The flags both answering arms carry. `RETURN_INITIAL_READS` is the measurement; the two
// skips are deviation 2 and the nonce precheck's companion, and they are identical on both
// arms so the height is the only variable.
const FLAGS = ['SKIP_VALIDATE', 'SKIP_FEE_CHARGE', 'RETURN_INITIAL_READS'];
const BOGUS_FLAG = 'THIS_FLAG_DOES_NOT_EXIST';

// Every rung carries why it is a rung. The version boundaries are the ones Recorder-Cairo
// CXP-CAIRO-1 bisected on 2026-10-20.
const LADDER = [
  { at: 300000, why: 'the depth the hand-built probe answered at — less than half the ~632,813 floor Chain-Support-Matrix.md §1.3 records' },
  { at: 480000, why: 'Starknet 0.12.3, BELOW the recorder executor floor 501,514: the node may serve what our executor cannot run' },
  { at: 501514, why: "the pipeline's floor exactly — 0.13.0's first block, the oldest versioned constants the executor carries" },
  { at: 620000, why: '0.13.1, still below the ~632,813 diff-series floor' },
  { at: 632813, why: "§1.3's recorded floor itself" },
  { at: 800000, why: '0.13.2.1' },
  { at: 1400000, why: "0.13.5, after 0.13.4's Sierra gas" },
  { at: 1943704, why: "the documented ~9,000-block hole's LOWER edge (Chain-Data-Ingestion.md §4)" },
  { at: 1948000, why: 'inside the documented hole' },
  { at: 1952704, why: "the documented hole's UPPER edge" },
  { at: 3000000, why: '0.14.0' },
  { at: 13000000, why: '0.14.3, the era the recorder was built against — and a pinned yield window' },
];

const argv = process.argv.slice(2);
const flag = (n, d) => { const i = argv.indexOf(`--${n}`); return i === -1 ? d : argv[i + 1]; };
const endpoint = flag('endpoint', DEFAULT_ENDPOINT);
const out = flag('out');
const planted = flag('plant-defect', '');
const PLANTS = ['prestate-is-echo', 'echo-is-prestate', 'crosscheck-swap', 'flag-accepted', 'beyond-tip'];
if (planted && !PLANTS.includes(planted)) {
  console.error(`unknown --plant-defect ${planted}; one of: ${PLANTS.join(' ')}`);
  process.exit(2);
}

let calls = 0;
let transportRetries = 0;

/** One JSON-RPC call, with rate-limit backoff. A transport failure is reported as one,
 *  never folded into an absence: "the endpoint refused" and "the call did not complete"
 *  are different readings. */
async function rpc(method, params) {
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      calls++;
      const r = await fetch(endpoint, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: calls, method, params }),
      });
      if (r.status === 429 || r.status >= 500) {
        transportRetries++;
        await new Promise((s) => setTimeout(s, 1200 * (attempt + 1)));
        continue;
      }
      return await r.json();
    } catch (e) {
      transportRetries++;
      if (attempt === 4) return { transport: String(e) };
      await new Promise((s) => setTimeout(s, 1200 * (attempt + 1)));
    }
  }
  return { transport: `${method}: rate limited or unreachable after 5 attempts` };
}

const felt = (h) => BigInt(h).toString(16);
const slot = (contract, key) => `${felt(contract)}/${felt(key)}`;
const errOf = (r) => (r.transport ? { transport: r.transport } : r.error);
const brief = (e) => JSON.stringify(e).slice(0, 300);

/** The read set as a Map of slot -> value, or null when the call did not answer.
 *  The simulated transaction's own execution status rides along, because an EMPTY read
 *  set is a reading that needs its reason stated: a reverted simulation reads nothing,
 *  and that is a different fact from an endpoint that served nothing. */
function readSet(res) {
  const ir = res.result?.initial_reads;
  if (!ir) return null;
  const sim = res.result.simulated_transactions?.[0]?.transaction_trace;
  return {
    storage: new Map((ir.storage ?? []).map((s) => [slot(s.contract_address, s.key), felt(s.value)])),
    counts: {
      storage: (ir.storage ?? []).length,
      nonces: (ir.nonces ?? []).length,
      classHashes: (ir.class_hashes ?? []).length,
      declaredContracts: (ir.declared_contracts ?? []).length,
      executionStatus: sim?.execution_invocation?.revert_reason
        ? 'reverted' : (sim ? 'executed' : 'no trace in the answer'),
      revertReason: sim?.execution_invocation?.revert_reason
        ? String(sim.execution_invocation.revert_reason).slice(0, 200) : undefined,
    },
  };
}

async function probeRung(rung) {
  const r = { rung: rung.at, why: rung.why };

  // The block, and the first INVOKE in it. Walking forward is recorded, never silent.
  let used = null, block = null;
  for (let b = rung.at; b < rung.at + SCAN_LIMIT; b++) {
    const res = await rpc('starknet_getBlockWithTxs', [{ block_number: b }]);
    if (!res.result) { r.blockRefused = brief(errOf(res)); return r; }
    const inv = res.result.transactions.filter((t) => t.type === 'INVOKE');
    if (inv.length) { used = b; block = res.result; r.transaction = inv[0]; break; }
  }
  if (!used) { r.note = `no INVOKE transaction in blocks ${rung.at}..${rung.at + SCAN_LIMIT - 1}`; return r; }
  r.blockUsed = used;
  r.scannedForward = used - rung.at;
  r.starknetVersion = block.starknet_version;
  r.transactionsInBlock = block.transactions.length;
  const hash = r.transaction.transaction_hash;
  const index = block.transactions.findIndex((t) => t.transaction_hash === hash);
  r.transactionIndexInBlock = index;
  delete r.transaction;

  // The deliverable's first leg: the transaction as the NODE has it, by hash.
  const byHash = await rpc('starknet_getTransactionByHash', [hash]);
  if (!byHash.result) { r.byHashRefused = brief(errOf(byHash)); return r; }
  const mined = byHash.result;
  r.tx = { hash, type: mined.type, version: mined.version, sender: mined.sender_address, nonce: mined.nonce };
  const { transaction_hash: _dropped, ...bcast } = mined;

  // The literal re-supply: deviation 1 only, no skips. A reading in its own right.
  const literal = await rpc('starknet_simulateTransactions',
    [{ block_number: used - 1 }, [bcast], ['RETURN_INITIAL_READS']]);
  const literalReads = readSet(literal);
  r.literal = literalReads
    ? { answered: true, ...literalReads.counts }
    : { answered: false, refusal: brief(errOf(literal)) };

  // V4's negative control, run before anything is believed about a 200.
  const bogusFlags = planted === 'flag-accepted' ? ['RETURN_INITIAL_READS'] : [BOGUS_FLAG];
  const bogus = await rpc('starknet_simulateTransactions', [{ block_number: used - 1 }, [bcast], bogusFlags]);
  r.flagControl = bogus.result
    ? { refused: false, note: 'the endpoint ANSWERED a flag list it should not recognise' }
    : { refused: true, error: errOf(bogus) };

  // Deviation 3, read rather than guessed: the account's own nonce at the transaction's
  // block. The echo arm needs it because blockifier's nonce precheck runs under
  // SKIP_VALIDATE, and a transaction carrying its mined nonce is refused at block N.
  const nonceAtN = await rpc('starknet_getNonce', [{ block_number: used }, mined.sender_address]);
  r.accountNonce = { atTxBlock: nonceAtN.result ?? null, inTransaction: mined.nonce };
  const bumped = { ...bcast, nonce: nonceAtN.result ?? ('0x' + (BigInt(mined.nonce) + 1n).toString(16)) };

  // The round trip, and the echo arm. Same flags, different height.
  const roundTripBlock = planted === 'prestate-is-echo' ? used : used - 1;
  const rt = await rpc('starknet_simulateTransactions',
    [{ block_number: roundTripBlock }, [planted === 'prestate-is-echo' ? bumped : bcast], FLAGS]);
  const rtReads = readSet(rt);
  r.roundTrip = rtReads
    ? { answered: true, atBlock: roundTripBlock, ...rtReads.counts }
    : { answered: false, atBlock: roundTripBlock, refusal: brief(errOf(rt)) };

  const echoBlock = planted === 'echo-is-prestate' ? used - 1 : used;
  const echo = await rpc('starknet_simulateTransactions', [{ block_number: echoBlock }, [bumped], FLAGS]);
  const echoReads = readSet(echo);
  r.echo = echoReads
    ? { answered: true, atBlock: echoBlock, nonceAdvanced: bumped.nonce !== mined.nonce, ...echoReads.counts }
    : { answered: false, atBlock: echoBlock, refusal: brief(errOf(echo)) };

  if (!rtReads) return r;

  // What the block wrote, from the chain's own diff.
  const su = await rpc('starknet_getStateUpdate', [{ block_number: used }]);
  if (!su.result) { r.stateUpdateRefused = brief(errOf(su)); return r; }
  const wrote = new Map();
  for (const d of su.result.state_diff.storage_diffs ?? [])
    for (const e of d.storage_entries ?? []) wrote.set(slot(d.address, e.key), felt(e.value));
  r.blockWroteSlots = wrote.size;

  const overlap = [...wrote.keys()].filter((k) => rtReads.storage.has(k));
  r.overlap = overlap.length;
  let v1Differs = 0, v1Matches = 0, v2Equal = 0, v2Unequal = 0, v2Absent = 0;
  const examples = [];
  for (const k of overlap) {
    const post = wrote.get(k);
    if (rtReads.storage.get(k) === post) v1Matches++; else v1Differs++;
    if (!echoReads) v2Absent++;
    else if (!echoReads.storage.has(k)) v2Absent++;
    else if (echoReads.storage.get(k) === post) v2Equal++;
    else v2Unequal++;
    if (examples.length < 3)
      examples.push({ slot: k, readAtParent: rtReads.storage.get(k),
                      readAtTxBlock: echoReads?.storage.get(k) ?? null, blockWrote: post });
  }
  r.prestate = { differsFromWhatTheBlockWrote: v1Differs, equalsWhatTheBlockWrote: v1Matches };
  r.echoReading = { equalsWhatTheBlockWrote: v2Equal, differs: v2Unequal, notRead: v2Absent };
  r.examples = examples;

  // V3: the node's own flat read, on the same slots.
  r.crossCheck = [];
  for (const k of overlap.slice(0, CROSSCHECK_KEYS)) {
    const [addr, key] = k.split('/');
    const parentHeight = planted === 'crosscheck-swap' ? used : used - 1;
    const atParent = await rpc('starknet_getStorageAt', ['0x' + addr, '0x' + key, { block_number: parentHeight }]);
    const atTxBlock = await rpc('starknet_getStorageAt', ['0x' + addr, '0x' + key, { block_number: used }]);
    r.crossCheck.push({
      slot: k,
      getStorageAtParent: atParent.result ? felt(atParent.result) : null,
      getStorageAtTxBlock: atTxBlock.result ? felt(atTxBlock.result) : null,
      parentAgrees: atParent.result ? felt(atParent.result) === rtReads.storage.get(k) : null,
      txBlockAgrees: atTxBlock.result && echoReads?.storage.has(k)
        ? felt(atTxBlock.result) === echoReads.storage.get(k) : null,
    });
  }
  return r;
}

// `beyond-tip` replaces the shallowest rung with a height the chain has not reached, so V5
// is driven red by a REAL refusal from the real endpoint rather than by a mocked one.
const ladder = planted === 'beyond-tip'
  ? [{ at: ((await rpc('starknet_blockNumber', [])).result ?? 0) + 1000000,
       why: 'planted defect: a height the chain has not reached' }, ...LADDER.slice(1)]
  : LADDER;

const rungs = [];
for (const rung of ladder) rungs.push(await probeRung(rung));

// ── the verdicts ──────────────────────────────────────────────────────────────────────
//
// A rung is TESTABLE for V1/V2 when its parent-block read set and its block's write set
// share at least one slot. Two measured facts make that a condition rather than an
// oversight, and both are recorded per rung rather than smoothed over:
//
//   * THE READ SET IS EXECUTION-DEPENDENT. Re-run at block N, the same transaction takes a
//     different path and reads FEWER slots — 2 of 42 at rung 632,813, 58 of 58 at rung
//     13,000,000. So V2 is judged over the slots BOTH arms read; a slot the echo arm never
//     read is counted as `notRead`, which is a different reading from a disagreement.
//   * A SIMULATION CAN READ NO STORAGE AT ALL. Rung 1,952,704's transaction answers with
//     an empty storage read set at both heights — and it is NOT a revert: that rung's
//     recorded `executionStatus` is `executed`, so the transaction ran and touched no
//     storage slot this method reports. A revert is the other way to get here, which is
//     why `executionStatus` is recorded rather than inferred. Either way the rung is
//     counted as not testable, never as a pass.
const answered = rungs.filter((r) => r.roundTrip?.answered);
const testable = answered.filter((r) => r.overlap > 0);
const failures = [];
const notTestable = answered
  .filter((r) => !(r.overlap > 0))
  .map((r) => ({ rung: r.rung, overlap: r.overlap ?? 0,
                 storageRead: r.roundTrip.storage,
                 executionStatus: r.roundTrip.executionStatus }));

if (!answered.length) {
  console.error('no rung produced a read set; nothing to judge');
  process.exit(2);
}
if (!testable.length) failures.push('no rung produced a slot both read at the parent block and written by its own block, so V1 and V2 are untested');

// V1 PRESTATE — not one slot the block wrote may already carry its written value.
for (const r of testable) {
  if (r.prestate.equalsWhatTheBlockWrote > 0)
    failures.push(`V1 rung ${r.rung}: ${r.prestate.equalsWhatTheBlockWrote} of ${r.overlap} slots read at block ${r.roundTrip.atBlock} ALREADY CARRY what block ${r.blockUsed} wrote — that reading is an echo, not a prestate`);
}
// V2 ECHO — the same slots read at block N must carry exactly what block N wrote, so V1 is
// a property of the height asked for and not of the method always disagreeing.
for (const r of testable) {
  if (!r.echo?.answered) {
    failures.push(`V2 rung ${r.rung}: the echo arm did not answer (${r.echo?.refusal ?? 'no reading'}), so V1 has no positive control here`);
    continue;
  }
  if (r.echoReading.differs > 0)
    failures.push(`V2 rung ${r.rung}: ${r.echoReading.differs} slot(s) read at block ${r.echo.atBlock} DISAGREE with what that block wrote; the echo arm must echo`);
  if (r.echoReading.equalsWhatTheBlockWrote === 0)
    failures.push(`V2 rung ${r.rung}: the echo arm re-read none of the ${r.overlap} written slots, so this rung's V1 reading has no positive control`);
}
// V3 NODE AGREES — a second, unrelated instrument on the same slots at both heights.
for (const r of answered) {
  for (const c of r.crossCheck ?? []) {
    if (c.parentAgrees === false)
      failures.push(`V3 rung ${r.rung}: getStorageAt at the parent block disagrees with the read set on ${c.slot}`);
    if (c.txBlockAgrees === false)
      failures.push(`V3 rung ${r.rung}: getStorageAt at the transaction's block disagrees with the echo reading on ${c.slot}`);
  }
}
// V4 FLAG RECOGNISED — a 200 carrying a read set is the flag being acted on.
for (const r of rungs) {
  if (!r.flagControl) continue;
  if (!r.flagControl.refused)
    failures.push(`V4 rung ${r.rung}: a flag list containing no recognised flag was ANSWERED, so a returned read set is not evidence the flag was acted on`);
  else if (r.flagControl.error?.code !== -32602)
    failures.push(`V4 rung ${r.rung}: the bogus flag was refused ${JSON.stringify(r.flagControl.error?.code)} rather than -32602`);
}
// V5 DEPTH — the question DEL-6 asks. Every rung on the ladder must serve a mined
// transaction's read set at its parent block, or the depth claim is bounded and the bound
// is where the ladder stops answering.
for (const r of rungs) {
  if (!r.roundTrip?.answered)
    failures.push(`V5 rung ${r.rung}: no read set at the parent block — ${r.roundTrip?.refusal ?? r.blockRefused ?? r.byHashRefused ?? r.note ?? 'no reading'}`);
}

const reading = {
  format: 'blocktracer/starknet-readset-roundtrip@1',
  chain: 'starknet-mainnet',
  measuredAt: new Date().toISOString(),
  endpoint,
  specVersion: (await rpc('starknet_specVersion', [])).result ?? null,
  chainTipAtRun: (await rpc('starknet_blockNumber', [])).result ?? null,
  flags: FLAGS,
  bogusFlag: BOGUS_FLAG,
  plantedDefect: planted || null,
  deviationsFromALiteralResupply: [
    'transaction_hash dropped: not a member of BROADCASTED_INVOKE_TXN',
    'SKIP_FEE_CHARGE added: the unmodified re-supply is refused code 41 "Resources bounds (…) exceed balance (…)" — see each rung\'s `literal` arm',
    "nonce advanced on the ECHO arm only, to the account's own nonce at the transaction's block, because blockifier's nonce precheck runs under SKIP_VALIDATE",
  ],
  rpcCalls: calls,
  transportRetries,
  loadAverage: readFileSync('/proc/loadavg', 'utf8').trim(),
  rungs,
  verdicts: {
    rungsOnLadder: ladder.length,
    rungsAnswering: answered.length,
    rungsTestableForPrestate: testable.length,
    slotsJudged: testable.reduce((a, r) => a + r.overlap, 0),
    notTestable,
    failures,
    held: failures.length === 0,
  },
};

if (out) { writeFileSync(out, JSON.stringify(reading, null, 1) + '\n'); console.log(`wrote ${out}`); }

for (const r of rungs) {
  const rt = r.roundTrip;
  console.log(
    `rung ${String(r.rung).padStart(9)} block ${r.blockUsed ?? '-'} v${r.starknetVersion ?? '-'} ` +
    `tx ${r.tx?.version ?? '-'} | round trip @${rt?.atBlock ?? '-'}: ` +
    (rt?.answered ? `storage=${rt.storage} classes=${rt.classHashes} ${rt.executionStatus}` : `REFUSED ${rt?.refusal ?? r.note ?? r.blockRefused}`) +
    (r.overlap > 0 ? ` | overlap=${r.overlap} prestate=${r.prestate.differsFromWhatTheBlockWrote}/${r.overlap} echo=${r.echoReading.equalsWhatTheBlockWrote} differ=${r.echoReading.differs} notRead=${r.echoReading.notRead}` : '') +
    ` | literal: ${r.literal?.answered ? 'answered' : 'refused'}`,
  );
}
console.log(`\n${answered.length} of ${ladder.length} rungs served a mined-transaction read set at the parent block; ` +
  `${testable.length} testable, ${testable.reduce((a, r) => a + r.overlap, 0)} slots judged; ` +
  `${calls} RPC calls, ${transportRetries} transport retries`);
if (failures.length) {
  console.error(`\n${failures.length} verdict failure(s):`);
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}
console.log('every verdict holds: V1 prestate, V2 echo control, V3 node agrees, V4 flag recognised, V5 depth');
process.exit(0);
