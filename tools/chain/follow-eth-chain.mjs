#!/usr/bin/env node
//
// follow-eth-chain.mjs — ETHEREUM MAINNET: THE RESIDENT TIP FOLLOWER. A loop that observes
// the chain, captures what has arrived, publishes it to an OBJECT STORE, and reports a
// measurement on every tick including the quiet ones.
//
// ── WHAT THIS IS THE OTHER HALF OF ────────────────────────────────────────────────────
//
// The upload half of this pipeline is finished and measured. `capture-eth-range.mjs` turns
// a block range into a `blocktracer/chain-snapshot@2` tree; `eth-ingest-range.mjs` files
// that range in a `blocktracer/coverage-ledger@1`, ingests the UNION of everything filed,
// derives a generation id from what the generation contains, and hands the tree to
// `blocktracer-publish`, which reconciles it against an `ObjectStore` with the visibility
// pointer written last. `eth-publish-proof.sh` (43 checks) and `eth-coverage-proof.sh`
// (46 without `--overlap`) are those measurements.
//
// Every one of those is a statement about a RUN SOMEBODY STARTED. What produces continuous
// coverage is not a run; it is a deployed daemon, and this is that daemon. It is the same
// three tools, driven by a loop whose own properties are the subject of
// `eth-follower-proof.sh`.
//
// ── IT IS NOT A SCHEDULED JOB, AND THE REASON IS A MEASUREMENT ───────────────────────
//
// `follow-chain.mjs` is Aztec's follower and its header carries the measurement that
// settled this: mainnet arrivals are BURSTY, eighteen transactions inside a fifty-three
// block span and then nothing for three hundred and nine blocks, so a scan wins only if it
// happens to run during a burst. A thirty-second poller caught nothing over a whole session
// and the fix was DURATION, not cadence.
//
// Ethereum's version of that shape is not a guess either, and it is structural rather than
// statistical: THE FINALIZED HEAD ADVANCES IN EPOCHS. Measured against
// `https://eth.drpc.org` while this was written — tip 26,189,111, finalized 26,189,038, a
// gap of 73 — the finalized head does not creep upward one block at a time. It stands still
// for roughly six and a half minutes and then jumps by a whole epoch, thirty-two blocks. A
// follower whose tick capacity is less than thirty-two therefore meets a burst it cannot
// drain EVERY EPOCH, on the ordinary chain, with nothing synthetic about it. That is why
// the queue below is the central mechanism and not a safeguard.
//
// This tool follows at or below FINALIZED, like `capture-eth-range.mjs --depth`, and for
// the same reason: an archive endpoint serves prestate at any depth, so Ethereum's
// constraint is not body pruning (that is Aztec's) but REORG — a block above the finalized
// head can still be displaced, and a recording of a displaced block is a recording of
// something that did not happen. ING-2 is where finality becomes published data; this loop
// simply never reaches above the line.
//
// ── THE QUEUE IS DERIVED, WHICH IS WHY A BURST CANNOT BE DROPPED ─────────────────────
//
// The obvious design holds a buffer of arrived-but-not-yet-captured heights and drains it.
// A buffer has a capacity, a capacity has an overflow, and an overflow is a drop — and the
// drop is invisible, because the thing that would have noticed is the buffer.
//
// So there is no buffer. The work outstanding is COMPUTED, every tick, as
//
//     owed = [floor .. finalized] \ (heights the live published generation maps)
//
// Both operands come from outside this process: the right-hand side is read back out of the
// object store by `blocktracer-follower-state resume`, and the left from the node. A height
// can therefore only leave `owed` by being PUBLISHED AND MAPPED, and "dropped" is not a
// state this program can reach — it would require the published height map to list a height
// the store does not hold, which is the one thing `blocktracer-verify-published`'s LEDGER
// and RANGE checks exist to catch. The tick capacity bounds how much is captured per tick
// and nothing else; the remainder is still owed at the next tick because it is still absent
// from the map.
//
// This is also, exactly, Pipeline-Architecture §3.2a's `pendingRanges`: "a scan for missing
// heights". The scan is in `blocktracer_follower_state.nim` so that it runs against the
// published output rather than against a local file.
//
// ── A RESTART IS NOT A SPECIAL CASE ──────────────────────────────────────────────────
//
// Because `owed` is derived, a restarted follower recomputes it and resumes with no gap and
// no double-count, and there is no code path for "resume" that is different from the path
// for "tick 1". §3.2a: the sync state "is a cache, not a system of record … losing it costs
// a restart, not data."
//
// WITH ONE MEASURED EXCEPTION, WHICH THIS TOOL REFUSES RATHER THAN SURVIVES. The ledger's
// per-range SNAPSHOT TREES are not reconstructible from published output — the store holds
// the ingested tree, not the capture that produced it — and `eth-ingest-range.mjs` ingests
// the union of the snapshots the LEDGER holds. So a follower whose state directory has been
// lost, pointed at a store that still maps earlier ranges, would file one new range into an
// empty ledger and publish a union of just that range at a fresh derived generation: the
// maps would be written, the pointer would agree with them, `POINTER` would pass, and every
// earlier range would be dropped from the index. That is ING-1's SHAPE 2, arrived at from
// the resume side instead of the publish side, and it is undetectable from the publisher's
// own output. `assertLedgerCoversWhatTheStoreMaps` below refuses the cycle by name instead.
// See `--allow-ledger-behind-store` for what it costs to override, and why you should not.
//
// ── ZERO ARRIVALS IS A WRITE ─────────────────────────────────────────────────────────
//
// A loop that reports arrivals is indistinguishable, during a drought, from a loop that has
// died. Ethereum's droughts are short but its epoch boundaries make most ticks empty by
// construction: at a sixty-second interval, five of every six ticks see the finalized head
// exactly where they left it. So every tick writes an observation — to the local JSONL
// stream AND into the store, at the head of the bounded ring
// `blocktracer-follower-state observe` maintains — and that observation states the height
// window it looked at and an explicit `arrivals: 0`. A stopped loop is then a ring whose
// newest entry does not advance, which is a different reading from a ring whose newest
// entry says it looked and found nothing.
//
// ── LAG BEHIND TIP IS THE PRIMARY SLI, AND IT IS PUBLISHED ───────────────────────────
//
// Chain-Data-Ingestion §6: "Lag behind tip is the primary SLI for this stage and the number
// a chain page surfaces as staleness." A number a page surfaces is a number in the store,
// so it goes there rather than into a log on the host — `obs/{chain}/follower.json`, lifted
// to the top of the document so a reader does not have to know the ring's shape.
//
// Three lags are reported and they answer different questions:
//
//   lagBlocks       tip - publishedHead       the SLI §6 names. What a visitor experiences.
//   lagToFinalized  finalized - publishedHead how far behind the loop is on work it is
//                                             ALLOWED to do. `lagBlocks` can never reach 0
//                                             on this chain: the tip-to-finalized gap is
//                                             structurally ~2 epochs (73 blocks, measured),
//                                             so a follower at zero outstanding work still
//                                             reads a lag of ~73. Reporting only the SLI
//                                             would make a healthy follower look stuck.
//   lagSeconds      now - headBlockTimestamp  the staleness a human means.
//
// ── NO ARTIFACT REACHES THE REPOSITORY ───────────────────────────────────────────────
//
// Aztec's follower GROWS A COMMITTED SNAPSHOT: `.ct` containers land in the working tree and
// a human commits them. ING-1 exists to end that. Everything this loop produces goes to the
// object store or to the state directory, and the state directory defaults to a
// `.`-prefixed path the repository already ignores. The proof asserts `git status
// --porcelain` byte-for-byte across a full iteration.
//
// ── NO ABSTRACTION IS SHARED WITH THE AZTEC FOLLOWER ─────────────────────────────────
//
// `follow-chain.mjs` follows Aztec and this follows Ethereum. This file imports nothing from
// it and it imports nothing from this file: no interface, no plugin, no registered module,
// no dispatch site. ING-7's two-consumer rule is SPENT BY THIS FILE'S EXISTENCE rather than
// by this file — a second CONCRETE follower is what licenses an extraction to be measured
// against two real consumers, and a seam guessed from one consumer is what that rule exists
// to prevent. Where this file wanted to share something, the wanting is a comment: search
// for `DEL-7`.
//
// It states no transaction row and builds no capture provenance, so it is not a producer in
// `lib/producer-scan.mjs`'s sense and must not become one. The capture is delegated whole to
// `capture-eth-range.mjs`, which is where this chain's facts are stated, once. §14 of
// `snapshot-contract-selftest.mjs` compares the producer roster by name, so a row literal
// added here would arrive as a named failure — correctly.
//
// ── USAGE ─────────────────────────────────────────────────────────────────────────────
//
//   node tools/chain/follow-eth-chain.mjs \
//     --recorder <path to codetracer-evm-recorder> --recorder-commit <sha> \
//     --dest <store dir> [--backend local|s3 --bucket B --endpoint U --prefix P] \
//     [--url https://eth.drpc.org] [--chain ethereum-mainnet] \
//     [--state .eth-follower] [--ledger-state .eth-chain-state] \
//     [--interval 60] [--tick-capacity 3] [--max 6] \
//     [--floor N] [--ceiling N] [--ticks N] [--deadline-min N] \
//     [--heads FILE] [--record-heads FILE] [--no-capture] [--ring 64] [--json]
//
//   --interval SEC     seconds between ticks (default 60; see `follow-chain.mjs` on why
//                      raising it is safe and lowering it does not help)
//   --tick-capacity N  how many heights ONE tick may capture (default 3). The remainder
//                      stays owed; it is not buffered and cannot be dropped.
//   --floor N          the lowest height this follower is responsible for. A POLICY, not a
//                      fact: how far back to reach is an operator's decision and ING-4's
//                      backfill is what reaches the rest. Unstated, a cold store starts at
//                      the first finalized head observed (and says so), and a warm store
//                      starts at the lowest height its live generation maps.
//   --ceiling N        never reach above height N. For a bounded proof, and for an operator
//                      splitting a span between followers.
//   --ticks N          stop after N ticks (0 = resident, the default)
//   --heads FILE       read head observations from a `blocktracer/eth-head-transcript@1`
//                      instead of the node. The seam that makes the loop's own properties
//                      measurable without waiting six minutes per epoch.
//   --record-heads F   while following the live node, WRITE that transcript.
//   --no-capture       observe, report and publish the SLI; never run the recorder. What
//                      an idle window looks like, with nothing to capture by construction.
//
// Exit codes: 0 the loop ran to its stopping condition · 1 a step refused · 2 this
// invocation is wrong.
//
// ── NO MOCKS ──────────────────────────────────────────────────────────────────────────
//
// There are none. The chain is read over JSON-RPC, the capture is `capture-eth-range.mjs`
// driving the real recorder, the ingest and publisher are the shipping binaries, and the
// store is a real `ObjectStore`. `--heads` is not a mock of the chain: it is a RECORDING of
// it, written by `--record-heads` from the same code path, and a transcript that was
// constructed rather than recorded must say so in its own `synthetic` member — this tool
// prints which kind it was handed, every run, so a measurement cannot quietly be over a
// made-up chain.

import { existsSync, mkdirSync, readFileSync, writeFileSync, appendFileSync,
         rmSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const HERE = 'tools/chain/follow-eth-chain.mjs';

/** This tool's one chain's default slug. Not a parameter over chains. */
const DEFAULT_CHAIN = 'ethereum-mainnet';

/** The head-transcript format: what `--heads` reads and `--record-heads` writes. */
const HEAD_TRANSCRIPT_FORMAT = 'blocktracer/eth-head-transcript@1';

/** The observation stream's format, one object per line. */
const OBSERVATION_FORMAT = 'blocktracer/follower-observation@1';

// ---------------------------------------------------------------------------
// refusals — a FIELD and not a class, following `eth-ingest-range.mjs`: the exit code
// needs two kinds of refusal, not two kinds of object.
// ---------------------------------------------------------------------------

const ConfigRefusal = 'config';
const SourceRefusal = 'source';
const refuse = (kind, message) => Object.assign(new Error(message), { refusalKind: kind });

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const argv = process.argv.slice(2);
const arg = (name, dflt) => {
  const i = argv.indexOf(`--${name}`);
  if (i === -1) {
    const eq = argv.find((a) => a.startsWith(`--${name}=`));
    return eq ? eq.slice(name.length + 3) : dflt;
  }
  const v = argv[i + 1];
  if (v === undefined || v.startsWith('--')) {
    throw refuse(ConfigRefusal, `--${name} takes a value`);
  }
  return v;
};
const flag = (name) => argv.includes(`--${name}`);
const intArg = (name, dflt) => {
  const raw = arg(name);
  if (raw === undefined) return dflt;
  const n = Number(raw);
  if (!Number.isInteger(n)) {
    throw refuse(ConfigRefusal, `--${name} must be an integer (got ${raw})`);
  }
  return n;
};

// ---------------------------------------------------------------------------
// the node
// ---------------------------------------------------------------------------

/**
 * One JSON-RPC call. No retry and no backoff HERE: §6's rate-limiting row is about the
 * fetch path, and a tick that could not read the head is an observation with a stated
 * failure rather than a tick that silently took longer. The loop's own interval is the
 * backoff.
 */
async function rpc(url, method, params) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  if (!res.ok) throw refuse(SourceRefusal, `${method}: HTTP ${res.status} from ${url}`);
  const j = await res.json();
  if (j.error) {
    throw refuse(SourceRefusal, `${method}: ${j.error.message ?? JSON.stringify(j.error)}`);
  }
  return j.result;
}

const headOf = (b) => ({
  height: parseInt(b.number, 16),
  hash: b.hash,
  timestamp: parseInt(b.timestamp, 16),
});

/** Both ends of the window the chain currently offers, as one observation. */
async function observeChain(url) {
  const [latest, finalized] = await Promise.all([
    rpc(url, 'eth_getBlockByNumber', ['latest', false]),
    rpc(url, 'eth_getBlockByNumber', ['finalized', false]),
  ]);
  return { tip: headOf(latest), finalized: headOf(finalized) };
}

// ---------------------------------------------------------------------------
// the store side — `blocktracer-follower-state`, which is where every published read and
// the SLI write live. This process never opens the store itself, so it is credential-free
// by construction and the S3 path is the one `publisher.nim` already has.
// ---------------------------------------------------------------------------

function storeArgs(cfg) {
  const a = ['--chain', cfg.chain, '--backend', cfg.backend];
  if (cfg.backend === 'local') a.push('--dest', cfg.dest);
  else {
    a.push('--bucket', cfg.bucket);
    if (cfg.endpoint) a.push('--endpoint', cfg.endpoint);
    if (cfg.prefix) a.push('--prefix', cfg.prefix);
  }
  return a;
}

function resumeFromPublishedOutput(cfg) {
  const a = ['resume', ...storeArgs(cfg)];
  if (cfg.floor > 0) a.push('--floor', String(cfg.floor));
  if (cfg.ceiling > 0) a.push('--ceiling', String(cfg.ceiling));
  const r = spawnSync(cfg.stateBin, a, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.error) {
    throw refuse(ConfigRefusal, `could not run '${cfg.stateBin}': ${r.error.message}`);
  }
  if (r.status !== 0) {
    throw refuse(SourceRefusal,
      `${cfg.stateBin} resume refused (rc=${r.status}):\n${(r.stdout ?? '') + (r.stderr ?? '')}`);
  }
  try { return JSON.parse(r.stdout); } catch (e) {
    throw refuse(SourceRefusal, `${cfg.stateBin} resume printed unparseable JSON: ${e.message}`);
  }
}

function publishObservation(cfg, observation) {
  const tmp = join(cfg.stateDir, 'observation.json');
  writeFileSync(tmp, JSON.stringify(observation, null, 1) + '\n');
  const r = spawnSync(cfg.stateBin,
    ['observe', ...storeArgs(cfg), '--observation', tmp, '--ring', String(cfg.ring)],
    { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  if (r.error) {
    throw refuse(ConfigRefusal, `could not run '${cfg.stateBin}': ${r.error.message}`);
  }
  if (r.status !== 0) {
    throw refuse(SourceRefusal,
      `${cfg.stateBin} observe refused (rc=${r.status}):\n${(r.stdout ?? '') + (r.stderr ?? '')}`);
  }
  return (r.stdout ?? '').trim();
}

// ---------------------------------------------------------------------------
// THE LEDGER GUARD — the one thing a restart cannot rebuild
// ---------------------------------------------------------------------------

/** Every height `eth-ingest-range.mjs`'s ledger holds a filed snapshot for. */
function ledgerHeights(ledgerStateDir) {
  const p = join(ledgerStateDir, 'coverage.json');
  if (!existsSync(p)) {
    return { present: false, heights: new Set(), ranges: 0, byKey: [] };
  }
  const l = JSON.parse(readFileSync(p, 'utf8'));
  const heights = new Set();
  const byKey = [];
  for (const [key, r] of Object.entries(l.ranges ?? {})) {
    for (let h = r.from; h <= r.to; h++) heights.add(h);
    byKey.push({ key, from: r.from, to: r.to });
  }
  byKey.sort((a, b) => a.from - b.from);
  return { present: true, heights, ranges: byKey.length, byKey,
           liveGeneration: l.liveGeneration ?? '' };
}

/**
 * REFUSE A CYCLE THAT WOULD SHRINK THE PUBLISHED INDEX.
 *
 * `eth-ingest-range.mjs` publishes the union of the snapshots its ledger holds, at a
 * generation derived from that union. If the store maps heights the ledger has no snapshot
 * for, the next cycle's union omits them, its generation id is new (so nothing is skipped),
 * its maps are self-consistent (so `POINTER` passes) and those heights become unreferenced.
 * ING-1's shape 2, reached from here. Nothing downstream can see it, so it is refused here.
 */
function assertLedgerCoversWhatTheStoreMaps(mappedHeights, ledger, allow) {
  const orphaned = mappedHeights.filter((h) => !ledger.heights.has(h));
  if (orphaned.length === 0) return { orphaned: [] };
  const first = orphaned.slice(0, 10).join(', ');
  const msg =
    `the published generation maps ${mappedHeights.length} height(s) and this follower's `
    + `coverage ledger holds a filed snapshot for ${mappedHeights.length - orphaned.length} `
    + `of them. ${orphaned.length} published height(s) have no snapshot in the ledger — `
    + `first: ${first}${orphaned.length > 10 ? ', …' : ''}.\n\n`
    + `A cycle from this state would publish the union of what the ledger DOES hold, at a `
    + `freshly derived generation, and those ${orphaned.length} height(s) would be dropped `
    + `from the published index. The block objects would all still be in the store, `
    + `fetchable by hash, listed by no map — and the audit's POINTER check would PASS over `
    + `it, because the pointer and its own map would agree. That is ING-1's shape 2.\n\n`
    + `This is the one piece of state a restart cannot rebuild from published output: the `
    + `store holds the INGESTED tree, not the captures it was built from. Either restore `
    + `the state directory (it is the daemon's data, not a cache), or re-capture those `
    + `ranges into it so the union is whole again.`;
  if (!allow) throw refuse(SourceRefusal, msg);
  return { orphaned, warned: msg };
}

// ---------------------------------------------------------------------------
// the capture + file + publish step
// ---------------------------------------------------------------------------

/** `capture-eth-range.mjs` over one contiguous span, into a directory of its own. */
function captureRange(cfg, from, to) {
  const out = join(cfg.stateDir, 'captures', `${from}-${to}`);
  if (existsSync(out)) rmSync(out, { recursive: true, force: true });
  const a = ['tools/chain/capture-eth-range.mjs',
             '--recorder', cfg.recorder, '--recorder-commit', cfg.recorderCommit,
             '--from', String(from), '--to', String(to),
             '--max', String(cfg.max), '--url', cfg.url,
             '--out', out, '--work', join(cfg.stateDir, 'work')];
  const r = spawnSync('node', a, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024,
                                   cwd: cfg.repoRoot });
  return { rc: r.status, out, log: (r.stdout ?? '') + (r.stderr ?? ''), argv: a };
}

/** `eth-ingest-range.mjs` over one captured tree: file, union, ingest, publish. */
function fileAndPublish(cfg, snapshotDir, from, to) {
  const a = ['tools/chain/eth-ingest-range.mjs',
             '--snapshot', snapshotDir, '--state', cfg.ledgerState,
             '--chain', cfg.chain, '--backend', cfg.backend,
             '--ingest-bin', cfg.ingestBin, '--publish-bin', cfg.publishBin,
             '--expect-from', String(from), '--expect-to', String(to),
             '--writer', cfg.writer, '--json'];
  if (cfg.backend === 'local') a.push('--dest', cfg.dest);
  else {
    a.push('--bucket', cfg.bucket);
    if (cfg.endpoint) a.push('--endpoint', cfg.endpoint);
    if (cfg.prefix) a.push('--prefix', cfg.prefix);
  }
  const r = spawnSync('node', a, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024,
                                   cwd: cfg.repoRoot });
  let report = null;
  try { report = JSON.parse(r.stdout); } catch { /* left null; the log carries the reason */ }
  return { rc: r.status, report, log: (r.stdout ?? '') + (r.stderr ?? ''), argv: a };
}

// ---------------------------------------------------------------------------
// the owed set, and the span one tick takes from it
// ---------------------------------------------------------------------------

/**
 * The work outstanding, DERIVED. See the header: there is no buffer, so there is no
 * overflow, so there is no drop.
 */
/**
 * COUNTED, NOT MATERIALISED, and the difference is a memory bound rather than a style note.
 *
 * `floor` is a POLICY (see `--floor`) and an operator who names a low one asks a question
 * whose honest answer is tens of millions of heights: Ethereum's finalized head is past
 * 26,000,000. Returning that as an array of numbers is roughly 200 MB per tick, and the
 * span picker's membership test over it made the per-tick cost quadratic in the queue depth.
 * The loop needs exactly two things from the owed set — HOW MANY, for the queue depth it
 * publishes, and the LOWEST CONTIGUOUS RUN, for what to capture — and both are computable
 * in one pass over a range with no array at all.
 *
 * The count is still the honest number. A follower told to be responsible for the whole
 * chain reports a queue depth of tens of millions, which is true, and is what ING-4's
 * backfill exists to work down.
 */
function owedSummary(floor, ceiling, mapped, filed, deferred, capacity) {
  let count = 0;
  let first = null;
  let last = null;
  let span = null;
  for (let h = floor; h <= ceiling; h++) {
    if (mapped.has(h) || filed.has(h)) continue;
    count++;
    if (first === null) first = h;
    last = h;
    if (span === null && !deferred.has(h)) {
      // The lowest contiguous run, extended while it stays contiguous, owed and not
      // deferred. Lowest-first, so coverage grows from the oldest gap and the published
      // span stays contiguous as it fills; `coverage-contiguity.mjs` is the reader that
      // cares. Contiguous, because `eth-ingest-range.mjs` refuses a snapshot with a hole in
      // its `blocks[]` — a span is a range key and a range key must describe what it covers.
      let to = h;
      while (to - h + 1 < capacity && to + 1 <= ceiling
             && !mapped.has(to + 1) && !filed.has(to + 1) && !deferred.has(to + 1)) to++;
      span = { from: h, to, heights: to - h + 1 };
    }
  }
  return { count, first, last, span };
}

// ---------------------------------------------------------------------------
// head transcripts — the seam, and it is a recording
// ---------------------------------------------------------------------------

function loadHeadTranscript(path) {
  const t = JSON.parse(readFileSync(path, 'utf8'));
  if (t.format !== HEAD_TRANSCRIPT_FORMAT) {
    throw refuse(SourceRefusal,
      `${path} states format '${t.format}' and this tool reads `
      + `'${HEAD_TRANSCRIPT_FORMAT}'.`);
  }
  if (!Array.isArray(t.observations) || t.observations.length === 0) {
    throw refuse(SourceRefusal, `${path} holds no observations`);
  }
  return t;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

export async function main() {
  const repoRoot = resolve(new URL('../..', import.meta.url).pathname);
  const cfg = {
    repoRoot,
    chain: arg('chain', DEFAULT_CHAIN),
    url: arg('url', 'https://eth.drpc.org'),
    stateDir: resolve(arg('state', '.eth-follower')),
    ledgerState: resolve(arg('ledger-state', '.eth-chain-state')),
    backend: arg('backend', 'local'),
    dest: arg('dest', ''),
    bucket: arg('bucket', ''),
    endpoint: arg('endpoint', ''),
    prefix: arg('prefix', ''),
    recorder: arg('recorder', ''),
    recorderCommit: arg('recorder-commit', ''),
    stateBin: arg('state-bin', 'blocktracer-follower-state'),
    // THE LEASE OWNER IS A DEPLOYMENT SLOT, NOT A PROCESS. A pid in it would make every
    // restart a different writer, so `releaseLease`'s holder test (it deletes only a lease
    // whose contents equal the writer id) could never recognise its own predecessor's
    // lease, and an operator reading the stale object could not tell which deployment left
    // it. One slot per chain is also the honest statement of the invariant: §6's Ordering
    // row is one writer per chain.
    writer: arg('writer', `follow-eth-chain/${arg('chain', DEFAULT_CHAIN)}`),
    ingestBin: arg('ingest-bin', 'blocktracer-chain-ingest'),
    publishBin: arg('publish-bin', 'blocktracer-publish'),
    interval: intArg('interval', 60),
    capacity: intArg('tick-capacity', 3),
    max: intArg('max', 6),
    floor: intArg('floor', 0),
    ceiling: intArg('ceiling', 0),
    ticks: intArg('ticks', 0),
    deadlineMin: intArg('deadline-min', 0),
    ring: intArg('ring', 64),
    // THREE RATHER THAN TWO, from a measurement. `https://eth.drpc.org` — the default,
    // and a free public endpoint — answered one capture in a proof run with HTTP 429
    // "You reached Public endpoint rate limit". Two attempts is ONE retry, which is not
    // enough slack for a rate limiter that is clearing, and the span then sat permanently
    // deferred over a condition that had already passed. The cost of a higher number is
    // bounded by the capture's own refusal being fast.
    maxAttempts: intArg('max-attempts', 3),
  };
  const noCapture = flag('no-capture');
  const headsPath = arg('heads', '');
  const recordHeads = arg('record-heads', '');
  const allowBehind = flag('allow-ledger-behind-store');
  const jsonOnly = flag('json');
  const observationsPath = arg('observations', join(cfg.stateDir, 'observations.jsonl'));

  const say = (m) => { if (!jsonOnly) console.error(`follow-eth-chain: ${m}`); };

  if (cfg.backend === 'local' && cfg.dest.length === 0) {
    throw refuse(ConfigRefusal,
      '--dest <dir> is required for --backend local: the follower\'s destination is an '
      + 'OBJECT STORE and not a workstation filesystem, which is the whole of ING-1\'s '
      + 'second deliverable. A local directory IS an object store here — its putIfAbsent '
      + 'is a genuine O_CREAT|O_EXCL — so this is the credential-free spelling of the '
      + 'same thing, not a stand-in for it.');
  }
  if (cfg.backend !== 'local' && cfg.bucket.length === 0) {
    throw refuse(ConfigRefusal, `--backend ${cfg.backend} needs --bucket`);
  }
  if (!noCapture && (cfg.recorder.length === 0 || cfg.recorderCommit.length === 0)) {
    throw refuse(ConfigRefusal,
      '--recorder and --recorder-commit are both required unless --no-capture. The commit '
      + 'is NOT derived, for the reason `eth-capture.sh` gives: it reaches every published '
      + 'row\'s `runtimeCommit`, the binary cannot be asked for it, and a default read off '
      + 'a sibling checkout\'s HEAD is silently WRONG — not absent — for a binary built in '
      + 'a worktree or before a pull.');
  }
  if (cfg.capacity < 1) {
    throw refuse(ConfigRefusal, `--tick-capacity must be at least 1 (got ${cfg.capacity})`);
  }
  if (headsPath && recordHeads) {
    throw refuse(ConfigRefusal,
      '--heads replays a transcript and --record-heads writes one from the live node; '
      + 'together they would write a copy of the file they read.');
  }

  mkdirSync(cfg.stateDir, { recursive: true });

  // ── the head source, stated rather than implied ──────────────────────────
  let transcript = null;
  if (headsPath) {
    transcript = loadHeadTranscript(headsPath);
    const kind = transcript.synthetic
      ? `SYNTHETIC (constructed: ${transcript.constructedBy ?? 'unstated'})`
      : 'RECORDED from a live node';
    say(`heads    ${headsPath} — ${transcript.observations.length} observation(s), ${kind}`);
    if (transcript.synthetic) {
      say('         a synthetic transcript is a statement about the LOOP, never about the '
          + 'chain. Nothing measured over it is a measurement of Ethereum.');
    }
  } else {
    say(`heads    live, ${cfg.url}`);
  }

  // ── resume: §3.2a, from published output ─────────────────────────────────
  let resumed = resumeFromPublishedOutput(cfg);
  if (!resumed.recentWindow.readable && resumed.head.present) {
    throw refuse(SourceRefusal,
      `the store's pointer for '${cfg.chain}' names generation `
      + `'${resumed.head.generation}' and its height maps could not be read: `
      + `${resumed.recentWindow.why}. A follower that resumed from an unreadable map would `
      + `treat every published height as outstanding and re-capture the whole chain.`);
  }
  const ledger = ledgerHeights(cfg.ledgerState);
  say(`store    ${cfg.backend === 'local' ? cfg.dest : cfg.bucket} — `
      + `${resumed.head.present ? `head ${resumed.head.height} generation ${resumed.head.generation}`
                                : 'COLD (no current.json)'}, `
      + `${resumed.recentWindow.count} height(s) mapped`);
  say(`ledger   ${cfg.ledgerState} — ${ledger.present ? `${ledger.ranges} range(s), `
      + `${ledger.heights.size} height(s)` : 'absent (first run)'}`);

  // ── THE LEASE A CRASHED PREDECESSOR LEAVES BEHIND ────────────────────────
  //
  // `publisher.nim` takes a per-chain `putIfAbsent` lease and releases it in a `finally`.
  // There is no TTL, no fencing token and no owner-liveness test — the publisher says so
  // deliberately: "a stale lease is a manual/operational concern, deliberately not
  // auto-broken here to keep single-writer honest." For a tool somebody runs, that is
  // right. For a RESIDENT daemon it means a kill anywhere inside the content upload —
  // 1,972 network PUTs for a three-block range — leaves one object that refuses every
  // later cycle by name, permanently.
  //
  // AND IT IS NOT HYPOTHETICAL. `publish-r2.yml`'s "Break stale publish leases" step
  // records the production incident it was added for: run 38388168109's
  // `blocktracer-publish` was SIGKILLed when its ephemeral runner was reaped mid-publish
  // ("Terminate orphan process"), `_leases/aztec.lock` survived it, and the next run failed
  // after FOUR AND THREE-QUARTER HOURS with "chain 'aztec' is locked by another publisher".
  // A resident follower is a process on a host that reboots; it is in exactly that class.
  //
  // THE REMEDY EXISTS AND IT IS A HUMAN. That step is a default-off `workflow_dispatch`
  // input, and its own comment says why it is not a binary flag: "Adding `--break-lease` to
  // the binary would undo that decision for every caller; a default-off input on the one
  // workflow that publishes leaves the guarantee intact and makes the exception
  // reviewable." This loop is a caller, so the same argument applies to it, and it does the
  // same thing the workflow does before the break: it READS the lease and names the holder.
  // It does not break it. Breaking a lease whose holder may be alive is how two writers
  // reach one chain's generation, and this process cannot tell a dead holder from a slow
  // one. The staleness evidence it CAN offer is the published SLI ring: a holder that is
  // alive is writing an observation every tick.
  if (resumed.lease?.held) {
    say('');
    say(`LEASE HELD — '${resumed.lease.key}' names writer '${resumed.lease.writer}'.`);
    say(`  Every publish this loop attempts will be refused by name ("chain `
        + `'${cfg.chain}' is locked by another publisher") until that object is gone.`);
    say('  If another follower or publisher is running, THIS process should not be: the');
    say('  lease is what keeps one writer per chain, and it is working.');
    say('  If the previous holder was killed, the lease is stale and an operator must');
    say(`  delete '${resumed.lease.key}' — which publish-r2.yml's break-stale-leases`);
    say('  input already does, by hand, for the reason it records. This loop will not:');
    say('  it cannot tell a dead');
    say('  holder from a slow one, and guessing is how two writers reach one generation.');
    say('  The published SLI ring is the staleness evidence — a live holder is writing an');
    say(`  observation every tick into obs/${cfg.chain}/follower.json.`);
    say('');
  }

  const guard = assertLedgerCoversWhatTheStoreMaps(
    resumed.mappedHeights, ledger, allowBehind);
  if (guard.warned) {
    say('');
    say('--allow-ledger-behind-store WAS GIVEN AND THIS IS THE REFUSAL IT SUPPRESSED:');
    for (const line of guard.warned.split('\n')) say(`  ${line}`);
    say('');
  }

  // ── the floor: a policy, stated ──────────────────────────────────────────
  let floor = cfg.floor;
  let floorWhy = 'stated by --floor';
  if (floor === 0) {
    if (resumed.recentWindow.count > 0) {
      floor = resumed.recentWindow.lowest;
      floorWhy = 'the lowest height the live generation maps (so this follower is '
               + 'responsible for exactly the span it has published, and upward)';
    } else {
      floor = -1;   // decided at the first observation; a cold store has nothing to say
      floorWhy = 'the first finalized head observed (the store is cold, so there is no '
               + 'published span to continue; ING-4\'s backfill is what reaches history)';
    }
  }

  const mapped = new Set(resumed.mappedHeights);
  const deferred = new Map();   // height -> attempts, so a refusing span cannot livelock
  const recorded = [];          // --record-heads
  const startedAt = Date.now();
  let tick = 0;
  let lastFinalized = resumed.finalized.height > 0 ? resumed.finalized.height : 0;
  // ── WHAT A NON-ZERO EXIT MEANS FOR A RESIDENT LOOP ───────────────────────
  //
  // MEASURED 2026-10-14, four times in one proof run. The first version of this loop set
  // the exit code on EVERY refused attempt, and `https://eth.drpc.org` — a free public
  // endpoint — answered one capture with HTTP 429 "You reached Public endpoint rate limit".
  // The next tick retried the same span, the retry succeeded, the published coverage was
  // complete and correct, and the process still exited 1. That is the wrong reading: a
  // transient refusal that the loop ITSELF recovered from is a figure for the observation
  // stream, not a verdict on the run, and a daemon whose supervisor restarts it for one
  // 429 from somebody else's rate limiter is a daemon that restarts for weather.
  //
  // So the exit code reports the state AT EXIT and nothing else: spans that are still
  // refusing after `--max-attempts`, or a loop that never once reached the chain. Heights
  // merely still OWED are not a failure — that is lag, which the SLI publishes.
  let transientRefusals = 0;
  let observedTicks = 0;

  say(`floor    ${floor > 0 ? floor : '(pending first observation)'} — ${floorWhy}`);
  say(`capacity ${cfg.capacity} height(s) per tick, interval ${cfg.interval}s, `
      + `${cfg.ticks > 0 ? `${cfg.ticks} tick(s)` : 'resident'}`);
  say('');

  const stop = () => {
    if (cfg.ticks > 0 && tick >= cfg.ticks) return 'tick budget';
    if (cfg.deadlineMin > 0 && Date.now() - startedAt > cfg.deadlineMin * 60_000) {
      return 'deadline';
    }
    if (transcript && tick >= transcript.observations.length) return 'transcript exhausted';
    return '';
  };

  for (;;) {
    const why = stop();
    if (why) { say(`stopping: ${why}`); break; }

    const tickStartedAt = new Date().toISOString();
    tick++;

    // ── OBSERVE ────────────────────────────────────────────────────────────
    let chainHead = null;
    let observeError = '';
    if (transcript) {
      const o = transcript.observations[tick - 1];
      chainHead = { tip: o.tip, finalized: o.finalized };
    } else {
      try { chainHead = await observeChain(cfg.url); }
      catch (e) { observeError = e.message; }
    }

    if (observeError) {
      // A TICK THAT COULD NOT READ THE HEAD IS STILL AN OBSERVATION. Reporting nothing
      // would make an endpoint outage look exactly like a drought, which is the pair ING-1
      // exists to separate — and would make it look like a stalled loop too.
      const obs = {
        format: OBSERVATION_FORMAT, tool: HERE, chain: cfg.chain,
        tick, at: tickStartedAt, observed: false, why: observeError,
        arrivals: 0, queueDepth: null, lagBlocks: null, lagSeconds: null,
        lagToFinalized: null, drained: null,
      };
      appendFileSync(observationsPath, JSON.stringify(obs) + '\n');
      publishObservation(cfg, obs);
      say(`tick ${tick}: the endpoint did not answer — ${observeError}`);
      // Counted, not fatal: see the exit-code note above.
      if (!stop()) await new Promise((r) => setTimeout(r, cfg.interval * 1000));
      continue;
    }

    observedTicks++;

    if (recordHeads) {
      recorded.push({ at: tickStartedAt, tip: chainHead.tip, finalized: chainHead.finalized });
    }

    if (floor < 0) {
      floor = chainHead.finalized.height;
      say(`floor    ${floor} — ${floorWhy}`);
    }

    const ceiling = cfg.ceiling > 0
      ? Math.min(cfg.ceiling, chainHead.finalized.height)
      : chainHead.finalized.height;

    // ── CAPTURED AND PUBLISHED ARE TWO DIFFERENT THINGS ────────────────────
    //
    // MEASURED, 2026-10-14, and it cost a wasted capture and a rate-limit refusal before it
    // was understood. A follower killed between a capture and the publish that would make
    // it visible leaves the range FILED in the ledger and ABSENT from the published map. If
    // "outstanding" is read off the map alone, the restart re-captures a range it already
    // holds — which is the "re-doing finished work" ING-1 D5 forbids, and on a public
    // endpoint it is also how a restart meets a 429 it had no need to ask for.
    //
    // So the two sets are kept apart. The ledger says what has been CAPTURED; the published
    // map says what is REACHABLE; and the gap between them is work that needs a publish and
    // no recorder at all. A tick finishes what it started before it starts more.
    const filed = ledgerHeights(cfg.ledgerState);
    // Not restricted to the window: a filed range outside the current window is still
    // carried by the next union publish, so delaying it would only widen the gap.
    const unpublished = [...filed.heights].filter((h) => !mapped.has(h)).sort((a, b) => a - b);

    // ── THE OWED SET, DERIVED ──────────────────────────────────────────────
    //
    // Minus what is already filed, for the reason above: a filed height needs publishing,
    // not capturing.
    const deferredNow = new Set(
      [...deferred].filter(([, n]) => n >= cfg.maxAttempts).map(([h]) => h));
    const owed = owedSummary(floor, ceiling, mapped, filed.heights, deferredNow,
                             cfg.capacity);
    // ARRIVALS are the heights that became reachable since the last observation. Counted
    // against the previous finalized head rather than against the owed set, because the
    // owed set also contains work that was owed before and is not an arrival. Counted
    // rather than listed, for `owedSummary`'s reason: on the first tick after a cold start
    // this range is the whole span the floor names.
    const arrivalLo = Math.max(floor, lastFinalized + 1);
    let arrivalCount = 0;
    let arrivalFirst = null;
    let arrivalLast = null;
    for (let h = arrivalLo; h <= ceiling; h++) {
      if (mapped.has(h)) continue;
      arrivalCount++;
      if (arrivalFirst === null) arrivalFirst = h;
      arrivalLast = h;
    }

    const publishedHead = resumed.head.present ? resumed.head.height : 0;
    const lagBlocks = publishedHead > 0 ? chainHead.tip.height - publishedHead : null;
    const lagToFinalized = publishedHead > 0
      ? chainHead.finalized.height - publishedHead : null;
    const lagSeconds = publishedHead > 0 && mapped.has(publishedHead)
      ? Math.max(0, Math.round(Date.now() / 1000) - chainHead.tip.timestamp
                    + (chainHead.tip.height - publishedHead) * 12)
      : null;

    // ── DRAIN, up to the tick's capacity ───────────────────────────────────
    const span = noCapture ? null : owed.span;

    let drained = null;
    let captureRc = null;
    let publishReport = null;
    let published = null;

    /**
     * The publish half of a tick, shared by the capture path and the catch-up path because
     * a second spelling of "did the publish land, and what does the map say now" is how one
     * of them goes stale. Returns the report, or null if the publish refused.
     */
    const publishFiled = (snapshotDir, from, to, label) => {
      const pub = fileAndPublish(cfg, snapshotDir, from, to);
      if (pub.rc !== 0) {
        for (let h = from; h <= to; h++) deferred.set(h, (deferred.get(h) ?? 0) + 1);
        writeFileSync(join(cfg.stateDir, `publish-${from}-${to}.log`), pub.log);
        say(`         ${label} refused (rc=${pub.rc}); see `
            + `${cfg.stateDir}/publish-${from}-${to}.log`);
        transientRefusals++;
        return null;
      }
      // RE-READ THE STORE rather than assume the publish landed where it was asked to. The
      // covered set is the PUBLISHED map, and a cycle that uploaded content but did not
      // flip the pointer (`--halt-before-pointer` is a real mode) has published nothing a
      // reader can reach. So `mapped` is refreshed from the store, not from the span this
      // process just handed over.
      resumed = resumeFromPublishedOutput(cfg);
      mapped.clear();
      for (const h of resumed.mappedHeights) mapped.add(h);
      say(`         published generation ${pub.report?.publish?.generation ?? '?'} `
          + `· uploaded ${pub.report?.publish?.uploaded ?? '?'} `
          + `· the live map now holds ${mapped.size} height(s)`);
      return pub.report;
    };

    if (unpublished.length > 0) {
      // ── CATCH-UP: FILED BUT NOT VISIBLE, SO PUBLISH AND DO NOT CAPTURE ───
      //
      // This is what a restart after a kill between capture and publish looks like, and it
      // costs no recorder and no endpoint call. `eth-ingest-range.mjs` is handed a range the
      // ledger ALREADY holds, which it detects and re-uses the filed snapshot for ("already
      // in the ledger … re-using its filed snapshot") while ingesting the union of
      // everything filed — so one call republishes the whole index. Any filed range will do;
      // the lowest is chosen so the message names the oldest outstanding work.
      const r = filed.byKey.find((x) => unpublished.some((h) => h >= x.from && h <= x.to))
                ?? filed.byKey[0];
      say(`tick ${tick}: tip ${chainHead.tip.height} finalized `
          + `${chainHead.finalized.height} · ${arrivalCount} arrival(s) · `
          + `${owed.count} owed · ${unpublished.length} height(s) CAPTURED BUT NOT `
          + `PUBLISHED — publishing the union, capturing nothing`);
      publishReport = publishFiled(join(cfg.ledgerState, 'ranges', r.key), r.from, r.to,
                                   'catch-up publish');
      published = publishReport === null ? null
        : { from: unpublished[0], to: unpublished[unpublished.length - 1],
            heights: unpublished.length, viaRange: r.key };
    } else if (span) {
      say(`tick ${tick}: tip ${chainHead.tip.height} finalized `
          + `${chainHead.finalized.height} · ${arrivalCount} arrival(s) · `
          + `${owed.count} owed · capturing ${span.from}..${span.to}`);
      const cap = captureRange(cfg, span.from, span.to);
      captureRc = cap.rc;
      // THE CAPTURE'S OWN OUTPUT IS KEPT WHETHER IT SUCCEEDED OR NOT. It carries facts this
      // loop does not restate — the container version it wrote, the engine pin's accepted
      // schema list, the prestate boundary controls — and discarding it on success left the
      // only statement of them in a pipe. An operator diagnosing a published page reads it.
      //
      // A REFUSAL GETS ITS OWN FILENAME, because the stable one is overwritten by the next
      // attempt. Measured: a span refused with HTTP 429 and captured on the retry left a log
      // showing only the SUCCESS, so the refusal this loop had reported in its own output
      // had no surviving evidence — which is the diagnosis an operator needs most.
      const capLog = join(cfg.stateDir, cap.rc === 0
        ? `capture-${span.from}-${span.to}.log`
        : `capture-${span.from}-${span.to}.refused-${(deferred.get(span.from) ?? 0) + 1}.log`);
      writeFileSync(capLog, cap.log);
      if (cap.rc !== 0) {
        for (let h = span.from; h <= span.to; h++) {
          deferred.set(h, (deferred.get(h) ?? 0) + 1);
        }
        say(`         capture refused (rc=${cap.rc}); ${span.from}..${span.to} attempt `
            + `${deferred.get(span.from)} of ${cfg.maxAttempts}. The span stays OWED — a `
            + `refused capture is not a covered height. See ${capLog}`);
        transientRefusals++;
      } else {
        say(`         captured; its own report is in ${capLog}`);
        publishReport = publishFiled(cap.out, span.from, span.to, 'file/publish');
        if (publishReport !== null) {
          drained = { from: span.from, to: span.to, heights: span.heights };
        }
      }
    } else {
      // ── A QUIET TICK IS A MEASUREMENT ────────────────────────────────────
      say(`tick ${tick}: tip ${chainHead.tip.height} finalized `
          + `${chainHead.finalized.height} · ${arrivalCount} arrival(s) · `
          + `${owed.count} owed · ${noCapture ? 'capture disabled' : 'nothing to capture'} `
          + `— observed ${floor}..${ceiling}`
          + (arrivalCount === 0
             ? ', and ZERO ARRIVALS IS THIS READING rather than silence: the window '
               + 'above is what was examined'
             : ''));
    }

    const observation = {
      format: OBSERVATION_FORMAT,
      tool: HERE,
      chain: cfg.chain,
      tick,
      at: tickStartedAt,
      observed: true,
      // THE WINDOW THIS TICK LOOKED AT. Without it, `arrivals: 0` is a number with no
      // subject: a reader cannot tell a tick that examined three heights and found nothing
      // from a tick that examined none.
      window: { from: floor, to: ceiling },
      tip: chainHead.tip,
      finalized: chainHead.finalized,
      arrivals: arrivalCount,
      arrivalRange: arrivalCount > 0
        ? { from: arrivalFirst, to: arrivalLast } : null,
      // The queue depth AFTER this tick's drain, which is what is still owed.
      queueDepth: owed.count - (drained ? drained.heights : 0),
      queueDepthBeforeDrain: owed.count,
      tickCapacity: cfg.capacity,
      drained,
      // CAPTURED-BUT-NOT-VISIBLE, reported separately from the queue because it is a
      // different kind of debt: it needs a publish and no recorder, and a restart after a
      // kill between the two is the only way to get into it. Folding it into `queueDepth`
      // would make a follower that is seconds from being caught up look as far behind as
      // one that has not captured anything.
      filedNotPublished: unpublished.length,
      publishedThisTick: published,
      deferred: [...deferredNow],
      // §6's primary SLI, and the two numbers that stop it being read as a fault.
      lagBlocks,
      lagToFinalized,
      lagSeconds,
      publishedHead: resumed.head.present ? resumed.head.height : null,
      publishedGeneration: resumed.head.present ? resumed.head.generation : null,
      mappedHeights: mapped.size,
      capture: captureRc === null ? null : { rc: captureRc },
      publish: publishReport?.publish ?? null,
    };

    appendFileSync(observationsPath, JSON.stringify(observation) + '\n');
    publishObservation(cfg, observation);
    if (jsonOnly) console.log(JSON.stringify(observation));

    lastFinalized = chainHead.finalized.height;

    if (recordHeads) {
      writeFileSync(recordHeads, JSON.stringify({
        format: HEAD_TRANSCRIPT_FORMAT,
        endpoint: cfg.url,
        chain: cfg.chain,
        recordedBy: HERE,
        recordedAt: new Date().toISOString(),
        intervalSeconds: cfg.interval,
        synthetic: false,
        observations: recorded,
      }, null, 1) + '\n');
    }

    if (!stop()) {
      // A TRANSCRIPT DOES NOT SLEEP. The interval is a property of reading a live chain;
      // waiting sixty seconds between two observations that were recorded sixty seconds
      // apart would make a proof over the transcript measure `setTimeout`.
      if (!transcript) await new Promise((r) => setTimeout(r, cfg.interval * 1000));
    }
  }

  // ── THE EXIT CODE, FROM THE STATE AT EXIT ────────────────────────────────
  const stuck = [...deferred].filter(([, n]) => n >= cfg.maxAttempts).map(([h]) => h);
  const exitCode = (stuck.length > 0 || observedTicks === 0) ? 1 : 0;

  say('');
  say(`ran ${tick} tick(s), ${observedTicks} of them reaching the chain; `
      + `observations in ${observationsPath}`);
  if (transientRefusals > 0) {
    say(`${transientRefusals} attempt(s) were refused and retried. That is a figure and `
        + `not a verdict: a span a later tick captured is covered, and the exit code below `
        + `reports the state at EXIT rather than every bump along the way.`);
  }
  if (stuck.length > 0) {
    say(`STILL REFUSING after ${cfg.maxAttempts} attempt(s): ${stuck.length} height(s), `
        + `first ${stuck[0]}. These are NOT published and NOT retried again by this `
        + `process; a restart retries them. Exit 1.`);
  }
  if (observedTicks === 0) {
    say(`NO TICK REACHED THE CHAIN. Every observation records the failure, so this is a `
        + `reported outage rather than a silent one — but nothing was measured about the `
        + `chain, so exit 1.`);
  }
  say(`SLI      obs/${cfg.chain}/follower.json in the store — lag behind tip, per §6`);
  return exitCode;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().then((rc) => process.exit(rc)).catch((e) => {
    console.error(`${HERE}: ${e.message}`);
    process.exit(e.refusalKind === ConfigRefusal ? 2 : 1);
  });
}
