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
// frozen container into a source-level one — `ingest.nim` still reads `recording.sourceLevel`
// out of the snapshot and out of nothing else, so no output of this tool can raise it.
//
// **IT NEVER WRITES A SNAPSHOT.** `snapshot.json` and the `ct/` containers are opened
// read-only and always will be: the captures are irreplaceable — the bodies behind them are
// pruned — so the tool that interrogates them may not be able to damage them even by mistake.
//
// THIS PARAGRAPH USED TO READ "IT WRITES NOTHING", AND `--write` IS THE CORRECTION.
// Reporting the answer to a terminal and leaving the published site saying `Not checked` for
// every transaction meant the corpus knew something the product did not. `--write` emits a
// SIDECAR — `artifact-resolution.json`, beside the capture, never inside it — carrying its own
// `measuredAt` and the resolver's own commit, and `ingest.nim` consumes it only where the
// capture recorded no answer of its own and marks every entry `measuredPostHoc`. The
// read-only guarantee above is unchanged, because the freeze is a different file.
//
// ── USAGE ─────────────────────────────────────────────────────────────────────────────
//
//   node --experimental-strip-types tools/chain/resolve-frozen-artifacts.mjs \
//     --runtime <path-to-aztec-avm-runtime> [--snapshot <dir>]... [--json] [--write]
//
// `--runtime` must be a checkout whose `replay/src/artifact_resolution.ts` exists; a runtime
// without it is refused BY NAME rather than reported as "nothing resolved", because those
// two readings are the entire subject of this file.

import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
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
// `--write` emits the SIDECAR, and the word sidecar is the whole design.
//
// `snapshot.json` is not opened for writing here and must never be: §6's freeze is
// irreplaceable, the bodies behind it are pruned, and a tool that could damage it by mistake
// is a tool that eventually does. So the answer lands BESIDE the capture, in
// `artifact-resolution.json`, carrying its own provenance — when it was measured, by which
// resolver, and against which runtime — precisely so that a consumer can tell a post-hoc
// answer from one the capture itself recorded. `ingest.nim` reads it under exactly that
// distinction and republishes it marked; it may not become a recording, and §6.1's rule that
// a resolution is not a recording is enforced there rather than assumed here.
const asWrite = argv.includes('--write');
const die = (m) => { console.error(`resolve-frozen-artifacts: ${m}`); process.exit(2); };

const runtime = arg('runtime', process.env.AZTEC_RUNTIME);
if (!runtime) die('--runtime <path-to-aztec-avm-runtime> is required. This repository carries '
  + 'no resolver and will not restate one: a second spelling of the proof would be a rule that '
  + 'can disagree with the one the driver actually uses.');
for (const f of ['replay/src/artifact_resolution.ts', 'replay/tools/artifact_sources.mjs',
                 'ct-host/src/source_map.ts']) {
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
// THE POSITIONING HALF, AND IT IS THE SAME CLASS THE RECORDER USES.
//
// `recording.ts:429` positions a step with `source.map.positionFor(step.pc)` and nothing else.
// This imports that class rather than restating the lookup, for the reason `--runtime` exists at
// all: a second spelling of the join is a rule that can disagree with the one the driver applies.
const { ContractSourceMap, rungFor } =
  await import(pathToFileURL(join(runtime, 'ct-host/src/source_map.ts')).href);

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

/** The resolver checkout's own commit, recorded into the sidecar.
 *
 * `provenance.runtimeCommit` already says which runtime CAPTURED a snapshot; a post-hoc
 * answer needs the same fact about the runtime that ANSWERED, because the two differ by
 * construction — that difference is the entire reason this tool exists — and a sidecar that
 * did not name its own resolver could not be re-derived or disputed later. Unknown is
 * written as `null` rather than omitted: a missing key reads as "not recorded", and this
 * file's whole subject is that absence and measurement must stay apart. */
function runtimeCommitOf(dir) {
  try {
    return execFileSync('git', ['-C', dir, 'rev-parse', 'HEAD'],
                        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() || null;
  } catch { return null; }
}
const resolverCommit = runtimeCommitOf(runtime);

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
  /** Every transaction this run actually opened, with the address list it interned — kept
   *  so the sidecar can distinguish "answered" from "not reached". A transaction whose
   *  container interned NO address produces no rows at all, and would otherwise vanish from
   *  the grouping and be published as the empty record `[]`, i.e. as "checked, executed no
   *  contract code". That is a different and stronger claim than this run can make. */
  const considered = [];

  for (const t of snap.transactions) {
    if (t.outcome !== 'replayed' && t.outcome !== 'divergent') continue;
    const ct = join(dir, t.container ?? '');
    if (!t.container || !existsSync(ct)) {
      die(`${dir}: ${t.txHash} is ${t.outcome} and its container ${t.container} is missing. `
        + 'A transaction whose container cannot be opened has no address list, and skipping it '
        + 'would shrink the set silently.');
    }
    transactions++;
    const addresses = addressesIn(ct, t.txHash);
    considered.push({ txHash: t.txHash, blockNumber: t.blockNumber, addresses });
    // The published step stream for this transaction, if the capture derived one. It carries the
    // AVM byte offset per step — the exact key `brillig_locations` uses — which is what makes the
    // positioning below a join over published data rather than a re-execution.
    const insPath = join(dir, 'instructions', `${t.txHash}.json`);
    const listing = existsSync(insPath)
      ? JSON.parse(readFileSync(insPath, 'utf8'))
      : null;
    for (const address of addresses) {
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

      // ── THE POSITIONING JOIN ─────────────────────────────────────────────────────────────
      //
      // A resolution says the artifact is provably this class's. It does NOT say the recording
      // shows source — that needs each step's pc carried through the artifact's map. The pcs
      // survive (they are in the container and republished in `instructions/`), the map is in
      // the artifact, so the join is computable now, for a transaction whose body is gone.
      //
      // ONE CONTRACT ONLY, and this is a refusal rather than a best effort. `instructions.json`
      // publishes `pc` per step and NOT which contract executed it, so on a transaction that
      // entered two contracts there is no way to say which map a pc belongs to. Positioning it
      // against whichever artifact happens to have resolved would attribute lines from one
      // contract's source to another's steps — a wrong answer that looks exactly like a right
      // one. Every transaction in this corpus enters exactly one contract; a future one that
      // does not gets `positions: null` and the reason, rather than a guess.
      let positions = null;
      if (res.resolved && listing !== null) {
        if (addresses.length !== 1) {
          positions = { unavailable: `this transaction entered ${addresses.length} contracts and `
            + 'the published step stream does not say which contract executed each step, so a pc '
            + 'cannot be attributed to a map' };
        } else if (!Array.isArray(listing.pc)) {
          positions = { unavailable: 'the published step stream carries no pc column' };
        } else {
          const a = res.artifact;
          const paths = [];
          const map = new ContractSourceMap(a.debugInfo, a.bytecode.length, a.files,
            (p) => { paths.push(p); return paths.length - 1; });
          const pathId = [], line = [], column = [];
          let positioned = 0;
          for (const pc of listing.pc) {
            const at = map.positionFor(pc);
            if (at === null || at === undefined) { pathId.push(null); line.push(null); column.push(null); continue; }
            positioned += 1;
            pathId.push(at.pathId); line.push(at.line); column.push(at.column ?? null);
          }
          positions = {
            steps: listing.pc.length,
            positioned,
            // The artifact's own verdict beside the recording's outcome, because they differ and
            // the difference is the finding: the ARTIFACT is rung 1, and this RECORDING is not,
            // and neither number explains the other on its own.
            artifactRung: rungFor(a.debugInfo, a.bytecode.length, a.files).rung,
            paths,
            pathId,
            line,
            column,
          };
        }
      }

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
        positions,
        // The TEXT, carried on the row so `--write` can emit a bundle without resolving twice.
        // Not printed by the human report and not put in `--json`: it is ~270 KB per artifact.
        files: res.resolved
          ? [...res.artifact.files.values()].map((f) => ({ path: f.path, source: f.source }))
          : null,
        shape: res.resolved ? res.artifact.shape : null,
        debugDigest: res.resolved ? (res.artifact.debugDigest ?? null) : null,
      });
    }
  }

  if (!asWrite) continue;

  // ── THE SIDECAR ────────────────────────────────────────────────────────────────────────
  //
  // One record per transaction this run OPENED, and a transaction is written with an
  // `artifacts` array only when the run answered for EVERY address its container interned.
  // Anything less is written `artifacts: null` with the reason, which is the same `null` the
  // capture path uses for "nobody looked" and lands the row on `Not checked` — the honest
  // outcome for a question this run did not finish asking.
  //
  // The alternative, publishing the addresses that did answer, is the exact defect
  // `test_chain_provenance`'s "the numerator and denominator are the transaction's, not the
  // resolved set's" exists to catch: a two-contract transaction that answered for one would
  // be published as 1/1 and read as complete. The denominator has to be the transaction's or
  // the fold is measuring a set nobody chose.
  const byTx = new Map();
  for (const r of rows) {
    if (r.chain !== chain) continue;
    if (!byTx.has(r.txHash)) byTx.set(r.txHash, []);
    byTx.get(r.txHash).push(r);
  }
  const txOut = [];
  let wrote = 0, withheld = 0, sourcesWritten = 0;
  for (const c of considered) {
    const got = byTx.get(c.txHash) ?? [];
    const answered = got.filter((r) => !r.note);
    const complete = c.addresses.length > 0 && answered.length === c.addresses.length;
    if (!complete) {
      withheld++;
      const why = c.addresses.length === 0
        ? 'this container interned no contract address, so there was nothing to resolve '
          + 'against and this run cannot say the transaction executed no contract code'
        : `${answered.length} of ${c.addresses.length} interned address(es) answered; the `
          + 'rest have no contract instance or no class the node will serve, so the '
          + 'transaction\'s denominator is unknown';
      txOut.push({ txHash: c.txHash, blockNumber: c.blockNumber, artifacts: null, reason: why });
      continue;
    }
    wrote++;
    // ── THE SOURCE BUNDLE, WRITTEN ONLY WHERE A STEP ACTUALLY LANDS IN IT ──────────────────
    //
    // `sources/<txHash>.json` is the shape `ingest.nim` already reads. It is emitted only when
    // this transaction has at least one positioned step: text with nothing pointing into it is
    // a source pane a visitor can open onto a file no step ever reaches, which reads as source
    // support the recording has not got.
    //
    // `sourceLevel` is written FALSE and it is not a placeholder. It means what the capture
    // means by it — every executed step of every contract positioned — and 86 of 108 is not
    // that. The field stays honest and `ingest.nim` keeps its own refusal keyed to it; what
    // this file adds is a bundle for a recording that is PARTLY positioned, which is a state
    // the corpus had no way to express before.
    const positioning = answered.map((r) => r.positions).filter((p) => p && p.positioned > 0);
    if (asWrite && positioning.length > 0) {
      const bundles = answered
        .filter((r) => r.resolved && r.files && r.files.length > 0)
        .map((r) => ({
          address: r.address,
          codeHash: r.contractClassId,
          artifactHash: r.artifactHash,
          origin: r.origin,
          shape: r.shape,
          corroboration: r.corroboration,
          agreeingDistributors: r.agreeingDistributors ?? [],
          debugDigest: r.debugDigest,
          files: Object.fromEntries(r.files.map((f) => [f.path, f.source])),
        }));
      const srcDir = join(dir, 'sources');
      mkdirSync(srcDir, { recursive: true });
      writeFileSync(join(srcDir, `${c.txHash}.json`),
        JSON.stringify({ txHash: c.txHash, sourceLevel: false, bundles }, null, 1) + '\n');
      sourcesWritten++;
    }
    txOut.push({
      txHash: c.txHash,
      blockNumber: c.blockNumber,
      // Per-step source coordinates, or `null` where none were computed. Consumed by
      // `ingest.nim`, which republishes them beside the container as `positions.json`.
      positions: positioning.length === 1 ? positioning[0]
        : (positioning.length === 0 ? null
           : { unavailable: 'more than one contract positioned steps and the published step '
               + 'stream does not say which executed each one' }),
      artifacts: answered.map((r) => ({
        address: r.address,
        contractClassId: r.contractClassId,
        artifactHash: r.artifactHash,
        resolved: r.resolved,
        origin: r.origin,
        corroboration: r.corroboration,
        // Kept because §6.2's reading of the corpus turns on it: `candidatesConsidered: 0`
        // with an empty `rejected` means both providers were asked and neither offered a
        // candidate, which is a measurement — a provider that threw would appear as a
        // rejection. Without these two a reader cannot tell that from a swallowed outage.
        candidatesConsidered: r.candidatesConsidered,
        rejected: r.rejected,
        reason: r.reason,
      })),
    });
  }
  const out = {
    format: 'blocktracer/artifact-resolution@1',
    // WHAT THIS IS, in the file, because the file will be read by someone who has not read
    // §6. A resolution is not a recording; nothing here may be folded into one.
    note: 'Off-chain artifact resolution measured AFTER the capture, against contract '
      + 'instances and classes the node still serves (world state survives the mempool '
      + 'pruning that destroyed these transaction bodies). It says whether a contract\'s '
      + 'artifact is provable, NOT that this recording positioned its steps against one — '
      + 'that needs the body and is permanently unavailable for these transactions.',
    chain,
    measuredAt: new Date().toISOString(),
    measuredBy: {
      tool: 'tools/chain/resolve-frozen-artifacts.mjs',
      resolver: 'replay/src/artifact_resolution.ts',
      runtimeCommit: resolverCommit,
    },
    // The snapshot's own provenance, restated so the gap this file exists to close is
    // legible from inside it: the capture ran a runtime that could not resolve, this run
    // used one that can, and those are two different commits.
    capturedWithRuntimeCommit: snap.provenance?.runtimeCommit ?? null,
    snapshotFrozenAt: snap.provenance?.frozenAt ?? null,
    endpoint: url,
    counts: {
      transactionsConsidered: considered.length,
      transactionsWithSourceBundle: sourcesWritten,
      stepsPositioned: txOut.reduce((n, t) => n + (t.positions?.positioned ?? 0), 0),
      stepsTotal: txOut.reduce((n, t) => n + (t.positions?.steps ?? 0), 0),
      transactionsAnswered: wrote,
      transactionsWithheld: withheld,
      contracts: txOut.reduce((n, t) => n + (t.artifacts?.length ?? 0), 0),
      resolved: txOut.reduce(
        (n, t) => n + (t.artifacts ?? []).filter((a) => a.resolved).length, 0),
    },
    transactions: txOut,
  };
  const dest = join(dir, 'artifact-resolution.json');
  writeFileSync(dest, JSON.stringify(out, null, 1) + '\n');
  console.error(`resolve-frozen-artifacts: wrote ${dest} — ${wrote} answered, `
    + `${withheld} withheld, ${out.counts.resolved}/${out.counts.contracts} resolved, `
    + `${out.counts.stepsPositioned}/${out.counts.stepsTotal} steps positioned, `
    + `${sourcesWritten} source bundle(s)`);
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
