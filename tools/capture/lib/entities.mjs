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

    // Per address: the segments its generation lists, the code hashes bound to
    // it, and whether any of those hashes has a published source bundle.
    //
    // Read from the data plane rather than from the rendered page, and by the
    // same rule as the trace availability above: a view named "the verified
    // source browser" has to be captured against a contract that HAS one, and
    // a view named "no verified source" against one that does not. Picking
    // either by position would re-point both the first time the seed moved,
    // and the second would silently photograph a verified contract.
    const gen = current.generation;
    const details = {};
    for (const address of addresses) {
      const shard = address.slice(2, 6);
      const indexPath = join(distDir, "d", chain, "g", gen, "addr", shard, `${address}.json`);
      const entry = { address, segments: [], codeHashes: [], verified: false };
      if (existsSync(indexPath)) {
        entry.segments = readJson(indexPath).segments ?? [];
        for (const segRel of entry.segments) {
          const segPath = join(distDir, segRel);
          if (!existsSync(segPath)) continue;
          for (const hash of readJson(segPath).transactions ?? []) {
            const factsPath = join(distDir, "d", chain, "tx", hash.slice(2, 6), `${hash}.json`);
            if (!existsSync(factsPath)) continue;
            for (const edge of readJson(factsPath).codeEdges ?? []) {
              if (edge.address === address && !entry.codeHashes.includes(edge.codeHash)) {
                entry.codeHashes.push(edge.codeHash);
              }
            }
          }
        }
      }
      entry.verified = entry.codeHashes.some((h) =>
        existsSync(join(distDir, "src", chain, h, "current.json")));
      details[address] = entry;
    }

    byChain[chain] = { chain, current, blocks, txs, addresses, addressDetails: details };
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

/** An address the tree binds CODE to, whose code hash does (`want = true`) or
 *  does not (`want = false`) have a published source bundle.
 *
 *  Throws rather than falling back, for the reason `txWithAvailability` does:
 *  `contract-source--unverified` captured against a verified contract is an
 *  image a reviewer would grade as the wrong finding, not as a missing one. */
export const contractWithSource = (want) => (ix) => {
  const c = ix.chain();
  const hit = c.addresses.find((a) => {
    const d = c.addressDetails?.[a];
    return d && d.codeHashes.length > 0 && d.verified === want;
  });
  if (!hit) {
    throw new Error(
      `data plane has no contract address whose source bundle is ` +
      `${want ? "published" : "absent"} ` +
      `(addresses with code: ${
        c.addresses.filter((a) => (c.addressDetails?.[a]?.codeHashes.length ?? 0) > 0).length})`);
  }
  return hit;
};

/** An address whose history the generation splits across more than one
 *  block-range segment — the case the cursor pager exists for, and the only
 *  one where "Older" renders at all. */
export const addressWithSegments = (least) => (ix) => {
  const c = ix.chain();
  const hit = c.addresses.find((a) => (c.addressDetails?.[a]?.segments.length ?? 0) >= least);
  if (!hit) throw new Error(`data plane indexes no address with >= ${least} segments`);
  return hit;
};

/** The id of the nth segment of an address's history, as it appears in the
 *  paged URL — read out of the published path, never recomputed. */
export const segmentIdOf = (address, n) => (ix) => {
  const segs = ix.chain().addressDetails?.[address]?.segments ?? [];
  if (segs.length <= n) throw new Error(`${address} has no segment at offset ${n}`);
  return segs[n].split("/").pop().replace(/\.json$/, "");
};

/** The transaction with more than one execution — the Aztec private/public
 *  split, which is the case the metadata pane's execution list exists for. */
export const txWithSplitExecutions = (ix) => {
  const t = ix.chain().txs.find((t) => (t.executions?.length ?? 0) > 1);
  if (!t) throw new Error(`data plane has no multi-execution transaction`);
  return t;
};
