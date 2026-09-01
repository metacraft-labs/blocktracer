// "What a visitor lands in is decided by the trace's availability, and every
//  transaction lands in one of exactly three things."
//
// Page-Descriptions.md §7.0, the table in full:
//
//   | ready, divergent      | The debugging interface, with transaction
//   |                       | metadata rendered around it (§7.1)
//   | onDemand              | The metadata, and the generate action
//   | absent, unsupported   | The metadata, with the reason stated.
//   |                       | No debugger, and no pretence of one
//
// and §14.1a's rule over all of them: "The page never degrades. Every one of
// these states shows the complete transaction; what varies is whether a debugger
// can be opened over it."
//
// WHY THIS IS COUNTED OVER THE WHOLE CORPUS
// -----------------------------------------
// "No pretence of one" is a negative claim, and a negative claim over a set is
// satisfied by an empty set (Verification-Harness-Traps.md §4). So: the corpus
// size is asserted, every page is classified, the per-class totals are asserted
// to SUM to the corpus, and an unclassified page is a named failure rather than
// a silent fourth class. A phase renamed in `session_view.nim` fails here, by
// name, instead of quietly reclassifying half the tree.
//
// The three classes are also asserted to be non-empty INDIVIDUALLY. A corpus in
// which every transaction happened to be `unavailable` would satisfy every
// per-class rule below for free, and would be the state this suite most needs to
// notice — it is what a chain capture that stopped publishing traces looks like.

import { visit } from "../lib/probe.mjs";
import { transactions, landingOf, LANDINGS } from "../lib/corpus.mjs";

export const id = "availability-decides-the-landing";
export const claim =
  "What a visitor lands in is decided by the trace's availability, and every transaction lands in one of exactly three things.";
export const spec = "Page-Descriptions.md §7.0 (the table), §14.1a — BlockTracer";
export const assertions = 13;

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  j.subjects(all, 20, "the exported tree carries transactions to classify");

  // ---- classification, over the whole corpus, from static bytes ----------
  const byClass = { session: [], generate: [], stated: [] };
  const unclassified = [];
  for (const t of all) {
    const cls = landingOf(t.phase);
    if (cls === null) unclassified.push(t);
    else byClass[cls].push(t);
  }

  j.countIs(
    unclassified.length,
    0,
    `every transaction's phase is one §7.0 names${
      unclassified.length
        ? `: unclassified ${unclassified.map((t) => `${t.chain}/${t.hash.slice(0, 10)}=${t.phase}`).join(", ")}`
        : ` (the phases §7.0 knows: ${Object.values(LANDINGS).flat().join(", ")})`
    }`,
  );
  j.countIs(
    byClass.session.length + byClass.generate.length + byClass.stated.length,
    all.length,
    "the three classes sum to the corpus, so none was counted twice or dropped",
  );

  // Each class is non-empty, so the per-class rules below have a subject.
  j.atLeast(byClass.session.length, 1, "§7.0 row 1 (ready/divergent) has members");
  j.atLeast(byClass.generate.length, 1, "§7.0 row 2 (onDemand) has members");
  j.atLeast(byClass.stated.length, 1, "§7.0 row 3 (absent/unsupported) has members");
  j.note(
    `corpus ${all.length}: session ${byClass.session.length}, ` +
      `generate ${byClass.generate.length}, stated ${byClass.stated.length}`,
  );

  // ---- the three rows, each driven in a browser --------------------------
  const drive = async (t) => {
    const v = await visit(browser, site.origin, t.debugPath);
    try {
      return { facts: v.facts, errors: v.pageErrors };
    } finally {
      await v.page.close();
    }
  };

  // Row 1 — the debugging interface. Stepping controls exist (live or declared
  // inert; §7.0's capability ladder says an engine that never loads still
  // leaves the served page standing).
  const r1 = await drive(byClass.session[0]);
  j.countIs(
    r1.facts.controlsLive + r1.facts.controlsInert,
    8,
    `row 1 serves the eight stepping controls (${byClass.session[0].debugPath})`,
  );

  // Row 2 — the metadata and the generate action. ONE action, not "an action":
  // §7.0 says "the generate action", singular.
  const r2 = await drive(byClass.generate[0]);
  j.countIs(
    r2.facts.controlsLive + r2.facts.controlsInert,
    0,
    "row 2 offers no stepping controls",
  );
  j.countIs(r2.facts.buttons, 1, "row 2 offers exactly one action — the generate action");

  // Row 3 — "No debugger, and no pretence of one", and the reason is STATED.
  const r3 = await drive(byClass.stated[0]);
  j.countIs(
    r3.facts.controlsLive + r3.facts.controlsInert,
    0,
    "row 3 offers no stepping controls",
  );
  j.countIs(r3.facts.buttons, 0, "row 3 makes no pretence of a debugger — no action at all");
  j.expect(
    (r3.facts.reasonText ?? "").trim().length > 0,
    "row 3 states the reason, in the producer's own words",
    `reason reads ${JSON.stringify((r3.facts.reasonText ?? "").slice(0, 90))}`,
  );

  // §14.1a over all three: "The page never degrades. Every one of these states
  // shows the complete transaction." Asserted as RENDERED text, so a page that
  // laid out nothing cannot satisfy it.
  const thin = [
    ["row 1", r1],
    ["row 2", r2],
    ["row 3", r3],
  ].filter(([, r]) => r.facts.visibleText <= 200);
  j.countIs(
    thin.length,
    0,
    `every row still shows the complete transaction${
      thin.length ? `: thin rows ${thin.map(([n, r]) => `${n}=${r.facts.visibleText}ch`).join(", ")}` : ""
    }`,
  );
}
