// "A visitor can step the session from the keyboard, and the dialog that
//  documents the chords lists exactly what is bound."
//
// `Debugger-Integration.md` §10.5 — the tooltip text "is derived from the
// binding in force, not written beside the control as a label" — and
// `Page-Descriptions.md` §13, the standing rule that this product does not
// ship a control that cannot succeed.
//
// THE TRAP THIS JOURNEY IS WRITTEN AGAINST
// ----------------------------------------
// There are two, and they are different in kind.
//
// The first is journey 03's, in a new place. `page.keyboard.press("n")` on a
// page with a `keydown` listener will advance `location.search` the moment the
// handler reaches the engine, and a journey that asserted "the URL changed"
// would be green over a bundle that dispatches the action and paints nothing.
// So the URL is a CONTROL — proof the keystroke reached the engine at all —
// and the verdict is taken from the rendered position, exactly as journey 03
// takes it: the step the session reports, and the line the pane marks.
//
// The second is specific to this feature and is the reason it exists. The
// defect being guarded is a DIALOG THAT DISAGREES WITH THE DISPATCHER —
// §10.5 records this product's own sibling docs giving Reverse Continue as
// both `Shift+F5` and `SHIFT+F8`, with `Shift+F5` also assigned to Stop in the
// same table. A settings dialog carrying its own hardcoded list would be the
// third copy and the one a visitor believes.
//
// `renderShortcutsDialog` is written to make that impossible by iterating
// `km.bindings`, and this journey is written to make the claim FALSIFIABLE
// rather than to restate it:
//
//   * the row count is read off the RENDERED rows and compared against the
//     `data-kb-rows` the renderer declared. Those two numbers come from
//     different places — one from the DOM, one from an attribute — and a
//     dialog that lost a row while claiming eight fails here.
//   * the row ACTIONS are compared against the toolbar's own `data-action`
//     set, so "exactly the bound set" is asserted as a set equality against
//     another surface, not as the number 8 written twice.
//
// Neither expectation names a chord, a preset or a count as a literal. Both
// are relations between two things the page reports — rule 4 in `run.mjs`.
//
// DO NOT SIMPLIFY THIS INTO A DOM CHECK. IT ALREADY CAUGHT THE THING A DOM
// CHECK CANNOT SEE.
// ---------------------------------------------------------------------------
// The first run of this journey found the gear could not open the dialog at
// all. `bindShortcuts` toggled with
//
//     setShortcutsOpen(not shortcutsDialog().hasAttribute("hidden"))
//
// and `hidden` is present when the dialog is CLOSED — so the expression asked
// "is it already open?", answered `false`, and the click closed an
// already-closed dialog. The shortcuts surface was unreachable.
//
// EVERY STRUCTURAL FACT ABOUT IT WAS TRUE THE WHOLE TIME. The dialog was in the
// DOM, its eight rows were present, its counts agreed, its actions matched the
// toolbar, its chords were spelled. A check that queried the markup — including
// four of the assertions in THIS file — passed over a dialog no visitor could
// reach. The Nim suites could not see it either: they were 520 green with the
// bug present, and none of them names the word `keymap`.
//
// The only thing that could tell the difference was performing the gesture and
// reading the element's STATE afterwards:
//
//     await page.click(GEAR)  →  open === true && aria-expanded === "true"
//
// So that assertion is the point of the file, not a formality around the
// content ones. A future edit that replaces the click with a query of the
// dialog's markup, or that drops it because "the dialog is obviously there",
// restores the exact hole this journey was written to close.
//
// AND THE GUARD IS ASSERTED AGAINST AN ELEMENT THAT EXISTS
// --------------------------------------------------------
// The stepping chords are UNMODIFIED LETTERS, which is only safe while no
// focused element wants letters.
//
// The obvious subject for that assertion is the site-wide search box, and it
// is NOT AVAILABLE HERE: the debug route renders its own chrome and no site
// nav, and the built page contains zero input elements. A first draft of this
// journey drove `.nav input[name="q"]` and failed by timeout — which is the
// harness working, and is why the assertion moved rather than being deleted.
// (`hydrate.nim`'s `isTypingTarget` carried the same wrong claim in prose; it
// now records what was measured.)
//
// The subject used instead is real, on this route, and rendered by the product
// under test: the dialog's own `input type="radio"` preset picker. A letter
// pressed while that has focus must not step the session behind the dialog.
//
// It is asserted the only way a negative honestly can be — the CONTROL proves
// the focus actually landed on an INPUT first, so a green cannot be a
// keystroke that went nowhere or a focus call that missed.

import { visit, readFacts } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-chord-steps-the-session";
export const claim =
  "A visitor can step the session from the keyboard, and the shortcuts dialog lists exactly what is bound.";
export const spec = "Debugger-Integration.md §10.5; Page-Descriptions.md §13 — BlockTracer";
export const assertions = 21;
export const needsEngine = true;

const GEAR = "#dbg-shortcuts-open";
const DIALOG = "#dbg-shortcuts";

/**
 * Press a chord and wait for ANY of the three things a step could move.
 *
 * A predicate, never a sleep — journey 03's rule, for its reason: a chord that
 * moves nothing must be a timeout with all three reported, rather than a race
 * this suite happened to lose.
 */
async function chordOnce(page, key, before) {
  await page.keyboard.press(key);
  const deadline = Date.now() + 15000;
  let after = before;
  while (Date.now() < deadline) {
    after = await readFacts(page);
    if (
      after.urlQuery !== before.urlQuery ||
      after.step !== before.step ||
      after.markedNumber !== before.markedNumber
    )
      break;
    await page.waitForTimeout(200);
  }
  return after;
}

/** What the shortcuts surface says about itself, read out of the rendered DOM. */
async function readShortcuts(page) {
  return page.evaluate(
    ({ gear, dialog }) => {
      const dlg = document.querySelector(dialog);
      const rows = [...(dlg?.querySelectorAll(".kbrow") ?? [])];
      return {
        gear: !!document.querySelector(gear),
        gearExpanded: document.querySelector(gear)?.getAttribute("aria-expanded") ?? null,
        present: !!dlg,
        open: dlg ? !dlg.hasAttribute("hidden") : false,
        // The renderer's own claim about how many bindings it drew, and the
        // rows it actually drew. Two numbers from two places, on purpose.
        declared: dlg?.querySelector(".kbrows")?.getAttribute("data-kb-rows") ?? null,
        rows: rows.length,
        actions: rows.map((r) => r.getAttribute("data-kb-action")),
        chords: rows.map((r) => r.querySelector(".kbchord")?.textContent?.trim() ?? ""),
        // The toolbar's own account of which moves exist, AND what each button
        // says about itself. The tooltip is what the visitor's report was
        // about — "I still don't see the keyboard shortcuts being displayed in
        // the tooltips of the debugger control buttons" — and until this was
        // read here, nothing outside a Nim string comparison ever looked at it:
        // this reader took `data-action` and dropped the attribute the report
        // named. A feature can be correct in the renderer, correct in the
        // dialog, and absent from the one channel that was asked for.
        buttons: [...document.querySelectorAll(".dc .dcbtn[data-action]")].map((b) => ({
          action: b.getAttribute("data-action"),
          title: b.getAttribute("title") ?? "",
          ariaLabel: b.getAttribute("aria-label") ?? "",
        })),
      };
    },
    { gear: GEAR, dialog: DIALOG },
  );
}

/** The chord a surface spells for a move, keyed by the move. */
const chordByAction = (actions, chords) =>
  new Map(actions.map((a, i) => [a, chords[i]]));

const sameSet = (a, b) => {
  const x = [...new Set(a)].sort();
  const y = [...new Set(b)].sort();
  return x.length === y.length && x.every((v, i) => v === y[i]);
};

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const withSession = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(withSession, 3, "transactions whose landing is a session with rows in its Code pane");

  const subject = withSession[0];
  j.note(`driving ${subject.debugPath}`);

  // ── THE SERVED PAGE HAS NO GEAR ───────────────────────────────────────
  //
  // Asserted FIRST and in its own context, because it is the claim the rest of
  // the feature is built on: the gear is inserted by the bundle, so the page
  // that cannot open a dialog does not offer to. A gear here would be a
  // control that cannot succeed, which `Page-Descriptions.md` §13 says this
  // product does not ship — and it would be invisible to every Nim suite,
  // because the served renderer is exactly the one they exercise.
  const noJs = await browser.newContext({ javaScriptEnabled: false });
  try {
    const p = await noJs.newPage();
    await p.goto(site.origin + subject.debugPath, { waitUntil: "load", timeout: 45000 });
    const served = await readShortcuts(p);
    j.expect(
      !served.gear && !served.present,
      "the script-less page offers no shortcuts control and no dialog to open",
      `gear=${served.gear} dialog=${served.present}`,
    );
    // AND NO TOOLTIP HERE NAMES A KEY. The same rule as the gear, in the
    // attribute the visitor's report was about: this build has no `keydown`
    // handler, so a chord in a tooltip would be a key nothing on the page
    // listens for. `renderControls` defaults to `kmNone` to make that true,
    // and this is where the default is checked on the artefact rather than in
    // the renderer that produced it.
    //
    // THE SUBJECT COUNT IS ASSERTED FIRST. "No button names a chord" is
    // satisfied by a page with no buttons, and a served frame whose toolbar
    // failed to render would pass this arm silently.
    j.atLeast(served.buttons.length, 1, "SUBJECTS: stepping buttons on the script-less page");
    j.countIs(
      served.buttons.filter((b) => b.title.includes("(")).length,
      0,
      `no tooltip on the script-less page names a key, because none is bound there` +
        ` — ${served.buttons.map((b) => b.title).join(" | ")}`,
    );
  } finally {
    await noJs.close();
  }

  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  const page = live.page;
  try {
    j.expect(
      live.settled && !live.timedOut,
      "the session reached `ready` with live controls, so there is something a chord could step",
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );

    const hydrated = await readShortcuts(page);
    j.expect(
      hydrated.gear && hydrated.present,
      "the hydrated page grew the gear and the dialog it opens, from the bundle",
      `gear=${hydrated.gear} dialog=${hydrated.present}`,
    );

    // ── THE CHORD FIRES THE ACTION ──────────────────────────────────────
    //
    // `n` is not written here as a fact about the keymap — it is the default
    // preset's step-forward chord, and if the default changes this assertion
    // becomes a statement about a key that is not bound and goes RED, which is
    // the correct outcome for a journey that claims a visitor can step from
    // the keyboard.
    const before = live.facts;
    const after = await chordOnce(page, "n", before);

    j.expect(
      after.urlQuery !== before.urlQuery,
      "CONTROL: the keystroke reached the engine (the time coordinate advanced)",
      `${before.urlQuery} -> ${after.urlQuery}`,
    );
    j.expect(
      after.step !== before.step,
      "the chord advanced the step the session reports",
      `data-step ${before.step} -> ${after.step} (of ${after.totalSteps})`,
    );
    j.countIs(after.marked, 1, "after the chord, exactly one line still carries the position mark");
    j.expect(
      after.markedNumber !== null && after.markedNumber !== before.markedNumber,
      "the chord moved the marked line",
      `marked line ${before.markedNumber} -> ${after.markedNumber}`,
    );

    // ── THE DIALOG LISTS EXACTLY THE BOUND SET ──────────────────────────
    await page.click(GEAR);
    await page.waitForTimeout(200);
    const open = await readShortcuts(page);

    j.expect(
      open.open && open.gearExpanded === "true",
      "the gear opens the dialog and says so to assistive technology",
      `open=${open.open} aria-expanded=${open.gearExpanded}`,
    );

    // The toolbar is the other surface that enumerates the moves. Comparing
    // against it — rather than against the number 8 — is what makes this an
    // assertion about agreement rather than two copies of one literal.
    const toolbarActions = open.buttons.map((b) => b.action);
    j.countIs(
      open.rows,
      toolbarActions.length,
      "the dialog draws one row per move the toolbar offers",
    );
    j.countIs(
      Number(open.declared),
      open.rows,
      "the count the renderer declared matches the rows it actually drew",
    );
    j.expect(
      sameSet(open.actions, toolbarActions),
      "the rows name the SAME moves the toolbar does — no extra, none missing",
      `dialog=${[...new Set(open.actions)].sort().join(",")} toolbar=${[...new Set(toolbarActions)].sort().join(",")}`,
    );
    j.expect(
      open.chords.length > 0 && open.chords.every((c) => c.length > 0),
      "every listed move names a chord, so no row documents a key that is not spelled",
      `chords=${open.chords.join(" ")}`,
    );

    // ── THE TOOLTIP ON THE BUTTON, WHICH IS WHAT WAS REPORTED ───────────
    //
    // Everything above judges the DIALOG. The report was about the buttons —
    // "I still don't see the keyboard shortcuts being displayed in the
    // tooltips of the debugger control buttons" — and until this arm existed
    // no check anywhere read a `title` off a hydrated toolbar. The Nim suite
    // compares the renderer's output string; the renderer is not the artefact,
    // and this route has twice shipped a capability that was correct in the
    // renderer and never reached the screen.
    //
    // THE EXPECTATION IS A RELATION BETWEEN TWO SURFACES THE PAGE RENDERS —
    // the button's tooltip and the dialog's row for the same move — and not a
    // chord written here. A keymap change moves both together; a renderer that
    // stopped composing the chord into the tooltip moves only one, and that is
    // the defect this arm is for.
    const spelled = chordByAction(open.actions, open.chords);
    const named = open.buttons.filter((b) => {
      const c = spelled.get(b.action);
      return c && b.title.includes(`(${c})`);
    });
    j.atLeast(open.buttons.length, 1, "SUBJECTS: stepping buttons on the hydrated page");
    j.countIs(
      named.length,
      open.buttons.length,
      `every button's tooltip names the chord the dialog gives that same move` +
        ` — ${open.buttons.map((b) => b.title).join(" | ")}`,
    );
    // One accessible name per control: the tooltip a pointer user reads and
    // the name a screen reader announces are the same sentence, so the chord
    // is not a thing only sighted visitors are told. `renderControls` emits
    // them from one string; this is that holding on the artefact.
    j.countIs(
      open.buttons.filter((b) => b.ariaLabel === b.title).length,
      open.buttons.length,
      "each button's accessible name is the same sentence as its tooltip",
    );

    // ── THE TYPING GUARD, ON THE ONE INPUT THIS ROUTE HAS ───────────────
    //
    // `:checked` — the preset already in force — so that focusing it cannot
    // fire `change` and swap the keymap out from under the assertion. Focus,
    // not click: a click would activate the radio and `applyKeymap` would
    // replace the dialog element the focus is sitting on.
    const settled = await readFacts(page);
    await page.focus('#dbg-shortcuts input[data-kb="preset"]:checked');
    const focus = await page.evaluate(() => ({
      tag: document.activeElement?.tagName ?? null,
      kb: document.activeElement?.getAttribute?.("data-kb") ?? null,
    }));
    // THE CONTROL COMES FIRST, and it is what makes the negative below mean
    // anything: focus that never landed would leave the session unmoved too,
    // and would look identical to a working guard.
    j.expect(
      focus.tag === "INPUT" && focus.kb === "preset",
      "CONTROL: focus landed on the dialog's preset input, which is what the guard tests for",
      `activeElement=${focus.tag} data-kb=${focus.kb}`,
    );
    await page.keyboard.press("n");
    await page.waitForTimeout(1500);
    const afterTyping = await readFacts(page);
    j.expect(
      afterTyping.step === settled.step && afterTyping.markedNumber === settled.markedNumber,
      "a letter pressed while that input has focus does not step the session behind the dialog",
      `data-step ${settled.step} -> ${afterTyping.step}, marked ${settled.markedNumber} -> ${afterTyping.markedNumber}`,
    );

    // Escape last, so the dialog it closes is one that was genuinely open.
    await page.keyboard.press("Escape");
    await page.waitForTimeout(200);
    const closed = await readShortcuts(page);
    j.expect(
      !closed.open && closed.gearExpanded === "false",
      "Escape closes the dialog and the gear's state follows it",
      `open=${closed.open} aria-expanded=${closed.gearExpanded}`,
    );
  } finally {
    await page.close();
  }
}
