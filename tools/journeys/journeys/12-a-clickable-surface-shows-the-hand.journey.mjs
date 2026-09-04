// "A visitor whose pointer rests on something clickable sees the hand that
//  means it."
//
// Page-Descriptions §7.0 (an affordance may not promise what the element does
// not do) and Debugger-Integration §4.2, which calls the row jump "the single
// most valuable interaction in the product".
//
// THE REPORT THIS FILE COMES FROM
// -------------------------------
// "Why is the cursor over the clickable elements showing as a plus sign (e.g.
// in the call trace). I expect a hand or something more familiar."
//
// The plus was `cursor:copy` — an arrow with a plus badge — and it was reaching
// the rows through a DESCENDANT. `a.ctrow,a.evrow{cursor:pointer}` had been
// correct since the rows became anchors, but `.copyable{cursor:copy}` sits on
// `.ctname` and `.evlabel`, which are the widest cell of each row and therefore
// the part of it a pointer actually rests on. `cursor` is resolved at the
// element under the pointer and not at the element that handles the click, so
// the child won across the row's whole reading surface while the rule the row
// carried looked right in the stylesheet and right in every test.
//
// The semantics are the argument, not the aesthetics. A `copy` cursor says
// "this gesture copies"; the row's gesture SEEKS — `hydrate.rowHandler` sends
// `ct/goto-ticks` for a click anywhere inside it. The plus named the one thing
// the row does not primarily do.
//
// WHY THIS IS A JOURNEY AND NOT A UNIT TEST ON THE STYLESHEET
// -----------------------------------------------------------
// Because the defect is INVISIBLE to every cheaper check, and provably so.
// Nothing in this repository asserted a cursor value before this file: `grep -r
// cursor client/tests tools` returns prose and nothing else. A test that read
// the stylesheet would have found `a.ctrow{cursor:pointer}` present and passed
// — the rule WAS there, it was overridden 480 lines further down by a selector
// that names neither row.
//
// And a test that asserted the CLASS would have been worse than useless. That
// is the sibling repository's `build-clickable` defect exactly: a class kept
// `cursor:pointer` after its click handler was deleted, and a Playwright spec
// asserted the class BY NAME (`ctPage.locator("#build .build-clickable")`), so
// the affordance went on lying with a green test pinned to it. A class is not
// an appearance. The only thing that answers "what does the visitor's cursor
// look like" is the computed value, in a browser, on the element the pointer is
// actually over.
//
// HIT-TESTED AT THE CENTRE, AND COVERAGE IS A FAILURE AND NOT A SKIP
// ------------------------------------------------------------------
// `getComputedStyle(row).cursor` is the wrong question: it reports what the ROW
// resolves, which was `pointer` throughout the defect. The right question is
// what the element UNDER THE POINTER resolves, so every measurement here goes
// through `document.elementFromPoint` at the element's own centre.
//
// An element is counted as reached when the hit lands on it OR on one of its
// descendants — a row is not "covered" by its own `.ctname`, and `cursor` is an
// inherited property, so a child with no rule of its own is reporting the row's
// answer. Anything else under the centre is a COVER, and covers are counted and
// asserted to be zero rather than quietly dropped from the denominator. This
// campaign has already had painted content wrongly rejected as covered by a
// check that assumed the reverse, so the two outcomes are separated and both
// are named.
//
// EMPTY SETS
// ----------
// "Every clickable row shows a hand" is vacuously true of a page with no rows,
// which is exactly how a selector that stopped matching would go green. Every
// population below is asserted NON-EMPTY with `atLeast` before anything is
// quantified over it, and the agreement is `countIs` — not "at least one row
// shows a hand", which one row in fourteen satisfies.
//
// THE RULE IS BIDIRECTIONAL, AND THAT IS WHAT MAKES IT CHECKABLE
// ---------------------------------------------------------------
// Page-Descriptions §13: "A pointer cursor is a promise, and it is kept in both
// directions. Everything that responds to a click shows a pointer cursor, and
// nothing that does not, shows one." Both halves have failed in this product —
// the visitor's report is the first, and the copy controls hydration adds are
// the second, acting without saying so.
//
// The spec makes it "checkable as a set equality read straight off the page:
// the elements whose computed cursor is `pointer` are exactly the elements that
// are anchors, buttons, or carry an interactive role", and notes that the
// reading is only COMPLETE because Front-End-Architecture §7 forbids
// hand-rolling an interactive element out of a `div`. Without that rule there
// could be a clickable thing outside the set and the inverse direction would be
// unenforceable; with it, `closest(CLICKABLE)` is a total answer. The two rules
// hold each other up, which is worth knowing before either is weakened.
//
// Inheritance is why the inverse is phrased as `closest` and not as equality of
// two `querySelectorAll` results. `cursor` is an INHERITED property, so every
// descendant of an anchor also computes `pointer`; asking "is this element a
// clickable" of each would report a working page as covered in violations. The
// question that means what the spec means is whether the hand ORIGINATES
// outside a clickable — which is exactly "does this element have no clickable
// ancestor".
//
// WHAT THIS CANNOT CATCH, STATED SO NOBODY RELIES ON IT
// -----------------------------------------------------
// Page-Descriptions §13 again: "an anchor whose handler is dead is still an
// anchor, so it keeps its pointer and passes." A control that looks live and
// does nothing is journey 09's claim — the position moves THERE — and not this
// one's. This file is about the promise, never about whether it is honoured,
// and it should not be extended to try.
//
// THE INSTRUMENT IS NEW, SO IT IS PROVED BEFORE IT IS BELIEVED
// ------------------------------------------------------------
// Computed style is one of four readings this suite had never taken (with
// scroll offset, hover and drag). A reading that never happens returns nothing
// and quantifies over nothing, and the standing failure mode is that this looks
// exactly like a pass. So the counts are asserted at three points — the
// population is non-empty, the hit-test LANDED on it, and the sweep found hands
// at all — and one control asserts the probe DISCRIMINATES: it must read at
// least two distinct cursor values on a page. A probe that had silently
// returned a constant, or run against a detached document, satisfies none of
// those.
//
// THE LOOP RAIL IS DELIBERATELY NOT JUDGED HERE
// ----------------------------------------------
// It was, in the first draft, and the population was EMPTY. `.frseg` renders on
// the served page — eight segments, all `.out` — and after hydration there are
// ZERO on any position reachable from the demo chain: measured across eight
// call-trace jumps and twelve toolbar steps, `document.querySelectorAll(".frseg")`
// is 0 every time. `renderEditor`'s `rail.navigable` branch, and the
// `role="button"` that `hydrate.markRailNavigable` would stamp on it, are dead
// in the deployed build.
//
// So a cursor assertion on the rail would quantify over nothing and pass, which
// is the one outcome this file exists to refuse — and a cursor RULE for it would
// be a rule no test could reach. Both were written and both were removed. The
// gap is real and is reported as a finding rather than papered over: whenever the
// navigable rail comes back it will arrive as a `span` with no `href`, and a
// browser gives `cursor:pointer` to `a[href]` and to nothing else, so it will
// need a rule and this comment is where the next reader will find that out.
//
// WHAT THE SWEEP DID NOT SWEEP, AND HOW IT IS KEPT FROM HAPPENING AGAIN
// ---------------------------------------------------------------------
// The interactive selector was written when every interactive thing on this page
// was clicked, and it was never revisited. Two surfaces had drifted out from
// under it, and neither was visible in any verdict:
//
//   * `role="slider"` — the trace scrubber. NOT in the selector, so the one
//     control on the page whose correct cursor is something other than `pointer`
//     was the one control nothing measured. The page said so on every run: the
//     hydrated audit's own note lists cursors `["auto","copy","grab","pointer"]`,
//     and `grab` appeared in no assertion in this file. `grabbing` — the half of
//     the promise that only exists while the pointer is down — had never been
//     read by anything at all.
//
//   * `button:not([disabled])` — this file's spelling of "an inert control is
//     excluded", which is not the product's. `renderControls` emits
//     `button.dcbtn.off` with `aria-disabled="true"` and no `disabled`
//     attribute, so all eight inert stepping buttons MATCHED the clickable set
//     and were required to compute `pointer` while the stylesheet gives them
//     `not-allowed`. It stayed green because it had no subject: the hydrated arm
//     settles on `controlsLive > 0` and by then every button is live — measured,
//     zero inert on both hydrated subjects.
//
// The slider's fix could not be "add it to the selector". The forward claim is
// `each computes pointer`, and a slider that computed `pointer` would be lying —
// a range is dragged to a value, not clicked to one. One expectation across both
// roles would have had to either force the wrong cursor onto the scrubber or be
// weakened to "something interactive", and a weakened assertion is the vacuous
// test this file exists to refuse. So the expectation is PER ROLE.
//
// AND THE LIST IS NOW CHECKED AGAINST THE PAGE. A person's audit is good until
// the next role lands; `ROLES_WITH_A_CURSOR_EXPECTATION` is compared against
// every `[role]` in the markup on every run, and a role in neither that list nor
// the not-actuated one is a RED. That assertion is what would have caught this,
// on the day `role="slider"` was stamped on the track.
//
// THE NO-SCRIPT ARM IS THE SCOPE CONTROL
// --------------------------------------
// The fix must not be "delete the copy cursor". `.copyable` is right where it
// is the ONLY affordance: on the served page the rows are `div.ctrow` with no
// `href`, they jump nowhere, and `user-select:all` plus a copy cursor is an
// honest description of the only gesture available. So the second arm loads the
// same page with JavaScript DISABLED — the artefact a visitor with scripting
// off is served — and asserts the rows are inert AND that the copy cursor
// survived there. A fix that had blanket-removed `cursor:copy` passes the first
// arm and reddens this one.

import { visit } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-clickable-surface-shows-the-hand";
export const claim =
  "A visitor whose pointer rests on something clickable sees the hand that means it.";
export const spec = "Page-Descriptions §7.0, Debugger-Integration §4.2 — BlockTracer";
export const assertions = 52;
export const needsEngine = true;

/**
 * The cursor every element matching `sel` computes AT ITS OWN CENTRE, read off
 * whatever the browser says is under the pointer there.
 *
 * Returns counts, never a boolean, because every assertion built on this is a
 * `countIs` against a population whose size is separately asserted.
 *
 *   total     — matched the selector
 *   shown     — and are rendered (`checkVisibility`, the rule probe.mjs states
 *               for `.srcline`: the panes hold elements that exist and are
 *               `display:none`, and a journey that counted the DOM would
 *               quantify over things no pointer can reach)
 *   reachable — and their centre lies inside the viewport, which is the
 *               precondition for `elementFromPoint` to mean anything at all
 *   hit       — and the element under that point is the element itself or one
 *               of its descendants
 *   covered   — reachable, but something outside the subtree is on top
 *   byCursor  — of the hit ones, how many computed each cursor value
 */
const cursorsAtCentre = (page, sel) =>
  page.evaluate((selector) => {
    const shown = (e) =>
      !!e &&
      typeof e.checkVisibility === "function" &&
      e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });

    const name = (e) =>
      !e ? "(nothing)" : e.tagName.toLowerCase() + (e.className ? "." + String(e.className).trim().split(/\s+/).join(".") : "");

    const out = {
      total: 0,
      shown: 0,
      reachable: 0,
      hit: 0,
      covered: 0,
      byCursor: {},
      samples: [],
      covers: [],
    };

    for (const el of document.querySelectorAll(selector)) {
      out.total += 1;
      if (!shown(el)) continue;
      out.shown += 1;

      // SCROLLED TO FIRST, WHICH IS WHAT THE VISITOR DOES. The panes are
      // independently scrollable and carry a sticky `.panehead`; a row resting
      // under that header is genuinely not hoverable where it is, and counting
      // it as a cover would report a working product as broken. Bringing each
      // element to the centre of its own scroller reproduces the state in which
      // a visitor actually points at it, and the rect is re-read AFTERWARDS
      // because scrolling is precisely what moves it.
      el.scrollIntoView({ block: "center", inline: "center" });
      const r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) continue;
      const cx = r.left + r.width / 2;
      const cy = r.top + r.height / 2;
      // Off the viewport there is nothing to hit-test against. After the scroll
      // above this is a pane that cannot bring the element into view at all, so
      // it is not a subject rather than a failure.
      if (cx < 0 || cy < 0 || cx > window.innerWidth || cy > window.innerHeight) continue;
      out.reachable += 1;

      const top = document.elementFromPoint(cx, cy);
      // The element's OWN descendants are not covers. `cursor` inherits, so a
      // child with no rule is reporting the ancestor's answer, and that is the
      // answer the visitor's pointer gets.
      if (!top || !(top === el || el.contains(top))) {
        out.covered += 1;
        if (out.covers.length < 4) out.covers.push(`${name(el)} covered by ${name(top)}`);
        continue;
      }
      out.hit += 1;

      const cursor = getComputedStyle(top).cursor;
      out.byCursor[cursor] = (out.byCursor[cursor] ?? 0) + 1;
      if (out.samples.length < 3) {
        out.samples.push(`"${(el.textContent ?? "").trim().slice(0, 20)}" -> ${cursor} on ${name(top)}`);
      }
    }
    return out;
  }, sel);

/**
 * The two halves of §13's set equality, read over the WHOLE page.
 *
 * `CLICKABLE` is the spec's set — anchors, buttons, and elements carrying an
 * interactive role — and it is total only because Front-End-Architecture §7
 * forbids interactive `div`s. A disabled `button` is excluded: §13 puts an
 * inert control in the second set and not the first, so it must NOT offer a
 * hand, and this repository already gives it `cursor:not-allowed`.
 *
 *   examined  — rendered elements the sweep actually read a cursor from
 *   pointer   — of those, how many compute `pointer` (the sweep FOUND hands)
 *   orphan    — of those, how many have no clickable ancestor: the violation
 *   distinct  — how many different cursor values the page produced, which is
 *               what proves the reading discriminates rather than returning a
 *               constant
 */
const CLICKABLE =
  'a[href],button:not([disabled]):not([aria-disabled="true"]),' +
  'summary,' +
  '[role="button"],[role="link"],[role="tab"],[role="menuitem"]';

/*
 * `summary` JOINED THE SET WHEN THE PAGE GREW ONE, WHICH IS THE LESSON THE
 * `role="slider"` PARAGRAPH ABOVE ALREADY PAID FOR.
 *
 * The Call Trace pane folds library subtrees — `Poseidon2::hash` and friends —
 * and draws the closed node as a real `<details>`/`<summary>` disclosure so it
 * opens with no JavaScript, from the keyboard, and announces its state. A
 * `<summary>` is natively clickable and carries `cursor:pointer`, so before this
 * line it would have counted as an ORPHAN: a surface showing the hand with no
 * clickable ancestor, which is this sweep's violation.
 *
 * The wrong fixes were both available. Dropping the cursor would make a control
 * that opens on click look inert; stamping `role="button"` on it would satisfy
 * the selector by DESTROYING the native disclosure semantics — a screen reader
 * would stop hearing "collapsed"/"expanded", which is the one thing that makes
 * the fold legible to a reader who cannot see the triangle. The selector was
 * written before this page had a disclosure; it is the selector that was
 * incomplete.
 */

/**
 * THE CONTROLS THAT ARE OPERATED BY A DRAG, WHICH IS NOT A CLICK.
 *
 * `.dctl` — the trace scrubber — carries `role="slider"`, and this sweep did not
 * look at it. The selector above was written before the control existed and was
 * never revisited, so the one interactive surface on the page with a cursor
 * OTHER than `pointer` was the one surface nothing measured. The page's own
 * cursor inventory said so out loud the whole time: the hydrated audit reports
 * `["auto","copy","grab","pointer"]`, and `grab` appeared in no assertion.
 *
 * ADDING IT TO `CLICKABLE` WOULD HAVE BEEN THE WRONG FIX, and it is worth being
 * explicit about why, because it is the same mistake in a new place. The forward
 * claim is `each computes pointer`; a slider that computed `pointer` would be
 * lying — you cannot click a range to a value — so the sweep would have had to
 * either force the wrong cursor onto the control or be weakened to "computes
 * something interactive", and a weakened assertion is the vacuous test this
 * whole layer is written against.
 *
 * So the expectation is PER ROLE. `grab` offered, `grabbing` while the pointer
 * is down — which is what `debugger_css` already ships and what nothing checked.
 *
 * `pointerAudit` is still given `CLICKABLE` and NOT this set, deliberately: a
 * slider that started showing the hand would then have no clickable ancestor and
 * would be reported as an ORPHAN by §13's inverse. The two directions cross-
 * check each other, and folding the slider into the clickable set would remove
 * that.
 */
const DRAGGABLE = '[role="slider"]';

/**
 * The controls that are RENDERED and DELIBERATELY DEAD.
 *
 * `button:not([disabled])` was this file's own spelling of "an inert control is
 * excluded", and the product does not spell it that way: `renderControls` emits
 * `button.dcbtn.off` with `aria-disabled="true"` and no `disabled` attribute, so
 * every inert stepping control MATCHED the clickable set and was required to
 * compute `pointer`, while the stylesheet gives it `not-allowed`.
 *
 * It never reddened because it was never exercised: the hydrated arm settles on
 * `controlsLive > 0`, and by then all eight buttons are live — measured, 0 inert
 * on both hydrated subjects. The assertion had the defect and no subject.
 *
 * Both spellings are excluded above, and the inert population is now judged in
 * its own right on the arm that HAS one: with scripting off all eight are dead,
 * which is §13's second half at its strongest — a control that cannot be
 * operated must not say it can.
 */
const INERT_CONTROL = 'button[disabled],button[aria-disabled="true"]';

/**
 * The roles this sweep has a cursor expectation for, and the roles that are not
 * actuated at all.
 *
 * THIS EXISTS SO THE SELECTOR LIST CANNOT SILENTLY FALL BEHIND THE PRODUCT
 * AGAIN. `role="slider"` was added to `.dctl` by a change that had no reason to
 * think about this file, and nothing here noticed for as long as the control
 * existed. An audit performed by a person is good until the next role lands; the
 * assertion below is the same audit performed on every run.
 *
 * A role goes in the first list when it has an expectation above, and in the
 * second when it announces rather than acts — `status`, `alert` and `img` are
 * live regions and a graphic, and a cursor claim about them would be a claim
 * about nothing. Anything in NEITHER list is a role the product uses and this
 * sweep is silent about, and that is the failure.
 */
const ROLES_WITH_A_CURSOR_EXPECTATION = ["button", "link", "tab", "menuitem", "slider"];
const ROLES_THAT_ARE_NOT_ACTUATED = [
  "status",
  "alert",
  "img",
  "presentation",
  "none",
  "note",
  "group",
  "region",
  "list",
  "listitem",
  "heading",
  "banner",
  "navigation",
  "contentinfo",
  "main",
  "complementary",
  "separator",
  "tooltip",
  // THE SHORTCUTS DIALOG, and this arm did its job on the day it landed. The
  // keymap change stamped `role="dialog"` and `role="radiogroup"` on markup
  // hydration injects, nothing in that change had any reason to read this
  // file, and this journey went red naming both roles — which is precisely
  // what the comment above predicted would happen "on the day `role='slider'`
  // was stamped on the track", happening again for a different role.
  //
  // Both belong in THIS list rather than the one above, because each is a
  // CONTAINER and neither is actuated: `dialog` groups the surface,
  // `radiogroup` groups the preset choices. What a pointer actuates inside
  // them is the close `<button>` and the `<label class="kbpreset">` around
  // each native radio — elements, not these boxes.
  //
  // AND THIS LIST IS THE ONLY ARM THAT SEES THEM AT ALL. `pointerAudit` walks
  // only what `checkVisibility` calls shown, and the dialog carries `hidden`
  // until the gear is pressed, so its contents are outside every cursor claim
  // this file makes. Saying so here rather than leaving it implied: the entry
  // below records that the roles are classified, not that anything measured a
  // cursor on them.
  "dialog",
  "radiogroup",
];

const pointerAudit = (page, clickableSel) =>
  page.evaluate((sel) => {
    const shown = (e) =>
      !!e &&
      typeof e.checkVisibility === "function" &&
      e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
    const name = (e) =>
      e.tagName.toLowerCase() +
      (e.className ? "." + String(e.className).trim().split(/\s+/).join(".") : "");

    const seen = new Set();
    let examined = 0;
    let pointer = 0;
    const orphans = [];
    for (const el of document.querySelectorAll("*")) {
      if (!shown(el)) continue;
      examined += 1;
      const c = getComputedStyle(el).cursor;
      seen.add(c);
      if (c !== "pointer") continue;
      pointer += 1;
      // INHERITANCE, HANDLED HERE AND NOT BY THE SELECTOR. A `span` inside an
      // anchor computes `pointer` because `cursor` inherits; it is not a
      // violation, it is the anchor's own promise reaching its own text. What
      // would be a violation is a hand ORIGINATING outside anything clickable.
      if (!el.closest(sel)) orphans.push(name(el));
    }
    return {
      examined,
      pointer,
      orphan: orphans.length,
      orphanNames: orphans.slice(0, 6),
      distinct: seen.size,
      values: [...seen].sort(),
    };
  }, clickableSel);

/** Every ARIA role in the document, whether on screen or not. */
const rolesInMarkup = (page) =>
  page.evaluate(() =>
    [
      ...new Set([...document.querySelectorAll("[role]")].map((e) => e.getAttribute("role"))),
    ].sort(),
  );

/**
 * The cursor a control shows WHILE IT IS ACTUALLY BEING OPERATED.
 *
 * Every other reading in this file is of a control at rest — what it OFFERS.
 * `grabbing` is the other half of the scrubber's promise and it exists for one
 * moment only, so it cannot be read at rest and cannot be read after release:
 * `debugger_css` spells it `.dctl.seekable:active,.dctl.scrubbing`, and the
 * second selector is there because the pointer is CAPTURED for the duration —
 * `:active` alone drops the moment the visitor's hand strays a pixel above the
 * bar. Reading it needs a real press, a real move, and a reading taken before
 * the release.
 *
 * The BEFORE reading is returned too, and it is not decoration: `grabbing` on an
 * element that already said `grabbing` at rest proves nothing, and a control
 * stuck in the pressed state is a real way to be wrong.
 *
 * This moves the session — a press on the track seeks. It is therefore done LAST
 * in its arm, after every at-rest population has been measured.
 */
async function cursorWhileDragging(page, sel) {
  const box = await page.evaluate((s) => {
    const el = document.querySelector(s);
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 ? { x: r.left, y: r.top, w: r.width, h: r.height } : null;
  }, sel);
  if (!box) return { pressed: false, why: `no rendered ${sel} on this page to drag` };

  const read = (x, y) =>
    page.evaluate(
      ([px, py, s]) => {
        const subject = document.querySelector(s);
        const top = document.elementFromPoint(px, py);
        return {
          cursor: top ? getComputedStyle(top).cursor : null,
          // The same subtree rule the at-rest sweep uses: a descendant is not a
          // cover, because `cursor` inherits and the descendant is reporting the
          // control's own answer.
          onSubject: !!top && !!subject && (top === subject || subject.contains(top)),
        };
      },
      [x, y, sel],
    );

  const y = box.y + box.h / 2;
  const from = box.x + box.w * 0.2;
  const to = box.x + box.w * 0.4;
  await page.mouse.move(from, y);
  const before = await read(from, y);
  await page.mouse.down();
  await page.mouse.move(to, y);
  const during = await read(to, y);
  await page.mouse.up();
  return { pressed: true, before, during };
}

/** The cursors that render as a plus, which is what the report named. */
const PLUS = ["copy", "cell", "crosshair"];
const plusCount = (m) => PLUS.reduce((n, c) => n + (m.byCursor[c] ?? 0), 0);
const shape = (m) =>
  `total ${m.total}, shown ${m.shown}, reachable ${m.reachable}, hit ${m.hit}, ` +
  `covered ${m.covered}, cursors ${JSON.stringify(m.byCursor)}` +
  (m.covers.length ? ` | covers: ${m.covers.join("; ")}` : "") +
  (m.samples.length ? ` | ${m.samples.join(" ; ")}` : "");

/**
 * One population, three counted assertions, in the order that makes a red one
 * readable: is there anything to judge, was it actually under the pointer, and
 * did it compute the value claimed.
 */
function judge(j, m, what, want) {
  j.atLeast(m.reachable, 1, `SUBJECTS: ${what}`);
  j.countIs(m.hit, m.reachable, `${what} — each is the element under the pointer at its own centre`);
  j.countIs(m.byCursor[want] ?? 0, m.hit, `${what} — each computes \`${want}\``);
}

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const withSession = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(withSession, 1, "transactions whose landing is a session with rows in its Code pane");

  // TWO SUBJECT KINDS, EACH ASSERTED NON-EMPTY, AND NO FALLBACK BETWEEN THEM.
  // `find(…) ?? withSession[0]` is what let six journeys judge only the demo
  // chain for their whole lives: the fallback makes "no real capture was
  // available" and "a real capture passed" the same green. The stylesheet is
  // inlined identically into every page, so a chain-specific cursor defect is
  // not the risk here — a chain-specific ROW STRUCTURE is, and that is what the
  // real arm below measures.
  const synthetic = withSession.filter((t) => !t.real);
  const realCaptures = withSession.filter((t) => t.real);
  j.atLeast(synthetic.length, 1, "SUBJECTS: synthetic sessions, so the demo arm has a subject");
  j.atLeast(realCaptures.length, 1, "SUBJECTS: REAL-capture sessions, so the chain arm has a subject");

  const subject = synthetic[0];
  const url = subject.debugPath;
  j.note(`driving ${url}`);

  // ── ARM 1: the hydrated page, which is where the report came from ──────
  const live = await visit(browser, site.origin, url, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  const page = live.page;
  try {
    j.expect(
      live.settled && !live.timedOut,
      "the session reached `ready` with live controls, so the rows on screen are the engine's",
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );
    j.countIs(live.pageErrors.length, 0, "no uncaught page errors while the cursor surfaces were measured");

    // THE PRECONDITION FOR THE WHOLE ARM. If hydration did not turn the rows
    // into anchors then they are not clickable, and "a clickable row shows a
    // hand" would be a claim about nothing — passing here while the product
    // had lost its navigation entirely.
    const rowKinds = await page.evaluate(() => ({
      rows: document.querySelectorAll(".ctrow,.evrow").length,
      anchors: document.querySelectorAll("a.ctrow,a.evrow").length,
    }));
    // NOT `anchors === rows`. The aggregate `Self cost` view renders
    // `div.ctrow.d0.flat` rows on purpose — a function is not a frame, those
    // rows jump nowhere, and they are correctly not anchors. What has to hold is
    // that hydration produced SOME anchors, because otherwise there is no click
    // for this journey to describe and every assertion below is about nothing.
    j.atLeast(
      rowKinds.anchors,
      1,
      "CONTROL: hydration turned navigation rows into anchors, so there is a click to describe",
    );

    // ── the call trace, the surface the visitor named ────────────────────
    const ct = await cursorsAtCentre(page, "a.ctrow");
    j.note(`call trace: ${shape(ct)}`);
    judge(j, ct, "call-trace rows", "pointer");

    // THE EXACT ELEMENT THE REPORT WAS ABOUT — the function name, which is the
    // widest cell in the row and the one carrying `.copyable`. Measured as its
    // own population because a row whose centre happened to fall in the gutter
    // would pass the row assertion above while the name still showed the plus.
    const ctName = await cursorsAtCentre(page, "a.ctrow .copyable");
    j.note(`copyable cells inside rows: ${shape(ctName)}`);
    judge(j, ctName, "copyable value cells sitting inside a navigable row", "pointer");

    // ── the copy controls hydration adds, which had no rule at all ───────
    const copybtn = await cursorsAtCentre(page, ".copybtn");
    j.note(`copy controls: ${shape(copybtn)}`);
    judge(j, copybtn, "copy controls hydration added to this page", "pointer");

    // ── the event log, which is not on screen until it is chosen ─────────
    //
    // The tab is found by PROPERTY and never by name, for journey 09's reason:
    // the pane that holds the event rows, and the control whose fragment points
    // at it. A renamed pane moves this on its own.
    const opened = await page.evaluate(() => {
      const pane = document.querySelector(".evrow")?.closest(".pane");
      if (!pane || !pane.id) return { ok: false, why: "the event rows are in no identified pane" };
      const tab = document.querySelector(`a[href="#${CSS.escape(pane.id)}"]`);
      if (!tab) return { ok: false, why: `no control targets #${pane.id}` };
      tab.click();
      return { ok: true, pane: pane.id };
    });
    await page.waitForTimeout(400);
    j.note(`event log: ${opened.ok ? `opened ${opened.pane}` : opened.why}`);

    const ev = await cursorsAtCentre(page, "a.evrow");
    j.note(`event log rows: ${shape(ev)}`);
    judge(j, ev, "event-log rows", "pointer");

    // ── §13'S SET EQUALITY, BOTH DIRECTIONS, OVER THE WHOLE PAGE ───────
    //
    // The populations above are the surfaces the report named. This is the rule
    // itself, and it is what catches the next one — a cursor defect on a pane
    // nobody thought to list here reddens without this file being edited.

    // FORWARD: everything that responds to a click shows the hand.
    const clickable = await cursorsAtCentre(page, CLICKABLE);
    j.note(`every clickable: ${shape(clickable)}`);
    judge(j, clickable, "every anchor, button and interactive role on the page", "pointer");

    // INVERSE: and nothing that does not, shows one.
    const audit = await pointerAudit(page, CLICKABLE);
    j.note(
      `audit: examined ${audit.examined}, pointer ${audit.pointer}, orphan ${audit.orphan}, ` +
        `cursors ${JSON.stringify(audit.values)}` +
        (audit.orphanNames.length ? ` | ${audit.orphanNames.join(", ")}` : ""),
    );
    j.atLeast(audit.examined, 1, "SUBJECTS: rendered elements the cursor sweep read a value from");
    // THE READING HAPPENED, AND IT DISCRIMINATES. Asserted separately from the
    // verdict because a probe that never ran, or that returned one constant for
    // everything, produces an `orphan` of 0 and would otherwise score a pass.
    j.atLeast(audit.pointer, 1, "CONTROL: the sweep actually found hands on this page");
    j.atLeast(
      audit.distinct,
      2,
      "CONTROL: the sweep reads more than one cursor value, so it is discriminating",
    );
    j.countIs(
      audit.orphan,
      0,
      "nothing that is not an anchor, a button or an interactive role shows the hand",
    );

    // THE REPORT, RESTATED AS ONE NUMBER OVER EVERYTHING MEASURED. `copy`,
    // `cell` and `crosshair` all render as a plus; this is the assertion whose
    // text is the visitor's sentence, and it is a count so that one surviving
    // surface out of five cannot hide behind four fixed ones.
    const plus = plusCount(ct) + plusCount(ctName) + plusCount(copybtn) + plusCount(ev);
    j.countIs(
      plus,
      0,
      "no clickable surface measured on the hydrated page computes a plus-rendering cursor",
    );

    // ── THE ROLE INVENTORY, WHICH IS WHAT KEEPS THE SWEEP HONEST ─────────
    //
    // The selectors above are a list, and a list cannot notice a control nobody
    // added it to — `tools/capture/check-coverage.mjs` learned that about chains
    // and this file has now learned it about roles. `role="slider"` arrived on
    // the scrubber and this sweep went on reporting a clean pass over a set that
    // no longer covered the page.
    //
    // So the list is checked against the page instead of trusted. Every role in
    // the markup must either have a cursor expectation here or be one that is
    // not actuated at all; a role in neither list is a surface this file claims
    // to judge and does not.
    const roles = await rolesInMarkup(page);
    j.note(`roles in the markup: ${JSON.stringify(roles)}`);
    j.atLeast(roles.length, 1, "SUBJECTS: ARIA roles the hydrated page puts in its markup");
    const unclassified = roles.filter(
      (r) =>
        !ROLES_WITH_A_CURSOR_EXPECTATION.includes(r) && !ROLES_THAT_ARE_NOT_ACTUATED.includes(r),
    );
    j.countIs(
      unclassified.length,
      0,
      `every role the page uses is one this sweep either expects a cursor for or knows is not actuated${
        unclassified.length ? `: ${unclassified.join(", ")}` : ""
      }`,
    );

    // ── THE SCRUBBER, WHICH IS DRAGGED AND THEREFORE NOT A `pointer` ─────
    const slider = await cursorsAtCentre(page, DRAGGABLE);
    j.note(`slider: ${shape(slider)}`);
    judge(j, slider, "the timeline scrubber, which is dragged and not clicked", "grab");

    // AND THE OTHER HALF OF ITS PROMISE. `grab` says it CAN be dragged;
    // `grabbing` says it IS being. The stylesheet has shipped both since the
    // gesture landed and nothing has ever read either. Last in the arm, because
    // the press seeks the session.
    const dragged = await cursorWhileDragging(page, DRAGGABLE);
    j.note(`while dragging: ${JSON.stringify(dragged)}`);
    j.expect(
      dragged.pressed && dragged.before.onSubject && dragged.during.onSubject,
      "CONTROL: the press and the move both landed on the scrubber itself",
      JSON.stringify(dragged),
    );
    j.expect(
      dragged.pressed &&
        dragged.before.cursor === "grab" &&
        dragged.during.cursor === "grabbing",
      "the scrubber closes the hand while it is being dragged, and offers it open at rest",
      `at rest ${dragged.pressed ? dragged.before.cursor : "not pressed"}, ` +
        `mid-drag ${dragged.pressed ? dragged.during.cursor : "not pressed"}`,
    );
  } finally {
    await page.close();
  }

  // ── ARM 2: a REAL capture, which is a different row population ────────
  await realArm(browser, site, j, realCaptures[0]);

  // ── ARM 3: the same page with scripting off ───────────────────────────
  await noScriptArm(browser, site, j, url);
}

/**
 * The same claim on a chain capture.
 *
 * Not a duplicate of arm 1. The cursor RULE is chain-independent — one inlined
 * stylesheet serves every page — but the DOM it lands on is not: a real
 * recording's rows are built by the engine from resolved source positions,
 * where the demo chain's are built by the exporter from a fixture. A row that
 * arrived without its `.copyable` name cell, or as a `div` because the producer
 * withheld the `href`, is a real-capture-only shape, and this arm is what would
 * see it. Rows only — a real capture need not render a loop rail, and asserting
 * an absent one would be the vacuous claim this file exists to avoid.
 */
async function realArm(browser, site, j, subject) {
  j.note(`driving REAL capture ${subject.debugPath}`);
  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  const page = live.page;
  try {
    j.expect(
      live.settled && !live.timedOut,
      "REAL: the chain session reached `ready` with live controls",
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );
    const rows = await cursorsAtCentre(page, ".ctrow,.evrow");
    j.note(`REAL rows: ${shape(rows)}`);
    judge(j, rows, "REAL: navigation rows on a chain capture", "pointer");
  } finally {
    await page.close();
  }
}

/**
 * The served artefact, and the control on the SCOPE of the fix.
 *
 * With no script the rows are `div.ctrow` carrying no `href`: they jump
 * nowhere, and `.copyable`'s `user-select:all` plus its copy cursor is a true
 * description of the only gesture on offer. Removing `cursor:copy` outright
 * would have satisfied every assertion in arm 1 and taken the affordance with
 * it, so the fix has to be shown to be a SUBORDINATION — the copy cursor yields
 * where a click means something else, and holds where nothing encloses it.
 */
async function noScriptArm(browser, site, j, url) {
  const ctx = await browser.newContext({ javaScriptEnabled: false });
  const page = await ctx.newPage();
  try {
    await page.goto(site.origin + url, { waitUntil: "load", timeout: 45000 });

    const kinds = await page.evaluate(() => ({
      rows: document.querySelectorAll(".ctrow,.evrow").length,
      anchors: document.querySelectorAll("a.ctrow,a.evrow").length,
    }));
    j.atLeast(kinds.rows, 1, "NO-SCRIPT: SUBJECTS — rows served to a visitor with scripting off");
    j.countIs(
      kinds.anchors,
      0,
      "NO-SCRIPT: the served rows carry no anchor, so nothing there promises a jump",
    );

    // THE DEFECT MIRRORED, AND IT IS ASSERTED HERE BECAUSE HERE IT IS NOT
    // VACUOUS. A `pointer` on something that does not respond to a click is the
    // same lie told backwards, and this repository has form: the sibling's
    // `build-clickable` kept `cursor:pointer` after its handler was deleted and
    // a spec asserted the CLASS, so the dead affordance stayed green. With no
    // script these rows are `div.ctrow` — inert, by design, and on screen in
    // numbers — which makes them the one population on which "nothing that
    // cannot be clicked shows the hand" is a real claim rather than a shrug.
    const inertRows = await cursorsAtCentre(page, ".ctrow,.evrow");
    j.note(`no-script inert rows: ${shape(inertRows)}`);
    j.atLeast(inertRows.hit, 1, "NO-SCRIPT: SUBJECTS — inert rows a pointer can rest on");
    j.countIs(
      inertRows.byCursor["pointer"] ?? 0,
      0,
      "NO-SCRIPT: no row that cannot be clicked offers the hand that says it can",
    );

    // §13'S INVERSE ON THE SERVED PAGE, which is where the inert population is
    // largest — every navigation row is a `div` here, so a rule that leaked a
    // hand onto something unclickable has the most room to show itself.
    const audit = await pointerAudit(page, CLICKABLE);
    j.note(
      `no-script audit: examined ${audit.examined}, pointer ${audit.pointer}, ` +
        `orphan ${audit.orphan}, cursors ${JSON.stringify(audit.values)}` +
        (audit.orphanNames.length ? ` | ${audit.orphanNames.join(", ")}` : ""),
    );
    j.atLeast(audit.pointer, 1, "NO-SCRIPT: CONTROL — the sweep found hands on the served page");
    j.atLeast(
      audit.distinct,
      2,
      "NO-SCRIPT: CONTROL — the served page produces more than one cursor value",
    );
    j.countIs(
      audit.orphan,
      0,
      "NO-SCRIPT: nothing unclickable shows the hand on the page served without script",
    );

    // ── THE INERT CONTROLS, ON THE ONE ARM THAT HAS ANY ─────────────────
    //
    // §13's second half at full strength: eight stepping buttons that cannot be
    // operated, rendered, on screen, saying so. This is the population the
    // hydrated arm cannot supply — it settles on `controlsLive > 0`, and by then
    // every button is live — which is exactly why `button:not([disabled])` could
    // carry the wrong spelling of "disabled" for as long as it liked. Judged
    // here, the exclusion in `CLICKABLE` is a claim with a subject.
    const inert = await cursorsAtCentre(page, INERT_CONTROL);
    j.note(`no-script inert controls: ${shape(inert)}`);
    judge(j, inert, "NO-SCRIPT: inert stepping controls, which cannot be operated", "not-allowed");

    // ── THE TIMELINE, SERVED WITHOUT ITS GESTURE ─────────────────────────
    //
    // The scope control for the slider rule, and the mirror of the copy-cursor
    // one below: the fix for "the scrubber never showed `grab`" must not be a
    // blanket `.dctl{cursor:grab}`. This build has no bundle, nothing here can
    // honour a drag, and a track that offered the open hand would be this
    // repository's house defect wearing its newest control.
    //
    // Both hands are counted, not just `grab`: `pointer` on an unmovable track
    // is the same lie told with a different glyph. The ROLE's absence is journey
    // 17's assertion and is deliberately not restated here — this file judges
    // what the cursor says.
    const servedTrack = await cursorsAtCentre(page, ".dctl");
    j.note(`no-script timeline: ${shape(servedTrack)}`);
    j.atLeast(
      servedTrack.hit,
      1,
      "NO-SCRIPT: SUBJECTS — the timeline is served, and a pointer can rest on it",
    );
    j.countIs(
      (servedTrack.byCursor["grab"] ?? 0) +
        (servedTrack.byCursor["grabbing"] ?? 0) +
        (servedTrack.byCursor["pointer"] ?? 0),
      0,
      "NO-SCRIPT: the served timeline offers no hand at all, open or pointing, because nothing can move it",
    );

    const copyable = await cursorsAtCentre(page, ".copyable");
    j.note(`no-script copyable: ${shape(copyable)}`);
    j.atLeast(copyable.reachable, 1, "NO-SCRIPT: SUBJECTS — copyable values on the served page");
    j.countIs(
      copyable.hit,
      copyable.reachable,
      "NO-SCRIPT: each copyable value is the element under the pointer at its own centre",
    );
    j.countIs(
      copyable.byCursor["copy"] ?? 0,
      copyable.hit,
      "NO-SCRIPT: the copy affordance survives where nothing encloses it",
    );
  } finally {
    await page.close();
    await ctx.close();
  }
}
