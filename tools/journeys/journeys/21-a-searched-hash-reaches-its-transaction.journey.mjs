// "A visitor who pastes a published transaction hash into the search box
//  arrives at that transaction."
//
// Page-Descriptions §11 ("Unambiguous input navigates immediately, without an
// intermediate results page") and §14's Object-not-found row ("'Not on this
// chain' with the chains checked, not a blank page"); Search-And-Routing §2
// (shape detection), §4 (direct path) and §5.4 ("Search must never fail
// because an index did not load").
//
// THE REPORT THIS FILE COMES FROM
// -------------------------------
// "The search doesn't seem to be functional. I tried searching for a tx hash."
//
// It was accurate, and the cause was this repository's signature defect in its
// purest form: an affordance that renders and cannot act. `/search` is reached
// by a real `<form action="/search" method="get">` from the home page and from
// the nav; the form submits; `/search/?q=…` returns 200 and renders. Every
// layer reported success. Nothing resolved anything, because a static file
// server cannot read `?q=` and `pageLayout` shipped no `<script>` — so the one
// component that could have read it, `SearchVM`, had exactly one caller in the
// entire repository and that caller was a unit test.
//
// The page even SAID so, in its own copy: "This deployment ships no script, so
// none of them ran." That sentence was true, was published, and was on the
// wrong side of the gate — it documented the defect instead of failing on it.
//
// WHY THIS IS A JOURNEY AND NOT A TEST ON `SearchVM`
// --------------------------------------------------
// Because `SearchVM` was already correct and already tested. `shapesOf`
// classified the user's hash perfectly; `resolve` would have found it. There is
// a green unit test over both. The defect lived entirely in the fact that
// nothing ever CONSTRUCTED the thing — precisely the shape run.mjs's rule 2 was
// written for, and precisely the shape its own preamble names in the sibling
// repo ("a suite literally named `test_every_entry_form_reaches_the_application`
// proves every URL form CLASSIFIES, while the function that would consult the
// classifier at run time has zero callers").
//
// So nothing below asserts that a handler fired, that a request was made, or
// that a viewmodel reached a state. What is asserted is where the visitor ENDS
// UP and what is on that page.
//
// WHY IT ASSERTS THE LANDING AND NOT A RESULTS LIST
// -------------------------------------------------
// §11's first bullet is "Unambiguous input navigates immediately, WITHOUT an
// intermediate results page". A single hit is therefore a navigation, and the
// strongest available reading of "search worked" is that the visitor is on the
// transaction's own page with the transaction's own hash rendered on it. A
// journey that stopped at "the search page listed a link" would pass over a
// link to a 404.
//
// NON-VACUITY (rule 3)
// --------------------
// Every hash searched is taken from the PUBLISHED corpus — `corpus.transactions`
// walks `{chain}/tx/{hash}/` in the built tree — so a test input nobody verified
// exists cannot enter. `j.subjects` asserts the sample is non-empty before
// anything quantifies, and the sample is one transaction PER CHAIN, so a build
// that publishes a chain the fan-out cannot reach fails here rather than being
// averaged away.
//
// AND THE MISS IS ASSERTED TOO, WHICH IS THE HALF THAT DISCRIMINATES
// -------------------------------------------------------------------
// "No results" and "nothing was looked in" render identically to a visitor and
// are completely different answers — the distinction `search_vm.nim` is built
// around and §14 requires. A gate that only checked the happy path would go
// green on a build that navigates correctly and then, for a hash nobody holds,
// prints a blank box. So the last two assertions search a well-formed hash
// DERIVED FROM a real one by changing a digit — verified absent from every
// published chain first — and require the page to say it was checked and name
// every chain it checked on.
//
// PROVEN TO BITE. On the tree before the fix (2f600bd, what
// blocktracer-dev.pages.dev was serving), built hydrated and driven by this
// file: 5 of 6 assertions RED. Every searched hash left the visitor on
// `/search/`, and the result slot the miss assertions read did not exist. See
// the commit message for the run.

import { transactions } from "../lib/corpus.mjs";

export const id = "a-searched-hash-reaches-its-transaction";
export const claim =
  "A visitor who pastes a published transaction hash into the search box arrives at that transaction.";
export const spec =
  "Page-Descriptions §11, §14; Search-And-Routing §2, §4, §5.4";
export const assertions = 8;

/** Load a URL and give the page's own script time to answer. */
async function open(browser, origin, path) {
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(origin + path, { waitUntil: "load", timeout: 45000 });
  return { page, close: () => context.close() };
}

/**
 * Search `q` and report where the visitor ended up.
 *
 * The wait is on the URL LEAVING `/search/`, not on a selector and not on a
 * fixed sleep: resolution is a fan-out of conditional fetches, so its duration
 * is a property of the corpus. A query that resolves navigates; one that does
 * not stays, and staying is the answer for the miss cases rather than a
 * timeout to be swallowed. 15s is far above the §8 budget (two requests,
 * < 300ms p75) and far below anything that would mask a hang.
 */
async function search(browser, origin, q) {
  const v = await open(browser, origin, `/search/?q=${encodeURIComponent(q)}`);
  try {
    await v.page
      .waitForURL((u) => !u.pathname.startsWith("/search"), { timeout: 15000 })
      .catch(() => {});
    // The slot is read AFTER the navigation race so a miss, which never
    // navigates, is read on the page that actually rendered it.
    const slot = await v.page.evaluate(() => {
      const el = document.getElementById("search-result");
      if (!el) return null;
      const inner = el.querySelector("[data-search-state]");
      return {
        state: inner?.getAttribute("data-search-state") ?? null,
        text: el.textContent.replace(/\s+/g, " ").trim(),
      };
    });
    return {
      url: new URL(v.page.url()),
      // The whole visible page, so "the hash is on screen" is a reading of what
      // was rendered rather than of one selector somebody could rename.
      body: await v.page.evaluate(() => document.body.innerText),
      // What the search box itself is showing. Read separately from the body
      // because it is the surface a visitor corrects a typo in.
      box: await v.page.evaluate(
        () => document.querySelector('input[name="q"]')?.value ?? null),
      slot,
    };
  } finally {
    await v.close();
  }
}

/** Does any chain publish an object at this hash? Read from the built tree. */
async function heldByAnyChain(origin, chains, hash) {
  for (const chain of chains) {
    const shard = hash.replace(/^0x/, "").slice(0, 4);
    for (const p of [
      `/d/${chain}/tx/${shard}/${hash}.json`,
      `/d/${chain}/block/${hash}.json`,
    ]) {
      const r = await fetch(origin + p).catch(() => null);
      if (r && r.ok) return true;
    }
  }
  return false;
}

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);

  // One transaction PER CHAIN. §5.4's fan-out is cross-chain by construction —
  // "resolved against every chain the registry publishes, concurrently" — and a
  // sample drawn from one chain would pass on an implementation that only ever
  // reached the first.
  const byChain = new Map();
  for (const t of all) if (!byChain.has(t.chain)) byChain.set(t.chain, t);
  const sample = [...byChain.values()];
  const chains = sample.map((t) => t.chain);

  j.subjects(sample, 1, "published transactions, one per chain, to search for");

  // ---- 1. the hash a visitor pastes reaches its transaction ---------------
  const wrongLanding = [];
  const hashNotOnPage = [];
  for (const t of sample) {
    const r = await search(browser, site.origin, t.hash);
    const want = `/${t.chain}/tx/${t.hash}`;
    if (!r.url.pathname.startsWith(want)) {
      wrongLanding.push(`${t.chain} ${t.hash.slice(0, 10)}… -> ${r.url.pathname}`);
      continue;
    }
    // The landing is necessary and not sufficient: a route that renders the
    // 404 shell under a correct-looking path would satisfy the line above.
    if (!r.body.includes(t.hash.slice(0, 18))) {
      hashNotOnPage.push(`${t.chain} ${t.hash.slice(0, 10)}…`);
    }
  }
  j.countIs(
    wrongLanding.length,
    0,
    `searching a published transaction hash arrives at that transaction${
      wrongLanding.length ? `: ${wrongLanding.slice(0, 3).join("; ")}` : ""
    }`,
  );
  j.countIs(
    hashNotOnPage.length,
    0,
    `the page a search arrived at renders the hash that was searched${
      hashNotOnPage.length ? `: ${hashNotOnPage.slice(0, 3).join("; ")}` : ""
    }`,
  );

  // ---- 2. the punctuation is not part of the identifier -------------------
  //
  // A hash is copied from a log line, a CSV column, a block explorer's table or
  // a chat message, and it arrives differently punctuated every time. Two spec
  // clauses bear on it and they pull in opposite directions, which is why this
  // is asserted over a TABLE of forms rather than one:
  //
  //   * SEO-And-Crawl-Budget §13.1 lists "Upper/lower-case hash alias" as an
  //     alias class that must resolve to ONE canonical encoding. Every
  //     published object is named in lowercase, so an upper-cased hash used to
  //     classify perfectly and then miss on every chain — reporting "not on
  //     this chain" about an object that is right there, which is a FALSE
  //     ABSENCE CLAIM and worse than the silence it replaced.
  //
  //   * Threat-Model §11 forbids normalisation that "collapses distinct
  //     identifiers into one result". Case is significant in base58, base64url
  //     and bech32 — §2's Solana, TON and Cardano rows — so the widening is
  //     HEX-ONLY, and the last row below is the one that would catch anybody
  //     who later replaces it with a blanket `.toLowerCase()`.
  //
  // The `0x` itself is punctuation the user did not choose. §2's table only
  // names the prefixed forms, so accepting a bare hash EXTENDS the spec; the
  // extension is asserted here because it is the difference between "search is
  // broken" and "search works" for anyone not pasting from an explorer URL.
  const subject = sample[0];
  const bare = subject.hash.replace(/^0x/, "");
  const forms = [
    ["as published", subject.hash],
    ["upper-cased, 0X prefix", "0X" + bare.toUpperCase()],
    ["mixed case", "0x" + bare.slice(0, 20).toUpperCase() + bare.slice(20)],
    ["no 0x prefix at all", bare],
    ["no prefix, upper-cased", bare.toUpperCase()],
    ["surrounded by whitespace", `  ${subject.hash} `],
  ];
  const formMisses = [];
  for (const [label, q] of forms) {
    const r = await search(browser, site.origin, q);
    if (!r.url.pathname.startsWith(`/${subject.chain}/tx/${subject.hash}`)) {
      formMisses.push(`${label} -> ${r.url.pathname}`);
    }
  }
  j.subjects(forms, 6, "punctuations of one published hash");
  j.countIs(
    formMisses.length,
    0,
    `every punctuation of a published hash arrives at the same transaction${
      formMisses.length ? `: ${formMisses.slice(0, 3).join("; ")}` : ""
    }`,
  );

  // THE LIMIT, asserted as a limit. `canonicalHash` lowercases hex and nothing
  // else; a query that is NOT hex must survive verbatim, because collapsing its
  // case would corrupt a real identifier into a different real-looking one.
  // There is no case-carrying chain in this corpus to resolve against, so what
  // is checked is that the page ECHOES the query it was given, unaltered.
  const cased = "EQAvDfWFG0oYX19jwNDNBBL1rKNT9XfaGP9HyTb5nb2Eml6y";
  const casedResult = await search(browser, site.origin, cased);
  j.expect(
    casedResult.box === cased,
    "a case-carrying non-hex identifier is echoed back uncollapsed",
    `searched a TON-shaped base64url address; the box shows ${
      JSON.stringify(casedResult.box)
    }`,
  );

  // ---- 3. a miss says it looked, and says where ---------------------------
  //
  // Derived from a real hash rather than invented, so it is well-formed by
  // construction and exercises the same shape; and verified ABSENT before it is
  // used, so this is a statement about a genuine miss rather than about a
  // string that happened to 404 for some other reason.
  const base = sample[0].hash.replace(/^0x/, "");
  const absent =
    "0x" + (base[0] === "f" ? "e" : "f") + base.slice(1);
  const reallyAbsent = !(await heldByAnyChain(site.origin, chains, absent));
  const miss = await search(browser, site.origin, absent);

  j.expect(
    reallyAbsent && miss.slot?.state === "notfound",
    "a well-formed hash no chain holds is reported as looked-for and not found",
    reallyAbsent
      ? `slot state was ${JSON.stringify(miss.slot?.state ?? null)} at ${miss.url.pathname}`
      : `PRECONDITION FAILED: ${absent.slice(0, 14)}… is published after all, so this measures nothing`,
  );

  // §14, literally: "'Not on this chain' WITH THE CHAINS CHECKED". A miss that
  // names nothing is the blank page the row forbids, and it is also the exact
  // rendering a build that searched nothing at all would produce.
  const unnamed = chains.filter((c) => !(miss.slot?.text ?? "").includes(c));
  j.countIs(
    unnamed.length,
    0,
    `the miss names every published chain it checked${
      unnamed.length ? `: missing ${unnamed.join(", ")}` : ""
    }`,
  );

  j.note(
    `${all.length} published transactions over ${chains.length} chains ` +
      `(${chains.join(", ")}); searched ${sample.length} hashes, one per chain, ` +
      `plus ${forms.length} punctuations of one of them, one case-carrying ` +
      `non-hex identifier, and one absent hash.`,
  );
}
