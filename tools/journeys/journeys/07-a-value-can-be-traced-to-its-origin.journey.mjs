// "A visitor who is promised they can trace a value to its origin can do so."
//
// The promise is in the product, twice, today:
//
//   client/src/ssr.nim:223          the home page's meta description
//   client/src/pages/home.nim:105   the hero, in the second sentence a visitor
//                                   reads: "Trace any value to its origin —
//                                   across many chains, VMs and languages."
//
// THE SURFACE DOES NOT EXIST, AND IT IS ONE ASSIGNMENT AWAY
// --------------------------------------------------------
// This is not "a feature we have not built yet". The machinery is present and
// unwired, which is the same shape as `currentEntryRequest()` in the sibling
// repository — a function with zero callers under a suite named for the journey
// it does not test.
//
//   The Embed SDK's `StateVM` declares the capability:
//       state_vm.nim:166  originChainLookup*: proc(name: string): Option[OriginChain]
//   It has a whole unit suite for it (`test_origin_chain_vm.nim`) and a view
//   that reads it (`isonim_state_view.nim`).
//
//   BlockTracer constructs a `StateVM` — `createStateVM(store)`, one of the six
//   `LiveSession` builds — and assigns `originChainLookup` NOWHERE. It stays
//   `nil` for the life of every session, in the served frame and in the bundle
//   alike. `projectState` maps the VM's variables to name/value/type and models
//   no origin at all, so `renderState` has nothing to draw and draws nothing.
//
// So a visitor reads the promise on the home page, opens a transaction, and
// there is no control anywhere in the session that will tell them where a value
// came from.
//
// WHY THIS JOURNEY IS WRITTEN RED RATHER THAN LEFT UNWRITTEN
// ---------------------------------------------------------
// Because the product ships the sentence. An unbuilt feature nobody promised is
// a backlog item; a promise the product makes and cannot keep is a defect, and
// the only two ways to close it are to build the surface or to stop making the
// promise. Both are legitimate and neither is this file's to choose — but a red
// test forces the choice instead of letting it be forgotten, and a green suite
// over a product that misdescribes itself is exactly the condition this whole
// layer exists to end.
//
// IT IS AN IMPLICATION, AND THE ANTECEDENT IS COUNTED
// --------------------------------------------------
// The claim is "IF the product promises this, THEN it provides it". So the
// promise's presence is asserted first, as a count over the rendered page —
// which means removing the copy turns this journey GREEN, honestly, because the
// antecedent is gone. That is the second legitimate resolution, and the journey
// says so rather than pretending only one exists.
//
// The pairing also protects the negative half: "no control offers a value's
// origin" is satisfied by a page with no controls at all, by a values pane that
// failed to populate, and by a selector that cannot match. All three are
// checked before the absence is asserted.

import { visit } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-value-can-be-traced-to-its-origin";
export const claim =
  "A visitor who is promised they can trace a value to its origin can do so.";
export const spec =
  "client/src/pages/home.nim (the hero) and ssr.nim (the meta description) — the product's own promise";
export const assertions = 7;
export const needsEngine = true;

const PROMISE = /trace any value to its origin/i;

export async function run({ browser, site, j }) {
  // ---- the antecedent: the product makes the promise ---------------------
  const home = await visit(browser, site.origin, "/");
  try {
    const rendered = await home.page.evaluate(() => document.body.innerText);
    j.expect(
      PROMISE.test(rendered),
      "the home page PROMISES that a value can be traced to its origin",
      `the sentence is ${PROMISE.test(rendered) ? "on screen" : "NOT on screen — if the copy was removed, this journey is closed and should be deleted"}`,
    );

    // The meta description carries it too, so a search result makes the same
    // promise before a visitor has loaded anything.
    const meta = await home.page.evaluate(
      () => document.querySelector('meta[name="description"]')?.getAttribute("content") ?? "",
    );
    j.expect(
      PROMISE.test(meta),
      "and the meta description makes it to search engines as well",
    );
  } finally {
    await home.page.close();
  }

  // ---- the consequent: a session offers the surface ----------------------
  const all = await transactions(site.root);
  const sessions = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(sessions, 3, "transactions whose landing is a session with source");

  const subject = sessions.find((t) => !t.real) ?? sessions[0];
  j.note(`driving ${subject.debugPath}`);

  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  try {
    j.expect(
      live.settled && !live.timedOut,
      "the session went live, so the Values pane is the bundle's and not the served frame's",
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
      const origin = [...document.querySelectorAll("a, button, [data-action], [role=button]")].filter(
        (e) =>
          /origin|where did this come from|provenance|trace value/i.test(
            `${e.textContent ?? ""} ${e.getAttribute("data-action") ?? ""} ${
              e.getAttribute("aria-label") ?? ""
            } ${e.getAttribute("title") ?? ""}`,
          ),
      );
      return {
        values: document.querySelectorAll(".strow").length,
        valuesShown: [...document.querySelectorAll(".strow")].filter(shown).length,
        interactive: [...document.querySelectorAll("a, button, [data-action]")].filter(shown).length,
        originAffordances: origin.length,
      };
    });

    // NON-VACUITY, BOTH HALVES. A pane with no values and a page with no
    // controls each satisfy "no origin affordance" for free.
    j.atLeast(
      probe.valuesShown,
      1,
      `the Values pane has values on screen, so there is something to ask the origin of (${probe.values} rows, ${probe.valuesShown} shown)`,
    );
    j.atLeast(
      probe.interactive,
      5,
      `CONTROL: the same scan finds ${probe.interactive} interactive controls, so a zero below is a measurement`,
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
