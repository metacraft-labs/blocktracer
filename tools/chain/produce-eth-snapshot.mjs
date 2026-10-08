#!/usr/bin/env node
//
// produce-eth-snapshot.mjs — ETHEREUM MAINNET: A CTFS CONTAINER PLUS CHAIN DATA, INTO A
// Data-Contract.md §5-CONFORMING SNAPSHOT TREE.
//
// ── WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT ─────────────────────────────────────
//
// `codetracer-evm-recorder trace-onchain <tx> --rpc-url <archive> --out-dir <dir>` writes
// a CTFS container and a disassembly listing. Nothing in that repository — or in any of
// the twelve recorder repositories, measured — writes a `snapshot.json`, a `chain-snapshot`
// directory, a `prestate` file or anything else this project reads. So the whole of the
// gap between a working recorder and a published chain is one component, and this file is
// that component for Ethereum mainnet: container + chain data -> a §5 tree. Everything
// rightward of `snapshot.json` is shared and already works.
//
// IT IS WRITTEN CONCRETELY AND DUPLICATIVELY, ALONGSIDE THE AZTEC PRODUCER, AND THAT IS
// THE POINT. `capture-chain.mjs` and `follow-chain.mjs` are the Aztec producers; this file
// shares no interface, no plugin and no registered module with them, and there is no
// per-chain dispatch anywhere in it — it names ONE chain, in its own source, the way
// `lib/eth-producer-facts.mjs` names one chain's facts. Chain-Delivery DEL-7 is the
// milestone that may extract a seam from the two, under ING-7's two-consumer rule; the
// duplication here is what makes that seam a MEASURED boundary rather than a guess. Where
// this file wanted to factor something out, the wanting is recorded as a comment for DEL-7
// instead of acted on — search this file for `DEL-7` to find them.
//
// WHAT IS SHARED, and why each is allowed: `lib/snapshot-format.mjs` (the format token and
// the closed outcome partition — 7 existing consumers), `lib/recount.mjs` (the one
// implementation of the `counts` block, including `@2`'s `accountedFor` — 4 existing
// consumers) and `lib/refusal.mjs` (the closed `refusalReason` set and its audit — 8
// existing consumers). All three are chain-agnostic and all three already had two or more
// consumers before this file existed. NOT shared: `lib/replay.mjs` and `lib/body-proxy.mjs`
// (both shell out to the Aztec runtime), and `lib/producer-facts.mjs` (one chain's facts,
// cloned per its own instruction rather than widened).
//
// ── THE PRESTATE STRATEGY, AND WHAT IT COSTS ──────────────────────────────────────────
//
// `replay-preceding`, declared in advance in `tools/chain/yield-method.json` and chosen on
// `eth_getProof` AT DEPTH as the discriminator. The recorder pins a fork at the target
// block's PARENT and re-executes transaction indices 0..k-1 to rebuild the prestate for
// index k, so the endpoint must serve ARCHIVE state at depth and needs no `debug_*` or
// `trace_*` method at all — which matters, because the endpoint this instance was chosen
// on refuses the DEFAULT (struct-log) tracer specifically while answering every archive
// read.
//
// ── THE THREE FIGURES THIS TOOL WILL NOT INVENT ───────────────────────────────────────
//
// A traced row's `effects` is a comparison, so it needs the REPLAY's own answer beside the
// chain's. The replay's answer lives in the recorder's stdout and nowhere else: there is no
// machine-readable report. So `--recorder-log` is REQUIRED for a traced row and the three
// figures are parsed out of it with anchored patterns; a log that does not carry all three
// is a refusal and not a default. Writing `matched: 3, mismatched: 0` without them would
// publish a divergence check that was never run, which is the one shape §5 argues about
// most: a detector reading clean on the condition it detects.
//
// ── THE SEQUENCING FACT THIS TOOL SURFACES RATHER THAN HIDES ──────────────────────────
//
// The container this producer consumes is container version 5 with `meta.dat` schema 6.
// The replay engine BlockTracer ships to visitors is pinned at `db_backend_bg.wasm` sha256
// `842c7164…`, and `tools/chain/health-checks.json` records that engine as accepting
// `meta.dat` schema 3 — measured on the pinned blob's own bytes, not transcribed. So a
// published Ethereum page RENDERS (the pages are static HTML) and its interactive replay
// REFUSES. That is the same disjointness the Aztec corpus has, arriving from the opposite
// side: Aztec's containers are too OLD for current readers and these are too NEW for the
// shipped engine. `client/hydrate/engine-pin.txt` carries the safety rule — do not bump
// that pin on its own — and this tool therefore prints the skew as a measured property of
// its own output rather than treating it as a failure or omitting it. `--no-skew-note`
// silences the print and changes nothing about the tree.
//
// ── NO MOCKS ──────────────────────────────────────────────────────────────────────────
//
// There are none. Every figure in the emitted tree comes from one of four real sources:
// the JSON-RPC endpoint, the container (through `codetracer-trace-format-nim`'s `ct-print`),
// the disassembly listing the recorder wrote, or the recorder's own stdout. Nothing is
// stubbed and nothing is defaulted; a source that cannot answer is a refusal.
//
// ── USAGE ─────────────────────────────────────────────────────────────────────────────
//
//   node tools/chain/produce-eth-snapshot.mjs \
//     --tx 0xf6998cac…71aa \
//     --rpc-url https://eth.drpc.org \
//     --capture <recorder --out-dir> \
//     --recorder-log <the trace-onchain run's stdout> \
//     --recorder-commit <codetracer-evm-recorder HEAD> \
//     --out <snapshot dir> \
//     [--ct-print ../codetracer-trace-format-nim/ct-print] \
//     [--chain ethereum-mainnet] [--label 'Real Ethereum mainnet data'] \
//     [--endpoint-label <url>] [--captured-at <iso8601>] \
//     [--no-skew-note] [--dry-run]
//
// Exit codes: 0 wrote a tree · 1 a source would not answer · 2 a configuration refusal.
//
// ── `--endpoint-label` AND `--captured-at`, AND WHY THEY ARE NOT COSMETIC ─────────────
//
// `--rpc-url` is the endpoint this RUN talked to. The published `provenance.endpoint` is a
// different fact — the contract says it holds "the node this capture was taken against,
// republished verbatim" — and the two stopped being the same thing when the capture became
// reproducible: `tools/chain/eth-rpc-transcript.mjs` serves the committed input set from a
// loopback port, so an offline run talks to `http://127.0.0.1:<kernel-assigned port>`.
// Republishing that as the node the capture came from would be false, and uselessly false:
// the port is different on every run and names no node at all. `--endpoint-label` is the
// node the DATA came from, which for a transcript replay is the upstream the transcript was
// recorded against.
//
// `--captured-at` is the same correction on the clock. `capturedAt` holds "the instant the
// capture stopped"; for a transcript replay that instant is when the TRANSCRIPT was
// recorded, not when the replay ran. Passing the transcript's own `recordedAt` makes the
// member true and makes the tree reproducible in the same move — a wall-clock read at
// produce time is the only thing that otherwise differs between two runs over identical
// inputs.
//
// Both default to the live-run values (`--rpc-url` and `new Date()`), so a run that does
// not pass them behaves exactly as before.

import { execFile } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync,
         writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { promisify } from 'node:util';

import { SNAPSHOT_FORMAT, assertReadableSnapshotFormat } from './lib/snapshot-format.mjs';
import { recountSnapshot } from './lib/recount.mjs';
import { assertRefusalsAreClosed } from './lib/refusal.mjs';
import {
  RECORDER, PRESTATE_STRATEGY, POSITION_LANGUAGE, POSITION_STREAM_SCHEMA,
  INSTRUCTION_STREAM_SCHEMA, CALLTRACE_STREAM_SCHEMA, INSTRUCTION_SET,
  costVectorForRow, executionsForRow,
} from './lib/eth-producer-facts.mjs';

const run = promisify(execFile);

const HERE = 'tools/chain/produce-eth-snapshot.mjs';

/** This producer's one chain. Not a parameter over chains — a default it states. */
const CHAIN_SLUG = 'ethereum-mainnet';

/** The chain id this producer is for. A different one is a configuration refusal. */
const CHAIN_ID = 1;

/**
 * The engine skew this tool reports about its own output. Both halves are READ from the
 * repository rather than restated: the pin from `client/hydrate/engine-pin.txt`, the
 * accepted schema set from `tools/chain/health-checks.json`'s `containerSchema.consumers`.
 */
const ENGINE_PIN_FILE = 'client/hydrate/engine-pin.txt';
const HEALTH_CHECKS_FILE = 'tools/chain/health-checks.json';

// ---------------------------------------------------------------------------
// refusals
// ---------------------------------------------------------------------------

// TWO KINDS OF REFUSAL, AS A TAG ON AN ORDINARY `Error` AND NOT AS TWO CLASSES.
//
// The exit code has to tell them apart — 2 is "this invocation is wrong", 1 is "a source
// would not answer" — and two `extends Error` subclasses is the ordinary way to do that in
// this directory (`backfill-bodies.mjs` and `tools/capture/ingest-review.mjs` each have
// one). They are declined here for a reason specific to this milestone rather than a
// stylistic one: DEL-5's verification entry `test_no_abstraction_was_introduced` asserts
// that the count of interfaces, plugins, registered modules and dispatch sites is the SAME
// after this milestone as before, measured against the code. A type hierarchy introduced by
// the one file the milestone is about would be a delta to argue about in exactly the
// category the test counts — so the distinction travels as a field, which is not a type at
// all, and the count does not move. Measured 2026-10-08: 7 classes in this tree's `.mjs`
// before and 7 after.
const ConfigRefusal = 'config';
const SourceRefusal = 'source';
const refuse = (kind, message) => Object.assign(new Error(message), { refusalKind: kind });

const die = (e) => {
  const code = e.refusalKind === ConfigRefusal ? 2 : 1;
  console.error(`${HERE}: ${e.message}`);
  process.exit(code);
};

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const argv = process.argv.slice(2);
const flag = (name, dflt = undefined) => {
  const i = argv.indexOf(`--${name}`);
  if (i === -1) {
    const eq = argv.find((a) => a.startsWith(`--${name}=`));
    if (eq) return eq.slice(name.length + 3);
    return dflt;
  }
  const v = argv[i + 1];
  if (v === undefined || v.startsWith('--')) {
    throw refuse(ConfigRefusal, `--${name} takes a value`);
  }
  return v;
};
const has = (name) => argv.includes(`--${name}`);

// ---------------------------------------------------------------------------
// JSON-RPC
// ---------------------------------------------------------------------------

/**
 * One JSON-RPC call, with retry on a POLICY refusal and no retry on an ABSENCE.
 *
 * THE RETRY LAYER IS NOT OPTIONAL AND THE REASON IS A MEASUREMENT. `replay-preceding` at
 * index N faults in accounts and storage slots one call at a time, and the endpoint this
 * instance was chosen on answered every archive probe in isolation and then returned
 * `HTTP 429 … Public endpoint rate limit` partway through the first preceding transaction.
 * That is a policy refusal mid-run, not an absent capability, and without a retry it reads
 * as an endpoint that cannot serve archive state when in fact it can.
 *
 * The three refusal classes are kept DISTINCT, because collapsing them is what makes an
 * endpoint survey useless: `-32601` is ABSENT (never retried — a method does not appear),
 * 429/403/401 and `-32602` with a policy sentence are POLICY (retried), and
 * `-32000`/`-32603` "pruned"/"not available" is PRESENT-BUT-PRUNED (never retried, and it
 * is the answer the floor probe is looking for).
 */
async function rpcRaw(url, method, params) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  const text = await res.text();
  let body = null;
  try { body = JSON.parse(text); } catch { /* a non-JSON body is reported as itself */ }
  return { http: res.status, body, text };
}

const POLICY_HTTP = new Set([401, 403, 429, 502, 503, 504]);

/** `absent` | `policy` | `pruned` | `ok` | `transport` — the class of one answer. */
export function classifyAnswer({ http, body, text }) {
  if (body && body.error) {
    const code = body.error.code;
    const msg = String(body.error.message ?? '');
    if (code === -32601) return 'absent';
    if (/prun|not available|historical state/i.test(msg)) return 'pruned';
    if (POLICY_HTTP.has(http)) return 'policy';
    if (/rate limit|personal token|not allowed|required/i.test(msg)) return 'policy';
    return 'policy';
  }
  if (POLICY_HTTP.has(http)) return 'policy';
  if (http !== 200) return 'transport';
  if (!body) return 'transport';
  if (body.result === undefined) return 'transport';
  return 'ok';
}

async function rpc(url, method, params, { retries = 12, backoffMs = 500 } = {}) {
  let last = null;
  for (let attempt = 0; attempt <= retries; attempt++) {
    let answer;
    try {
      answer = await rpcRaw(url, method, params);
    } catch (e) {
      answer = { http: 0, body: null, text: String(e) };
    }
    const cls = classifyAnswer(answer);
    if (cls === 'ok') return answer.body.result;
    last = { cls, answer };
    if (cls === 'absent' || cls === 'pruned') break;
    if (attempt < retries) {
      await new Promise((r) => setTimeout(r, backoffMs * (attempt + 1)));
    }
  }
  const { cls, answer } = last;
  throw refuse(SourceRefusal, 
    `${method} was refused by ${url} as ${cls.toUpperCase()}: `
    + `http ${answer.http} ${answer.text.slice(0, 200)}`);
}

/** The same call, but an answer of any class is RETURNED rather than thrown. */
async function probe(url, method, params) {
  let answer;
  try {
    answer = await rpcRaw(url, method, params);
  } catch (e) {
    answer = { http: 0, body: null, text: String(e) };
  }
  return { cls: classifyAnswer(answer), answer };
}

// ---------------------------------------------------------------------------
// the archive floor — the capture's own boundary
// ---------------------------------------------------------------------------

/**
 * THE LOWEST HEIGHT AT WHICH THIS ENDPOINT PROVES ACCOUNT STATE, by bisection.
 *
 * ── WHY THIS IS MEASURED AND NOT TYPED ────────────────────────────────────────────────
 *
 * `window.replayableFrom` is the member the reader derives BOTH registry profile members
 * from: `reachFromWindow` returns `windowed` when the boundary is `finalized + 1` and
 * `floor` otherwise, and `historyFloor.height` IS the boundary. CPC-5 requires the pair to
 * be derived from the capture's own boundary; `src/blocktracer/contract/chain_profile.nim`
 * says in as many words why a typed one is worse than none — "a `historyFloor` of `0` on a
 * chain nobody measured would make every transaction on it read as above the floor". So
 * this probes.
 *
 * ── WHY `eth_getProof` AND NOT `eth_getBalance` ───────────────────────────────────────
 *
 * A flat read is not a discriminating instrument here. `eth_getBalance` on an address that
 * did not exist yet answers `0x0`, and a node that answered `0x0` for state it does not
 * HOLD would be indistinguishable from one that answered `0x0` because the balance was
 * zero — so a bisection on "did it answer" would report a floor of 0 for a pruned node.
 * `eth_getProof` cannot be faked that way: the node must return a Merkle path against the
 * block's own state root, which it can only do if it holds the trie at that height.
 *
 * TWO CONTROLS MAKE THE ZERO MEAN SOMETHING, and both are returned so the caller can
 * publish them rather than assert them:
 *
 *   * `presentAt` — at the capture's own parent block the proof's `codeHash` must be the
 *     hash of the code actually deployed there, i.e. NOT the empty-code hash. That is the
 *     positive control: the node is answering about this address at this height.
 *   * `absentAt` — at the floor the proof's `codeHash` must be the EMPTY-code hash, because
 *     this address did not exist then. That is the negative control, and it is the half
 *     that distinguishes "the node holds the trie and the account is absent" from "the node
 *     does not hold the trie". Two DISTINCT answers from one instrument is what makes the
 *     instrument discriminating.
 */
const EMPTY_CODE_HASH =
  '0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470';

async function probeArchiveFloor(url, address, { parentBlock, finalized }) {
  const hex = (n) => `0x${n.toString(16)}`;
  const proofAt = async (h) => probe(url, 'eth_getProof', [address, [], hex(h)]);

  const proves = (p) => p.cls === 'ok'
    && Array.isArray(p.answer.body.result?.accountProof)
    && p.answer.body.result.accountProof.length > 0;

  const atParent = await proofAt(parentBlock);
  if (!proves(atParent)) {
    throw refuse(SourceRefusal, 
      `${url} will not prove account state for ${address} at the capture's own parent `
      + `block ${parentBlock} (answered ${atParent.cls}: `
      + `${atParent.answer.text.slice(0, 200)}). The boundary cannot be measured against `
      + `an endpoint that does not answer at the depth the capture itself needed.`);
  }
  const presentCodeHash = atParent.answer.body.result.codeHash;

  // Bisect the lowest height that proves. `lo` is known-not-to-prove or -1 when 0 proves;
  // `hi` is known-to-prove. The parent block is the known-to-prove seed.
  const atZero = await proofAt(0);
  let floor;
  let absentCodeHash = null;
  if (proves(atZero)) {
    floor = 0;
    absentCodeHash = atZero.answer.body.result.codeHash;
  } else {
    let lo = 0;
    let hi = parentBlock;
    while (hi - lo > 1) {
      const mid = Math.floor((lo + hi) / 2);
      // eslint-disable-next-line no-await-in-loop
      const p = await proofAt(mid);
      if (proves(p)) { hi = mid; absentCodeHash = p.answer.body.result.codeHash; }
      else lo = mid;
    }
    floor = hi;
  }

  return {
    height: floor,
    probedWith: 'eth_getProof',
    address,
    presentAtParent: { block: parentBlock, codeHash: presentCodeHash },
    atFloor: { block: floor, codeHash: absentCodeHash },
    emptyCodeHash: EMPTY_CODE_HASH,
    // The controls, as the readings that make the figure a measurement. Stated as
    // booleans AND as the two code hashes, so a later reader can re-derive the verdict.
    positiveControlHeld: presentCodeHash !== EMPTY_CODE_HASH,
    negativeControlHeld: absentCodeHash !== null && absentCodeHash !== presentCodeHash,
    finalizedAtProbe: finalized,
    // `reachFromWindow`'s own discriminator, restated here as a reading rather than left
    // for the reader to be the only thing that knows it.
    wouldBeWindowed: floor === finalized + 1,
  };
}

// ---------------------------------------------------------------------------
// the container
// ---------------------------------------------------------------------------

/** `$CT_PRINT`, `--ct-print`, or a sibling checkout's built binary. */
function ctPrintPath(explicit) {
  const cands = [explicit, process.env.CT_PRINT,
                 resolve('..', 'codetracer-trace-format-nim', 'ct-print')]
    .filter(Boolean);
  for (const c of cands) if (existsSync(c)) return c;
  throw refuse(ConfigRefusal, 
    `no container reader found. Pass --ct-print <path> or set $CT_PRINT. Tried: `
    + `${cands.join(', ')}. The reader is codetracer-trace-format-nim's \`ct-print\` and `
    + `is NOT a dependency of this repository.`);
}

/**
 * The container's own version byte, read from the header rather than from a constant.
 *
 * The CTFS magic is the first four bytes and the container version is the sixth. A file
 * whose magic does not match is refused here rather than at publish time, which is where
 * `S5-CONTAINER-NOT-PREENCODED` would otherwise catch it with less to say.
 */
function containerVersion(file) {
  const b = readFileSync(file).subarray(0, 8);
  const magic = [0xc0, 0xde, 0x72, 0xac];
  for (let i = 0; i < 4; i++) {
    if (b[i] !== magic[i]) {
      throw refuse(SourceRefusal, 
        `${file} does not begin with the CTFS magic (got `
        + `${[...b.subarray(0, 4)].map((x) => x.toString(16)).join(' ')}). A snapshot `
        + `container holds what a RECORDER wrote; an already-encoded object is refused.`);
    }
  }
  return b[5];
}

async function readContainer(ctPrint, file) {
  let meta;
  try {
    const { stdout } = await run(ctPrint, ['--meta-json', file], { maxBuffer: 1 << 28 });
    meta = JSON.parse(stdout);
  } catch (e) {
    throw refuse(SourceRefusal, 
      `${ctPrint} would not open ${file}: ${String(e.stderr ?? e.message).slice(0, 400)}`);
  }
  const { stdout: ev } = await run(ctPrint, ['--events', file], { maxBuffer: 1 << 28 });
  const lines = ev.split('\n').filter((l) => l.trim().length > 0).map((l) => JSON.parse(l));
  const header = lines.find((l) => l.metadata) ?? {};
  const steps = lines.filter((l) => l.kind === 'step');
  const callEntries = lines.filter((l) => l.kind === 'call_entry');
  const ioEvents = lines.filter((l) => l.kind === 'io');
  return {
    counts: meta.counts,
    flags: meta.metadata.flags,
    program: meta.metadata.program,
    paths: header.paths ?? [],
    steps,
    callEntries,
    ioEvents,
    version: containerVersion(file),
  };
}

// ---------------------------------------------------------------------------
// the disassembly listing
// ---------------------------------------------------------------------------

/**
 * The listing, as `(pc, mnemonic)` per 1-based line.
 *
 * The recorder writes one line per instruction as `0x%04x  MNEMONIC [operand]`, and the
 * container's steps carry the LINE. So the program counter a step was at is recoverable
 * exactly, by indexing the listing — which is what makes the instruction sidecar a
 * measurement of the container rather than a second guess at it.
 *
 * A line this parser cannot read is recorded as a hole rather than skipped: a skipped line
 * would renumber every line after it and attribute every later step to the wrong
 * instruction.
 */
export function parseDisassembly(text) {
  const out = [];
  for (const line of text.split('\n')) {
    if (line.trim().length === 0) { out.push(null); continue; }
    const m = /^0x([0-9a-fA-F]+)\s+(\S+)/.exec(line);
    out.push(m ? { pc: parseInt(m[1], 16), op: m[2] } : null);
  }
  // `split('\n')` on a trailing newline yields one empty tail element; drop exactly it.
  if (out.length > 0 && out[out.length - 1] === null && text.endsWith('\n')) out.pop();
  return out;
}

// ---------------------------------------------------------------------------
// the recorder's own answer
// ---------------------------------------------------------------------------

/**
 * THE REPLAY'S THREE FIGURES, parsed out of the recorder's stdout with anchored patterns.
 *
 * Each is required and each refusal names which one was missing, because a row's `effects`
 * is a COMPARISON and a comparison with one side absent is not a weaker comparison — it is
 * a published claim nobody checked. The recorder prints:
 *
 *     entry point 0x…, status ok, gas used 49018
 *     captured 556 step(s), 1 call(s), 1 log(s); frame memory captured
 *
 * DEL-7 NOTE: this is the single ugliest join in this producer and it is the one place a
 * seam would obviously pay — a recorder that emitted a small JSON report would make this
 * function disappear. It is recorded here rather than built, because a report format
 * designed against one recorder is the guess DEL-7 exists to avoid. The Aztec producer
 * reaches the same figures from its driver's structured report, so the two halves of the
 * comparison already exist and DEL-7 can measure them.
 */
export function parseRecorderLog(text) {
  const status = /status\s+(ok|reverted|failed)\b/.exec(text);
  const gas = /gas used\s+(\d+)/.exec(text);
  const shape = /captured\s+(\d+)\s+step\(s\),\s+(\d+)\s+call\(s\),\s+(\d+)\s+log\(s\)/
    .exec(text);
  const entry = /entry point\s+(0x[0-9a-fA-F]{40})/.exec(text);
  const missing = [];
  if (!status) missing.push('status');
  if (!gas) missing.push('gas used');
  if (!shape) missing.push('captured N step(s), N call(s), N log(s)');
  if (!entry) missing.push('entry point');
  if (missing.length > 0) {
    throw refuse(SourceRefusal, 
      `the recorder log carries no ${missing.join(', no ')}. A traced row's \`effects\` is `
      + `a comparison against the replay's own answer, and this tool will not publish one `
      + `side of it as though both had been read.`);
  }
  return {
    status: status[1],
    gasUsed: Number(gas[1]),
    capturedSteps: Number(shape[1]),
    capturedCalls: Number(shape[2]),
    capturedLogs: Number(shape[3]),
    entryPoint: entry[1],
  };
}

// ---------------------------------------------------------------------------
// the engine/schema skew this tool reports about its own output
// ---------------------------------------------------------------------------

/**
 * The skew between the container this producer emits and the engine a visitor runs,
 * READ from the two files that state each half.
 */
function engineSkew(repoRoot, containerVer, ctPrintReadsSchema) {
  const pinText = readFileSync(join(repoRoot, ENGINE_PIN_FILE), 'utf8');
  const rec = pinText.split('\n')
    .filter((l) => l.trim().length > 0 && !l.trimStart().startsWith('#'))
    .map((l) => l.trim().split(/\s+/))
    .find((f) => f[0] === 'pkg/db_backend_bg.wasm');
  const health = JSON.parse(readFileSync(join(repoRoot, HEALTH_CHECKS_FILE), 'utf8'));
  // `consumers` is an ARRAY of entries each carrying its own `id`, not a map keyed by id.
  const shipped = (health.containerSchema?.consumers ?? [])
    .find((x) => x.id === 'shipped-engine');
  return {
    containerVersion: containerVer,
    containerSchema: ctPrintReadsSchema,
    enginePin: rec ? rec[2] : null,
    engineAccepts: shipped?.accepts ?? null,
    pinFile: ENGINE_PIN_FILE,
    schemaStatedBy: HEALTH_CHECKS_FILE,
  };
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

async function main() {
  const txHash = flag('tx');
  const url = flag('rpc-url', process.env.CODETRACER_EVM_RECORDER_RPC_URL);
  const capture = flag('capture');
  const recorderLogPath = flag('recorder-log');
  const recorderCommit = flag('recorder-commit');
  const outDir = flag('out');
  const chain = flag('chain', CHAIN_SLUG);
  const label = flag('label', 'Real Ethereum mainnet data');
  // The node the DATA came from, and the instant it came from there — see the header.
  // Defaulting to the live-run values keeps a run that passes neither byte-for-byte
  // identical to one taken before these existed.
  const endpointLabel = flag('endpoint-label', url);
  const capturedAtFlag = flag('captured-at');
  if (capturedAtFlag && Number.isNaN(Date.parse(capturedAtFlag))) {
    throw refuse(ConfigRefusal,
      `--captured-at must be a date \`Date.parse\` accepts (got ${capturedAtFlag}). `
      + `\`provenance.capturedAt\` is republished verbatim into every row's \`capturedAt\`, `
      + `and a string no reader can parse is worse than the wall clock it replaced.`);
  }
  const ctPrint = ctPrintPath(flag('ct-print'));
  const dryRun = has('dry-run');
  const skewNote = !has('no-skew-note');
  const repoRoot = resolve(dirname(new URL(import.meta.url).pathname), '..', '..');

  for (const [n, v] of [['tx', txHash], ['rpc-url', url], ['capture', capture],
                        ['recorder-log', recorderLogPath],
                        ['recorder-commit', recorderCommit], ['out', outDir]]) {
    if (!v) throw refuse(ConfigRefusal, `--${n} is required`);
  }
  if (!/^0x[0-9a-f]{64}$/.test(txHash)) {
    throw refuse(ConfigRefusal, 
      `--tx must be a 0x-prefixed 32-byte LOWERCASE hash (got ${txHash}). This chain's `
      + `identifier encoding is hex, whose key form is the lowercased payload, and a `
      + `producer that keys a published object under a mixed-case spelling publishes it `
      + `at an address no client computes — Data-Contract.md §5.6.`);
  }
  if (!existsSync(capture)) throw refuse(ConfigRefusal, `no capture directory at ${capture}`);
  if (!existsSync(recorderLogPath)) {
    throw refuse(ConfigRefusal, `no recorder log at ${recorderLogPath}`);
  }

  // The closed sets this producer writes into, asserted before anything is fetched.
  assertReadableSnapshotFormat(SNAPSHOT_FORMAT, HERE);
  assertRefusalsAreClosed();

  // ── the chain ────────────────────────────────────────────────────────────
  const chainIdHex = await rpc(url, 'eth_chainId', []);
  const chainId = parseInt(chainIdHex, 16);
  if (chainId !== CHAIN_ID) {
    throw refuse(ConfigRefusal, 
      `${url} serves chain id ${chainId} and this producer is Ethereum mainnet `
      + `(${CHAIN_ID}). It is written for ONE chain on purpose: there is no dispatch here `
      + `to widen, and a second EVM instance is a second producer (Chain-Delivery DEL-6).`);
  }

  // The control, taken against the SAME endpoint in the same run, so "it answered" is a
  // reading rather than an assumption. An endpoint that answers a method that does not
  // exist is a blind proxy and every other answer from it is uninterpretable.
  const control = await probe(url, 'thisMethodDoesNotExist', []);
  if (control.cls === 'ok') {
    throw refuse(SourceRefusal, 
      `${url} answered \`thisMethodDoesNotExist\` with a result. It is a blind proxy and `
      + `no answer from it discriminates anything.`);
  }

  const tx = await rpc(url, 'eth_getTransactionByHash', [txHash]);
  if (!tx) throw refuse(SourceRefusal, `${url} does not know transaction ${txHash}`);
  const blockNumber = parseInt(tx.blockNumber, 16);
  const txIndex = parseInt(tx.transactionIndex, 16);

  const block = await rpc(url, 'eth_getBlockByNumber',
                          [`0x${blockNumber.toString(16)}`, false]);
  const blockTxs = block.transactions.map((h) => h.toLowerCase());
  const tipHex = await rpc(url, 'eth_blockNumber', []);
  const tip = parseInt(tipHex, 16);
  const finalizedBlock = await rpc(url, 'eth_getBlockByNumber', ['finalized', false]);
  const finalized = parseInt(finalizedBlock.number, 16);
  const clientVersion = await probe(url, 'web3_clientVersion', []);

  // ── every transaction the enumeration saw ────────────────────────────────
  //
  // §5.2: "Every transaction the enumeration saw appears in `transactions`, traced or
  // not." The enumeration here is the target block, whole — nothing sampled within it —
  // so the denominator is the block's own transaction count and a row this producer did
  // not trace is in it. `tools/chain/yield-method.json`'s `pinned.eth` declares the same
  // thing from the other side: zero structural exclusions, because `not-first-in-block`
  // is not structural on a chain where `replay-preceding` reaches index k, and there is no
  // chain-absent population at all.
  let receipts = null;
  const br = await probe(url, 'eth_getBlockReceipts',
                         [`0x${blockNumber.toString(16)}`]);
  if (br.cls === 'ok' && Array.isArray(br.answer.body.result)) {
    receipts = br.answer.body.result;
  } else {
    receipts = [];
    for (const h of blockTxs) {
      // eslint-disable-next-line no-await-in-loop
      receipts.push(await rpc(url, 'eth_getTransactionReceipt', [h]));
    }
  }
  if (receipts.length !== blockTxs.length) {
    throw refuse(SourceRefusal, 
      `${url} answered ${receipts.length} receipt(s) for a block of ${blockTxs.length} `
      + `transaction(s). A row's \`revertCode\` and cost vector are the receipt's own `
      + `figures and this tool will not publish a row it has no receipt for.`);
  }
  // The full transaction objects, for the gas LIMIT the sender set — which is on the
  // transaction and not on the receipt, and is the cost vector's `limit`.
  const fullBlock = await rpc(url, 'eth_getBlockByNumber',
                              [`0x${blockNumber.toString(16)}`, true]);
  const byHash = new Map(fullBlock.transactions.map((t) => [t.hash.toLowerCase(), t]));

  // ── the container, the listing and the recorder's answer ─────────────────
  const containerFiles = [];
  const walk = (d) => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.ct')) containerFiles.push(p);
    }
  };
  walk(capture);
  if (containerFiles.length !== 1) {
    throw refuse(ConfigRefusal, 
      `${capture} holds ${containerFiles.length} container(s) and this producer publishes `
      + `one traced transaction per run: ${containerFiles.join(', ')}`);
  }
  const containerSrc = containerFiles[0];
  const containerBytes = readFileSync(containerSrc).length;
  const c = await readContainer(ctPrint, containerSrc);
  const replay = parseRecorderLog(readFileSync(recorderLogPath, 'utf8'));

  if (c.paths.length !== 1) {
    throw refuse(SourceRefusal, 
      `the container interns ${c.paths.length} path(s) and this producer's listing join `
      + `assumes one — the disassembly of the entry point. Paths: `
      + `${c.paths.join(', ')}. A capture over several addresses needs the join widened, `
      + `and widening it silently would attribute steps to the wrong listing.`);
  }
  const internedPath = c.paths[0];
  // THE INTERNED PATH IS RESOLVED BY SEARCHING THE CAPTURE, NOT BY ARITHMETIC ON IT.
  //
  // The path the container carries is whatever the recorder's `--out-dir` made it —
  // relative to the recorder's cwd when it was relative, absolute when it was absolute —
  // so no fixed number of leading segments can be stripped to turn it into a path on this
  // host. What is stable is the file's own name, and the capture is a directory this tool
  // was given. So the listing is located by name inside the capture, and a name that
  // matches zero or several files is a refusal: picking one of several would key the
  // source bundle to a file the container was not talking about.
  const wantName = internedPath.split('/').pop();
  const listingCandidates = [];
  const walkFor = (d) => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const p = join(d, e.name);
      if (e.isDirectory()) walkFor(p);
      else if (e.name === wantName) listingCandidates.push(p);
    }
  };
  walkFor(capture);
  if (listingCandidates.length !== 1) {
    throw refuse(SourceRefusal, 
      `the container interns ${internedPath} and ${capture} holds `
      + `${listingCandidates.length} file(s) named ${wantName}`
      + `${listingCandidates.length ? `: ${listingCandidates.join(', ')}` : ''}. The `
      + `source bundle's keys must be the paths the container asks for, byte for byte `
      + `(Data-Contract.md §5.4), so the file behind that key has to be identified and `
      + `not chosen.`);
  }
  const listingPath = listingCandidates[0];
  const listingText = readFileSync(listingPath, 'utf8');
  const listing = parseDisassembly(listingText);

  // ── the boundary ─────────────────────────────────────────────────────────
  const floor = await probeArchiveFloor(url, replay.entryPoint.toLowerCase(),
                                        { parentBlock: blockNumber - 1, finalized });
  const proofAtParent = await rpc(url, 'eth_getProof',
                                  [replay.entryPoint.toLowerCase(), [],
                                   `0x${(blockNumber - 1).toString(16)}`]);

  // ── the rows ─────────────────────────────────────────────────────────────
  const hexOrEmpty = (v) => (v === undefined || v === null ? '' : v);
  const rows = [];
  for (let i = 0; i < blockTxs.length; i++) {
    const h = blockTxs[i];
    const r = receipts[i];
    const t = byHash.get(h);
    if (!r || r.transactionHash.toLowerCase() !== h) {
      throw refuse(SourceRefusal, 
        `receipt ${i} is for ${r?.transactionHash} and the block's index ${i} is ${h}; `
        + `the receipt list is not in block order and this tool will not pair them by `
        + `position when position is what is wrong.`);
    }
    // `revertCode` — 0 when the receipt says the execution succeeded, 1 when it reverted.
    // The receipt's `status` is the chain's own answer and the only one; a transaction
    // with no status member at all is pre-Byzantium and is refused rather than guessed.
    if (r.status === undefined || r.status === null) {
      throw refuse(SourceRefusal, 
        `receipt for ${h} carries no \`status\`. That is a pre-Byzantium receipt, whose `
        + `success is not recoverable from the receipt alone, and a guessed `
        + `\`revertCode\` is a published number nobody measured.`);
    }
    const revertCode = parseInt(r.status, 16) === 1 ? 0 : 1;
    // The sentence an untraced row carries, computed BEFORE the row literal so the row
    // states its own execution partition by call rather than by spread — `producer-scan`'s
    // R2 requires the call to be visible in the literal that carries `firstInBlock`, and
    // it is right to: a spread is where the Aztec range producer lost both members.
    const untracedReason = h === txHash ? null
      : `This producer traced the one transaction it was given (${txHash}, index `
        + `${txIndex}) and enumerated the rest of its block so the denominator is the `
        + `block and not the capture. Nothing about this transaction or about Ethereum `
        + `stopped it: this chain's declared prestate strategy reaches index ${i} by `
        + `re-executing indices 0..${i - 1} from the parent block, which this run did not `
        + `spend. A run with a wider budget traces it.`;
    const base = {
      txHash: h,
      blockNumber,
      txIndexInBlock: i,
      revertCode,
      cost: costVectorForRow({
        gasUsed: hexOrEmpty(r.gasUsed),
        gasLimit: hexOrEmpty(t?.gas),
        effectiveGasPrice: hexOrEmpty(r.effectiveGasPrice),
        blobGasUsed: r.blobGasUsed ?? null,
        blobGasPrice: r.blobGasPrice ?? null,
      }),
      executions: executionsForRow(untracedReason),
      firstInBlock: i === 0,
      bodyRetained: true,
      effectVisible: true,
    };

    if (untracedReason !== null) {
      rows.push({
        ...base,
        outcome: 'not-attempted',
        reason: untracedReason,
        refusalReason: 'not-attempted',
      });
      continue;
    }

    // ── the one traced row ────────────────────────────────────────────────
    //
    // `effects` IS A COMPARISON AND EVERY FACT IN IT IS READ FROM BOTH SIDES. Three facts
    // the chain published and the replay also produced: the execution's success, the gas
    // it burned, and how many logs it emitted. `matched`/`mismatched` are the tallies
    // over exactly those three and `mismatches` names any that disagreed, so a reader can
    // see WHICH fact failed rather than that something did.
    const publishedLogs = (r.logs ?? []).length;
    const publishedGas = parseInt(r.gasUsed, 16);
    const facts = [
      { field: 'status',
        published: revertCode === 0 ? 'ok' : 'reverted',
        replayed: replay.status },
      { field: 'gasUsed', published: publishedGas, replayed: replay.gasUsed },
      { field: 'logs', published: publishedLogs, replayed: replay.capturedLogs },
    ];
    const mismatches = facts.filter((f) => f.published !== f.replayed)
      .map((f) => ({ ...f, matches: false }));
    const matched = facts.length - mismatches.length;
    const reproduced = mismatches.length === 0;

    // The step count is the CONTAINER's, read back through the reader the db-backend
    // consumes, and not the replay's. They differ by exactly one — the opening step
    // `TraceWriter::start` emits — and publishing the replay's figure would make every
    // sidecar's length check disagree with the recording by one.
    const steps = c.counts.steps;
    const positioned = c.steps.filter((s) => s.path_id !== null && s.line > 0).length;

    rows.push({
      ...base,
      outcome: reproduced ? 'replayed' : 'divergent',
      kind: reproduced ? 'replayed' : 'divergent',
      replayed: true,
      container: `ct/${h}.ct`,
      containerBytes,
      recordedBy: recorderCommit,
      preStateReadAt: blockNumber - 1,
      instructionsExecuted: replay.capturedSteps,
      effects: { reproduced, matched, mismatched: mismatches.length, mismatches },
      recording: {
        bytes: containerBytes,
        steps,
        callsOpened: c.counts.calls,
        logEvents: c.counts.io_events,
        // `false`, AND IT IS A MEASUREMENT. The positions in this container point at a
        // DISASSEMBLY listing of the deployed bytecode, not at Solidity: the address is
        // verified on Sourcify with solc 0.4.18, the dev shell ships 0.8.33, and solc
        // refuses the source outright, so no `srcmap-runtime` exists to map a pc to a
        // span. The recording is at EVM-opcode granularity and is NOT source level, and
        // that is the sentence a landing page owes a visitor.
        sourceLevel: false,
        stepsPositioned: positioned,
        stepsUnpositioned: steps - positioned,
        distinctOpcodes: new Set(c.steps
          .map((s) => listing[s.line - 1]?.op).filter(Boolean)).size,
        contexts: 1,
      },
      sourceBundles: `sources/${h}.json`,
      instructions: `instructions/${h}.json`,
      positions: `positions/${h}.json`,
      callTrace: `calltrace/${h}.json`,
      artifacts: [{
        address: replay.entryPoint.toLowerCase(),
        contractClassId: proofAtParent.codeHash,
        resolved: false,
        origin: null,
        corroboration: null,
        reason:
          'Sourcify serves verified sources for this address and the compiler they were '
          + 'verified with (0.4.18+commit.9cf6e910) is not on this host, so no '
          + '`srcmap-runtime` could be produced and no artifact was proved. The steps are '
          + 'positioned against a disassembly of the bytecode deployed at the target '
          + 'block instead, which needs nothing recovered from anywhere.',
      }],
    });
  }

  // ── the snapshot ─────────────────────────────────────────────────────────
  const capturedAt = capturedAtFlag ?? new Date().toISOString();
  const snapshot = {
    format: SNAPSHOT_FORMAT,
    provenance: {
      kind: 'live-capture',
      chain,
      label,
      endpoint: endpointLabel,
      recorder: { ...RECORDER },
      prestateStrategy: PRESTATE_STRATEGY,
      capturedAt,
      nodeVersion: control.cls === 'absent' && clientVersion.cls === 'ok'
        ? clientVersion.answer.body.result
        : '',
      l1ChainId: chainId,
      tool: HERE,
      runtimeCommit: recorderCommit,
      // THE CONTROL, PUBLISHED RATHER THAN ASSERTED. §5's own argument about `counts` is
      // that a figure nobody can re-derive is a figure nobody checked, and the same holds
      // of an endpoint survey: a snapshot that says "the endpoint answered" without
      // saying what it answered to a method that does not exist is a snapshot whose other
      // readings are uninterpretable.
      endpointControl: {
        method: 'thisMethodDoesNotExist',
        classified: control.cls,
        http: control.answer.http,
        code: control.answer.body?.error?.code ?? null,
      },
      // The boundary probe, whole, so `window.replayableFrom` can be re-derived from the
      // readings rather than trusted. CPC-5's requirement is that the registry's `reach`
      // and `historyFloor` be DERIVED from the capture's own boundary; this is the
      // boundary, with both of its controls.
      archiveFloorProbe: floor,
      containerVersion: c.version,
      containerFlags: c.flags,
    },
    window: {
      tip,
      finalized,
      // DERIVED, NOT TYPED — see `probeArchiveFloor`. The reader turns this into
      // `reach` (`windowed` when it is `finalized + 1`, `floor` otherwise) and into
      // `historyFloor.height`, so it is the one member on which both registry profile
      // members rest.
      replayableFrom: floor.height,
      replayableTo: tip,
      blocks: tip - floor.height + 1,
    },
    counts: {},
    blocks: [{
      number: blockNumber,
      hash: block.hash,
      timestamp: parseInt(block.timestamp, 16),
      // `parentArchiveRoot` IS REQUIRED OF EVERY PRODUCER AND IS NAMED AFTER ANOTHER
      // CHAIN'S OBJECT. Data-Contract.md §5.2b marks it required on `blocks[]` and
      // `ingest.nim` reaches it by an unguarded subscript, so a tree without it is
      // refused — but an "archive root" is Aztec's rollup commitment and Ethereum has no
      // such thing. The honest Ethereum value for "the commitment this block's parent
      // left behind" is the parent's own block hash, and that is what is stated here.
      //
      // DEL-7 NOTE: this is a chain-specific member name in a chain-independent census,
      // and it is the clearest piece of evidence this producer produced for the seam
      // DEL-7 will measure. It is recorded here rather than renamed: the member is a
      // published wire name read by both halves of the seam, and renaming a required
      // member is a format-token bump under §3.1's rule 3.
      parentArchiveRoot: block.parentHash,
      stateRoot: block.stateRoot,
      baseFeePerGas: block.baseFeePerGas ?? '',
      gasUsed: block.gasUsed,
      miner: block.miner,
      transactions: blockTxs,
    }],
    transactions: rows,
    captures: [{
      capturedAt,
      by: HERE,
      window: { tip, finalized, replayableFrom: floor.height, replayableTo: tip,
                blocks: tip - floor.height + 1 },
      nodeVersion: clientVersion.cls === 'ok' ? clientVersion.answer.body.result : '',
      runtimeCommit: recorderCommit,
      yielded: [{ txHash, outcome: rows.find((r) => r.txHash === txHash).outcome }],
    }],
    artifactResolution: 'artifact-resolution.json',
  };

  // `counts` IS DERIVED ON EVERY WRITE AND NEVER MERGED INTO — §5.2. `recountSnapshot` is
  // the one implementation of the block, including `@2`'s `accountedFor`, and it already
  // had four consumers before this file existed.
  snapshot.counts = recountSnapshot(snapshot);

  if (dryRun) {
    console.log(JSON.stringify({
      chain, blockNumber, txIndex, blockTransactions: blockTxs.length,
      counts: snapshot.counts, window: snapshot.window,
      archiveFloorProbe: floor,
    }, null, 1));
    return;
  }

  // ── the tree ─────────────────────────────────────────────────────────────
  const out = resolve(outDir);
  for (const d of ['', 'ct', 'sources', 'instructions', 'positions', 'calltrace']) {
    mkdirSync(join(out, d), { recursive: true });
  }
  const writeJson = (rel, obj) => {
    const p = join(out, rel);
    const tmp = `${p}.tmp`;
    writeFileSync(tmp, `${JSON.stringify(obj, null, 1)}\n`);
    renameSync(tmp, p);
  };

  copyFileSync(containerSrc, join(out, 'ct', `${txHash}.ct`));

  // SOURCE BUNDLE — keyed by the contract class and keyed INSIDE by the path the container
  // asks for, byte for byte. §5.4: "the bundle's value is that its keys match what the
  // container asks for", so the key here is the interned path verbatim and not a tidied
  // one. `language` is this bundle's own, which is what makes a bundle and its language
  // unable to disagree.
  writeJson(`sources/${txHash}.json`, {
    txHash,
    sourceLevel: false,
    bundles: [{
      address: replay.entryPoint.toLowerCase(),
      codeHash: proofAtParent.codeHash,
      files: { [internedPath]: listingText },
      origin: `disassembly of the bytecode eth_getCode returned at block ${blockNumber}`,
      shape: 'disassembly',
      corroboration: 'single-distributor',
      agreeingDistributors: ['the chain itself'],
      language: POSITION_LANGUAGE,
    }],
  });

  // INSTRUCTION LISTING — the container's own program counters, joined to the listing the
  // recorder wrote. `steps` must equal the recording's or the publish is refused
  // (`S5-INSTRUCTIONS-AGREE`); `isa` is carried up to the chain's registry row.
  //
  // THE OPCODE TRAVELS AS THE MNEMONIC THE LISTING CARRIES AND NOT AS A NUMBER, which is
  // the opposite of the Aztec listing's choice and is deliberate: the recorder has already
  // decoded the byte into a name against the instruction set it replayed under, and
  // re-deriving a number from the name here would be this file inventing a second decoding
  // it cannot check. The `isa` says which table the names belong to.
  const traced = rows.find((r) => r.txHash === txHash);
  writeJson(`instructions/${txHash}.json`, {
    schema: INSTRUCTION_STREAM_SCHEMA,
    tx: txHash,
    isa: INSTRUCTION_SET,
    path: internedPath,
    steps: traced.recording.steps,
    counters: c.steps.filter((s) => listing[s.line - 1]).length,
    pc: c.steps.map((s) => listing[s.line - 1]?.pc ?? null),
    op: c.steps.map((s) => listing[s.line - 1]?.op ?? null),
    ctx: c.steps.map((s) => s.depth ?? 0),
  });

  // POSITION STREAM — the same object one column set over. Every column is as long as the
  // recording's step count or the publish is refused (`S5-POSITIONS-COLUMNS`), and the
  // stream states its own schema token, which the reader republishes verbatim.
  writeJson(`positions/${txHash}.json`, {
    schema: POSITION_STREAM_SCHEMA,
    tx: txHash,
    steps: traced.recording.steps,
    positioned: traced.recording.stepsPositioned,
    measuredPostHoc: false,
    measuredBy: `${HERE} (read from the container)`,
    paths: [internedPath],
    pathId: c.steps.map(() => 0),
    line: c.steps.map((s) => s.line),
    column: c.steps.map((s) => s.column),
  });

  // CALL TRACE — the frames, with the synthetic top-level frame `S5-CALLTRACE-AGREE`
  // counts. `frames` must be the recording's `callsOpened` plus one.
  const toplevel = c.callEntries[0] ?? {};
  writeJson(`calltrace/${txHash}.json`, {
    schema: CALLTRACE_STREAM_SCHEMA,
    tx: txHash,
    callsOpened: traced.recording.callsOpened,
    frames: traced.recording.callsOpened + 1,
    steps: traced.recording.steps,
    // NO FOLD RULES, and the empty list is a statement rather than an omission. A fold
    // rule hides a subtree behind a closed triangle because a visitor did not write it —
    // Noir's stdlib, a vendored crate. This recording's steps are all one contract's own
    // opcodes, so there is no library frame to fold and folding anything would hide the
    // only thing the recording has. `S5-CALLTRACE-FOLD-NONEMPTY` refuses a folded frame
    // with nothing behind it, which is the same argument from the other side.
    foldRules: [],
    foldedFrames: 0,
    foldedSteps: 0,
    measuredPostHoc: false,
    measuredBy: `${HERE} (read from the container)`,
    frame: [
      { name: '<transaction>', depth: 0, step: 0, path: null, line: null, args: [],
        contractAddress: null, endStep: null, foldedBy: null, foldWhy: null,
        hiddenDescendants: 0, hiddenSteps: 0 },
      { name: toplevel.function ?? '<toplevel>', depth: 1, step: toplevel.entry_step ?? 0,
        path: internedPath, line: 1, args: [],
        contractAddress: replay.entryPoint.toLowerCase(),
        endStep: traced.recording.steps, foldedBy: null, foldWhy: null,
        hiddenDescendants: 0, hiddenSteps: 0 },
    ],
  });

  // ARTIFACT RESOLUTION — the one sidecar about the SNAPSHOT rather than about a row. It
  // carries a version token of its own, on its own clock, and naming a different chain is
  // refused rather than skipped.
  writeJson('artifact-resolution.json', {
    format: 'blocktracer/artifact-resolution@1',
    chain,
    measuredAt: capturedAt,
    measuredBy: { tool: HERE, resolver: 'Sourcify v2 + solc, through the recorder',
                  runtimeCommit: recorderCommit },
    endpoint: endpointLabel,
    counts: {
      transactionsConsidered: 1,
      transactionsWithSourceBundle: 1,
      stepsPositioned: traced.recording.stepsPositioned,
      stepsTotal: traced.recording.steps,
      contracts: 1,
      resolved: 0,
    },
    transactions: [{
      txHash,
      blockNumber,
      artifacts: traced.artifacts,
      positions: null,
    }],
  });

  writeJson('snapshot.json', snapshot);

  // ── what was written, and the one skew it carries ────────────────────────
  console.log(`${HERE}: wrote ${out}`);
  console.log(`  chain ${chain} · block ${blockNumber} · ${blockTxs.length} transaction(s) `
              + `enumerated · 1 traced at index ${txIndex}`);
  console.log(`  counts.blocks=${snapshot.counts.blocks} `
              + `counts.transactions=${snapshot.counts.transactions} `
              + `counts.accountedFor=${snapshot.counts.accountedFor}`);
  console.log(`  window.replayableFrom=${floor.height} finalized=${finalized} `
              + `=> the reader derives reach=`
              + `${floor.wouldBeWindowed ? 'windowed' : 'floor'} and `
              + `historyFloor.height=${floor.height}`);
  console.log(`  boundary controls: positive(code present at parent)=`
              + `${floor.positiveControlHeld} negative(distinct answer at the floor)=`
              + `${floor.negativeControlHeld}`);
  console.log(`  recording: steps=${traced.recording.steps} `
              + `callsOpened=${traced.recording.callsOpened} `
              + `positioned=${traced.recording.stepsPositioned} `
              + `effects matched=${traced.effects.matched}/`
              + `${traced.effects.matched + traced.effects.mismatched}`);

  if (skewNote) {
    const skew = engineSkew(repoRoot, c.version, 6);
    console.log('');
    console.log('  MEASURED PROPERTY OF THIS TREE, not a failure of it:');
    console.log(`    this container is version ${skew.containerVersion} / `
                + `meta.dat schema ${skew.containerSchema} (the reader that opened it `
                + `reads schema 6 only, and refuses 3 by name)`);
    console.log(`    the engine a visitor runs is pinned at `
                + `${String(skew.enginePin).slice(0, 16)}… and ${HEALTH_CHECKS_FILE} `
                + `records it as accepting meta.dat `
                + `${JSON.stringify(skew.engineAccepts)}`);
    console.log('    so a published page RENDERS (the pages are static HTML) and its '
                + 'INTERACTIVE REPLAY REFUSES.');
    console.log(`    ${ENGINE_PIN_FILE} carries the rule: do not bump that pin on its `
                + `own. This is the Aztec corpus's disjointness arriving from the `
                + `opposite side — those containers are too OLD for current readers and `
                + `this one is too NEW for the shipped engine.`);
  }
}

main().catch(die);
