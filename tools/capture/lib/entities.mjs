// Entity index over a built `dist/`.
//
// Named views are semantic ("the newest block", "the transaction with the most
// content"), not hash-literal. The demo data plane is a pure function of a
// fixed seed, so the hashes are stable — but hard-coding them into the view
// list would mean a seed change silently renames every image and quietly
// re-points every baseline. Resolving them here instead keeps the view NAMES
// stable across a reseed, which is the property the baselines actually need.
//
// Selection is deterministic: blocks by descending height, transactions in
// block order, everything else lexicographic.

import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join } from "node:path";

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

export function buildEntityIndex(distDir) {
  const registryPath = join(distDir, "registry", "chains.v1.json");
  if (!existsSync(registryPath)) {
    throw new Error(
      `no data plane at ${distDir} (missing registry/chains.v1.json) — run the exporter first`,
    );
  }
  const registry = readJson(registryPath);
  const chains = Object.keys(registry.chains).sort();
  if (chains.length === 0) throw new Error(`registry lists no chains`);

  const byChain = {};
  for (const chain of chains) {
    const current = readJson(join(distDir, "d", chain, "current.json"));

    // Blocks, newest first, from the on-disk block objects.
    const blockDir = join(distDir, chain, "block");
    const blockHashes = existsSync(blockDir)
      ? readdirSync(blockDir).filter((h) => h.startsWith("0x")).sort()
      : [];
    const blocks = blockHashes
      .map((hash) => readJson(join(distDir, "d", chain, "block", `${hash}.json`)))
      .sort((a, b) => b.height - a.height || a.hash.localeCompare(b.hash));

    // Transactions in block order (newest block first, index order within it).
    const txs = [];
    for (const b of blocks) {
      for (const hash of b.transactions) {
        txs.push({ hash, block: b.hash, height: b.height });
      }
    }

    // Trace availability per transaction, read from the TraceSelection
    // overlay at the generation's pinned version. The debugger views are
    // selected by what a transaction's trace IS — a view named "the divergent
    // session" has to be captured against a divergent trace, and the demo
    // tree's first transaction in block order happens to be an on-demand one.
    // Reading the overlay is how the view list stays semantic across a reseed
    // instead of pinning a hash that would rot.
    const tsv = current.traceSelectionVersion ?? "1";
    for (const t of txs) {
      const shard = t.hash.slice(2, 6);
      const overlayPath = join(distDir, "d", chain, "ts", tsv, shard, `${t.hash}.json`);
      t.availability = null;
      t.executions = [];
      t.reconstructed = false;
      if (!existsSync(overlayPath)) continue;
      const overlay = readJson(overlayPath);
      // Single-execution transactions carry `trace`; split ones carry
      // `executions` (Data-Contract's TraceSelection overlay).
      const execs = overlay.trace ? [overlay.trace] : (overlay.executions ?? []);
      t.executions = execs;
      // The headline is the strongest availability among the executions, in
      // the same order `bestTrace` uses, so a transaction whose private half
      // is absent and whose public half is ready reads as `ready` here too.
      for (const want of ["ready", "divergent", "onDemand"]) {
        if (execs.some((e) => e.availability === want)) { t.availability = want; break; }
      }
      if (t.availability === null && execs.length > 0) {
        t.availability = execs[0].availability ?? null;
      }
      // Orthogonal to availability (Trace-Artifacts §2.3a): a trace can be
      // `ready` AND heuristically reconstructed, and the route says so on the
      // identity bar. The flagship `debugger` view wants the plain case.
      t.reconstructed = execs.some((e) => e.reconstructed === true);
    }

    const addrDir = join(distDir, chain, "address");
    const addresses = existsSync(addrDir)
      ? readdirSync(addrDir).filter((a) => a.startsWith("0x")).sort()
      : [];

    byChain[chain] = { chain, current, blocks, txs, addresses };
  }

  return {
    distDir,
    chains,
    primaryChain: chains[0],
    byChain,
    chain(name) {
      const c = byChain[name ?? chains[0]];
      if (!c) throw new Error(`no such chain in the data plane: ${name}`);
      return c;
    },
  };
}

// ── Selectors used by views.mjs ────────────────────────────────────────────

/** Newest block on the primary chain. */
export const headBlock = (ix) => ix.chain().blocks[0];

/** Nth block from the head (0 = head). */
export const nthBlock = (n) => (ix) => {
  const b = ix.chain().blocks[n];
  if (!b) throw new Error(`data plane has no block at offset ${n}`);
  return b;
};

/** Nth transaction in block order (0 = first tx of the newest block). */
export const nthTx = (n) => (ix) => {
  const t = ix.chain().txs[n];
  if (!t) throw new Error(`data plane has no transaction at offset ${n}`);
  return t;
};

/** First indexed address. */
export const firstAddress = (ix) => {
  const a = ix.chain().addresses[0];
  if (!a) throw new Error(`data plane indexes no addresses`);
  return a;
};

/** The first transaction in block order whose headline trace availability is
 *  `want` — `"ready"`, `"divergent"`, `"onDemand"`, `"absent"` … .
 *
 *  Throws rather than falling back. A debugger view captured against a
 *  transaction that has no trace would photograph the on-demand state and be
 *  filed under `debugger`, which is precisely the "an image a reviewer would
 *  mistake for a styled page" failure `check-coverage.mjs` exists to prevent.
 */
export const txWithAvailability = (want, { reconstructed = null } = {}) => (ix) => {
  const t = ix.chain().txs.find(
    (t) => t.availability === want &&
           (reconstructed === null || t.reconstructed === reconstructed));
  if (!t) {
    const seen = [...new Set(ix.chain().txs.map((t) => t.availability))].join(", ");
    throw new Error(
      `data plane has no transaction whose trace is "${want}"` +
      (reconstructed === null ? "" : ` with reconstructed=${reconstructed}`) +
      ` (present: ${seen || "none"})`);
  }
  return t;
};

/** The transaction with more than one execution — the Aztec private/public
 *  split, which is the case the metadata pane's execution list exists for. */
export const txWithSplitExecutions = (ix) => {
  const t = ix.chain().txs.find((t) => (t.executions?.length ?? 0) > 1);
  if (!t) throw new Error(`data plane has no multi-execution transaction`);
  return t;
};
