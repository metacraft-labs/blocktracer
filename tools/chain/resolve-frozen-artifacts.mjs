#!/usr/bin/env node
// resolve-frozen-artifacts.mjs — WHAT A CAPTURE WOULD HAVE MEASURED, ASKED AFTERWARDS.
//
// ── WHY THIS EXISTS ───────────────────────────────────────────────────────────────────
//
// Every transaction in `client/fixtures/chain/` reads `declaredRung: 3,
// stepsPositioned: 0` and carries NO `artifacts` key. Read carelessly that is a finding
// about Aztec contracts. It is not: those captures were taken with a runtime that predates
// off-chain artifact resolution, so nothing in them ever asked whether a contract's sources
// could be proved. `artifacts` is absent precisely so that "nobody looked" stays
// distinguishable from "looked and proved nothing" — see `lib/replay.mjs` — but an absent
// key only says WHICH question was not asked, never what its answer would have been.
//
// The obvious way to find out is to capture the transaction again. That is impossible and
// permanently so: `getTxByHash` is a mempool query and the body is hard-deleted at
// finalization (CHAIN-CAPTURE.md §1). Measured 2026-09-01, all eight frozen transactions
// answer `null` there while `getTxEffect` still answers, which is the pruning, not an
// outage.
//
// So the question is asked WITHOUT the transaction. Three facts survive pruning:
//
//   1. the committed `.ct` container, which interned the address of every contract the
//      execution entered;
//   2. the contract INSTANCE at that address, which the node still serves — instances are
//      world state, not mempool;
//   3. the contract CLASS behind it, likewise, and it is the class that carries
//      `artifactHash` and `packedBytecode`.
//
// Given those three, `resolveContractArtifact` — the EXACT function the replay driver calls,
// imported from the runtime rather than restated here — decides the same way it would have
// decided during the capture.
//
// ── WHAT THIS IS NOT ──────────────────────────────────────────────────────────────────
//
// **IT DOES NOT PRODUCE A RECORDING AND MUST NEVER BE READ AS ONE.** A resolution says an
// artifact is provably this class's; a rung-1 RECORDING additionally requires the step
// stream to have been written against that artifact's debug map, and that needs the
// transaction body. So a `resolved: true` here means "this contract's sources are provable
// and this capture never asked", which is a fact about the corpus. It does not turn the
// frozen container into a source-level one, and nothing downstream may treat it as if it
// did — `ingest.nim` reads `recording.sourceLevel` out of the snapshot and this tool writes
// no snapshot at all.
//
// **IT WRITES NOTHING.** The freeze is opened read-only. That is the whole point: the
// captures are irreplaceable, so the tool that interrogates them may not be able to damage
// them even by mistake.
//
// ── USAGE ─────────────────────────────────────────────────────────────────────────────
//
//   node --experimental-strip-types tools/chain/resolve-frozen-artifacts.mjs \
//     --runtime <path-to-aztec-avm-runtime> [--snapshot <dir>]... [--json]
//
// `--runtime` must be a checkout whose `replay/src/artifact_resolution.ts` exists; a runtime
// without it is refused BY NAME rather than reported as "nothing resolved", because those
// two readings are the entire subject of this file.

import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join, resolve as resolvePath } from 'node:path';
import { pathToFileURL } from 'node:url';

const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : fallback;
};
const args = (name) => argv.flatMap((a, i) => (a === `--${name}` ? [argv[i + 1]] : []))
  .filter(Boolean);
const asJson = argv.includes('--json');
const die = (m) => { console.error(`resolve-frozen-artifacts: ${m}`); process.exit(2); };

const runtime = arg('runtime', process.env.AZTEC_RUNTIME);
if (!runtime) die('--runtime <path-to-aztec-avm-runtime> is required. This repository carries '
  + 'no resolver and will not restate one: a second spelling of the proof would be a rule that '
  + 'can disagree with the one the driver actually uses.');
for (const f of ['replay/src/artifact_resolution.ts', 'replay/tools/artifact_sources.mjs']) {
  if (!existsSync(join(runtime, f))) {
    die(`${runtime} has no ${f}. This runtime CANNOT resolve artifacts, which is a different `
      + 'fact from "it resolved none" and must not be reported as one. Point --runtime at a '
      + 'checkout that carries the resolver.');
  }
}

const { resolveContractArtifact } =
  await import(pathToFileURL(join(runtime, 'replay/src/artifact_resolution.ts')).href);
const { artifactCrypto, liveChainProviders } =
  await import(pathToFileURL(join(runtime, 'replay/tools/artifact_sources.mjs')).href);

/** Which Aztecscan deployment a captured chain slug names. The resolver refuses an unknown
 *  chain rather than guessing a base URL, and so does this. */
const SCAN_CHAIN = { aztec: 'aztec-mainnet', 'aztec-testnet': 'aztec-testnet' };

let rpcId = 0;
async function rpc(url, method, params) {
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params }),
  });
  if (!r.ok) throw new Error(`${method}: HTTP ${r.status}`);
  const j = await r.json();
  if (j.error) throw new Error(`${method}: ${j.error.message ?? JSON.stringify(j.error)}`);
  return j.result;
}

/**
 * Every contract address a container interned.
 *
 * A CTFS container stores them as CBOR text strings, and an Aztec address is the only
 * `0x` + 64 lowercase hex string it carries apart from the recording's own `sourcePath`
 * (`/aztec/<txHash>.avm`), which the caller excludes by name. Scanning for the SHAPE rather
 * than parsing CBOR is deliberate: this repository has no CTFS reader, cannot take one as a
 * dependency (the site build is hermetic), and a shape scan that over-matches is safe here —
 * a spurious address is answered "no contract instance" by the node and reported as such,
 * whereas a missed one would silently shrink the set every claim below quantifies over.
 */
function addressesIn(containerPath, txHash) {
  const text = readFileSync(containerPath).toString('latin1');
  return [...new Set([...text.matchAll(/0x[0-9a-f]{64}/g)].map((m) => m[0]))]
    .filter((a) => a !== txHash);
}

const snapshotDirs = args('snapshot');
if (snapshotDirs.length === 0) {
  const root = resolvePath(new URL('../..', import.meta.url).pathname);
  const fixtures = join(root, 'client', 'fixtures', 'chain');
  if (!existsSync(fixtures)) die(`no --snapshot given and ${fixtures} does not exist`);
  for (const name of readdirSync(fixtures).sort()) {
    if (existsSync(join(fixtures, name, 'snapshot.json'))) snapshotDirs.push(join(fixtures, name));
  }
}
if (snapshotDirs.length === 0) die('no snapshot directories to read');

const rows = [];
let transactions = 0, contracts = 0, resolved = 0;

for (const dir of snapshotDirs) {
  const snap = JSON.parse(readFileSync(join(dir, 'snapshot.json'), 'utf8'));
  const chain = snap.provenance?.chain ?? '';
  const url = snap.provenance?.endpoint;
  if (!url) die(`${dir}: the snapshot names no endpoint, so its chain cannot be re-asked`);
  const scanChain = SCAN_CHAIN[chain];
  if (scanChain === undefined) {
    die(`${dir}: no Aztecscan deployment is known for chain '${chain}'. Refusing to guess: a `
      + 'wrong base URL answers 404 for every class, which is indistinguishable from an '
      + 'explorer that holds nothing.');
  }
  const providers = liveChainProviders({ chain: scanChain });

  for (const t of snap.transactions) {
    if (t.outcome !== 'replayed' && t.outcome !== 'divergent') continue;
    const ct = join(dir, t.container ?? '');
    if (!t.container || !existsSync(ct)) {
      die(`${dir}: ${t.txHash} is ${t.outcome} and its container ${t.container} is missing. `
        + 'A transaction whose container cannot be opened has no address list, and skipping it '
        + 'would shrink the set silently.');
    }
    transactions++;
    for (const address of addressesIn(ct, t.txHash)) {
      const instance = await rpc(url, 'node_getContract', [address]);
      if (!instance) {
        rows.push({ chain, txHash: t.txHash, blockNumber: t.blockNumber, address,
                    note: 'no contract instance at this address' });
        continue;
      }
      const classId = instance.currentContractClassId ?? instance.contractClassId;
      const cc = await rpc(url, 'node_getContractClass', [classId]);
      if (!cc) {
        rows.push({ chain, txHash: t.txHash, blockNumber: t.blockNumber, address, classId,
                    note: 'the node serves no class for this instance' });
        continue;
      }
      const packedBytecode = Buffer.isBuffer(cc.packedBytecode)
        ? cc.packedBytecode.toString('base64')
        : cc.packedBytecode?.type === 'Buffer'
          ? Buffer.from(cc.packedBytecode.data).toString('base64')
          : String(cc.packedBytecode);
      const like = {
        id: String(cc.id ?? classId),
        artifactHash: String(cc.artifactHash),
        privateFunctionsRoot: String(cc.privateFunctionsRoot),
        packedBytecode,
      };
      const res = await resolveContractArtifact(address, like, providers, artifactCrypto);
      contracts++;
      if (res.resolved) resolved++;
      rows.push({
        chain, txHash: t.txHash, blockNumber: t.blockNumber, address,
        contractClassId: like.id,
        artifactHash: like.artifactHash,
        packedBytecodeBytes: Buffer.from(packedBytecode, 'base64').length,
        // WHAT THE CAPTURE RECORDED, beside what the resolver now says. Both, always: the
        // point of the tool is the gap between them, and a report carrying only the second
        // could not show one.
        capturedDeclaredRung: t.recording?.declaredRung ?? null,
        capturedStepsPositioned: t.recording?.stepsPositioned ?? null,
        capturedArtifacts: Array.isArray(t.artifacts) ? t.artifacts.length : null,
        resolved: res.resolved === true,
        candidatesConsidered: res.candidatesConsidered ?? null,
        rejected: res.rejected.map((r) => ({ origin: r.origin, fault: r.fault })),
        origin: res.resolved ? res.artifact.origin : null,
        corroboration: res.resolved ? res.corroboration : null,
        agreeingDistributors: res.resolved ? res.agreeingDistributors : null,
        sourceFiles: res.resolved ? res.artifact.files.size : 0,
        reason: res.reason,
      });
    }
  }
}

if (asJson) {
  console.log(JSON.stringify({ transactions, contracts, resolved,
                               unresolved: contracts - resolved, rows }, null, 1));
} else {
  for (const r of rows) {
    if (r.note) { console.log(`  ${r.chain} ${r.txHash} ${r.address} — ${r.note}`); continue; }
    console.log(`  ${r.chain} block ${r.blockNumber} tx ${r.txHash}`);
    console.log(`    contract ${r.address}`);
    console.log(`    class    ${r.contractClassId}`);
    console.log(`    artifactHash ${r.artifactHash}  packedBytecode ${r.packedBytecodeBytes} bytes`);
    console.log(`    CAPTURED: declaredRung=${r.capturedDeclaredRung} `
      + `stepsPositioned=${r.capturedStepsPositioned} artifacts=`
      + `${r.capturedArtifacts === null ? 'ABSENT (nobody looked)' : r.capturedArtifacts}`);
    console.log(`    RESOLVED NOW: ${r.resolved ? `YES via ${r.origin} (${r.corroboration}, `
      + `${r.sourceFiles} source file(s))` : `no — ${r.candidatesConsidered} candidate(s), `
      + `${r.rejected.length} rejected`}`);
    for (const x of r.rejected) console.log(`      rejected: ${x.origin} -> ${x.fault}`);
  }
  // §4b: the size before any property of the set. A universal claim over an empty set is
  // vacuously true, and this is the tool most likely to be handed one.
  console.log(`\n${transactions} transaction(s) with a container; ${contracts} contract(s) `
    + `interrogated; ${resolved} resolved, ${contracts - resolved} not.`);
  if (contracts === 0) {
    console.log('NOTHING WAS INTERROGATED. Read no conclusion out of this run: an empty set '
      + 'satisfies every statement anyone might make about it.');
    process.exit(1);
  }
}
