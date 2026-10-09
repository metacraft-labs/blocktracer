#!/usr/bin/env node
//
// capture-eth-range.mjs — ETHEREUM MAINNET: A RANGE OF BLOCKS, RECORDED LOCALLY, INTO ONE
// SNAPSHOT TREE A DEVELOPER CAN OPEN.
//
// ── THE WORKFLOW THIS IS FOR, AND WHAT IT IS NOT ──────────────────────────────────────
//
// "During development we work with local builds of the followers. We ask to process ranges
// of blocks manually, we inspect the results, etc. Once everything seems to be stable, we
// deploy them permanently." So: ONE command, a block range, a local output tree, and a
// human watching it. Not a CI job, not a build step, not a daemon. The deployed follower
// is the same tool in tip-following mode and comes later; nothing here is wired into a
// gate, and `--out` deliberately defaults OUTSIDE the committed tree (see `--out` below).
//
// ── WHAT IT DRIVES, RATHER THAN REIMPLEMENTS ──────────────────────────────────────────
//
// Two programs, both of which already existed and are kit-accepted end to end:
//
//   1. `codetracer-evm-recorder trace-onchain <tx> --rpc-url <archive> --out-dir <dir>`
//      writes one CTFS container per transaction. Called once per transaction to RECORD.
//   2. `tools/chain/produce-eth-snapshot.mjs` turns containers plus chain data into a
//      `blocktracer/chain-snapshot@2` tree. Called ONCE, with every recording this run
//      finished and with the block window to enumerate.
//
// THE PRODUCER IS CALLED ONCE AND NOT ONCE PER TRANSACTION, because `counts`, `blocks[]`
// and `captures[]` are whole-tree facts. N trees merged afterwards would be N tallies
// nobody recomputed, which is precisely the defect `lib/recount.mjs`'s header documents
// having reached committed data. So this file records, and the producer publishes; it
// writes no `snapshot.json` member of its own and holds no copy of the §5 tree's shape.
//
// NO ABSTRACTION IS INTRODUCED AND NONE IS SHARED WITH THE AZTEC CAPTURE.
// `capture-chain.mjs` is Aztec's range capture and this is Ethereum's; they share no
// interface, no plugin, no registered module and no dispatch site, and this file imports
// nothing from `lib/` at all. That is deliberate under ING-7's two-consumer rule: a second
// CONCRETE follower is what licenses DEL-7 to extract a seam from the two and measure it,
// and a seam guessed from one consumer is the thing that rule exists to prevent. Where
// this file wanted to factor something out, the wanting is a comment — search for `DEL-7`.
//
// It is NOT a producer in `lib/producer-scan.mjs`'s sense and must not become one: it
// writes no transaction row, so it states no row member, so there is nothing for it to
// restate. Every published figure in the tree is stated by the producer, once.
//
// ── THE RANGE: BOTH SPELLINGS, AND WHY `--depth` ANCHORS ON FINALIZED ─────────────────
//
// `--from`/`--to` is the primary spelling, because it is the request the workflow above
// actually makes: a developer asks for a range of blocks, by number, and then asks for the
// same range again after a code change. `--depth N` is the second spelling, for "give me
// something recent without me looking up a height first".
//
// `--depth N` MEANS THE N BLOCKS ENDING AT THE FINALIZED HEAD, NOT AT THE TIP, and that is
// the one place this tool's interface deliberately departs from `capture-chain.mjs`'s.
// Aztec's `--depth` counts below the TIP because its constraint is that transaction bodies
// are pruned at the finalized tip — a recording has to happen in the window ABOVE
// finalized or it cannot happen at all. Ethereum's constraint is the exact opposite shape:
// an archive endpoint serves state at any depth (that is what the `replay-preceding`
// strategy rests on), while a block above the finalized head can still REORG OUT. A
// recording of a transaction that reorged away is a recording of a transaction that is not
// on the chain, published with provenance saying it is. So the honest default is to stay
// at or below finalized, and `--depth` says so by construction rather than by a warning.
//
// Measured on `https://eth.drpc.org` while this was written: tip 26,157,381, finalized
// 26,157,296 — a gap of 85 blocks, i.e. roughly seventeen minutes of chain that `--depth`
// declines to record and `--from`/`--to` will still reach if an operator asks for it by
// number. `--from`/`--to` is NOT clamped to finalized: an operator who names a height
// means it, and refusing a stated number would be this tool overruling the request the
// whole interface exists to serve. It prints how far above finalized the request reached.
//
// ── `--max`: THE CAP IS ON RECORDING, BECAUSE RECORDING IS THE EXPENSIVE STEP ─────────
//
// Enumerating a block is two JSON-RPC calls. Recording a transaction at index k re-executes
// indices 0..k-1 first, to rebuild the prestate the fork needs — that is what
// `replay-preceding` is. So the cost of a capture is dominated by the recordings, and
// within them by how deep in its block each transaction sits. `--max` therefore caps
// transactions RECORDED (default 6, the same default and the same meaning as
// `capture-chain.mjs`'s) and the enumeration is never capped: §5.2 requires every
// transaction the enumeration saw to appear in `transactions`, traced or not, so the
// denominator is the whole range whatever the budget was.
//
// WHICH TRANSACTIONS, GIVEN A BUDGET: the candidates are ordered by (index within block
// ASCENDING, then block ASCENDING) and the first `--max` are taken. Two reasons, and they
// point the same way:
//
//   * CHEAPEST FIRST. Index 0 costs zero preceding replays, index 1 costs one, and so on.
//     A budget spent on index 0 of six blocks buys six recordings for the price of the
//     predecessors of none of them; the same budget spent on six transactions of one
//     mid-block stretch can cost hundreds of replays.
//   * SPREAD ACROSS THE RANGE. Ordering by index first means the budget lands in as many
//     distinct blocks as it has room for, which is what makes the result a sample OF THE
//     RANGE rather than a sample of its first block. A range capture whose traces all sat
//     in one block would tell a developer nothing the single-transaction capture did not.
//
// It is a deterministic order over a measured candidate list, so the same range and the
// same budget select the same transactions on every run — which is what makes `--plan`
// worth reading before spending the recordings, and what makes a resumed run continue the
// same plan rather than a new one.
//
// ── RESUMABILITY, AND WHY IT IS THE RECORDINGS THAT ARE KEPT ──────────────────────────
//
// A range of any size will be interrupted — the endpoint rate-limits mid-run, the operator
// gets bored, the laptop sleeps — and re-running must not redo finished work. What is
// expensive is the recordings and ONLY the recordings, so they are what the work directory
// keeps: `<work>/rec/<txHash>/{capture/,run.log,done.json}`, with `done.json` written only
// after the recorder exited 0 AND a container was found. A resumed run re-reads the plan,
// skips every transaction that has a `done.json`, and records the rest.
//
// The producer is re-run from scratch every time, deliberately. It is a handful of calls
// per block and one `eth_getProof` bisection, it has no partial state to keep, and caching
// its output would mean this file owning a second idea of when a published tree is stale.
// `--fresh` discards the work directory; nothing else in here deletes a recording.
//
// A `done.json` is NOT a claim that the recording is good, only that it finished: the
// producer re-reads every container through `ct-print` and re-parses every recorder log on
// every run, and a recording it cannot read is a refusal there rather than a silent skip
// here. That is the right split — this file knows whether the recorder ran, the producer
// knows whether what it wrote is publishable.
//
// ── WHY `--out` DOES NOT DEFAULT INTO `client/fixtures/chain/` ────────────────────────
//
// `capture-chain.mjs` defaults `--out` to `client/fixtures/chain/<chain>`, i.e. into the
// committed fixture tree. For Ethereum that path is refused: the tree would carry
// `ct/<hash>.ct`, and the `ban-added-ct-recordings` pre-commit hook refuses an ADDED `.ct`
// by name — correctly, because a committed recording pins a recorder version nothing
// tracks. Defaulting there would make this tool's first run fail for a reason that has
// nothing to do with what it does, so the default is `.eth-range/tree`, gitignored,
// alongside `.eth-capture/`.
//
// THE DEFAULT PATHS ARE RELATIVE AND THAT IS LOAD-BEARING, for the reason
// `tools/chain/eth-capture.sh` records: the recorder INTERNS its `--out-dir` into the
// container, so an absolute work directory makes the container's bytes host-specific. A
// repo-relative default keeps two machines' containers comparable. An operator who passes
// an absolute `--work` gets absolute interned paths, which is their choice to make.
//
// ── NO MOCKS ──────────────────────────────────────────────────────────────────────────
//
// There are none. The chain is read over JSON-RPC, the recorder is a real binary, the
// producer is the shipping one, and every figure this file prints is either read from one
// of those three or counted from its own plan.
//
// ── USAGE ─────────────────────────────────────────────────────────────────────────────
//
//   node tools/chain/capture-eth-range.mjs \
//     --recorder <path to codetracer-evm-recorder> \
//     --recorder-commit <sha of the checkout that built it> \
//     --from <block> --to <block>      | --depth <N>
//     [--max <N>]            cap on transactions to RECORD (default 6)
//     [--out <dir>]          the snapshot tree (default .eth-range/tree)
//     [--work <dir>]         kept recordings (default .eth-range/work)
//     [--url <rpc>]          the node (default https://eth.drpc.org)
//     [--ct-print <path>]    passed to the producer
//     [--plan]               print the plan and record nothing
//     [--fresh]              discard kept recordings first
//     [--source-fetch]       let the recorder ask Sourcify (off by default; see below)
//     [--no-skew-note]       passed to the producer
//
// Exit codes: 0 a tree was written · 1 the chain, the recorder or the producer refused ·
// 2 this invocation is wrong.
//
// `--source-fetch` is OFF by default for the reason `eth-capture.sh` gives at length:
// whether an address has verified source, and whether the matching solc is on this host,
// are both mutable inputs, so a capture that depends on them is not reproducible. Off, the
// attribution comes from the disassembly of the bytecode the chain served.

import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

const HERE = 'tools/chain/capture-eth-range.mjs';

/** This tool's one chain, named in its own source. Not a parameter over chains. */
const CHAIN_ID = 1;

/** The producer this drives, located from this file rather than from the cwd. */
const PRODUCER = resolve(dirname(new URL(import.meta.url).pathname),
                         'produce-eth-snapshot.mjs');

// ---------------------------------------------------------------------------
// refusals
// ---------------------------------------------------------------------------

// A FIELD AND NOT A CLASS, for the reason `produce-eth-snapshot.mjs` states where it makes
// the same choice: DEL-5's `test_no_abstraction_was_introduced` counts type hierarchies,
// and the exit code needs two kinds of refusal rather than two kinds of object.
const ConfigRefusal = 'config';
const SourceRefusal = 'source';
const refuse = (kind, message) => Object.assign(new Error(message), { refusalKind: kind });

const die = (e) => {
  console.error(`${HERE}: ${e.message}`);
  process.exit(e.refusalKind === ConfigRefusal ? 2 : 1);
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

const intFlag = (name, dflt) => {
  const raw = flag(name);
  if (raw === undefined) return dflt;
  const n = Number(raw);
  if (!Number.isInteger(n)) {
    throw refuse(ConfigRefusal, `--${name} must be an integer (got ${raw})`);
  }
  return n;
};

// ---------------------------------------------------------------------------
// JSON-RPC
// ---------------------------------------------------------------------------

/**
 * One JSON-RPC call, retried on a POLICY refusal and not on an ABSENCE.
 *
 * THE RETRY IS NOT OPTIONAL AND THE REASON IS THE SAME MEASUREMENT THE PRODUCER RECORDS:
 * the endpoint this instance was chosen on answers every archive probe in isolation and
 * then returns `HTTP 429 … Public endpoint rate limit` partway through a run. Enumerating a
 * range is many more calls than enumerating one block, so this file meets that limit
 * sooner than anything else here does — and a 429 read as "the endpoint cannot serve this
 * range" would be a wrong conclusion about a capability the endpoint has.
 *
 * It is NOT shared with the producer's copy. The two are eight lines of `fetch` and a sleep
 * each, in two tools that talk to the chain for different reasons; a shared client would be
 * a third module with two consumers whose only common ground is HTTP. DEL-7 NOTE: if a seam
 * is extracted from the two Ethereum tools, this is the least interesting candidate and the
 * most obvious one, which is a useful thing to have measured rather than argued.
 */
async function rpc(url, method, params, { retries = 12, backoffMs = 500 } = {}) {
  let last = 'no attempt was made';
  for (let attempt = 0; attempt <= retries; attempt++) {
    let http = 0;
    let body = null;
    let text = '';
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
      });
      http = res.status;
      text = await res.text();
      try { body = JSON.parse(text); } catch { /* reported as itself */ }
    } catch (e) {
      text = String(e);
    }
    if (http === 200 && body && body.result !== undefined) return body.result;
    const code = body?.error?.code ?? null;
    last = `http ${http} ${text.slice(0, 200)}`;
    // -32601 is "this method does not exist" and no amount of waiting creates it.
    if (code === -32601) break;
    if (attempt < retries) {
      const wait = backoffMs * (attempt + 1);
      // SAID OUT LOUD, because this is a tool to be watched and a silent pause of up to a
      // minute is indistinguishable from a hang. The task of reporting the rate limit is
      // the operator's, and they cannot report what the tool did not print.
      process.stderr.write(`   ${method} refused (${last.slice(0, 80)}); `
                           + `retry ${attempt + 1}/${retries} in ${wait}ms\n`);
      await new Promise((r) => setTimeout(r, wait));
    }
  }
  throw refuse(SourceRefusal, `${method} was refused by ${url}: ${last}`);
}

// ---------------------------------------------------------------------------
// child processes — rc read from the child, never from a pipeline
// ---------------------------------------------------------------------------

/**
 * Run a child, mirroring its output to this process's stderr AND to a log file, and
 * resolve with the CHILD'S OWN exit code.
 *
 * THE RC IS THE CHILD'S AND THE MIRRORING IS WHY THIS IS NOT A PIPELINE. The recorder's
 * stdout is two things at once: the operator's progress report while it runs, and the
 * input `produce-eth-snapshot.mjs` parses three published figures out of. A `tee` would
 * make the status this file reads the tee's, which is the failure
 * `tools/chain/eth-capture.sh` already documents having been bitten by — so the stream is
 * split in process and the code comes off the `close` event.
 */
function runChild(bin, args, { logPath = null, mirror = true } = {}) {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(bin, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    const chunks = [];
    const take = (buf) => {
      chunks.push(buf);
      if (mirror) process.stderr.write(buf);
    };
    child.stdout.on('data', take);
    child.stderr.on('data', take);
    child.on('error', rejectRun);
    child.on('close', (code, signal) => {
      const text = Buffer.concat(chunks).toString('utf8');
      if (logPath) writeFileSync(logPath, text);
      resolveRun({ code: code === null ? 128 : code, signal, text });
    });
  });
}

// ---------------------------------------------------------------------------
// the plan
// ---------------------------------------------------------------------------

/**
 * Every transaction in the window, in the order a budget should be spent on them.
 *
 * `candidates` is the measured population — one entry per transaction in every enumerated
 * block, in chain order — and `queue` is the same list reordered (index asc, block asc).
 * Both are returned because the ratio between them is the figure that says what a budget
 * bought, and a tool that printed only the second could not tell an operator that a range
 * held 1,700 transactions.
 */
function planFrom(blocks, max) {
  const candidates = [];
  for (const b of blocks) {
    b.txs.forEach((h, i) => candidates.push({
      txHash: h, blockNumber: b.number, txIndex: i, preceding: i,
    }));
  }
  const queue = [...candidates]
    .sort((a, b) => a.txIndex - b.txIndex || a.blockNumber - b.blockNumber)
    .slice(0, max);
  // Shown and recorded in chain order, which is the order a developer reads a range in.
  queue.sort((a, b) => a.blockNumber - b.blockNumber || a.txIndex - b.txIndex);
  return { candidates, queue };
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

async function main() {
  const recorder = flag('recorder');
  const recorderCommit = flag('recorder-commit');
  const url = flag('url', 'https://eth.drpc.org');
  const outDir = flag('out', '.eth-range/tree');
  const workDir = flag('work', '.eth-range/work');
  const max = intFlag('max', 6);
  const depth = intFlag('depth', undefined);
  const from = intFlag('from', undefined);
  const to = intFlag('to', undefined);
  const planOnly = has('plan');
  const fresh = has('fresh');
  const sourceFetch = has('source-fetch');
  const ctPrint = flag('ct-print');

  if (!recorder) {
    throw refuse(ConfigRefusal,
      '--recorder <path to codetracer-evm-recorder> is required. This repository carries '
      + 'no EVM and does not build the recorder; it is a Rust build in the '
      + '`codetracer-evm-recorder` sibling.');
  }
  if (!existsSync(recorder)) {
    throw refuse(ConfigRefusal, `no recorder at ${recorder}`);
  }
  if (!recorderCommit) {
    // THE SAME REFUSAL `just eth-capture` MAKES, AND FOR THE SAME REASON. It is published
    // into every row's `runtimeCommit`, nothing can read it off the binary
    // (`--version` answers `0.1.0`), and a default of `git -C ../codetracer-evm-recorder
    // rev-parse HEAD` would be silently WRONG — not absent — for a binary built in a
    // worktree or before a pull.
    throw refuse(ConfigRefusal,
      '--recorder-commit <sha> is required. It is the commit of the checkout that BUILT '
      + 'the binary, it is published into every row\'s `runtimeCommit`, and nothing here '
      + 'can read it off the binary.');
  }
  if (!Number.isInteger(max) || max < 1) {
    throw refuse(ConfigRefusal,
      `--max must be a positive integer (got ${max}). A capture that records nothing is `
      + `an enumeration, and \`--plan\` is the way to ask for one.`);
  }
  if ((from === undefined) !== (to === undefined)) {
    throw refuse(ConfigRefusal,
      `--from and --to are given together or not at all (got from=${from} to=${to}).`);
  }
  if (from === undefined && depth === undefined) {
    throw refuse(ConfigRefusal,
      'the range is required: either --from <block> --to <block>, or --depth <N> for the '
      + 'N blocks ending at the finalized head.');
  }
  if (from !== undefined && depth !== undefined) {
    throw refuse(ConfigRefusal,
      `--from/--to and --depth both state a range (from=${from} to=${to} depth=${depth}) `
      + `and this tool will not pick one of two stated ranges.`);
  }
  if (depth !== undefined && (!Number.isInteger(depth) || depth < 1)) {
    throw refuse(ConfigRefusal, `--depth must be a positive integer (got ${depth})`);
  }

  // ── the chain ────────────────────────────────────────────────────────────
  const chainId = parseInt(await rpc(url, 'eth_chainId', []), 16);
  if (chainId !== CHAIN_ID) {
    throw refuse(ConfigRefusal,
      `${url} serves chain id ${chainId} and this capture is Ethereum mainnet `
      + `(${CHAIN_ID}). It names one chain in its own source: there is no dispatch here to `
      + `widen, and a second EVM instance is a second capture.`);
  }
  const tip = parseInt(await rpc(url, 'eth_blockNumber', []), 16);
  const finalized = parseInt(
    (await rpc(url, 'eth_getBlockByNumber', ['finalized', false])).number, 16);

  let lo;
  let hi;
  if (depth !== undefined) {
    hi = finalized;
    lo = finalized - depth + 1;
    if (lo < 0) {
      throw refuse(ConfigRefusal,
        `--depth ${depth} reaches below block 0 from the finalized head ${finalized}.`);
    }
  } else {
    lo = from;
    hi = to;
    if (lo < 0 || hi < lo) {
      throw refuse(ConfigRefusal, `--from ${from} --to ${to} is not an ascending range.`);
    }
    if (hi > tip) {
      throw refuse(SourceRefusal,
        `--to ${hi} is above this endpoint's tip ${tip}; there is no such block yet.`);
    }
  }

  console.error(`${HERE}`);
  console.error(`  endpoint   ${url} · chain id ${chainId}`);
  console.error(`  tip        ${tip} · finalized ${finalized} (gap ${tip - finalized})`);
  console.error(`  range      ${lo}..${hi} (${hi - lo + 1} block(s))`
                + `${depth !== undefined ? ` — from --depth ${depth}, anchored on the `
                  + `finalized head because a block above it can still reorg out` : ''}`);
  // ABOVE-FINALIZED IS STATED AND NOT REFUSED, for a range the operator named by number.
  if (hi > finalized) {
    console.error(`  NOTE       ${hi - finalized} block(s) of this range are ABOVE the `
                  + `finalized head ${finalized} and can still reorg out. A recording of a `
                  + `reorged-out transaction is a recording of a transaction that is not on `
                  + `the chain; --depth would have stopped at ${finalized}.`);
  }

  // ── the enumeration ──────────────────────────────────────────────────────
  //
  // ONE CALL PER BLOCK, with `false` for the transaction detail: the plan needs hashes and
  // their positions and nothing else. The producer re-enumerates with receipts and full
  // transaction objects because a published ROW needs those; this does not, and fetching
  // them here would double the enumeration cost to build a list that is thrown away.
  // THE PROGRESS LINE REWRITES ITSELF ON A TERMINAL AND SCROLLS IN A LOG. A `\r` written
  // into a redirected file leaves every block's line concatenated onto one unreadable
  // line, and this tool's output is read both ways — watched while it runs, and read back
  // afterwards out of a log. So the carriage return is conditional on `isTTY` rather than
  // unconditional, and a non-terminal gets one line per block.
  const tty = process.stderr.isTTY === true;
  const blocks = [];
  for (let n = lo; n <= hi; n++) {
    process.stderr.write(tty
      ? `\r  enumerate  block ${n} (${n - lo + 1}/${hi - lo + 1})   `
      : `  enumerate  block ${n} (${n - lo + 1}/${hi - lo + 1})\n`);
    // eslint-disable-next-line no-await-in-loop
    const b = await rpc(url, 'eth_getBlockByNumber', [`0x${n.toString(16)}`, false]);
    if (!b) throw refuse(SourceRefusal, `${url} does not know block ${n}`);
    blocks.push({ number: n, txs: b.transactions.map((h) => h.toLowerCase()) });
  }
  if (tty) process.stderr.write('\r');
  const { candidates, queue } = planFrom(blocks, max);
  console.error(`  enumerated ${blocks.length} block(s), ${candidates.length} `
                + `transaction(s)`);
  if (candidates.length === 0) {
    throw refuse(SourceRefusal,
      `blocks ${lo}..${hi} hold no transactions at all, so there is nothing to record and `
      + `a tree over them would have no traced row. Ask for a different range.`);
  }
  console.error(`  budget     --max ${max} => ${queue.length} to record, `
                + `${candidates.length - queue.length} enumerated and not recorded`);
  console.error('');
  console.error('  PLAN — cheapest first (index ascending, then block), shown in chain order:');
  for (const q of queue) {
    console.error(`    ${String(q.blockNumber).padStart(9)}:${String(q.txIndex).padStart(3)}`
                  + `  ${q.txHash}  ${q.preceding} preceding replay(s)`);
  }
  console.error(`    total preceding replays this plan costs: `
                + `${queue.reduce((n, q) => n + q.preceding, 0)}`);
  console.error('');

  if (planOnly) {
    console.error('  --plan: nothing was recorded.');
    return;
  }

  // ── the recordings, resumably ────────────────────────────────────────────
  const work = workDir;
  if (fresh && existsSync(work)) {
    console.error(`  --fresh: discarding ${work}`);
    rmSync(work, { recursive: true, force: true });
  }
  const recRoot = join(work, 'rec');
  mkdirSync(recRoot, { recursive: true });

  /** The container in a finished recording's capture directory, or null. */
  const containerIn = (dir) => {
    const found = [];
    const walk = (d) => {
      if (!existsSync(d)) return;
      for (const e of readdirSync(d, { withFileTypes: true })) {
        const p = join(d, e.name);
        if (e.isDirectory()) walk(p);
        else if (e.name.endsWith('.ct')) found.push(p);
      }
    };
    walk(dir);
    return found.length === 1 ? found[0] : null;
  };

  const started = Date.now();
  let recorded = 0;
  let resumed = 0;
  for (const q of queue) {
    const dir = join(recRoot, q.txHash);
    const capture = join(dir, 'capture');
    const log = join(dir, 'run.log');
    const done = join(dir, 'done.json');
    const n = `${recorded + resumed + 1}/${queue.length}`;

    // A FINISHED RECORDING IS SKIPPED, AND "FINISHED" IS BOTH HALVES: the marker exists AND
    // the container it claims is still there. A marker alone would let a half-deleted work
    // directory resume into a producer call that refuses, which is a worse failure than
    // re-recording — it happens later and names the producer.
    if (existsSync(done) && existsSync(log) && containerIn(capture)) {
      const m = JSON.parse(readFileSync(done, 'utf8'));
      console.error(`  [${n}] RESUME  ${q.blockNumber}:${q.txIndex} ${q.txHash} `
                    + `— recorded ${m.recordedAt}, kept`);
      resumed++;
      continue;
    }

    // A STALE OR PARTIAL ATTEMPT IS REMOVED BEFORE RETRYING, so the recorder's `--out-dir`
    // cannot end up holding two containers — which the producer refuses by name, correctly.
    rmSync(dir, { recursive: true, force: true });
    mkdirSync(capture, { recursive: true });

    console.error(`  [${n}] RECORD  ${q.blockNumber}:${q.txIndex} ${q.txHash} `
                  + `(${q.preceding} preceding replay(s))`);
    const args = ['trace-onchain', q.txHash, '--rpc-url', url, '--out-dir', capture];
    if (!sourceFetch) args.push('--skip-source-fetch');
    const t0 = Date.now();
    // eslint-disable-next-line no-await-in-loop
    const r = await runChild(recorder, args, { logPath: log });
    const secs = ((Date.now() - t0) / 1000).toFixed(1);

    // THE RECORDER'S OWN RC, and a failure STOPS the run rather than thinning the plan.
    //
    // Continuing past it was the other option and is the wrong one here: every untraced row
    // in the published tree carries the sentence "a run with a wider budget traces it", and
    // a transaction this run TRIED and failed to record is not that. Rather than publish a
    // row whose stated reason is false, the run stops with the failure named — and because
    // every recording before it is kept, re-running resumes from here instead of repeating
    // them.
    if (r.code !== 0) {
      throw refuse(SourceRefusal,
        `the recorder exited ${r.code}${r.signal ? ` on ${r.signal}` : ''} on `
        + `${q.txHash} (block ${q.blockNumber} index ${q.txIndex}); its output is in `
        + `${log}. ${recorded} recording(s) from this run are kept in ${recRoot}, so `
        + `re-running resumes from this transaction. No tree was written: a tree whose `
        + `untraced rows say "a run with a wider budget traces it" must not include a `
        + `transaction this run tried and could not record.`);
    }
    const container = containerIn(capture);
    if (!container) {
      throw refuse(SourceRefusal,
        `the recorder exited 0 on ${q.txHash} and left no single container in ${capture}. `
        + `Its output is in ${log}.`);
    }
    writeFileSync(done, `${JSON.stringify({
      txHash: q.txHash,
      blockNumber: q.blockNumber,
      txIndex: q.txIndex,
      precedingReplays: q.preceding,
      recorder,
      recorderCommit,
      endpoint: url,
      container,
      containerBytes: readFileSync(container).length,
      seconds: Number(secs),
      recordedAt: new Date().toISOString(),
    }, null, 1)}\n`);
    recorded++;
    console.error(`          ok in ${secs}s — ${container} `
                  + `(${readFileSync(container).length} bytes)`);
  }

  console.error('');
  console.error(`  recordings ${recorded} made, ${resumed} resumed, ${queue.length} total `
                + `in ${((Date.now() - started) / 1000).toFixed(1)}s`);

  // ── the tree, from the producer that knows the contract ──────────────────
  const producerArgs = [PRODUCER,
                        '--rpc-url', url,
                        '--recorder-commit', recorderCommit,
                        '--from', String(lo), '--to', String(hi),
                        '--out', outDir];
  for (const q of queue) {
    producerArgs.push('--tx', q.txHash,
                      '--capture', join(recRoot, q.txHash, 'capture'),
                      '--recorder-log', join(recRoot, q.txHash, 'run.log'));
  }
  if (ctPrint) producerArgs.push('--ct-print', ctPrint);
  if (has('no-skew-note')) producerArgs.push('--no-skew-note');

  // ── THE OUTPUT TREE IS REPLACED, NOT ADDED TO ────────────────────────────
  //
  // The producer writes into `--out` with `mkdirSync({recursive: true})` and overwrites the
  // objects of the recordings it was given. It does not — and should not — delete anything,
  // so a second run with a SMALLER plan over the same `--out` would leave the first run's
  // `ct/<hash>.ct`, `positions/<hash>.json` and the rest sitting beside a `snapshot.json`
  // that no longer mentions them. Orphans in a published tree are the kind of thing that
  // reads as a tree holding more traces than it has, and the counts cannot see them because
  // `counts` is derived from the ROWS.
  //
  // So the caller that knows the plan clears the directory. IT WILL ONLY CLEAR A TREE IT
  // RECOGNISES: an absent path, an empty directory, or one holding a `snapshot.json` whose
  // `format` is the snapshot token. Anything else is refused by name rather than deleted —
  // `--out` is a path a developer typed, and a tool that recursively removes whatever it is
  // pointed at is one bad tab-completion away from being the worst thing in this directory.
  if (existsSync(outDir)) {
    const marker = join(outDir, 'snapshot.json');
    const entries = readdirSync(outDir);
    let recognised = entries.length === 0;
    if (!recognised && existsSync(marker)) {
      try {
        recognised = String(JSON.parse(readFileSync(marker, 'utf8')).format ?? '')
          .startsWith('blocktracer/chain-snapshot@');
      } catch { recognised = false; }
    }
    if (!recognised) {
      throw refuse(ConfigRefusal,
        `${outDir} exists and is not a snapshot tree this tool can replace: it holds `
        + `${entries.length} entr(ies) and no \`snapshot.json\` stating a `
        + `\`blocktracer/chain-snapshot@…\` format. A run that merely wrote INTO it would `
        + `leave whatever is already there beside a snapshot that does not mention it, and `
        + `a run that cleared it would delete a directory this tool did not create. Point `
        + `--out somewhere else, or empty it yourself.`);
    }
    rmSync(outDir, { recursive: true, force: true });
  }

  console.error('');
  console.error(`  produce    ${PRODUCER} -> ${outDir}`);
  const p = await runChild(process.execPath, producerArgs);
  if (p.code !== 0) {
    throw refuse(p.code === 2 ? ConfigRefusal : SourceRefusal,
      `the producer exited ${p.code}; no tree was written. Every recording is kept in `
      + `${recRoot}, so re-running after a fix records nothing again.`);
  }

  console.error('');
  console.error(`  DONE — ${outDir}`);
  console.error(`    inspect it:  cat ${join(outDir, 'snapshot.json')} | head -40`);
  console.error(`    verify it:   conformance-kit-release/bin/blocktracer-conformance `
                + `--snapshot ${outDir}`);
}

main().catch(die);
