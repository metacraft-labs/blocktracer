// replay.mjs — the ONE implementation of "did this transaction replay, and may the
// recording be used as evidence".
//
// WHY THIS IS A MODULE AND NOT TWO COPIES. `capture-chain.mjs` (the one-shot scan) and
// `follow-chain.mjs` (the follower) both have to decide the same three-way question, and
// the answer is subtle enough that a second spelling of it would drift. This repository
// has already paid for a restatable condition once: `costLabel` guarded the cost join and
// `txMetadataRows` spelled the same join a second time without the guard, and ten of
// twelve reviewers filed the dangling separator that produced. The finding recorded then
// applies here verbatim — "what was wrong was never the condition, it was that the
// condition was restatable at all".
//
// THE RULE, stated once:
//
//   1. A NON-ZERO EXIT IS NOT THE SAME QUESTION AS "DID IT REPLAY". The driver exits 1
//      when the replay's effects do not reproduce the block's — and still completes the
//      execution, still writes the container, and still prints its full report on stdout.
//      So the REPORT decides, and the exit code is consulted only when there is no report.
//      Reading the exit code alone once filed a transaction that matched 11 of 13 effects
//      as `refusal: unknown` with a truncated line of stderr for a reason.
//
//   2. NO REPORT ⇒ REFUSAL, by name. The runtime names its refusals; the row keeps the
//      name, so the snapshot says which transaction could not be replayed and why rather
//      than silently omitting it.
//
//   3. A REPORT WITH NO CONTAINER ON DISK IS A REFUSAL, not a replay. The driver claimed
//      success and wrote nothing; publishing a row that points at a missing container
//      would be worse than saying so.
//
//   4. REPRODUCED OR NOT, THE RECORDING IS REAL AND IT STEPS. The distinction the explorer
//      needs is not "did this work" but "may this be used as evidence of what the chain
//      did", and those are different answers. A divergent trace is a correct recording of
//      an execution that disagreed with the block: a thing worth showing, and a thing that
//      must never be shown silently. It is `divergent` — which the client renders as
//      `taDivergent` behind a non-dismissible banner — and it is NOT a refusal.
//
// What this module will never do is manufacture a verdict. There is no path here that
// produces `replayed` without a driver report whose own `verdict.reproduced` is true, and
// no path that publishes a container the driver did not write.

import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

/** Run a command to completion, capturing both streams. Never rejects: the caller's
 *  decision is made from the streams, and a spawn failure is reported as an empty
 *  report with a non-zero code, which rule 2 turns into a named refusal. */
export function run(cmd, args, cwd) {
  return new Promise((res) => {
    const p = spawn(cmd, args, { cwd, env: { ...process.env } });
    let out = '';
    let err = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { err += d; });
    p.on('error', (e) => res({ code: -1, out, err: `${err}\nspawn: ${e.message}` }));
    p.on('close', (code) => res({ code, out, err }));
  });
}

/** The refusal name, extracted from the driver's stderr.
 *
 *  Exported because the selftest asserts against it directly: a refusal whose name is
 *  `unknown` when the runtime did name it is the failure mode this whole path exists to
 *  prevent, and it is only visible if the extraction is testable on its own. */
export function refusalName(stderr) {
  const m = String(stderr ?? '').match(
    /^\s*([A-Z][A-Za-z]+(?:Error|Unavailable|NotFound|Unsupported|Regression|Exceeded)):?.*$/m);
  return m ? m[1] : 'unknown';
}

/** Decide the outcome from what the driver produced.
 *
 *  Split out from the spawning so it can be driven with recorded driver output — the
 *  selftest exercises every branch of rules 1-4 without a node, a chain or an AVM, which
 *  is the only way each arm can be shown to redden on its own.
 *
 *  @param {object}  r              `{ code, out, err }` from `run`
 *  @param {string}  ctPath         where the container was asked for
 *  @param {boolean} containerOnDisk whether it is actually there
 *  @param {number}  containerBytes  its size, measured (0 when absent)
 */
export function decideOutcome(r, ctPath, containerOnDisk, containerBytes) {
  // Rule 1: the report decides.
  let facts = null;
  try { facts = JSON.parse(r.out); } catch { /* fall through to rule 2 */ }

  // Rule 2: no report ⇒ a named refusal.
  if (facts === null || typeof facts !== 'object' || facts.verdict == null) {
    const why = refusalName(r.err);
    return {
      replayed: false,
      outcome: 'refused',
      refusal: why,
      reason: `This transaction could not be re-executed: the replay runtime refused with `
        + `${why}. No trace was recorded for it.`,
      detail: String(r.err ?? '').trim().split('\n').slice(-3).join(' ').slice(0, 400),
    };
  }

  // Rule 3: a report that points at a container which is not there is a refusal.
  if (!containerOnDisk) {
    return {
      replayed: false,
      outcome: 'refused',
      refusal: 'no-container-written',
      reason: `The replay runtime reported a completed execution and wrote no container, `
        + `so there is nothing to step. No trace was recorded for it.`,
      detail: 'the driver reported success and wrote no container',
    };
  }

  // Rule 4: reproduced or not, the recording is real. `reproduced` is read from the
  // driver's own verdict and is never inferred from the absence of mismatches — a run
  // that compared nothing would otherwise present as a clean reproduction.
  const kind = facts.verdict.reproduced === true ? 'replayed' : 'divergent';
  return {
    replayed: true,
    outcome: kind,
    kind,
    container: ctPath,
    containerBytes,
    l2BlockNumber: facts.l2BlockNumber,
    txIndexInBlock: facts.txIndexInBlock,
    preStateReadAt: facts.preStateReadAt,
    contractReferenceBlock: facts.contractReferenceBlock,
    hydrationRounds: facts.rounds,
    seedSize: facts.seedSize,
    instructionsExecuted: facts.instructionsExecuted,
    publishedRevertCode: facts.published?.revertCode,
    replayedRevertCode: facts.replayed?.revertCode,
    // The effect comparison, whole. `reproduced` alone would hide a run that matched
    // nothing because it compared nothing.
    effects: {
      reproduced: facts.verdict.reproduced === true,
      matched: facts.verdict.matched,
      mismatched: facts.verdict.mismatched,
      mismatches: facts.mismatches ?? [],
    },
    // The recording's own account of its fidelity. `declaredRung: 3` is the ceiling a
    // chain contract can reach: `ContractClassPublic` carries no debug_symbols, no
    // file_map and no source text, so there is nothing to position a program counter
    // against. `stepsPositioned` proves that rather than asserting it.
    recording: facts.recording,
    // The roots deliberately do not agree, and the divergence travels with the recording:
    // replay hydrates only the leaves the execution touched, so the trees it rebuilds are
    // sparse and their roots cannot equal the block's. Dropping this in transit would turn
    // a known, explained difference into an unexplained one.
    roots: facts.roots,
    rootsAnyAgree: facts.rootsAnyAgree,
    skipped: facts.skipped ?? [],
  };
}

/** Replay one settled transaction and decide its outcome.
 *
 *  `ctRelative` is what the row will carry (e.g. `ct/0xabc….ct`); `ctPath` is where the
 *  driver is told to write. The two are separate because the snapshot is committed and
 *  must not carry an absolute path from whoever ran the capture. */
export async function replayTransaction({
  nodeBin, runtime, url, txHash, ctPath, ctRelative, avm, ctWriter,
}) {
  const r = await run(nodeBin, [
    '--experimental-wasm-exnref',
    'replay/tools/replay_settled_transaction.mjs',
    '--url', url,
    '--tx', txHash,
    '--module', resolve(avm),
    '--ct', ctPath,
    '--ct-writer', resolve(ctWriter),
    '--json',
  ], runtime);

  const onDisk = existsSync(ctPath);
  const bytes = onDisk ? (await readFile(ctPath)).length : 0;
  const decided = decideOutcome(r, ctRelative ?? ctPath, onDisk, bytes);
  if (decided.replayed) decided.container = ctRelative ?? ctPath;
  return decided;
}
