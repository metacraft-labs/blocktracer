// "A visitor reading a transaction list can tell which transactions can be
//  debugged against source, and the badge never claims more than the recording
//  carries."
//
// Page-Descriptions.md §6 (the shared transactions table, column 1 — the Debug
// affordance, "first column, always visible"), §7.1 (the transaction's facts
// rendered in two places from one source), §9 (where the word *verification*
// belongs, and where it does not).
//
// WHY THIS CLAIM HAD NOTHING ASSERTING IT
// ---------------------------------------
// Every list in this product showed a `Debug` button of identical weight for a
// transaction that steps through Noir source and one that steps through bare
// opcodes. Both are correct sessions; they are not the same offer. The only way
// to find out which one a row was came down to opening it, and the two seed
// defects this suite exists for both survived because nothing anywhere stated
// what a visitor could tell from a page WITHOUT opening something.
//
// THE HARD PART IS THAT A TRANSACTION IS NOT ONE CONTRACT
// ------------------------------------------------------
// A transaction executes several contracts and the runtime resolves them one at
// a time, so "some of this transaction has source" is a normal shape and not an
// edge case. That is why the strong state is worded *available* and not
// *verified*, and it is why the assertions below are counted per ROW against
// the per-contract evidence rather than per chain.
//
// AND IT IS WHY `verified` MAY NOT APPEAR
// ---------------------------------------
// `artifactHash` is the chain's commitment to the ARTIFACT and does not commit
// to its `debug_symbols` or its `file_map`: an artifact with every source
// location rewritten passes all three acceptance checks, and a published npm
// decoy ships bytecode byte-identical to a deployed class under a different
// artifact hash with different debug symbols. A row that said `verified` would
// be making a claim about the source TEXT that nothing in the chain backs.
// §9's contract source browser owns that word, over a provider's match level.
//
// WHAT IS COMPARED AGAINST WHAT
// -----------------------------
// The page is read in a browser, with `checkVisibility`, so a badge that is in
// the DOM and painted nowhere is not a pass. It is judged against the PUBLISHED
// `/d/**` FACTS — `native.replay.artifacts`, the recording's own
// `ct.source-provenance` — folded independently in `corpus.sourceStateOf`.
// Comparing a page to another page would be satisfied by two surfaces agreeing
// on the same wrong answer; comparing a page to the evidence is the claim.
//
// NON-VACUITY, AND THE ONE THING THIS JOURNEY DELIBERATELY DOES NOT DEMAND
// -----------------------------------------------------------------------
// Rule 3: the page count, the row count and every total are asserted with
// `countIs`, so a corpus that lost its transaction lists fails here rather than
// sweeping. What is NOT demanded is that every state have members. Of the eight
// containers frozen into this tree, exactly one executes a class anybody
// publishes and those captures predate off-chain artifact resolution entirely,
// so today every measured row is in one state. Demanding one row per state
// would make this journey a statement about which captures happen to be frozen
// rather than about what a visitor can tell — and it would go red on a
// perfectly correct build. The distribution is NOTED instead, and the
// agreement-with-the-evidence assertion is what has teeth in every distribution.

import { visit } from "../lib/probe.mjs";
import { transactionListPages, publishedFacts, sourceStateOf } from "../lib/corpus.mjs";

export const id = "a-transaction-list-says-what-can-be-debugged";
export const claim =
  "A visitor reading a transaction list can tell which transactions can be debugged against source, and the badge never claims more than the recording carries.";
export const spec = "Page-Descriptions.md §6, §7.1, §9 — BlockTracer";
export const assertions = 16;

/** Read every row of every transactions table on the page in front of us. */
const readRows = (page) =>
  page.evaluate(() => {
    const shown = (e) =>
      !!e && typeof e.checkVisibility === "function"
        ? e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })
        : false;
    const rows = [];
    for (const tr of document.querySelectorAll("table.txtbl tbody tr")) {
      const act = tr.querySelector("td.act");
      const link = tr.querySelector('td.hash a[href*="/tx/"]');
      if (!link) continue; // the empty-state row carries no transaction
      const badge = tr.querySelector("[data-sources]");
      rows.push({
        hash: link.getAttribute("href").split("/tx/")[1].split("/")[0],
        state: badge?.getAttribute("data-sources") ?? null,
        text: badge?.textContent?.trim() ?? null,
        // THE STATE WORDS ALONE, WITH THE RATIO TAKEN OFF STRUCTURALLY.
        //
        // The badge is `display:flex; gap:4px` and holds two items: the state
        // label, and — for `partial` and `none` — a `.mono` ratio. The gap is a
        // CSS token, so it is NOT a character: `textContent` reads
        // `Instruction level0/1` for a badge that renders `Instruction level 0/1`
        // four pixels apart. `tables.nim` chose the gap deliberately, because a
        // literal `" "` is whitespace between flex items and gets stripped —
        // which is how a ratio came to read as part of the word before it.
        //
        // So the ratio is removed by ELEMENT rather than by splitting on spaces.
        // A word-boundary heuristic over this string cannot work and cannot be
        // made to: there is no boundary in the DOM to find.
        label: (() => {
          if (!badge) return null;
          const ratio = badge.querySelector(".mono");
          if (!ratio) return badge.textContent.trim();
          return [...badge.childNodes]
            .filter((n) => n !== ratio)
            .map((n) => n.textContent)
            .join("")
            .trim();
        })(),
        visible: shown(badge),
        // §6 column 1 is the one column that never scrolls out of view, and the
        // badge is a statement about the control in it. A badge that rendered
        // at the far right of a horizontally scrolling table would satisfy a
        // whole-document query and would be exactly what §6 rules out.
        inFirstColumn: !!badge && !!act && act.contains(badge),
        // The action must still be the only control in the cell.
        controlsInCell: act ? act.querySelectorAll("a, button").length : 0,
      });
    }
    return rows;
  });

export async function run({ browser, site, j }) {
  const pages = await transactionListPages(site.root);
  j.subjects(pages, 3, "exported pages rendering the shared transactions table");

  // ---- every row of every list, read from a real browser -------------------
  const rows = [];
  const pagesWithRows = [];
  for (const p of pages) {
    const v = await visit(browser, site.origin, p.path);
    try {
      const found = await readRows(v.page);
      if (found.length) pagesWithRows.push(p.path);
      for (const r of found) rows.push({ ...r, page: p.path, chain: p.path.split("/")[1] });
    } finally {
      await v.page.close();
    }
  }
  j.subjects(rows, 10, "rows across those pages, each naming a transaction");
  j.atLeast(pagesWithRows.length, 3, "the rows come from more than one page kind");

  // ---- the evidence, folded independently from the published facts ---------
  const evidence = new Map();
  let unreadable = 0;
  for (const r of rows) {
    const key = `${r.chain}/${r.hash}`;
    if (evidence.has(key)) continue;
    const facts = await publishedFacts(site.root, r.chain, r.hash);
    if (facts === null) unreadable++;
    else evidence.set(key, sourceStateOf(facts));
  }
  j.countIs(
    unreadable,
    0,
    "every transaction a row links to has published facts to judge the row against",
  );

  // ---- 1. the page agrees with the tree, row by row ------------------------
  const disagree = [];
  for (const r of rows) {
    const want = evidence.get(`${r.chain}/${r.hash}`);
    if (r.state !== want) disagree.push(`${r.page} ${r.hash.slice(0, 10)} page=${r.state} tree=${want}`);
  }
  j.countIs(
    disagree.length,
    0,
    `every row states the state its recording carries${disagree.length ? `: ${disagree.slice(0, 4).join("; ")}` : ""}`,
  );

  // ---- 2. a stated row states it VISIBLY, in the first column --------------
  const stated = rows.filter((r) => r.state !== null);
  const unstated = rows.filter((r) => r.state === null);
  // BOTH BRANCHES NEED A SUBJECT, AND NEITHER HAD ONE.
  //
  // Nine of this journey's thirteen assertions are `countIs(…, 0)` over a subset
  // of `rows`, and `rows` itself is asserted (123 of them). But the SUBSETS were
  // not: a renderer that stopped emitting the badge entirely empties `stated`,
  // and the two assertions below become `countIs(0, 0)` — a clean pass over a
  // list that has stopped saying anything at all, which is the exact defect §6
  // is about. The mirror holds for `unstated` and claim 3.
  //
  // Measured: 123 rows over 54 lists, 24 stated and 99 not. The floors are
  // existential rather than counted because the split is a property of whichever
  // recordings the chain has published, not a number this file may pin — but an
  // existential floor on a set that CAN empty is the difference between a
  // vacuous pass and a red, which is what these are for.
  j.atLeast(stated.length, 1, "SUBJECTS: rows whose recording states a source resolution");
  j.atLeast(unstated.length, 1, "SUBJECTS: rows that say nothing about source");
  j.countIs(
    stated.filter((r) => !r.visible || !r.text).length,
    0,
    "every source statement is rendered, not merely present in the DOM",
  );
  j.countIs(
    stated.filter((r) => !r.inFirstColumn).length,
    0,
    "every source statement sits in §6 column 1, beside the action it qualifies",
  );
  j.countIs(
    rows.filter((r) => r.controlsInCell > 1).length,
    0,
    "the badge did not become a second control: §6 column 1 still holds exactly one",
  );

  // ---- 3. silence is only ever where no resolution was applied ------------
  // The negative direction of the same claim. A row with no badge must be a row
  // whose transaction has no replay record — not a row the renderer forgot.
  j.countIs(
    unstated.filter((r) => evidence.get(`${r.chain}/${r.hash}`) !== null).length,
    0,
    "a row says nothing about source only where no artifact resolution was applied",
  );

  // ---- 4. no row claims more than the recording carries -------------------
  // Non-vacuous because the row count above is asserted: this is a filter over
  // a set whose size is known, not an "at least one" over a set that may be
  // empty.
  const overclaims = rows.filter(
    (r) => (r.state === "all" || r.state === "partial") && evidence.get(`${r.chain}/${r.hash}`) === "none",
  );
  j.countIs(overclaims.length, 0, "no row claims sources for a recording that resolved none");
  j.countIs(
    rows.filter((r) => (r.text ?? "").toLowerCase().includes("verif")).length,
    0,
    "no row says `verified`: the chain commits to the bytecode, not to the source text",
  );

  // ---- 5. one transaction reads the same in every list it appears in ------
  // §7.1's rule is about one transaction's facts on two surfaces. Transaction
  // lists are the same fact on up to four page kinds, and a per-page derivation
  // is exactly how they would come to disagree.
  const byTx = new Map();
  for (const r of rows) {
    const key = `${r.chain}/${r.hash}`;
    if (!byTx.has(key)) byTx.set(key, new Set());
    byTx.get(key).add(String(r.state));
  }
  const inconsistent = [...byTx.entries()].filter(([, s]) => s.size > 1);
  j.countIs(
    inconsistent.length,
    0,
    `a transaction reads the same in every list it appears in${inconsistent.length ? `: ${inconsistent.map(([k]) => k).join(", ")}` : ""}`,
  );

  // ---- 6. and the transaction's own page says the same thing --------------
  // The list is where a visitor chooses; the transaction page is where they
  // act. A list that promised source and a page that did not mention it would
  // be the divergence §7.1 exists to forbid.
  const pageDisagrees = [];
  // THE `continue` SKIPS THE ONLY THING THIS BLOCK DOES, so how many times it
  // did NOT skip is the whole question. A corpus in which every row is silent
  // takes the `continue` on all 54 lists, opens no page, compares nothing, and
  // `countIs(pageDisagrees.length, 0)` prints a pass — the §7.1 divergence check
  // reporting green having loaded not one transaction page. Counted here and
  // asserted below, which is `run.mjs`'s declared-assertion rule applied inside
  // a loop the declared count cannot see into.
  let pagesCompared = 0;
  for (const [key, states] of byTx) {
    const state = [...states][0];
    if (state === "null") continue;
    const [chain, hash] = key.split("/");
    const v = await visit(browser, site.origin, `/${chain}/tx/${hash}`);
    try {
      // EVERY `dt`, not `.dl dt`. §7.0 routes a `ready` transaction's own URL
      // to the debugging session, whose metadata pane is the SAME `MetaRow`
      // seq rendered by a different component into `.mddl` — which is exactly
      // the divergence §7.1 forbids and exactly what a class-scoped selector
      // here would have failed to notice, by reporting both surfaces silent.
      const said = await v.page.evaluate(() => {
        const dt = [...document.querySelectorAll("dt")].find(
          (e) => e.textContent.trim() === "Sources",
        );
        return dt?.nextElementSibling?.textContent?.trim() ?? null;
      });
      // THE STATE, NOT THE DENSITY. The two surfaces render the same
      // `sourcesState(...)` — one function, so a copy edit moves both together —
      // and then differ ON PURPOSE in what they add to it: the list appends the
      // ratio, because `0/1` is the actionable part of a partial row in a table;
      // the page states the whole thing in a sentence in its own `dd`. That is
      // affordance, not divergence, and §7.1 forbids the second.
      //
      // This used to take `want.split(" ").slice(0, 2)` off the list's full
      // badge text. Two words was already a guess, and it broke outright the
      // first time a real transaction reached a state that carries a ratio:
      // `Instruction level0/1` split to `["Instruction", "level0/1"]`, and no
      // page starts with `level0/1`. Comparing the label removes the guess —
      // and it is STRICTER than the old prefix, because it matches the whole
      // state rather than its first two words (`No contract code` was only ever
      // checked as far as `No contract`).
      const want = rows.find((r) => r.chain === chain && r.hash === hash)?.label ?? null;
      if (said === null || want === null || !said.startsWith(want)) {
        pageDisagrees.push(`${key} list=${want} page=${said}`);
      }
      pagesCompared += 1;
    } finally {
      await v.page.close();
    }
  }
  j.atLeast(
    pagesCompared,
    1,
    "SUBJECTS: transaction pages opened and compared against the row that promised them",
  );
  j.countIs(
    pageDisagrees.length,
    0,
    `the transaction's own page states what its list row did${pageDisagrees.length ? `: ${pageDisagrees.slice(0, 3).join("; ")}` : ""}`,
  );

  const dist = {};
  for (const r of rows) dist[String(r.state)] = (dist[String(r.state)] ?? 0) + 1;
  j.note(
    `${rows.length} rows over ${pagesWithRows.length} lists; states ` +
      Object.entries(dist)
        .sort()
        .map(([k, n]) => `${k}=${n}`)
        .join(", "),
  );
}
