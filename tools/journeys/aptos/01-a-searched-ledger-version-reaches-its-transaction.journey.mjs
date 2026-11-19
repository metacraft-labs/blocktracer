// "A visitor who types an Aptos ledger version into the search box arrives at that
//  transaction."
//
// Recorder-Move CXP-MOVE-7, `test_aptos_identity_is_a_version_not_a_hash`: "Aptos rows
// carry `id.kind: "version"` and resolve by version through search. Control: a Sui row in
// the same run carries `id.kind: "hash"`, so the union is shown to have two live
// inhabitants." Static-Site-Architecture §2.3 gives Aptos `id: {kind: "version", version,
// hash}` and `order: {kind: "globalVersion"}`; Search-And-Routing §2 and §3 read a decimal
// as a block height, which for Aptos is a different number from the version a visitor
// copies out of another explorer.
//
// WHAT IS JUDGED. Every version is taken from the PUBLISHED rows (`d/aptos-mainnet/tx/…`),
// and the claim is where the visitor ENDS UP: on the transaction's own page, which is named
// by its hash, with the hash on screen. The controls are the other half: the Sui rows in
// the same tree carry a hash identity and a Sui digest still resolves by hash; a Sui
// checkpoint number is not looked up as a version on Sui; and a version nothing is
// published at does not navigate anywhere.
//
// WHICH TREE. This set runs over a site that publishes `aptos-mainnet` and a Sui chain —
// not the Aztec-only `default`, where it would have no subject. Aptos is not in
// `produced-captures`, so the tree is the producer's own output (`just aptos-capture`)
// placed into the site build by hand; `just journeys-aptos` does both:
//
//   just journeys-aptos .aptos-capture/tree
//
// It is in no CI job, for the reason `produced-captures` gives for Aptos.

import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { transactions } from "../lib/corpus.mjs";

export const id = "a-searched-ledger-version-reaches-its-transaction";
export const claim =
  "A visitor who types an Aptos ledger version into the search box arrives at that transaction.";
export const spec =
  "Recorder-Move CXP-MOVE-7 (test_aptos_identity_is_a_version_not_a_hash); Static-Site-Architecture §2.3; Search-And-Routing §2, §3, §5";
export const assertions = 10;

/** Every published transaction row of a chain, read out of the tree as the site serves it. */
async function publishedRows(root, chain) {
  const rows = [];
  const txRoot = join(root, "d", chain, "tx");
  const shards = await readdir(txRoot, { withFileTypes: true }).catch(() => []);
  for (const s of shards) {
    if (!s.isDirectory()) continue;
    for (const f of await readdir(join(txRoot, s.name)).catch(() => [])) {
      if (!f.endsWith(".json")) continue;
      const row = JSON.parse(await readFile(join(txRoot, s.name, f), "utf8"));
      rows.push(row);
    }
  }
  return rows;
}

/** Search `q` and report where the visitor ended up, and what the page fetched. */
async function search(browser, origin, q) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const requests = [];
  page.on("request", (r) => requests.push(new URL(r.url()).pathname));
  try {
    await page.goto(`${origin}/search/?q=${encodeURIComponent(q)}`, {
      waitUntil: "load",
      timeout: 45000,
    });
    // A query that resolves navigates; one that does not stays, and staying is the
    // answer for the miss cases. Waiting on the URL, as journeys 21 and 22 do.
    await page
      .waitForURL((u) => !u.pathname.startsWith("/search"), { timeout: 15000 })
      .catch(() => {});
    // A miss renders into the slot without navigating; give it the same bound.
    if (new URL(page.url()).pathname.startsWith("/search")) {
      await page
        .waitForSelector("#search-result [data-search-state]", { timeout: 15000 })
        .catch(() => {});
    }
    const slot = await page.evaluate(() => {
      const el = document.getElementById("search-result");
      const inner = el?.querySelector("[data-search-state]");
      return {
        state: inner?.getAttribute("data-search-state") ?? null,
        text: el?.textContent.replace(/\s+/g, " ").trim() ?? "",
      };
    }).catch(() => ({ state: null, text: "" }));
    return {
      url: new URL(page.url()),
      body: await page.evaluate(() => document.body.innerText).catch(() => ""),
      slot,
      requests,
    };
  } finally {
    await context.close();
  }
}

export async function run({ browser, site, j }) {
  const registry = JSON.parse(
    await readFile(join(site.root, "registry", "chains.v1.json"), "utf8"));
  const chainsOrderedBy = (kind) =>
    Object.entries(registry.chains ?? {})
      .filter(([, row]) => row?.ordering?.kind === kind)
      .map(([slug]) => slug)
      .sort();
  const versionChains = chainsOrderedBy("globalVersion");
  const checkpointChains = chainsOrderedBy("checkpoint");
  const aptos = versionChains[0] ?? "aptos-mainnet";
  const sui = checkpointChains[0] ?? "sui-mainnet";

  // ---- 1. the identity union, as published ---------------------------------
  //
  // Every Aptos row is identified by its version, and every Sui row by its hash. Read
  // from the rows the site serves, so a producer that stopped writing the version kind
  // fails here before any search is made.
  const aptosRows = await publishedRows(site.root, aptos);
  const suiRows = await publishedRows(site.root, sui);
  j.subjects(aptosRows, 1, `published ${aptos} transactions (the chain ordered by globalVersion)`);
  const notVersion = aptosRows.filter(
    (r) => r?.id?.kind !== "version" || !/^(0|[1-9][0-9]*)$/.test(r?.id?.version ?? ""));
  j.countIs(
    notVersion.length,
    0,
    `every ${aptos} row carries id.kind "version" with a canonical decimal version${
      notVersion.length ? `: ${notVersion.slice(0, 2).map((r) => JSON.stringify(r.id)).join("; ")}` : ""
    }`,
  );
  j.subjects(suiRows, 1, `published ${sui} transactions (the control)`);
  const notHash = suiRows.filter((r) => r?.id?.kind !== "hash");
  j.countIs(
    notHash.length,
    0,
    `CONTROL: every ${sui} row carries id.kind "hash"${
      notHash.length ? `: ${notHash.slice(0, 2).map((r) => JSON.stringify(r.id)).join("; ")}` : ""
    }`,
  );

  // ---- 2. a version typed into the box arrives at its transaction ----------
  const notReached = [];
  const hashNotOnPage = [];
  const otherIndexReads = [];
  for (const row of aptosRows) {
    const { version, hash } = row.id;
    const r = await search(browser, site.origin, version);
    const want = `/${aptos}/tx/${hash}`;
    if (!r.url.pathname.startsWith(want)) {
      notReached.push(`${version} -> ${r.url.pathname} (state ${r.slot.state})`);
      continue;
    }
    if (!r.body.includes(hash.slice(0, 18))) hashNotOnPage.push(`${version} (${hash.slice(0, 10)}…)`);
    // SCOPED TO THE CHAIN THAT DECLARED IT: no other chain's version index is asked.
    for (const p of r.requests) {
      if (/^\/idx\/[^/]+\/version\//.test(p) && !p.startsWith(`/idx/${aptos}/version/`)) {
        otherIndexReads.push(p);
      }
    }
  }
  j.countIs(
    notReached.length,
    0,
    `searching a published ${aptos} ledger version arrives at that transaction's page${
      notReached.length ? `: ${notReached.slice(0, 3).join("; ")}` : ""
    }`,
  );
  j.countIs(
    hashNotOnPage.length,
    0,
    `the page a version search arrived at renders the transaction's hash${
      hashNotOnPage.length ? `: ${hashNotOnPage.slice(0, 3).join("; ")}` : ""
    }`,
  );
  j.countIs(
    otherIndexReads.length,
    0,
    `a version search reads no version index but ${aptos}'s${
      otherIndexReads.length ? `: ${[...new Set(otherIndexReads)].slice(0, 3).join(", ")}` : ""
    }`,
  );

  // ---- 3. CONTROL: a Sui digest still resolves by hash ---------------------
  const suiHash = suiRows[0]?.id?.hash ?? "";
  const bySuiHash = await search(browser, site.origin, suiHash);
  j.expect(
    suiHash.length > 0 && bySuiHash.url.pathname.startsWith(`/${sui}/tx/${suiHash}`),
    `CONTROL: a published ${sui} digest, searched as typed, arrives at its transaction by hash`,
    `${suiHash.slice(0, 12)}… -> ${bySuiHash.url.pathname} (state ${bySuiHash.slot.state})`,
  );

  // ---- 4. CONTROL: a Sui checkpoint is a number, and is not a version on Sui
  //
  // Sui's ordering is `checkpoint`, so its numbers keep the meaning they had: no request to
  // a Sui version index, and no navigation. Whatever version-ordered chain the deployment
  // has is the only one asked.
  const checkpoint = String(suiRows[0]?.order?.seq ?? "");
  const cp = await search(browser, site.origin, checkpoint || "28845373");
  const suiVersionReads = cp.requests.filter((p) => p.startsWith(`/idx/${sui}/version/`));
  j.expect(
    cp.url.pathname.startsWith("/search") && suiVersionReads.length === 0 &&
      cp.slot.state === "unsupported",
    `CONTROL: a ${sui} checkpoint number is not looked up as a version on ${sui}, and does not navigate`,
    `searched ${checkpoint || "28845373"}: landed ${cp.url.pathname}, state ${cp.slot.state}, ` +
      `${suiVersionReads.length} read(s) of /idx/${sui}/version/`,
  );

  // ---- 5. a version nothing is published at says so, and names the chain ----
  const published = new Set(aptosRows.map((r) => r.id.version));
  let absent = null;
  for (const r of aptosRows) {
    const next = (BigInt(r.id.version) + 1n).toString();
    if (!published.has(next)) { absent = next; break; }
  }
  const miss = await search(browser, site.origin, absent ?? "0");
  j.expect(
    absent !== null && miss.url.pathname.startsWith("/search") &&
      miss.slot.state === "unsupported" && miss.slot.text.includes(aptos) &&
      miss.slot.text.includes(absent),
    "a version no transaction is published at stays on the search page and names the chain it checked",
    `searched ${absent}: landed ${miss.url.pathname}, state ${miss.slot.state}, ` +
      `text ${JSON.stringify(miss.slot.text.slice(0, 160))}`,
  );

  j.note(
    `${aptosRows.length} ${aptos} rows (versions ${[...published].sort().join(", ")}), ` +
      `${suiRows.length} ${sui} rows; version-ordered chains [${versionChains.join(", ")}], ` +
      `checkpoint-ordered [${checkpointChains.join(", ")}]`,
  );
}
