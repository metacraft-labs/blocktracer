// "A visitor can trace a value to its origin — and until they can, the product
//  does not say they can."
//
// WHAT CHANGED, AND WHY THE JOURNEY DID NOT SIMPLY GO GREEN
// --------------------------------------------------------
// This journey was written as an implication: IF the home page promises that a
// value can be traced to its origin, THEN some control offers it. The promise
// has now been removed from `client/src/pages/home.nim` and `client/src/ssr.nim`,
// which under the old shape would have turned this file green by deleting its
// antecedent — a legitimate resolution, and the one that was taken, but one
// that would have taken the SIGNAL with it.
//
// So the journey keeps the id and inverts the first half. It now asserts that
// the false claim is GONE (a regression guard on the copy, in the one place a
// visitor and a search engine actually read it) and still asserts the
// capability, unconditionally. It is RED today on the capability half, and it
// goes green when the surface lands. That is the same signal, without the
// escape hatch.
//
// THE PREVIOUS DIAGNOSIS IN THIS FILE WAS WRONG, AND SO WAS ITS CONTROL ARM
// ------------------------------------------------------------------------
// It said the surface was "ONE ASSIGNMENT AWAY" — that `StateVM.originChainLookup`
// is declared and BlockTracer merely never assigns it. Both halves of that are
// true and the conclusion does not follow, because there is nothing to look the
// origin of UP. Measured against the pinned Embed SDK (`ci/embed-sdk-pin.env`,
// 8d1c84a8):
//
//   `ReplayDataStore.requestLocals` (store/replay_data_store.nim:664-680) sends
//   `ct/load-locals` and DISCARDS the reply. Its `onSuccess` sets
//   `loadingState` and `loadedForRRTicks` and nothing else, and its own comment
//   says why: "The actual JSON→Variable parsing will be added when the locals
//   panel is converted; for now we just update loading state."
//
//   The only writer of `store.locals.locals` is `updateLocals` (:795). Nothing
//   under `client/hydrate/` calls it — only `tests/tdebugpanes.nim` does, which
//   is why that suite is green about a data path the shipping bundle lacks.
//
// So `StateVM.currentVariables` is empty for the life of every hydrated
// session, `projectState` yields no values, and `hydrate.nim`'s PaneLatch —
// which only writes the State pane when `values.len > 0` — never fires. The
// visitor keeps looking at the STATICALLY EXPORTED State pane for as long as
// the tab is open.
//
// That is also what was wrong with the old control arm. It asserted
// `valuesShown >= 1` as its non-vacuity guard and concluded "there is something
// to ask the origin of". Those rows are the served frame's fixture text. The
// guard was satisfied by exactly the artefact whose persistence IS the defect,
// so the journey could not have detected the defect it was written for. This
// version measures the served frame and the hydrated page separately and
// compares them, which is the difference between "there are rows" and "the rows
// are the engine's".
//
// THE SECOND BLOCKER, WHICH OUTLIVES THE FIRST
// --------------------------------------------
// Fidelity. Every transaction this explorer publishes is declared rung 3, and
// `client/src/debugger/demo_session.nim` prints the consequence verbatim: "This
// recording carries no variable names: naming a local needs debug symbols,
// which an Aztec contract class does not publish." The origin classifier works
// by splitting the right-hand side of a source assignment (see codetracer's
// `tests/fixtures/origin/noir/simple_trivial_chain/ANSWERS.md`), so with no
// source and no names it has nothing to split. Fixing the SDK alone would give
// a live but nameless pane, and an origin chain over it would terminate at
// `UnknownVariable` on every hop.
//
// Where it WOULD be meaningful is the demo tour: eight real Noir programs
// recorded by `nargo trace`, each with a `sources/` tree and `varnames` in its
// trace. That — not the real chain — is the subject the surface should first be
// demonstrated on.

import { visit } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-value-can-be-traced-to-its-origin";
export const claim =
  "A visitor can trace a value to its origin — and until they can, the product does not say they can.";
export const spec =
  "client/src/pages/home.nim (the hero) and ssr.nim (the meta description) — the product's own promise, now withdrawn";
export const assertions = 9;
export const needsEngine = true;

const PROMISE = /trace any value to its origin/i;

/** The State pane's rows as the DOM holds them, from an already-loaded page. */
const READ_ROWS = () => {
  const shown = (e) =>
    !!e &&
    typeof e.checkVisibility === "function" &&
    e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
  const rows = [...document.querySelectorAll(".strow")];
  return {
    rows: rows.length,
    shown: rows.filter(shown).length,
    // The reading, not the markup: a class change elsewhere must not read as
    // "the engine supplied different values".
    text: rows.map((e) => (e.textContent ?? "").replace(/\s+/g, " ").trim()).join("|"),
  };
};

export async function run({ browser, site, j }) {
  // ---- half one: the product no longer claims what it cannot do -----------
  const home = await visit(browser, site.origin, "/");
  try {
    const rendered = await home.page.evaluate(() => document.body.innerText);
    j.expect(
      !PROMISE.test(rendered),
      "the home page does NOT promise that a value can be traced to its origin",
      PROMISE.test(rendered)
        ? "the sentence is back on screen — the surface must land before the copy does"
        : "the hero claims stepping and the call trace, both of which it has",
    );

    const meta = await home.page.evaluate(
      () =>
        document.querySelector('meta[name="description"]')?.getAttribute("content") ?? "",
    );
    j.expect(
      !PROMISE.test(meta),
      "and the meta description does not make the promise to search results either",
      meta.length > 0 ? "" : "NO meta description at all — this assertion would pass vacuously",
    );
    // Non-vacuity for the two above: an empty page and a missing tag each
    // satisfy "does not contain the sentence" for free.
    j.expect(
      rendered.length > 200 && meta.length > 40,
      "CONTROL: the page and the meta tag both have substantial copy, so the two absences above are measurements",
      `body ${rendered.length} chars, meta ${meta.length} chars`,
    );
  } finally {
    await home.page.close();
  }

  // ---- half two: the capability itself ------------------------------------
  const all = await transactions(site.root);
  const sessions = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(sessions, 3, "transactions whose landing is a session with source");

  const subject = sessions.find((t) => !t.real) ?? sessions[0];
  j.note(`driving ${subject.debugPath}`);

  // The SERVED frame: the same URL with scripting off, which is what the
  // exporter wrote and what the visitor sees before the bundle runs.
  //
  // `javaScriptEnabled` is a CONTEXT option in Playwright, not a page method —
  // this harness is Playwright (`chromium.launch` in lib/probe.mjs), and the
  // Puppeteer spelling `page.setJavaScriptEnabled(false)` throws here rather
  // than quietly leaving scripting on. Worth the sentence: a served-frame
  // reading taken with the bundle still running would compare the hydrated
  // page against itself and report "unchanged" for every session, which is the
  // failing verdict below arrived at for entirely the wrong reason.
  const servedCtx = await browser.newContext({ javaScriptEnabled: false });
  let served;
  try {
    const servedPage = await servedCtx.newPage();
    await servedPage.goto(site.origin + subject.debugPath, {
      waitUntil: "domcontentloaded",
      timeout: 45000,
    });
    served = await servedPage.evaluate(READ_ROWS);
  } finally {
    await servedCtx.close();
  }

  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  try {
    j.expect(
      live.settled && !live.timedOut,
      "the session went live, so the panes on screen are the bundle's to write",
      `phase=${live.facts.phase}`,
    );

    const probe = await live.page.evaluate(() => {
      const shown = (e) =>
        !!e &&
        typeof e.checkVisibility === "function" &&
        e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
      // Every spelling an origin affordance could plausibly take. Generous on
      // purpose: the claim is that NONE of them is present, and a narrow
      // selector would make that easy to satisfy by accident.
      const origin = [
        ...document.querySelectorAll("a, button, [data-action], [role=button]"),
      ].filter((e) =>
        /origin|where did this come from|provenance|trace value/i.test(
          `${e.textContent ?? ""} ${e.getAttribute("data-action") ?? ""} ${
            e.getAttribute("aria-label") ?? ""
          } ${e.getAttribute("title") ?? ""}`,
        ),
      );
      return {
        originAffordances: origin.length,
        interactive: [...document.querySelectorAll("a, button, [data-action]")].filter(shown)
          .length,
      };
    });
    const hydrated = await live.page.evaluate(READ_ROWS);

    // NON-VACUITY. Comparing two empty panes would report "unchanged" for a
    // reason that has nothing to do with the engine.
    j.atLeast(
      served.shown,
      1,
      `the SERVED frame already shows Values rows, so the comparison below has something to compare (${served.rows} rows, ${served.shown} shown)`,
    );

    // CONTROL, and the one the previous version of this journey lacked: the
    // bundle demonstrably rewrites SOMETHING on this page. Without it, "the
    // Values pane did not change" is equally explained by a bundle that never
    // ran, and the defect below would be indistinguishable from a dead engine.
    j.atLeast(
      probe.interactive,
      5,
      `CONTROL: the live page has ${probe.interactive} interactive controls and reached phase=ready, so the bundle ran`,
    );

    // THE DEFECT. `ct/load-locals` is sent and its reply discarded upstream, so
    // the pane the visitor ends up reading is byte-for-byte the one the
    // exporter wrote. A pane that is the engine's would differ.
    j.expect(
      hydrated.text !== served.text,
      "the Values pane a live session shows is the ENGINE's, not the served frame's",
      hydrated.text === served.text
        ? `identical to the served frame (${hydrated.rows} rows) — the SDK discards the ct/load-locals reply, so StateVM.currentVariables is empty and the PaneLatch never fires`
        : `served ${served.rows} rows, live ${hydrated.rows} rows`,
    );

    // THE CONSEQUENT.
    j.atLeast(
      probe.originAffordances,
      1,
      "some control offers to trace a value to its origin",
    );
  } finally {
    await live.page.close();
  }
}
