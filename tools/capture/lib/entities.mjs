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
