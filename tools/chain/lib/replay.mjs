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
 *  prevent, and it is only visible if the extraction is testable on its own.
 *
 *  WAS A SUFFIX ALLOWLIST, AND THE ALLOWLIST WAS THE BUG. The previous rule accepted a
 *  name only if it ended in `Error`, `Unavailable`, `NotFound`, `Unsupported`,
 *  `Regression` or `Exceeded` — six suffixes, each of which had been added when a
 *  particular class was seen to fail. Measured against the 92 error classes the replay
 *  runtime actually defines, that rule classified 43 and returned `unknown` for the other
 *  FORTY-NINE, including `AvmTrap`, `HydrationDidNotConverge`, `RecordingPassDiverged`,
 *  `TxSimAppLogicRevert`, `TxSimTeardownRevert` and `WasiProcExit` — every one of them a
 *  plausible verdict on a live public transaction. Two mainnet catches on 2026-08-31
 *  (0x09a4747d at 67798, 0x2dd44ab6 at 67802) were filed as `refusal: "unknown"` by it,
 *  and both bodies have since pruned, so what refused them is now unknowable.
 *
 *  A list of the endings seen so far can only ever name the refusals that have already
 *  cost something. The name is therefore recognised BY SHAPE instead: Node prints an
 *  uncaught throw as `Name: message` on a line of its own, and an error class is a
 *  PascalCase identifier. Anything shaped that way is a name, whatever it ends in, so a
 *  class the runtime gains tomorrow is classified without this file being edited. */
const NAMED_LINE = /^\s*([A-Z][A-Za-z0-9_]{2,}):\s+\S/;

/** Node echoes the throwing SOURCE LINE above the message, and an object literal in it
 *  (`  Foo: bar,`) is shaped like a message. Source echoes end in an opener or a comma,
 *  or carry an arrow; messages do not. */
const looksLikeSource = (l) => /=>|[,({]\s*$/.test(l);

export function refusalName(stderr) {
  for (const raw of String(stderr ?? '').split('\n')) {
    const line = raw.trimEnd();
    if (looksLikeSource(line)) continue;
    const m = line.match(NAMED_LINE);
    if (!m) continue;
    // `(node:123) ExperimentalWarning: ...` is excluded by the leading `(`, but a bare
    // warning line would not be, and a warning is not a refusal.
    if (/Warning$/.test(m[1])) continue;
    return m[1];
  }
  return 'unknown';
}

/** The informative part of a refusal's stderr.
 *
 *  WAS `split('\n').slice(-3)`, AND THAT WAS BACKWARDS. A Node stack trace ends with the
 *  interpreter's own banner, so the last three lines of a real refusal were
 *  `"}  Node.js v24.19.0"` — which is what the first two mainnet catches recorded, in a
 *  field whose entire job is to say what went wrong. The refusal NAME survived, so the
 *  row was not wrong, merely useless at the moment it was most needed.
 *
 *  The message is at the TOP of a thrown error's output, not the bottom. This anchors on
 *  the named line and keeps it plus what follows, and falls back to the leading
 *  non-empty lines rather than the trailing ones.
 *
 *  AND THE FALLBACK WAS STILL BLIND, for a reason the swing from `-3` to `+3` did not
 *  touch. The fallback runs exactly when the name is `unknown` — the one case where the
 *  detail is the only thing left that could explain the loss — and it takes the first
 *  three non-noise lines. The replay driver opens EVERY run with exactly three lines that
 *  are not noise by the old rule:
 *
 *      (node:42017) ExperimentalWarning: WASI is an experimental feature ...
 *      (Use `node --trace-warnings ...` to show where the warning was created)
 *      replay: 0x… via https://aztec.drpc.org
 *
 *  Three lines of preamble against a three-line budget, so the fallback could never reach
 *  the error, whatever it was. That is not a near miss: it is the field being structurally
 *  incapable of its job. Both mainnet transactions that recorded `refusal: "unknown"`
 *  recorded precisely this preamble as their `detail`, and the string is identical for
 *  both because it contains nothing about either.
 *
 *  So the preamble is noise, and so are the source-location echo, the caret and the
 *  echoed `throw` line that Node prints above a message. The `replay:` filter is
 *  deliberately narrow — it matches the driver's three known progress forms and not the
 *  early-exit lines like `replay: no first-in-block transaction …`, which ARE diagnoses. */
export function refusalDetail(stderr, name) {
  const lines = String(stderr ?? '').split('\n').map((l) => l.trimEnd());
  const isNoise = (l) =>
    l.trim().length === 0 ||
    /^Node\.js v\d/.test(l.trim()) ||
    /^\s*at\s/.test(l) ||
    /^[{}\s]*$/.test(l) ||
    /^\s*\^+\s*$/.test(l) ||            // the caret under a source echo
    /^\(node:\d+\)/.test(l) ||          // (node:42017) ExperimentalWarning: …
    /^\(Use `node/.test(l) ||           // its continuation line
    /^file:\/\//.test(l) ||             // the source-location echo above a message
    /^\s*throw new /.test(l) ||         // the echoed throwing line
    /^replay: (0x|round |tip )/.test(l); // the driver's own progress chatter
  // The MESSAGE line, not the first line that happens to contain the name. Node echoes the
  // throwing source line above the message — `    throw new AvmToolchainRegression(` — so a
  // plain `includes` anchors on the code that raised rather than on what it said. The
  // message is the line where the name is followed by a colon at the start of the line.
  const named = new RegExp(`^${name}\\b\\s*:`);
  let start = name && name !== 'unknown'
    ? lines.findIndex((l) => named.test(l.trim()))
    : -1;
  if (start < 0 && name && name !== 'unknown') {
    start = lines.findIndex((l) => l.includes(name) && !/\bthrow\b|\bnew\b/.test(l));
  }
  const picked = [];
  if (start >= 0) {
    for (let i = start; i < lines.length && picked.length < 3; i++) {
      if (!isNoise(lines[i])) picked.push(lines[i].trim());
    }
  }
  if (picked.length === 0) {
    for (const l of lines) {
      if (picked.length >= 3) break;
      if (!isNoise(l)) picked.push(l.trim());
    }
  }
  return picked.join(' ').slice(0, 400);
}

/** How many blocks in this snapshot are COMPLETE — every transaction the chain put in the
 *  block has a reproduced replay.
 *
 *  WHY THIS AND NOT A COUNT OF REPLAYS. The demo's bar is a whole block that steps, not a
 *  transaction that steps: a block page showing three transactions of which one has a trace
 *  is an overclaim of exactly the kind this campaign exists to prevent. Counting replays
 *  would reach a target of "3" on three transactions drawn from three different half-covered
 *  blocks, and every one of those blocks would render incomplete.
 *
 *  IT MEASURES AGAINST THE CHAIN'S OWN LIST. `block.transactions` is written from the
 *  node's `txEffects` for that block — every transaction the chain put in it, including the
 *  ones this tool declined to attempt (`not-first-in-block`, `pruned`). So a block only
 *  counts when nothing in it is unaccounted for. A definition that instead ranged over the
 *  transactions the follower CHOSE would be satisfied by choosing fewer, which is the
 *  vacuity trap in another costume.
 *
 *  `divergent` does not count. A divergent recording is real and worth showing, but it did
 *  not reproduce the block, and "every transaction in this block replays" would be false. */
export function completeBlockCount(snap) {
  const outcome = new Map((snap?.transactions ?? []).map((t) => [t.txHash, t.outcome]));
  let n = 0;
  for (const b of snap?.blocks ?? []) {
    const hashes = b?.transactions ?? [];
    if (hashes.length === 0) continue;            // an empty block is not a captured block
    if (hashes.every((h) => outcome.get(h) === 'replayed')) n++;
  }
  return n;
}

/** The complete blocks themselves, newest first — for a log line that names what it has. */
export function completeBlockNumbers(snap) {
  const outcome = new Map((snap?.transactions ?? []).map((t) => [t.txHash, t.outcome]));
  return (snap?.blocks ?? [])
    .filter((b) => (b?.transactions ?? []).length > 0
      && b.transactions.every((h) => outcome.get(h) === 'replayed'))
    .map((b) => b.number)
    .sort((a, b) => b - a);
}

/** Prove the replay toolchain works BEFORE starting to wait for a rare event.
 *
 *  WHY THIS EXISTS, and it is the most expensive lesson this tool has taught. The follower
 *  caught two live mainnet transactions on 2026-08-31 — 67648 and 67650, inside the window
 *  with 30 and 32 blocks of headroom, bodies retained, exactly what it was built to do —
 *  and refused both with `AvmToolchainRegression`, because `--avm` pointed at
 *  `vm2wasm/avm.wasm`. That is M6's early spike artefact: it OWNS its memory, and this host
 *  is for `--import-memory` modules, so the runtime named the refusal and declined. The
 *  configuration was wrong from the first minute of the watch.
 *
 *  A catch is RARE and UNREPEATABLE. Mainnet transactions arrive 25 to 142 blocks apart and
 *  the body prunes about thirty minutes after it lands, so a misconfiguration discovered at
 *  catch time does not cost a retry — it costs the transaction, permanently. Everything a
 *  watch can check about itself, it must check before it starts watching.
 *
 *  IT ASKS THE RUNTIME RATHER THAN RESTATING ITS RULE. The memory-import gate belongs to
 *  `node-host`'s loader and lives there; a second copy in this repository would be a rule
 *  that could drift out of agreement with the one that actually decides. So the preflight
 *  imports `compileAvm` and calls it. If the loader ever gains a condition, this gains it
 *  too, for free.
 */
export async function preflightToolchain({ nodeBin, runtime, avm, ctWriter }) {
  const problems = [];
  for (const [what, p] of [['avm', avm], ['ct-writer', ctWriter]]) {
    if (!existsSync(p)) problems.push(`${what} path does not exist: ${p}`);
  }
  if (problems.length) return { ok: false, problems };

  const loader = resolve(runtime, 'node-host/src/loader.ts');
  if (!existsSync(loader)) {
    // Not fatal: a runtime layout this tool does not recognise should not stop a watch that
    // might still work. It is reported, so a refusal later is not a surprise.
    return { ok: true, problems: [], note: `no ${loader} — module gate not pre-checked` };
  }
  const script =
    `import(${JSON.stringify('file://' + loader)}).then(async (L) => {` +
    `try { const c = await L.compileAvm(${JSON.stringify(avm)});` +
    ` console.log('PREFLIGHT_OK ' + c.declaredImports.length); }` +
    ` catch (e) { console.log('PREFLIGHT_REFUSED ' + e.constructor.name + ' :: ' +` +
    ` String(e.message).split('\\n')[0]); } })` +
    `.catch((e) => console.log('PREFLIGHT_UNAVAILABLE ' + String(e.message).split('\\n')[0]));`;
  const r = await run(nodeBin, ['--experimental-wasm-exnref', '-e', script], runtime);
  const out = `${r.out}`.trim();
  const line = out.split('\n').find((l) => l.startsWith('PREFLIGHT_')) ?? '';
  if (line.startsWith('PREFLIGHT_OK')) {
    return { ok: true, problems: [], note: `avm module accepted (${line.split(' ')[1]} imports)` };
  }
  if (line.startsWith('PREFLIGHT_REFUSED')) {
    return { ok: false, problems: [`the replay runtime refuses this --avm module: ` +
      line.slice('PREFLIGHT_REFUSED '.length)] };
  }
  // The probe itself could not run. Reported, never fatal — see the note above.
  return { ok: true, problems: [],
           note: `module gate not pre-checked (${line || out.slice(0, 160) || 'no output'})` };
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
      detail: refusalDetail(r.err, why),
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
    // THE RECORDING'S OWN ACCOUNT OF ITS FIDELITY, COPIED THROUGH UNTOUCHED.
    //
    // THIS COMMENT USED TO SAY "`declaredRung: 3` is the ceiling a chain contract can
    // reach", and that sentence was wrong in one word. `ContractClassPublic` really does
    // carry no debug_symbols, no file_map and no source text — so rung 3 is the ceiling
    // reachable FROM THE NODE — but upstream's `artifactHash` exists precisely so a client
    // can verify an artifact fetched from somewhere else, and the runtime's
    // `replay/src/artifact_resolution.ts` does that: it proves a candidate artifact against
    // the class's `artifactHash`, byte-compares its public bytecode against the class's
    // `packedBytecode`, and recomputes the class id from both. A contract whose artifact is
    // proved that way records at rung 1 with real Noir positions.
    //
    // So `declaredRung`, `sourceLevel` and `contractRungs` are the runtime's measurements
    // and nothing here decides them. `stepsPositioned` remains what keeps the claim honest
    // in both directions: a page must not render source over a container whose steps are
    // unpositioned, and must not withhold it from one whose steps are.
    recording: facts.recording,
    // THE RESOLUTION ITSELF, INCLUDING EVERY REJECTION. "we did not look" and "we looked
    // and proved nothing" are different sentences for a transaction page to say, and a
    // snapshot that recorded only the successes could not tell them apart. `ingest.nim`
    // also builds this transaction's code edges from here, which is why UNRESOLVED entries
    // are kept: a code edge is a fact about what the transaction executed, not about
    // whether source was found for it.
    artifacts: facts.artifacts ?? [],
    // The roots deliberately do not agree, and the divergence travels with the recording:
    // replay hydrates only the leaves the execution touched, so the trees it rebuilds are
    // sparse and their roots cannot equal the block's. Dropping this in transit would turn
    // a known, explained difference into an unexplained one.
    roots: facts.roots,
    rootsAnyAgree: facts.rootsAnyAgree,
    skipped: facts.skipped ?? [],
  };
}

/** How many bundles a driver-written source file actually carries.
 *
 *  Read back rather than assumed. `ingest.nim` refuses a row that claims source level with
 *  no bundle to open, and that refusal is only worth having if this side never names a file
 *  it did not measure — an absent file, an empty `bundles` array and an unparseable file are
 *  all "nothing to name", and none of them may become a path in a committed snapshot. */
async function sourceBundleCount(path) {
  if (!path || !existsSync(path)) return 0;
  try {
    const parsed = JSON.parse(await readFile(path, 'utf8'));
    return Array.isArray(parsed.bundles) ? parsed.bundles.length : 0;
  } catch {
    return 0;
  }
}

/** Replay one settled transaction and decide its outcome.
 *
 *  `ctRelative` is what the row will carry (e.g. `ct/0xabc….ct`); `ctPath` is where the
 *  driver is told to write. The two are separate because the snapshot is committed and
 *  must not carry an absolute path from whoever ran the capture. `sourcesPath` /
 *  `sourcesRelative` are the same split for the source bundle the runtime resolved
 *  off-chain, and it is asked for on EVERY replay: whether a transaction reaches source
 *  level depends on whether every contract it executed had a provable artifact, which is
 *  not knowable before the replay has run. */
export async function replayTransaction({
  nodeBin, runtime, url, txHash, ctPath, ctRelative, sourcesPath, sourcesRelative,
  avm, ctWriter,
}) {
  const r = await run(nodeBin, [
    '--experimental-wasm-exnref',
    'replay/tools/replay_settled_transaction.mjs',
    '--url', url,
    '--tx', txHash,
    '--module', resolve(avm),
    '--ct', ctPath,
    '--ct-writer', resolve(ctWriter),
    ...(sourcesPath ? ['--sources', sourcesPath] : []),
    '--json',
  ], runtime);

  const onDisk = existsSync(ctPath);
  const bytes = onDisk ? (await readFile(ctPath)).length : 0;
  const decided = decideOutcome(r, ctRelative ?? ctPath, onDisk, bytes);
  if (decided.replayed) {
    decided.container = ctRelative ?? ctPath;
    // Absent rather than empty when there is nothing: an absent key reads as "this capture
    // resolved no source", where `""` would read as "there is a file and it is nowhere".
    if (await sourceBundleCount(sourcesPath) > 0) {
      decided.sourceBundles = sourcesRelative ?? sourcesPath;
    }
  }
  return decided;
}
