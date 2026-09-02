#!/usr/bin/env node
// capture-chain.mjs — turn a live Aztec chain into a committed snapshot this repository can build.
//
// WHY A SNAPSHOT AND NOT A BUILD-TIME FETCH. Three reasons, each independently sufficient:
//
//   1. The site build is hermetic. `nix build .#default` runs `static_export.nim` in a sandbox with
//      no network. A build that reached an Aztec node would either fail in CI or, worse, silently
//      serve whatever the node happened to answer — and a deploy whose content depends on somebody
//      else's uptime is the failure this repository is shaped to avoid.
//   2. Determinism is a published contract. `ci.yml`'s "Determinism — regenerate and diff" step
//      regenerates the tree and diffs it. A live fetch makes that step fail by construction.
//   3. FRESHNESS IS UNATTAINABLE ANYWAY, so pretending to chase it would be the dishonest choice.
//      `getTxByHash` prunes at the finalized tip: a transaction is replayable for roughly an hour
//      and then is not. No build cadence closes that gap. What CAN be honest is a recording taken
//      while the transaction was replayable, published with the time it was taken — which is
//      exactly what a snapshot is.
//
// WHAT IT PRODUCES, under --out:
//
//   snapshot.json        the capture metadata, the block window, and one row per transaction
//   ct/<txHash>.ct       one CodeTracer container per REPLAYED transaction, verbatim
//   sources/<txHash>.json  the source text behind a SOURCE-LEVEL recording, when there is one
//
// THE SOURCE BUNDLE IS A SEPARATE FILE FROM THE CONTAINER BECAUSE IT COMES FROM SOMEWHERE ELSE.
// The container is what the runtime recorded; the bundle is what the runtime FETCHED off-chain and
// proved against the contract class's `artifactHash`. `ct.source-provenance` inside the container
// says which artifact positioned each step, and this file carries the text those positions point
// into — keyed by the EXACT absolute paths the container interned (upstream CI build paths such as
// `/home/aztec-dev/aztec-packages/noir-projects/.../src/main.nr`). Those keys are never rewritten:
// a bundle whose keys do not match the interned paths is a bundle the viewer cannot use, and a
// prettier path would be a cosmetic change that silently breaks the only thing the file is for.
//
// The snapshot records BOTH populations, and that is the point of it:
//   * transactions that were inside the replayable window at capture and were re-executed, each
//     with its container, its effect comparison and its measured recording facts;
//   * transactions the node still SHOWS (`getTxEffect` answers) but will no longer REPLAY
//     (`getTxByHash` has pruned the body). Those get no container and no trace, and the reason is
//     recorded so the page can state it rather than rendering an empty debugger.
//
// USAGE
//   node tools/chain/capture-chain.mjs --runtime <path-to-aztec-avm-runtime> --out <dir> [options]
//
//   --runtime <dir>   a checkout of metacraft-labs/aztec-avm-runtime with `replay/node_modules`
//                     installed and the ct-writer wasm built. THIS TOOL SHELLS OUT TO IT; this
//                     repository deliberately carries no @aztec dependency and no AVM.
//   --out <dir>       where the snapshot goes (default client/fixtures/chain/aztec-testnet)
//   --url <rpc>       the node (default https://aztec-testnet.drpc.org)
//   --avm <path>      avm.wasm, the --import-memory build (or $AVM_WASM_PATH)
//   --ct-writer <p>   aztec_ct_writer.wasm (or $CT_WRITER_WASM_PATH)
//   --node <path>     a Node >= 24 binary; needs --experimental-wasm-exnref support
//   --depth N         how many blocks below the tip to enumerate for the visible-but-pruned
//                     population (default 220)
//   --max N           cap on transactions to REPLAY (default 6)
//
// EVERY VALUE IN THE SNAPSHOT IS MEASURED. Nothing here synthesises a hash, a gas figure or a step
// count. If a datum could not be read, the row says so by name; there is no default that stands in
// for a fact.

import { spawn } from 'node:child_process';
import { mkdir, rm, writeFile, readFile, copyFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, resolve } from 'node:path';

import { resolverPresence, refusalName, refusalDetail } from './lib/replay.mjs';

const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : fallback;
};

const runtime = arg('runtime');
const url = arg('url', 'https://aztec-testnet.drpc.org');
// THE SLUG IS AN ARGUMENT, because a second real chain has to be a capture, not
// a second producer. It defaults off the endpoint rather than off nothing, and
// `ingest.nim` refuses `aztec` outright — that slug belongs to the synthetic
// demo, and a real chain landing on it would overwrite the demo's blocks and
// make generated and real data indistinguishable in a URL.
const chain = arg('chain', url.includes('testnet') ? 'aztec-testnet' : 'aztec-mainnet');
const label = arg('label', chain === 'aztec-mainnet' ? 'Real Aztec mainnet data'
  : chain === 'aztec-testnet' ? 'Real Aztec testnet data' : 'Real chain data');
const outDir = resolve(arg('out', `client/fixtures/chain/${chain}`));
const avm = arg('avm', process.env.AVM_WASM_PATH);
const ctWriter = arg('ct-writer', process.env.CT_WRITER_WASM_PATH);
const nodeBin = arg('node', process.execPath);
const depth = Number(arg('depth', 220));
const maxReplays = Number(arg('max', 6));

const die = (m) => { console.error(`capture-chain: ${m}`); process.exit(2); };

if (!runtime) die('--runtime <path-to-aztec-avm-runtime> is required. This repository carries no AVM.');
if (!avm) die('--avm <avm.wasm> (or $AVM_WASM_PATH) is required. It must be the --import-memory build.');
if (!ctWriter) die('--ct-writer <aztec_ct_writer.wasm> (or $CT_WRITER_WASM_PATH) is required.');
for (const [label, p] of [['runtime', runtime], ['avm', avm], ['ct-writer', ctWriter]]) {
  if (!existsSync(p)) die(`${label} path does not exist: ${p}`);
}
// A RUNTIME THAT CANNOT RESOLVE ARTIFACTS IS A WRONG CAPTURE, NOT A FAILED ONE, so it is
// refused here rather than discovered in the committed fixture a year later. The rule is
// `lib/replay.mjs`'s and is IMPORTED rather than restated: this file already carries a second
// copy of the outcome decision, and a second copy of this one would be the same mistake in a
// place where being wrong costs an unrepeatable transaction. See `resolverPresence`.
{
  const r = resolverPresence(runtime);
  if (!r.ok) die(r.problem);
}

// ---- the node, spoken to directly for enumeration -------------------------------------------
// Enumeration is plain JSON-RPC because it needs no AVM and no @aztec package. Replay is the part
// that needs the runtime, and only that part shells out.
let rpcId = 0;
async function rpc(method, params = []) {
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params }),
  });
  if (!r.ok) throw new Error(`${method}: HTTP ${r.status}`);
  const j = await r.json();
  if (j.error) return { __err: j.error.message ?? JSON.stringify(j.error) };
  return j.result;
}

const capturedAt = new Date().toISOString();
const nodeInfo = await rpc('node_getNodeInfo');
if (nodeInfo?.__err) die(`the node refused getNodeInfo: ${nodeInfo.__err}`);
const tip = await rpc('node_getBlockNumber');
const finalized = await rpc('node_getBlockNumber', ['finalized']);
const proven = await rpc('node_getBlockNumber', ['proven']);

console.error(`capture-chain: ${url} nodeVersion=${nodeInfo.nodeVersion} l1ChainId=${nodeInfo.l1ChainId}`);
console.error(`capture-chain: tip=${tip} finalized=${finalized} proven=${proven} window=${tip - finalized}`);

// ---- enumerate ---------------------------------------------------------------------------------
// `header.totalManaUsed` first: a block that did no work had no transactions, and asking for the
// body of every block would be `depth` wasted round trips. The body is fetched only when the mana
// says there is something in it — and it is fetched WITH `{includeTransactions:true}`, because
// without that option the node answers a body-less block and a caller that did not notice would
// read every block as empty.
const blocks = [];
const rows = [];
for (let n = tip; n > tip - depth; n--) {
  const head = await rpc('node_getBlock', [n]);
  if (!head || head.__err) continue;
  const mana = String(head.header.totalManaUsed);
  const empty = /^0x0*$/.test(mana);
  const blockRow = {
    number: n,
    hash: head.hash,
    timestamp: Number(head.header.globalVariables.timestamp),
    totalManaUsed: mana,
    coinbase: head.header.globalVariables.coinbase,
    feePerL2Gas: head.header.globalVariables.gasFees.feePerL2Gas,
    archiveRoot: head.archive.root,
    parentArchiveRoot: head.header.lastArchive.root,
    transactions: [],
  };
  if (!empty) {
    const full = await rpc('node_getBlock', [n, { includeTransactions: true }]);
    for (const [i, eff] of (full?.body?.txEffects ?? []).entries()) {
      // The two calls are asked separately and BOTH answers are kept, because their disagreement is
      // the finding: `getTxByHash` reads the mempool, which is emptied at finalization, while
      // `getTxEffect` reads the archive, which is not. A transaction can therefore be perfectly
      // visible and no longer replayable, and that is a state the explorer has to render.
      const byHash = await rpc('node_getTxByHash', [eff.txHash]);
      const effect = await rpc('node_getTxEffect', [eff.txHash]);
      const bodyRetained = !!byHash && !byHash.__err;
      const effectVisible = !!effect && !effect.__err;
      blockRow.transactions.push(eff.txHash);
      rows.push({
        txHash: eff.txHash,
        blockNumber: n,
        txIndexInBlock: i,
        revertCode: eff.revertCode,
        transactionFee: eff.transactionFee,
        bodyRetained,
        effectVisible,
        firstInBlock: i === 0,
      });
    }
  }
  blocks.push(blockRow);
}
console.error(`capture-chain: ${blocks.length} blocks, ${blocks.filter(b => b.transactions.length).length} with transactions, ${rows.length} transactions`);

// ---- replay ------------------------------------------------------------------------------------
// A transaction is a replay candidate when the node still serves its body AND it is first in its
// block. The second condition is the runtime's, not ours: replaying transaction k requires the
// state after k-1, and the node does not serve intra-block intermediate state, so the runtime
// refuses with `IntraBlockPredecessorsUnavailable` rather than replaying against the wrong state.
const candidates = rows.filter(r => r.bodyRetained && r.firstInBlock).slice(0, maxReplays);
console.error(`capture-chain: ${candidates.length} replay candidate(s) of ${rows.filter(r => r.bodyRetained).length} with a retained body`);

await rm(outDir, { recursive: true, force: true });
await mkdir(join(outDir, 'ct'), { recursive: true });
await mkdir(join(outDir, 'sources'), { recursive: true });

function run(cmd, args, cwd) {
  return new Promise((res) => {
    const p = spawn(cmd, args, { cwd, env: { ...process.env } });
    let out = '';
    let err = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { err += d; });
    p.on('close', (code) => res({ code, out, err }));
  });
}

const replays = new Map();
for (const c of candidates) {
  const ctPath = join(outDir, 'ct', `${c.txHash}.ct`);
  // ASKED FOR ON EVERY REPLAY, NOT ONLY THE ONES EXPECTED TO PRODUCE ONE. Whether a
  // transaction reaches source level is decided by whether every contract it executed had a
  // provable off-chain artifact, and that is not knowable before the replay runs. The driver
  // writes this file when it has bundles and leaves it absent when it has none, so its
  // presence is a MEASUREMENT rather than a flag this tool set in advance.
  const srcRel = `sources/${c.txHash}.json`;
  const srcPath = join(outDir, srcRel);
  console.error(`capture-chain: replaying ${c.txHash} (block ${c.blockNumber})`);
  const r = await run(nodeBin, [
    '--experimental-wasm-exnref',
    'replay/tools/replay_settled_transaction.mjs',
    '--url', url,
    '--tx', c.txHash,
    '--module', resolve(avm),
    '--ct', ctPath,
    '--ct-writer', resolve(ctWriter),
    '--sources', srcPath,
    '--json',
  ], runtime);
  // A NON-ZERO EXIT IS NOT THE SAME QUESTION AS "DID IT REPLAY".
  //
  // The driver exits 1 when the replay's effects do not reproduce the block's — and still
  // completes the execution, still writes the container, and still prints its full report on
  // stdout. Reading the exit code alone throws all of that away and files a real, steppable,
  // honestly-divergent recording as an unexplained refusal. It did, once: a transaction that
  // matched 11 of 13 effects (the fee and one storage write differed) was recorded as
  // `refusal: unknown` with a truncated line of stderr for a reason.
  //
  // So the REPORT decides, and the exit code is only consulted when there is no report.
  let facts = null;
  try { facts = JSON.parse(r.out); } catch { /* no report — fall through to the refusal path */ }
  if (facts === null) {
    // A genuine refusal. The runtime names its refusals; the row keeps the name so the snapshot
    // says which transaction could not be replayed and why, rather than silently omitting it.
    // BOTH HALVES COME FROM `lib/replay.mjs`, AND THIS FILE USED TO CARRY ITS OWN COPY OF EACH.
    // The copies were the versions that library had already been fixed for, so the tool an
    // operator drives BY HAND was the one recording the worse answer:
    //
    //   * the name was matched by a SUFFIX ALLOWLIST (`Error|Unavailable|NotFound|Unsupported|
    //     Regression|Exceeded`). `refusalName`'s comment records what that costs — measured
    //     against the 92 error classes the runtime defines it classified 43 and returned
    //     `unknown` for the other 49, including `AvmTrap`, `WasiProcExit` and
    //     `HydrationDidNotConverge`, every one a plausible verdict on a live public
    //     transaction. Two mainnet catches were filed as `unknown` by that rule and both
    //     bodies have since pruned, so what refused them is now permanently unknowable.
    //   * the detail was the LAST THREE LINES of stderr. Node prints an uncaught throw as the
    //     message, then the stack, then the error's own properties, a blank line and its
    //     version banner — so the last three lines are the END of that, not the message. On a
    //     real `AvmToolchainRegression` this recorded `"}  Node.js v24.19.0"`: the closing
    //     brace of the error object, a blank line and the Node version, with the sentence
    //     naming the wrong `--avm` build discarded. `refusalDetail` anchors on the message
    //     line and skips the stack, the caret and the banner.
    //
    // A capture is rare and a refused body prunes within the hour, so the detail is frequently
    // the only surviving evidence of why a transaction was lost. Duplicating the logic meant
    // fixing it twice; this asks the library instead, so it is fixed once.
    const why = refusalName(r.err);
    console.error(`capture-chain:   refused (${why})`);
    replays.set(c.txHash, {
      replayed: false,
      refusal: why,
      reason: `This transaction could not be re-executed: the replay runtime refused with `
        + `${why}. No trace was recorded for it.`,
      detail: refusalDetail(r.err, why),
    });
    continue;
  }
  if (!existsSync(ctPath)) {
    replays.set(c.txHash, { replayed: false, refusal: 'no-container-written', detail: 'the driver reported success and wrote no container' });
    continue;
  }
  const bytes = (await readFile(ctPath)).length;
  // THE BUNDLE FILE IS NAMED IN THE ROW ONLY WHEN IT EXISTS AND HAS SOMETHING IN IT.
  //
  // `ingest.nim` REFUSES a snapshot whose row claims source level and whose bundle file is
  // missing or empty, because a manifest that claims source level with nothing to open puts
  // the debugger's source pane on a file it cannot fetch. That refusal is only useful if this
  // side never names a file it did not measure — so the path is read back and counted here
  // rather than written from the argument that was passed to the driver.
  let sourceBundleCount = 0;
  if (existsSync(srcPath)) {
    try {
      const parsed = JSON.parse(await readFile(srcPath, 'utf8'));
      sourceBundleCount = Array.isArray(parsed.bundles) ? parsed.bundles.length : 0;
    } catch {
      // Unparseable is not "absent": say so rather than silently publishing a row with no
      // bundle beside a recording that measured itself as source level.
      console.error(`capture-chain:   source bundle at ${srcRel} did not parse; not naming it`);
    }
  }
  const total = facts.verdict.matched + facts.verdict.mismatched;
  // REPRODUCED OR NOT, THE RECORDING IS REAL AND IT STEPS. The distinction the explorer needs is
  // not "did this work" but "may this be used as evidence of what the chain did", and those are
  // different answers: a divergent trace is a correct recording of an execution that disagreed
  // with the block, which is a thing worth showing and a thing that must never be shown silently.
  const kind = facts.verdict.reproduced ? 'replayed' : 'divergent';
  console.error(`capture-chain:   ${kind} — ${facts.verdict.matched}/${total} effects, `
    + `${facts.recording.steps} steps, rung ${facts.recording.declaredRung}, container ${bytes} bytes`
    + (facts.recording.sourceLevel
        ? `, SOURCE LEVEL (${sourceBundleCount} bundle(s))`
        : ''));
  replays.set(c.txHash, {
    replayed: true,
    kind,
    container: `ct/${c.txHash}.ct`,
    containerBytes: bytes,
    // Absent rather than empty when there is nothing: an absent key reads as "this capture
    // resolved no source", where `""` would read as "there is a file and it is nowhere".
    ...(sourceBundleCount > 0 ? { sourceBundles: srcRel } : {}),
    l2BlockNumber: facts.l2BlockNumber,
    txIndexInBlock: facts.txIndexInBlock,
    preStateReadAt: facts.preStateReadAt,
    contractReferenceBlock: facts.contractReferenceBlock,
    hydrationRounds: facts.rounds,
    seedSize: facts.seedSize,
    instructionsExecuted: facts.instructionsExecuted,
    publishedRevertCode: facts.published.revertCode,
    replayedRevertCode: facts.replayed.revertCode,
    // The effect comparison, whole. `reproduced` alone would hide a run that matched nothing
    // because it compared nothing.
    effects: {
      reproduced: facts.verdict.reproduced,
      matched: facts.verdict.matched,
      mismatched: facts.verdict.mismatched,
      mismatches: facts.mismatches ?? [],
    },
    // THE RECORDING'S OWN ACCOUNT OF ITS FIDELITY, AND `declaredRung` IS A MEASUREMENT PER
    // TRANSACTION RATHER THAN A CONSTANT.
    //
    // THIS COMMENT USED TO SAY "`declaredRung: 3` is the ceiling a chain contract can reach", and
    // that sentence was wrong in one word. `ContractClassPublic` really does carry no
    // debug_symbols, no file_map and no source text — so rung 3 is the ceiling reachable FROM THE
    // NODE — but upstream's `artifactHash` exists precisely so a client can verify an artifact
    // fetched from somewhere else, and the runtime's `replay/src/artifact_resolution.ts` does that:
    // it proves a candidate artifact against the class's `artifactHash`, byte-compares its public
    // bytecode against the class's `packedBytecode`, and recomputes the class id from both. A
    // contract whose artifact is proved that way records at rung 1 with real Noir positions; a
    // contract whose artifact cannot be proved records at rung 3 exactly as before, and says which
    // in `ct.source-provenance`.
    //
    // So `recording.declaredRung`, `recording.sourceLevel` and `recording.contractRungs` are copied
    // through UNTOUCHED and nothing here decides them. `stepsPositioned` remains the measurement
    // that keeps the claim honest in both directions: a page must not render source over a
    // container whose steps are unpositioned, and must not withhold it from one whose steps are.
    recording: facts.recording,
    // L5: THE RESOLUTION ITSELF, INCLUDING EVERY REJECTION. "we did not look" and "we looked and
    // proved nothing" are different sentences for a transaction page to say, and a snapshot that
    // recorded only successes could not tell them apart.
    //
    // THREE STATES, AND `?? []` COLLAPSED TWO OF THEM. See the long note on the same line in
    // `lib/replay.mjs`, which is the copy the follower uses: an array with entries, an empty
    // array, and NO array are three different facts, and the third one — "the runtime that
    // produced this report cannot resolve artifacts at all" — is the one every capture frozen
    // before 2026-09-01 is in. `ingest.nim` distinguishes `null` from `[]` deliberately; this
    // side has to be able to hand it the `null`.
    artifacts: Array.isArray(facts.artifacts) ? facts.artifacts : null,
    // THE ROOTS DELIBERATELY DO NOT AGREE, and the divergence travels with the recording. Replay
    // hydrates only the leaves the execution touched, so the trees it rebuilds are sparse and their
    // roots cannot equal the block's. Dropping this in transit would turn a known, explained
    // difference into an unexplained one.
    roots: facts.roots,
    rootsAnyAgree: facts.rootsAnyAgree,
    skipped: facts.skipped ?? [],
  });
}

// ---- the snapshot ------------------------------------------------------------------------------
const transactions = rows.map((r) => {
  const rep = replays.get(r.txHash);
  if (rep?.replayed) return { ...r, outcome: rep.kind, ...rep };
  if (rep) return { ...r, outcome: 'refused', ...rep };
  if (!r.bodyRetained) {
    return {
      ...r,
      outcome: 'pruned',
      reason: `The node still serves this transaction's effects but no longer serves its body: `
        + `getTxByHash prunes at the finalized tip (block ${finalized} when this snapshot was taken) `
        + `and getTxEffect does not. This transaction settled in block ${r.blockNumber}, `
        + (finalized === r.blockNumber
            ? `which is that tip exactly — pruning takes the finalized block too. `
            : `${finalized - r.blockNumber} block(s) below it. `)
        + `It can no longer be re-executed, so no trace was recorded for it.`,
    };
  }
  if (!r.firstInBlock) {
    return {
      ...r,
      outcome: 'not-first-in-block',
      reason: `Replaying this transaction needs the state left by the transaction before it in `
        + `block ${r.blockNumber}, and the node does not serve intra-block intermediate state. `
        + `Only the first transaction in a block can be re-executed from published data.`,
    };
  }
  return { ...r, outcome: 'not-attempted', reason: `Inside the replayable window but beyond this capture's --max of ${maxReplays}.` };
});

const snapshot = {
  format: 'blocktracer/chain-snapshot@1',
  provenance: {
    // WHAT THIS IS, in the snapshot itself, so no consumer has to infer it.
    kind: 'live-capture',
    chain,
    label,
    endpoint: url,
    capturedAt,
    nodeVersion: nodeInfo.nodeVersion,
    l1ChainId: nodeInfo.l1ChainId,
    rollupVersion: nodeInfo.rollupVersion,
    rollupAddress: nodeInfo.l1ContractAddresses?.rollupAddress ?? '',
    tool: 'tools/chain/capture-chain.mjs',
    runtimeCommit: (await run('git', ['rev-parse', 'HEAD'], runtime)).out.trim(),
  },
  window: {
    // The replayable window, as it was at capture. Both ends are node answers, not choices.
    tip, finalized, proven,
    replayableFrom: finalized + 1,
    replayableTo: tip,
    blocks: Math.max(0, tip - finalized),
    enumeratedDepth: depth,
  },
  counts: {
    blocks: blocks.length,
    blocksWithTransactions: blocks.filter(b => b.transactions.length).length,
    transactions: rows.length,
    bodyRetained: rows.filter(r => r.bodyRetained).length,
    replayed: transactions.filter(t => t.outcome === 'replayed').length,
    divergent: transactions.filter(t => t.outcome === 'divergent').length,
    refused: transactions.filter(t => t.outcome === 'refused').length,
    pruned: transactions.filter(t => t.outcome === 'pruned').length,
  },
  blocks,
  transactions,
};

await writeFile(join(outDir, 'snapshot.json'), JSON.stringify(snapshot, null, 1) + '\n');
console.error(`capture-chain: wrote ${join(outDir, 'snapshot.json')}`);
console.error(`capture-chain: ${snapshot.counts.replayed} reproduced, ${snapshot.counts.divergent} divergent `
  + `(both carry containers), ${snapshot.counts.refused} refused, ${snapshot.counts.pruned} visible but pruned, `
  + `${snapshot.counts.transactions} transactions total`);
