// "A visitor who pastes a published account address into the search box arrives
//  at that address's page, on the chain that holds it."
//
// Search-And-Routing §2 (shape detection, and its ambiguity paragraph: "a single
// input may match several shapes; all matches are carried forward ... exactly one
// answers"), §5 (the hash index, an exact map from an identifier to every
// `(chain, kind)` that claims it), Page-Descriptions §11 ("Unambiguous input
// navigates immediately") and §14 (a miss says it looked).
//
// WHY ADDRESSES NEED THEIR OWN JOURNEY
// ------------------------------------
// Journey 21 searches transaction hashes, and the two take different routes
// through the client. `searchboot`'s direct path (`candidatesFor`) builds a
// transaction and a block candidate and NO address candidate — its own comment
// says so — so an address resolves only through the hash index, whose `hkAddress`
// claims the validator requires for every walked address. Nothing searched an
// address end to end, so nothing would have noticed that path breaking.
//
// WHERE THE AMBIGUITY IS JUDGED, AND WHY NOT HERE
// -----------------------------------------------
// Recorder-Flow CXP-FLOW-6's verification asks that a Flow account address (`0x`
// + 16 hex) resolve while "the same string also dispatches against Starknet and
// exactly one answers": §2's Cadence row overlaps the Starknet felt row on
// purpose. A journey cannot carry that claim. It names no chain (run.mjs rule 1),
// and the `journeys` job runs over `.#default`, which publishes address pages for
// one chain only, so an arm asking for an address well-formed on two published
// chains has no subject there, and a missing subject is a failure. The claim is
// asserted one layer down instead, over the real `indexProbesOf`, `indexPlanFor`
// and `hitsFor` with a Flow and a Starknet claim in one shard:
// `client/tests/test_searchboot.nim`, suite "a Flow account address resolves
// through the index, on the one chain that holds it". This journey carries the
// end-to-end half on every build.
//
// MEASURED OVER `.#site-staging` (blocktracer ec7bf03, 2026-10-23), which does
// publish Flow: Flow's `0x18eb4ee6b3c026d2` and the Ethereum, Starknet, Sui and
// demo addresses each landed on their address page. Solana's system program
// `111…1` did NOT: it is 32 characters, outside §2's 43–44 base58 band, so the
// classifier returns "unsupported" for a published address. That is recorded as
// its own issue (codetracer-pm `issues/2026-10-23-search-refuses-a-published-
// solana-address-shorter-than-43-characters.md`) and is why this journey is red on
// that build.
//
// NON-VACUITY (rule 3): one published address PER CHAIN, read from the built
// tree's `{chain}/address/{addr}/` pages. The miss is a real address with one
// digit changed, verified absent from every chain's address pages first.

export const id = "a-searched-address-reaches-its-address-page";
export const claim =
  "A visitor who pastes a published account address into the search box arrives at that address's page.";
export const spec = "Search-And-Routing §2, §5; Page-Descriptions §11, §14";
export const assertions = 5;

import { readdir } from "node:fs/promises";
import { join } from "node:path";

async function subdirs(p) {
  return readdir(p, { withFileTypes: true })
    .then((es) => es.filter((e) => e.isDirectory()).map((e) => e.name))
    .catch(() => []);
}

/** Search `q` and report where the visitor ended up (journey 21's reading). */
async function search(browser, origin, q) {
  const context = await browser.newContext();
  const page = await context.newPage();
  try {
    await page.goto(`${origin}/search/?q=${encodeURIComponent(q)}`,
                    { waitUntil: "load", timeout: 45000 });
    await page
      .waitForURL((u) => !u.pathname.startsWith("/search"), { timeout: 15000 })
      .catch(() => {});
    const slot = await page.evaluate(() => {
      const el = document.getElementById("search-result");
      const inner = el?.querySelector("[data-search-state]");
      return el ? { state: inner?.getAttribute("data-search-state") ?? null } : null;
    });
    return {
      url: new URL(page.url()),
      body: await page.evaluate(() => document.body.innerText),
      slot,
    };
  } finally {
    await context.close();
  }
}

export async function run({ browser, site, j }) {

  // One published address per chain, and every chain's address set for the
  // absence check.
  const held = new Map();
  for (const chain of await subdirs(site.root)) {
    const addrs = await subdirs(join(site.root, chain, "address"));
    if (addrs.length > 0) held.set(chain, new Set(addrs));
  }
  const sample = [...held].map(([chain, set]) => ({ chain, address: [...set].sort()[0] }));
  j.subjects(sample, 1, "published addresses, one per chain, to search for");

  const wrongLanding = [];
  const notOnPage = [];
  const landed = new Set();
  for (const s of sample) {
    const r = await search(browser, site.origin, s.address);
    if (!r.url.pathname.startsWith(`/${s.chain}/address/${s.address}`)) {
      wrongLanding.push(`${s.chain} ${s.address.slice(0, 12)}… -> ${r.url.pathname}` +
                        `${r.slot?.state ? ` (${r.slot.state})` : ""}`);
      continue;
    }
    landed.add(s.chain);
    if (!r.body.includes(s.address)) notOnPage.push(`${s.chain} ${s.address.slice(0, 12)}…`);
  }
  j.countIs(wrongLanding.length, 0,
    `searching a published address arrives at that address's page${
      wrongLanding.length ? `: ${wrongLanding.slice(0, 4).join("; ")}` : ""}`);
  j.countIs(notOnPage.length, 0,
    `the page a search arrived at renders the address that was searched${
      notOnPage.length ? `: ${notOnPage.slice(0, 3).join("; ")}` : ""}`);

  // ── a miss says it looked ─────────────────────────────────────────────────
  // Derived from a `0x`-prefixed address, whose last digit can be changed and stay
  // well-formed; a base58 one would need its own alphabet rule.
  const hexAddressed = sample.filter((s) => s.address.startsWith("0x"));
  j.atLeast(hexAddressed.length, 1, "SUBJECTS: a 0x-prefixed address to derive a miss from");
  const base = hexAddressed[0];
  const last = base.address.at(-1);
  const absent = base.address.slice(0, -1) + (last === "0" ? "1" : "0");
  const reallyAbsent = ![...held.values()].some((set) => set.has(absent));
  const miss = await search(browser, site.origin, absent);
  j.expect(reallyAbsent && miss.slot?.state === "notfound",
    "a well-formed address no chain holds is reported as looked-for and not found",
    reallyAbsent
      ? `slot state was ${JSON.stringify(miss.slot?.state ?? null)} at ${miss.url.pathname}`
      : `PRECONDITION FAILED: ${absent.slice(0, 14)}… is published after all`);

  j.note(`${sample.length} chains publish address pages (${[...held.keys()].join(", ")}); ` +
         `${landed.size} of their sampled addresses were searched and landed on their page.`);
}
