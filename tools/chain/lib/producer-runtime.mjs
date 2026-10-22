// producer-runtime.mjs — WHAT EVERY `produce-<chain>-snapshot.mjs` IN THIS TREE DOES THAT
// SAYS NOTHING ABOUT A CHAIN.
//
// Chain-Delivery DEL-7. Each member below is here because it was MEASURED to be duplicated
// across producers, and each carries the count and the consumers that justify it. ING-7's
// inherited rule — no abstraction before it has two consumers — is the gate this file had
// to pass, and `abstraction-consumers-selftest.mjs` re-counts the consumers from the
// producers' own import statements rather than from this comment.
//
// ── WHAT THIS FILE IS NOT ─────────────────────────────────────────────────────────────
//
// It is NOT an interface over producers, a registry, or a dispatch site. There is no
// `switch` on a chain, no table keyed on a prestate strategy, and no second
// implementation of any member: a producer imports the members it uses and calls them
// directly, the way it already imports `lib/snapshot-format.mjs` and `lib/recount.mjs`.
// `lib/producer-facts.mjs`'s header states the same boundary from the other side — "a data
// module for ONE producer, not an interface over producers" — and this file does not
// contradict it, because nothing here is a fact about a chain. It is the container header,
// the exit-code protocol, the argv grammar and the one published row shape that does not
// vary. `lib/<chain>-producer-facts.mjs` keeps every statement that does.
//
// It is also NOT `lib/refusal.mjs`, and the distinction is load-bearing rather than
// stylistic. `lib/refusal.mjs` is "the only place a TRANSACTION is allowed to be declined"
// (ING-3's closed set): its members are reasons a published row carries. The refusal in
// THIS file declines an INVOCATION or a SOURCE — a missing `--out`, an unreadable
// container, a reader binary that is not installed — and never reaches a published row.
// Measured 2026-10-22: all five producers import `lib/refusal.mjs` AND define a local
// `refuse` of their own, so the local one was never bypassing the registry; the two names
// were two concepts. This file is the second concept, given a home and one spelling.
//
// ── WHY THE OPERATIONAL REFUSAL IS A FIELD AND NOT A CLASS ────────────────────────────
//
// `produce-eth-snapshot.mjs` argued this first and the argument is adopted rather than
// restated: DEL-5's `test_no_abstraction_was_introduced` counts type hierarchies in this
// tree's `.mjs`, so the distinction between "this invocation is wrong" (exit 2) and "a
// source would not answer" (exit 1) travels as a field, which is not a type at all.
// Measured 2026-10-22, before this file: three producers (eth, flow, starknet) tagged an
// ordinary `Error` and two (sol, sui) declared `class ConfigRefusal extends Error {}` and
// `class SourceRefusal extends Error {}` — one concern, two mechanisms, five copies. The
// field mechanism is the one kept, so adopting this file REMOVES four classes rather than
// adding any. DEL-5's entry recorded the three it could not resolve — "`.mjs` classes
// 7→10 … Recorded for DEL-7, which is where a second producer's shapes are compared" —
// and this is that comparison.

import { existsSync, readFileSync } from 'node:fs';

// ── the operational refusal, and the exit code it decides ─────────────────────────────

/** "This invocation is wrong." Exit 2. */
export const CONFIG_REFUSAL = 'config';

/** "A source would not answer." Exit 1. */
export const SOURCE_REFUSAL = 'source';

/**
 * An operational refusal: an ordinary `Error` tagged with which of the two it is.
 *
 * Consumers (5): `produce-eth-snapshot.mjs`, `produce-flow-snapshot.mjs`,
 * `produce-starknet-snapshot.mjs`, `produce-sol-snapshot.mjs`,
 * `produce-sui-snapshot.mjs`.
 */
export const refuseOperation = (kind, message) =>
  Object.assign(new Error(message), { refusalKind: kind });

/**
 * The exit code a refusal implies. Anything that is not a configuration refusal — a
 * source refusal, and equally a `TypeError` from a bug in the producer — is 1, because
 * exit 2 is a claim that the OPERATOR got it wrong and a producer must not make that
 * claim about its own defect.
 *
 * NOT EXPORTED, deliberately. It has one caller, `dieOperational`, and a one-consumer
 * export is what this milestone refuses. The behaviour it decides is asserted from the
 * outside instead: `abstraction-consumers-selftest.mjs` runs each of the five producers
 * with no arguments and reads the real exit code.
 */
const operationalExitCode = (e) => (e?.refusalKind === CONFIG_REFUSAL ? 2 : 1);

/**
 * Print `where: message` on stderr and exit with the code the refusal implies.
 *
 * Consumers (5): the five producers' top-level `catch`.
 *
 * @param {string} where the tool's own path, for the message
 */
export function dieOperational(where, e) {
  console.error(`${where}: ${e.message}`);
  process.exit(operationalExitCode(e));
}

// ── the container, as a FORMAT rather than as a chain ─────────────────────────────────

/** The four bytes a CTFS container begins with. NOT exported: one caller, and a
 *  one-consumer export is what this milestone refuses. */
const CTFS_MAGIC = Object.freeze([0xc0, 0xde, 0x72, 0xac]);

/**
 * The container's own version byte, read from the header rather than from a constant.
 *
 * The CTFS magic is the first four bytes and the container version is the sixth. A file
 * whose magic does not match is refused HERE rather than at publish time, which is where
 * `S5-CONTAINER-NOT-PREENCODED` would otherwise catch it with less to say.
 *
 * This is a fact about the trace format, not about any chain: the same four bytes and the
 * same offset held for every one of the five producers that had written the check out
 * (eth, flow, starknet and sui as a function; sol inline inside its `readContainer`).
 * Measured 2026-10-22: 5 copies of the check, 4 as a named function in 3 distinct texts,
 * differing only in the prose of the refusal — which is why the prose is a parameter and
 * the check is not.
 *
 * Consumers (5): the five producers.
 *
 * @param {string} file the container path
 * @param {{note?: string}} [opts] `note` is appended to the refusal, so a producer keeps
 *   the sentence it already said about what a snapshot container holds
 */
export function containerVersion(file, { note = '' } = {}) {
  const b = readFileSync(file).subarray(0, 8);
  for (let i = 0; i < CTFS_MAGIC.length; i++) {
    if (b[i] !== CTFS_MAGIC[i]) {
      const got = [...b.subarray(0, 4)].map((x) => x.toString(16)).join(' ');
      throw refuseOperation(SOURCE_REFUSAL,
        `${file} does not begin with the CTFS magic (got ${got})${note ? `. ${note}` : ''}`);
    }
  }
  return b[5];
}

/**
 * Where the container reader is, from the candidates the caller names, in order.
 *
 * THE CANDIDATE LIST IS A PARAMETER AND THAT IS A FINDING, NOT A CONVENIENCE. The
 * classification this milestone wrote called reader discovery network-agnostic on the
 * evidence of four copies in three texts. It is not: `produce-flow-snapshot.mjs` reads a
 * DIFFERENT BINARY — the `flow-ct-print` flake package at the writer revision its recorder
 * links — so the sibling-checkout fallback three of the four producers share is wrong for
 * it, and would silently resolve to a reader that cannot open a Flow container. The
 * mechanism (explicit flag, then `$CT_PRINT`, then the fallbacks, first that exists) is
 * shared; the candidate list and the hint are network-specific. See
 * `ingestion-classification.json`, finding `container-reader-fallbacks-are-network-specific`.
 *
 * Consumers (4): eth, flow, starknet, sui. `produce-sol-snapshot.mjs` resolves its reader
 * from `--ct-print` with its own default and is NOT a consumer; it is not made one here,
 * because doing so for the count's sake is the self-fulfilling move this milestone refuses.
 *
 * @param {{explicit?: string, fallbacks?: string[], hint?: string}} opts
 */
export function containerReaderPath({ explicit, fallbacks = [], hint = '' } = {}) {
  const cands = [explicit, process.env.CT_PRINT, ...fallbacks].filter(Boolean);
  for (const c of cands) if (existsSync(c)) return c;
  throw refuseOperation(CONFIG_REFUSAL,
    `no container reader found. Pass --ct-print <path> or set $CT_PRINT.`
    + (cands.length ? ` Tried: ${cands.join(', ')}.` : '')
    + (hint ? ` ${hint}` : ''));
}

// ── reading a file the invocation named ───────────────────────────────────────────────

/**
 * JSON off disk, with an unreadable file a source refusal that names WHAT was being read.
 *
 * Consumers (2): `produce-starknet-snapshot.mjs`, `produce-sui-snapshot.mjs`, whose two
 * definitions were byte-identical after comment and whitespace normalisation (measured
 * 2026-10-22: 2 definitions, 1 distinct text).
 */
export function readJsonOrRefuse(path, what) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (e) {
    throw refuseOperation(SOURCE_REFUSAL, `${what} at ${path} is not readable JSON: ${e.message}`);
  }
}

// ── the argv grammar two producers share exactly ──────────────────────────────────────

/**
 * `--name value` repeated, plus a set of valueless flags.
 *
 * Consumers (2): `produce-starknet-snapshot.mjs`, `produce-sui-snapshot.mjs`, whose two
 * `parseArgs` definitions were byte-identical after normalisation — 2 definitions, 1
 * distinct text, the only exact pair in the producers' 11 duplicated declarations.
 *
 * `flag()` in eth, flow and sol is NOT folded in here. Three definitions, three distinct
 * texts and three different behaviours — eth accepts `--name=value`, flow refuses a
 * missing value, sol returns `undefined` — so one implementation would change two
 * producers' CLI semantics. Two consumers is the floor this milestone enforces, not a
 * licence: the copies also have to be copies. Recorded as a refused candidate in
 * `ingestion-classification.json`.
 *
 * @param {string[]} argv arguments after the script name
 * @param {{usage: string, valueless?: string[]}} opts
 * @returns {{one: (n: string, dflt?: string) => string|undefined,
 *            all: (n: string) => string[], has: (n: string) => boolean}}
 */
export function parseProducerArgs(argv, { usage, valueless = ['dry-run', 'help'] } = {}) {
  const many = new Map();
  const flags = new Set();
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) {
      throw refuseOperation(CONFIG_REFUSAL, `unexpected argument '${a}'\n${usage}`);
    }
    const name = a.slice(2);
    if (valueless.includes(name)) { flags.add(name); continue; }
    const v = argv[++i];
    if (v === undefined) {
      throw refuseOperation(CONFIG_REFUSAL, `--${name} needs a value\n${usage}`);
    }
    if (!many.has(name)) many.set(name, []);
    many.get(name).push(v);
  }
  const one = (n, dflt) => {
    const vs = many.get(n) ?? [];
    if (vs.length > 1) throw refuseOperation(CONFIG_REFUSAL, `--${n} given ${vs.length} times`);
    return vs[0] ?? dflt;
  };
  return { one, all: (n) => many.get(n) ?? [], has: (n) => flags.has(n) };
}

// ── the one published row shape that did not vary ─────────────────────────────────────

/**
 * `transactions[].executions` for a chain that publishes ONE execution per transaction.
 *
 * MEASURED, AND IT IS THE STRONGEST RESULT THIS EXTRACTION RESTS ON: of the four
 * `*ForRow` helpers the five per-chain facts modules declare, this one had 5 definitions
 * and ONE distinct text, while `costVectorForRow` had 5 definitions in 5 texts,
 * `rolesForRow` 5 in 5 and `payloadForRow` 4 in 4. So the facts modules are
 * network-specific as their headers claim, with exactly one exception, and this is it.
 *
 * AND THE AXIS IS NOT THE PRESTATE CLASS. The five chains that share this text span three
 * of §3's seven classes plus one chain with no token at all (eth and starknet
 * `replay-preceding`, sui `version-addressed`, sol `forward-capture`, flow
 * `undetermined`). What they share is that each publishes one execution environment per
 * transaction. `lib/producer-facts.mjs` — Aztec's — declares
 * `executionsForRow = () => [{ selector: 'public' }]` instead, and is deliberately not a
 * consumer: Aztec publishes a public half and declares the private one `absent`. The unit
 * of variation here is the EXECUTION-ENVIRONMENT COUNT, which is why the name says
 * `oneExecutionPerTransaction` and not `executionsForRow`.
 *
 * A fresh array per call: the row it goes into is mutated by later passes, and a frozen
 * shared literal would make two rows the same object.
 *
 * Consumers (5): `lib/eth-producer-facts.mjs`, `lib/flow-producer-facts.mjs`,
 * `lib/starknet-producer-facts.mjs`, `lib/solana-producer-facts.mjs`,
 * `lib/sui-producer-facts.mjs`.
 */
export const oneExecutionPerTransaction = (reason) => (reason
  ? [{ selector: 'transaction', reason }]
  : [{ selector: 'transaction' }]);
