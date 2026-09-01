// "A visitor who opens a transaction with a trace lands in the debugging
//  interface, not in a waiting room."
//
// Page-Descriptions.md §7.0, first row of the table, and rule 1 taken literally:
//
//   "The transaction page is not a waiting room before the debugger; it is the
//    debugger's first frame."
//   "a button that opens the debugger is a link to the primary action, not the
//    primary action"
//
// WHAT MAKES THIS A JOURNEY AND NOT A RENDER TEST
// -----------------------------------------------
// `client/tests/test_debug_route.nim` asserts the debug ROUTE renders a session.
// It cannot assert this, because this claim is about the OTHER URL — the
// transaction's own address — and about a browser having loaded it. The
// anti-goal §7.0 names ("therefore the transaction page keeps a Debug button")
// is a fact about the rendered page, so it is asserted here as one: on a
// transaction that has a session, no control on the page offers to open a
// debugger, because the visitor is already in it.

import { visit } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "tx-page-is-the-session";
export const claim =
  "A visitor who opens a transaction with a trace lands in the debugging interface, not a waiting room.";
export const spec = "Page-Descriptions.md §7.0 (table row 1) — BlockTracer";
export const assertions = 10;

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const withSession = all.filter((t) => landingOf(t.phase) === "session");

  // NON-VACUITY FIRST. "every transaction with a session shows one" is true of
  // a tree with no such transaction, and would stay true if the exporter
  // stopped writing them.
  j.subjects(all, 10, "the exported tree carries transactions to walk");
  j.subjects(withSession, 3, "some of them have a session to land in");

  // EVERY ONE OF THEM, NOT A REPRESENTATIVE. The two seed defects this layer
  // was built from both survived because every assertion about a positioned
  // session ran on the demo chain — a sample of one, chosen by sort order.
  // `withSession` spans the demo chain AND the frozen real-chain captures, and
  // the counts below are asserted to equal its size, so a chain whose sessions
  // stopped rendering fails here by number rather than by luck of the draw.
  const seen = [];
  for (const t of withSession) {
    // Drive the TRANSACTION's own URL, not /debug. §7.0 is a claim about this
    // address; /debug is "the explicit full-viewport route" and a different one.
    const v = await visit(browser, site.origin, t.txPath);
    try {
      const affordances = await v.page.evaluate(() => ({
        // Rule 1's anti-goal, as an observable: a page that IS the primary
        // action does not also offer a link to it.
        debug: [...document.querySelectorAll("a, button")].filter((e) =>
          /^\s*(debug|open (in )?debugger|step through)\s*$/i.test(e.textContent ?? ""),
        ).length,
        // CONTROL ON THAT SELECTOR, through the SAME scan. A query that can
        // never match satisfies the zero above for free
        // (Verification-Harness-Traps.md §4a: the pairing is the control).
        labelled: [...document.querySelectorAll("a, button")].filter(
          (e) => (e.textContent ?? "").trim().length > 0,
        ).length,
      }));
      seen.push({ t, facts: v.facts, errors: v.pageErrors, affordances });
    } finally {
      await v.page.close();
    }
  }

  // BOTH PROVENANCES, NOT MERELY MORE THAN ONE CHAIN. This is the guard against
  // the condition that hid both seed defects: a subject set that is entirely
  // synthetic. A chain COUNT does not catch it — the tree carried three chains
  // while every positioned assertion still ran on the demo one — and a chain
  // NAME does not survive a rename, which this tree did within a day. The
  // product's own `data-provenance` is the question already answered.
  const synthetic = withSession.filter((t) => !t.real).length;
  const real = withSession.filter((t) => t.real).length;
  j.expect(
    synthetic >= 1 && real >= 1,
    "the sessions include both synthetic and real-capture transactions",
    `${synthetic} synthetic, ${real} real capture(s)`,
  );

  const errored = seen.filter((s) => s.errors.length > 0);
  j.countIs(
    errored.length,
    0,
    `no transaction page raised an uncaught error${
      errored.length ? `: ${errored[0].t.txPath} — ${errored[0].errors.join(" | ")}` : ""
    }`,
  );

  // §7.0's first row: "the debugging interface, with transaction metadata
  // rendered around it".
  const withPanes = seen.filter((s) => s.facts.paneTitles.length >= 5);
  j.countIs(
    withPanes.length,
    seen.length,
    `every one serves the debugging interface${
      withPanes.length === seen.length
        ? ` (panes: ${seen[0].facts.paneTitles.join(", ")})`
        : `: ${seen.find((s) => s.facts.paneTitles.length < 5).t.txPath} has ${
            seen.find((s) => s.facts.paneTitles.length < 5).facts.paneTitles.length
          }`
    }`,
  );

  // "it is the debugger's FIRST FRAME" — and §14.1a: "The page never degrades.
  // Every one of these states shows the complete transaction."
  //
  // NOT "every session shows source". A recording no source resolved for is at
  // instruction level — a specified state, and one an earlier draft of this
  // journey reported as six broken pages. What §14.1a requires is that a
  // session either shows its source or SAYS why it has none, and that the two
  // classes account for all of them.
  //
  // THE CLASSES ARE NO LONGER "HAS ROWS" VS "HAS PROSE", and that distinction is
  // what this pair used to be spelled with. A session with no source now renders
  // the program counters the recording carries, so it has rows AND states the
  // absence — `srclinesShown === 0` picked out nothing at all and the second
  // branch went empty. The rule is unchanged; what it is read from is the
  // corpus's `hasSource`, taken off the markup, so a contract whose artifact
  // resolves moves between these classes on its own.
  const showsSource = seen.filter((s) => s.t.hasSource && s.facts.srclinesShown >= 1);
  const statesAbsence = seen.filter(
    (s) => !s.t.hasSource && (s.facts.reasonText ?? "").trim().length > 0,
  );
  j.countIs(
    showsSource.length + statesAbsence.length,
    seen.length,
    `every session either shows its source or states why it has none` +
      ` (${showsSource.length} show it, ${statesAbsence.length} state its absence)${
        showsSource.length + statesAbsence.length === seen.length
          ? ""
          : `; silent: ${seen
              .filter((s) => s.facts.srclinesShown === 0 && !(s.facts.reasonText ?? "").trim())
              .map((s) => s.t.txPath)
              .join(", ")}`
      }`,
  );

  // Both classes are non-empty, so neither branch of the rule above is being
  // satisfied by an empty set. This is also the check that notices a corpus
  // that lost its real-chain captures: with only the demo chain, `statesAbsence`
  // goes to zero and the rule above still passes.
  j.atLeast(showsSource.length, 1, "some session shows source, so that branch has a subject");
  j.atLeast(
    statesAbsence.length,
    1,
    "some session states an absence, so that branch has a subject too",
  );

  j.countIs(
    seen.filter((s) => s.affordances.debug === 0).length,
    seen.length,
    "no page offers to open a debugger, because the visitor is already in one",
  );
  j.countIs(
    seen.filter((s) => s.affordances.labelled >= 1).length,
    seen.length,
    "CONTROL: the same scan finds labelled controls, so the zero above is a measurement",
  );
}
