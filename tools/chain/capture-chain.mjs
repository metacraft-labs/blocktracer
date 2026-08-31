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
  console.error(`capture-chain: replaying ${c.txHash} (block ${c.blockNumber})`);
  const r = await run(nodeBin, [
    '--experimental-wasm-exnref',
    'replay/tools/replay_settled_transaction.mjs',
    '--url', url,
    '--tx', c.txHash,
    '--module', resolve(avm),
    '--ct', ctPath,
    '--ct-writer', resolve(ctWriter),
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
    const why = (r.err.match(/^\s*([A-Z][A-Za-z]+(?:Error|Unavailable|NotFound|Unsupported|Regression|Exceeded)):?.*$/m) ?? [null, 'unknown'])[1];
    console.error(`capture-chain:   refused (${why})`);
    replays.set(c.txHash, {
      replayed: false,
      refusal: why,
      reason: `This transaction could not be re-executed: the replay runtime refused with `
        + `${why}. No trace was recorded for it.`,
      detail: r.err.trim().split('\n').slice(-3).join(' ').slice(0, 400),
    });
    continue;
  }
  if (!existsSync(ctPath)) {
    replays.set(c.txHash, { replayed: false, refusal: 'no-container-written', detail: 'the driver reported success and wrote no container' });
    continue;
  }
  const bytes = (await readFile(ctPath)).length;
  const total = facts.verdict.matched + facts.verdict.mismatched;
  // REPRODUCED OR NOT, THE RECORDING IS REAL AND IT STEPS. The distinction the explorer needs is
  // not "did this work" but "may this be used as evidence of what the chain did", and those are
  // different answers: a divergent trace is a correct recording of an execution that disagreed
  // with the block, which is a thing worth showing and a thing that must never be shown silently.
  const kind = facts.verdict.reproduced ? 'replayed' : 'divergent';
  console.error(`capture-chain:   ${kind} — ${facts.verdict.matched}/${total} effects, `
    + `${facts.recording.steps} steps, rung ${facts.recording.declaredRung}, container ${bytes} bytes`);
  replays.set(c.txHash, {
    replayed: true,
    kind,
    container: `ct/${c.txHash}.ct`,
    containerBytes: bytes,
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
    // THE RECORDING'S OWN ACCOUNT OF ITS FIDELITY. `declaredRung: 3` is the ceiling a chain
    // contract can reach: `ContractClassPublic` carries no debug_symbols, no file_map and no source
    // text, so there is nothing to position a program counter against. `stepsPositioned` is the
    // measurement that proves it rather than asserting it — every step is unpositioned, and a page
    // that rendered this as source-level would be inventing the positions.
    recording: facts.recording,
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
