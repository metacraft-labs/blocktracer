// The corpus a journey quantifies over — read from the exported tree, never
// listed in a file here.
//
// WHY IT IS DISCOVERED
// --------------------
// `tools/capture/check-coverage.mjs` already learned this the expensive way and
// wrote it down: "A list cannot notice a chain nobody added it to." The visual
// corpus named its views by hand, the tree gained `aztec-testnet` and
// `aztec-mainnet`, every named view kept resolving through `chains.sort()[0]`,
// and 232 images were captured of the synthetic chain and none of either real
// one — while coverage reported 67/67.
//
// That lesson is applied here to the transactions a journey walks. The corpus
// is whatever the exporter wrote, so a new chain is in it on the next run, and
// its SIZE is asserted by the journeys before anything quantifies over it.
//
// THE DEMO CHAIN AND THE REAL CHAINS ARE SEPARATED, DELIBERATELY
// -------------------------------------------------------------
// The two seed defects this suite was built from both survived because every
// assertion about a positioned session ran on the demo path. `aztec` is the
// synthetic demo chain, produced by `client/src/debugger/demo_session.nim`;
// `aztec-testnet` and `aztec-mainnet` are frozen captures of a real chain under
// `client/fixtures/chain/`. A journey that means "a chain transaction" must be
// able to say so, so `realChains` is a fact about the tree rather than a
// judgement made at each call site.

import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

/** The synthetic chain the demo data plane generates. Everything else is real. */
export const DEMO_CHAIN = "aztec";

async function subdirs(p) {
  return readdir(p, { withFileTypes: true })
    .then((es) => es.filter((e) => e.isDirectory()).map((e) => e.name))
    .catch(() => []);
}

/**
 * Every transaction the exporter wrote, as
 * `{ chain, hash, txPath, debugPath, phase, real }`.
 *
 * `phase` is read out of the served HTML — the session's own account of itself
 * — so the classification a journey asserts over is the product's, not this
 * file's opinion of it.
 */
export async function transactions(root) {
  const out = [];
  for (const chain of await subdirs(root)) {
    const txRoot = join(root, chain, "tx");
    for (const hash of await subdirs(txRoot)) {
      const debugIndex = join(txRoot, hash, "debug", "index.html");
      const html = await readFile(debugIndex, "utf8").catch(() => null);
      if (html === null) continue;
      const m = /data-session-phase="([A-Za-z-]*)"/.exec(html);
      out.push({
        chain,
        hash,
        txPath: `/${chain}/tx/${hash}`,
        debugPath: `/${chain}/tx/${hash}/debug`,
        phase: m ? m[1] : null,
        real: chain !== DEMO_CHAIN,

        // Whether the chain published SOURCE for this contract, which is a
        // different question from whether a session exists.
        //
        // An Aztec contract class carries bytecode and no debug symbols, so a
        // real-chain recording is at instruction level: "Stepping is complete;
        // only the text is missing." That is a specified state, not a defect,
        // and a journey that demanded a source listing of every session would
        // report six correct pages as broken — which an earlier draft of
        // journey 01 did. What the spec requires of these pages is that they
        // SAY so, and journey 05 is where that is asserted.
        //
        // Read from the markup rather than from the chain's name, so a testnet
        // capture that gains verified sources moves classes on its own.
        hasListing: /class="srcline/.test(html),
      });
    }
  }
  out.sort((a, b) => (a.chain + a.hash).localeCompare(b.chain + b.hash));
  return out;
}

/**
 * Page-Descriptions.md §7.0's three landing outcomes, as the phases that
 * produce each.
 *
 * The spec's column is `trace.availability` (`ready`, `divergent`, `onDemand`,
 * `absent`, `unsupported`); the page publishes `SessionPhase`
 * (`client/src/debugger/session_view.nim`). This is the ONE place the two
 * vocabularies are related, so a journey asserts §7.0's rows rather than an
 * enum's spelling, and a renamed phase fails HERE, by name, instead of
 * silently reclassifying a page.
 */
export const LANDINGS = {
  // "ready, divergent -> The debugging interface, with transaction metadata
  //  rendered around it (§7.1)"
  session: ["fetching", "opening", "positioning", "ready"],
  // "onDemand -> The metadata, and the generate action"
  generate: ["awaitingGeneration"],
  // "absent, unsupported -> The metadata, with the reason stated. No debugger,
  //  and no pretence of one"
  stated: ["unavailable"],
};

export function landingOf(phase) {
  for (const [name, phases] of Object.entries(LANDINGS)) {
    if (phases.includes(phase)) return name;
  }
  return null; // an unclassified phase is a failure, never a silent third class
}

// ---------------------------------------------------------------------------
// THE CAPABILITY SEAM
// ---------------------------------------------------------------------------
//
// The demo chain is being rebuilt from one stand-in recording into a suite of
// purpose-built Noir programs, one per capability — loops and the iteration
// rail, branch taken / not-taken, inline values, the call trace, the event log,
// the type system — designed so that the capability a program demonstrates is
// the capability it tests. It is meant to serve three consumers: the shared
// ViewModels on both backends, desktop CodeTracer's GUI, and this one.
//
// NO JOURNEY IN THIS DIRECTORY NAMES A TRANSACTION, and that is the seam. Every
// subject is selected by a PROPERTY read off the tree — `landingOf(phase)`,
// `hasListing` — so the corpus can be replaced wholesale without editing a
// journey. The suite is already exercising 62 transactions across three chains
// that no file here lists.
//
// When the corpus lands with its manifest, `capabilitiesOf` below starts
// returning real answers and a journey can say "the transaction that
// demonstrates loops" instead of "one that has a listing". Until then it
// returns an empty set, and — this is the important part — a journey that
// selected on a capability would then find NO subjects and fail its
// `j.subjects()` call rather than passing over nothing. That is the correct
// behaviour for a claim whose fixture has not arrived, and it is why this
// returns an empty set rather than falling back to "any transaction".
//
// TWO ASYMMETRIES TO ASSERT RATHER THAN PAPER OVER, when parity journeys arrive:
//
//   * A chain trace is rung 3 — no source, no names — and a demo trace is
//     source-level. Journeys 01 and 05 already split on exactly this, and the
//     split is the finding: six real-chain sessions state that they have no text
//     and never state which step they are on.
//   * BlockTracer has no origin-chain surface at all, so a cross-consumer parity
//     claim cannot be "the three agree everywhere". Where they cannot agree, the
//     difference is the assertion; a gap left unstated reads as parity, which is
//     the vacuous pass this layer exists to refuse.

import { readFile as _readFile } from "node:fs/promises";

/**
 * What each demo transaction is FOR, from the corpus manifest if the tree
 * carries one. `{}` until it does — never a guess, and never "everything".
 */
export async function capabilityManifest(root) {
  for (const candidate of ["d/demo-capabilities.json", "registry/capabilities.json"]) {
    const raw = await _readFile(join(root, candidate), "utf8").catch(() => null);
    if (raw !== null) {
      try {
        return JSON.parse(raw);
      } catch {
        // A manifest that does not parse is a broken input, not an absent one.
        // Saying so beats silently behaving as though the corpus had none.
        throw new Error(`${candidate} is present but is not valid JSON`);
      }
    }
  }
  return {};
}

/** The capabilities one transaction demonstrates. Empty until the manifest exists. */
export function capabilitiesOf(manifest, tx) {
  const entry = manifest?.[tx.hash] ?? manifest?.[`${tx.chain}/${tx.hash}`];
  return entry?.demonstrates ?? [];
}
