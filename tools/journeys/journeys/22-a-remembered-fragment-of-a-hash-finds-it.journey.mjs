// "A visitor who remembers only the start of a hash is shown the entities that
//  begin with it, and is told when the fragment is too short to look up."
//
// Search-And-Routing §5 (the prefix-sharded hash index, its exactness, and
// §5.3's variable shard depth), §5.4 (the fallback), §8's not-found contract;
// Page-Descriptions §11 (grouped candidates) and §14 ("'Not on this chain' with
// the chains checked, not a blank page").
//
// WHAT THIS EXTENDS RATHER THAN IMPLEMENTS
// -----------------------------------------
// Search-And-Routing does not specify prefix search over hashes, and it is
// worth saying so in the file that asserts it. §7's suggestion table points the
// other way — "Hash, chain pinned | No suggestion" and "Hash, no chain | No
// suggestion; resolves on submit via the index" — and the only `prefix` the
// spec discusses for hashes is the SHARDING key, not a query form. So this
// journey judges an extension.
//
// What makes the extension cheap is that §5's artefact already has the shape:
// "sharded by a leading slice of the hash" puts every hash with a common
// prefix in one file, and "an exact map from hash to (chain, entity kind)"
// means the keys are there to scan. One fetch answers a prefix for the same
// cost as an exact hash.
//
// THE PREREQUISITE THAT WAS NOT OPTIONAL, AND WAS NOT THE OBVIOUS ONE
// -------------------------------------------------------------------
// The reason to think prefix search was nearly free was that the index existed.
// It did — for one chain. Measured on a hydrated build of 37afe34: 52 shards,
// 56 entries, every entry `demo`, the synthetic chain. `/aztec` and
// `/aztec-testnet` — the two chains carrying real captured data, 204 blocks and
// 8 transactions between them — appeared in no shard, and their generation
// roots carried no `idx` descriptor at all, because `chain/ingest.nim` writes
// `idx: nil`.
//
// Serving prefix search from that index would have been the WORST available
// outcome, and worse than not shipping it: §5's index is exact, so a miss in it
// is a definite answer, and every real transaction on the site would have been
// answered "no published entity begins with this" — with confidence, naming the
// index, in the same not-found treatment §14 requires. A false absence dressed
// in the uniform of a good error message.
//
// So the index is now built globally, over the route enumeration that decides
// which pages exist, and `SUBJECTS: chains represented in the published hash
// index` below is the assertion that keeps it that way. That assertion, not the
// prefix ones, is the one that would have caught the original state.
//
// WHY THE "TOO SHORT" CASE IS HALF THIS FILE
// -------------------------------------------
// A prefix shorter than the shard depth selects no shard, so nothing can be
// fetched and nothing can be concluded. Rendering that as "no results" is a
// false absence claim about every object that does begin with it — the same
// defect, one layer down, and the reason it is asserted here as a DISTINCT
// rendered state rather than folded into the miss.
//
// And the floor is not a constant. §5.3: shard depth "follows arithmetically
// from the total entry count across all chains, and should be recomputed rather
// than fixed: more chains or more history means a deeper prefix". A client with
// a compiled-in depth computes wrong shard paths the first time the index
// deepens and reports every hash absent while doing it. So the floor is read
// from `/idx/hash/meta.json`, and this journey reads it from there too — the
// numbers below are the deployment's, not this file's.
//
// PROVEN TO BITE. On 37afe34 built hydrated, every assertion below fails except
// the two SUBJECTS counts — and the chain-coverage subject fails there, which
// is the point. See the commit message for the run.

import { transactions } from "../lib/corpus.mjs";

export const id = "a-remembered-fragment-of-a-hash-finds-it";
export const claim =
  "A visitor who remembers only the start of a hash is shown the entities that begin with it, and is told when the fragment is too short to look up.";
export const spec =
  "Search-And-Routing §5, §5.3, §5.4, §8; Page-Descriptions §11, §14";
export const assertions = 8;

async function search(browser, origin, q) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const requests = [];
  page.on("request", (r) => requests.push(new URL(r.url()).pathname));
  await page.goto(`${origin}/search/?q=${encodeURIComponent(q)}`, {
    waitUntil: "load",
    timeout: 45000,
  });
  try {
    await page
      .waitForURL((u) => !u.pathname.startsWith("/search"), { timeout: 15000 })
      .catch(() => {});
    const slot = await page.evaluate(() => {
      const el = document.getElementById("search-result");
      const inner = el?.querySelector("[data-search-state]");
      return {
        state: inner?.getAttribute("data-search-state") ?? null,
        text: el?.textContent.replace(/\s+/g, " ").trim() ?? "",
        // The routes the candidate list actually offers — read from the
        // rendered anchors, so a list that prints text and links nowhere is
        // not a pass.
        hrefs: [...(el?.querySelectorAll("a[data-search-hit]") ?? [])].map(
          (a) => new URL(a.href).pathname,
        ),
        groups: [...(el?.querySelectorAll("h3") ?? [])].map((h) =>
          h.textContent.trim(),
        ),
      };
    });
    return { url: new URL(page.url()), slot, requests };
  } finally {
    await context.close();
  }
}

export async function run({ browser, site, j }) {
  // The descriptor is the deployment's own statement about its index. Every
  // number this journey uses comes from it rather than from a literal here.
  const meta = await (await fetch(`${site.origin}/idx/hash/meta.json`)).json();
  const depth = meta.prefixLen;

  const all = await transactions(site.root);
  const publishedChains = [...new Set(all.map((t) => t.chain))].sort();

  // THE ASSERTION THAT WOULD HAVE CAUGHT THE ORIGINAL STATE. An index covering
  // one of three chains is not a smaller index; it is an index that answers
  // confidently and wrongly for the other two.
  const shardBodies = await Promise.all(
    meta.shards.map((p) =>
      fetch(`${site.origin}/idx/hash/${meta.indexVersion}/${p}.bin`).then((r) =>
        r.arrayBuffer(),
      ),
    ),
  );
  const indexedChains = new Set();
  for (const buf of shardBodies) {
    const d = new Uint8Array(buf);
    // Header: magic(4) fmt(1) prefixLen(1) hashLen(1) chainCount(1) count(4),
    // then `chainCount` u8-length-prefixed chain names.
    let pos = 12;
    for (let i = 0; i < d[7]; i++) {
      const n = d[pos++];
      indexedChains.add(new TextDecoder().decode(d.subarray(pos, pos + n)));
      pos += n;
    }
  }
  j.subjects(
    [...indexedChains],
    1,
    "chains represented in the published hash index",
  );
  const unindexed = publishedChains.filter((c) => !indexedChains.has(c));
  j.countIs(
    unindexed.length,
    0,
    `every chain the site publishes is in the hash index${
      unindexed.length ? `: missing ${unindexed.join(", ")}` : ""
    }`,
  );

  // One transaction per chain, from the published corpus.
  const byChain = new Map();
  for (const t of all) if (!byChain.has(t.chain)) byChain.set(t.chain, t);
  const sample = [...byChain.values()];
  j.subjects(sample, 1, "published transactions to search a fragment of");

  // ---- 1. a fragment finds its transaction, on every chain ----------------
  //
  // The fragment is longer than the shard depth and shorter than a hash, so it
  // is unambiguously a PREFIX query and could not have been answered by the
  // direct-path probe: a probe is an exact-key lookup of one computed path.
  const missing = [];
  for (const t of sample) {
    const frag = t.hash.slice(0, 2 + depth + 8);
    const r = await search(browser, site.origin, frag);
    if (!r.slot.hrefs.some((h) => h.startsWith(`/${t.chain}/tx/${t.hash}`))) {
      missing.push(`${t.chain} ${frag} -> ${r.slot.state} ${r.slot.hrefs[0] ?? "(no links)"}`);
    }
  }
  j.countIs(
    missing.length,
    0,
    `a fragment of a published hash offers that transaction as a candidate${
      missing.length ? `: ${missing.slice(0, 3).join("; ")}` : ""
    }`,
  );

  // ---- 2. it costs one shard fetch, not a probe per chain ------------------
  //
  // §5's whole reason for existing: "One fetch, regardless of how many chains
  // exist", against a fallback that "costs one request per chain". Asserted on
  // the REQUESTS the page made, because an implementation that quietly probed
  // every chain would render an identical answer.
  const one = sample[0];
  const probe = await search(
    browser,
    site.origin,
    one.hash.slice(0, 2 + depth + 8),
  );
  const dataReads = probe.requests.filter((p) => p.startsWith("/d/"));
  j.countIs(
    dataReads.length,
    0,
    `a fragment is answered from the index, with no per-chain data probing${
      dataReads.length ? `: ${dataReads.slice(0, 3).join(", ")}` : ""
    }`,
  );

  // ---- 3. §11's grouped candidates, containing transactions ---------------
  //
  // The group keys come off the wire (`tx`) and §11's prose says "transaction".
  // The first version of the renderer used the prose as the lookup key, so the
  // transaction group matched nothing and every transaction was dropped from a
  // list that otherwise rendered perfectly. This asserts the group is there and
  // that the transaction is IN it.
  const wide = await search(browser, site.origin, one.hash.slice(0, 2 + depth));
  j.expect(
    wide.slot.state === "candidates" &&
      wide.slot.hrefs.some((h) => h.startsWith(`/${one.chain}/tx/${one.hash}`)),
    "a fragment matching several entities lists them as candidates, transactions included",
    `state=${wide.slot.state} groups=[${wide.slot.groups.join(", ")}] links=${wide.slot.hrefs.length}`,
  );

  // ---- 4. too short to look up is NOT not-found ---------------------------
  //
  // Distinct rendered state, distinct sentence, and the minimum stated. A
  // deployment whose index deepens says a bigger number here without a code
  // change, which is what reading it from the descriptor buys.
  const tooShort = await search(
    browser,
    site.origin,
    one.hash.slice(0, 2 + depth - 1),
  );
  j.expect(
    tooShort.slot.state === "tooshort" &&
      tooShort.slot.text.includes(String(depth)),
    "a fragment shorter than the shard depth says so, and says the minimum",
    `state=${tooShort.slot.state}; the deployment publishes prefixLen=${depth}; text=${JSON.stringify(tooShort.slot.text.slice(0, 120))}`,
  );

  // ---- 5. a real miss still names what was covered ------------------------
  //
  // §14: "'Not on this chain' with the chains checked, not a blank page." The
  // index answers for every chain at once, which is a stronger statement than a
  // per-chain probe makes — and it is only checkable if the chains are named.
  const absent = "0x" + "f".repeat(2 + depth + 8);
  const miss = await search(browser, site.origin, absent);
  const unnamed = publishedChains.filter((c) => !miss.slot.text.includes(c));
  j.countIs(
    unnamed.length,
    0,
    `a fragment nothing begins with reports a miss naming every chain covered${
      unnamed.length ? `: missing ${unnamed.join(", ")}, state=${miss.slot.state}` : ""
    }`,
  );

  j.note(
    `index: prefixLen=${depth}, ${meta.shardCount} shards, ${meta.entryCount} ` +
      `entries, largest ${meta.largestShardBytes} B, chains ` +
      `[${[...indexedChains].sort().join(", ")}]; site publishes ` +
      `[${publishedChains.join(", ")}]`,
  );
}
