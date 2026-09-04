// "A visitor whose contract has more files than the strip can show sees them on
//  ONE row — with the file being read always named, and every other file still
//  reachable."
//
// Page-Descriptions.md §13 (the Code pane is the flagship pane; a reduction is
// announced rather than silent) and the note on `--bt-layout-tabmenu-max-height`
// in docs/DESIGN-DIVERGENCES-WEB.md D-11: "A tab strip is a way IN to the
// document beneath it, so a strip that displaces that document has inverted its
// own purpose."
//
// THE REPORT THIS JOURNEY EXISTS FOR
// ----------------------------------
//     "In the smart contract that has sources available, the Code panel has many
//      tabs that are rendered on multiple rows. I think we should have a way to
//      accommodate a long list of tabs on a single row."
//
// Measured on the 32-file Aztec FeeJuice bundle before the fix: SEVEN rows of
// tabs at 1280 (172px of a 672px pane — a quarter of the pane's height spent
// naming files), six rows at 1440, five at 1920.
//
// WHY THE ROW COUNT AND NOT THE HEIGHT
// ------------------------------------
// The height is the consequence; the rows are the complaint, and they are the
// reading that cannot be satisfied by the wrong fix. A strip capped with
// `max-height` and left to wrap has a BOUNDED height and still wraps — that is
// what shipped, and it is what the reporter was looking at. So the assertion is
// on `rows`, computed as the number of distinct top offsets the tabs occupy,
// which is the same thing the eye counts. The height is recorded beside it as
// evidence rather than asserted, because "how tall is one row" is a type-scale
// question this journey has no business pinning.
//
// THE TRAP, AND IT IS WHY THE ACTIVE TAB IS ASSERTED AT THREE SCROLL POSITIONS
// ---------------------------------------------------------------------------
// "THE STRIP IS ONE ROW" PASSES UNDER A WORSE DEFECT THAN THE ONE IT FIXES.
//
// A strip that simply stops wrapping is one row at every width and hides most
// of the bundle off the right edge. Each panel carries its own strip and a
// freshly revealed panel starts at `scrollLeft: 0`, so the tab for the file the
// visitor is actually reading is off-screen for everything past the fourth —
// measured, before this journey was written, off-screen for the 18th tab of 32
// and every tab after it. A journey that asserted only the row count would have
// certified that.
//
// So the marked tab is read at THREE scroll positions — hard left, the middle,
// and hard right — and must be inside the strip's visible extent at all three.
// One position is not enough: at `scrollLeft: 0` a strip whose active tab
// happens to be third from the left passes while telling you nothing, and the
// panels whose active document sits late in the bundle are exactly the ones the
// defect hits.
//
// AND REACHABILITY IS ASSERTED BY NAME, NOT BY COUNT
// --------------------------------------------------
// `32 tabs are present` is satisfied by 32 tabs all naming the same file, and a
// count is what a truncating fix leaves intact while it drops the files off the
// end. Every document the page holds is read from the panels themselves — each
// `.srcdoc` carries the interned path on `data-path` — and each one must be
// named by a tab whose `href` is that panel's anchor. The two sets are compared
// as SETS OF PATHS, so a file that lost its tab is named in the failure rather
// than subtracted from a total.
//
// WHY THE MENU IS ASSERTED TOO
// ----------------------------
// One row that scrolls sideways keeps every file reachable in the sense that a
// mouse can get to it, and that is a thin sense: at 1280 the strip is 520px and
// the bundle is 3623px of tabs, so the file a visitor wants is on average a
// three-screen drag away. The control that opens the whole list is what makes the
// list usable rather than merely present, and it is the half of the fix a reader
// would miss first if it regressed — nothing else on the page would look wrong.
// So: it exists on a bundle bigger than a row, opening it shows every document,
// and closing it returns the strip to one row.
//
// AND WHY DISPLACEMENT IS NOW AN ASSERTION OF ITS OWN
// --------------------------------------------------
// THE FIRST FIX PASSED EVERY ASSERTION ABOVE AND THE REPORTER REJECTED IT.
//
// It was a DISCLOSURE: the control unfolded the same anchors back into the
// wrapped grid, in flow, in place. Measured here on the 32-file bundle, the
// unfolded state was EIGHT rows and 196px at 1280 — against the seven rows and
// 172px that were filed as the bug. Every assertion above was green over that,
// because every one of them reads the CLOSED strip or counts what the open one
// contains, and none of them read what opening it COST. "One row at rest, and a
// worse-than-the-bug layout one click away" is a sentence this file could not
// distinguish from a fix.
//
// The report that followed named the treatment: "a drop down menu for the tabs
// that don't fit". A menu is defined against a disclosure by exactly this — it
// is drawn OVER the document instead of in place of it — so that is what is
// asserted, as a measurement rather than as a mechanism:
//
//   * opening the list moves NOTHING. The source body's top edge and the strip
//     row's height are read before and after, and both deltas must be zero. Not
//     "the strip is short when open", which a capped in-flow list also satisfies;
//     zero, which only an out-of-flow one does.
//   * the open list is drawn OVER the source — its box overlaps the body's — and
//     stays INSIDE the pane it belongs to, so a menu that escaped its pane or
//     that merely appeared below everything both fail.
//
// Neither reads `position`, `display` or any other declaration. A journey that
// asserted `getComputedStyle(...).position === "absolute"` would pass over an
// absolutely positioned list that had been given `top:0` and covered the tabs,
// and would fail a future fix that reached the same screen another way.
//
// WHAT THIS JOURNEY DOES NOT JUDGE
// --------------------------------
// Whether a SMALL bundle gets the control. The threshold is a statement about
// what a row can be assumed to hold at the narrowest desktop width, not a claim
// about a visitor, and pinning it here would make a layout tuning into a gate.
// The three-file demo bundle is read and reported, and asserted only in that it
// must still be one row.

import { visit } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-long-file-list-fits-on-one-row";
export const claim =
  "A visitor whose contract has more files than the tab strip can show sees them on one row, " +
  "with the file being read always named, every other file still reachable, and the rest of them " +
  "one click away in a menu that costs the document none of its height.";
export const spec =
  "Page-Descriptions.md §13; docs/DESIGN-DIVERGENCES-WEB.md D-11 — BlockTracer";
// 11, and every one of them runs exactly once: the per-subject work accumulates
// into failure lists and the verdicts are taken over those lists afterwards.
// Counting per subject would make the declared number a function of the corpus,
// which is how an arm that stopped running goes unnoticed.
export const assertions = 11;
export const needsEngine = false;

// The three desktop widths the debugger is judged at. 1440 and 1920 are
// `capture/views.mjs`'s `laptop` and `wide`; 1280 is added here because it is
// BELOW the 1320px rung at which the debugger's identity bar wraps
// (`debugger_css.nim`), so it is the narrowest pane this layout has to hold —
// and the width at which the wrap was worst.
const WIDTHS = [
  { width: 1280, height: 800 },
  { width: 1440, height: 900 },
  { width: 1920, height: 1080 },
];

/**
 * Everything this journey judges, read from one panel in one pass.
 *
 * It is one `evaluate` because every reading has to come from the SAME layout:
 * a row count taken before a scroll and a visibility taken after it are two
 * different pages, and the difference is invisible in the result.
 */
const readStrip = (page) =>
  page.evaluate(() => {
    const shown = (e) =>
      !!e &&
      typeof e.checkVisibility === "function" &&
      e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });

    const panels = [...document.querySelectorAll(".srcdoc")];
    const visible = panels.filter(shown);
    if (visible.length !== 1) return { error: `${visible.length} visible .srcdoc panels` };
    const panel = visible[0];
    const strip = panel.querySelector(".srctabs");
    if (!strip) return { error: "no .srctabs in the visible panel" };

    const tabs = [...strip.querySelectorAll(".srctab")];
    const marked = [...panel.querySelectorAll(".srctab.on")];
    const on = marked[0] ?? null;

    // ROWS: distinct rounded top offsets, which is what the eye counts.
    const rowsOf = () =>
      new Set(tabs.map((t) => Math.round(t.getBoundingClientRect().top))).size;

    // The marked tab inside the strip's own visible extent, at a given offset.
    const insideAt = (offset) => {
      if (!on) return false;
      strip.scrollLeft = offset;
      const sb = strip.getBoundingClientRect();
      const ob = on.getBoundingClientRect();
      return (
        ob.left >= sb.left - 0.5 &&
        ob.right <= sb.right + 0.5 &&
        ob.top >= sb.top - 0.5 &&
        ob.bottom <= sb.bottom + 0.5
      );
    };

    const before = strip.scrollLeft;
    const atLeftEdge = insideAt(0);
    const atMiddle = insideAt(strip.scrollWidth / 2);
    const atRightEdge = insideAt(strip.scrollWidth);
    strip.scrollLeft = before;

    // REACHABILITY BY NAME. The documents are the panels' own interned paths;
    // a tab reaches one when its href is that panel's anchor.
    const documents = panels.map((p) => p.getAttribute("data-path"));
    const anchorOf = new Map(panels.map((p) => [p.id, p.getAttribute("data-path")]));
    const reached = new Set();
    for (const t of tabs) {
      const href = t.getAttribute("href") || "";
      if (!href.startsWith("#")) continue;
      const path = anchorOf.get(href.slice(1));
      if (path) reached.add(path);
    }

    // THE MENU, driven rather than inspected: a control that is present and does
    // nothing is the thing worth catching, and a control whose open state pushes
    // the document down is the thing the FIRST fix did while passing.
    //
    // The row box and the source body are read on BOTH sides of the click, in
    // this one evaluation, so the two numbers being subtracted come from the same
    // layout. A displacement computed across two page loads is a difference
    // between two pages.
    const stripBox = panel.querySelector(".srcstrip");
    const srcBody = panel.querySelector(".src");
    const paneBody = panel.closest(".panebody");
    const rectOf = (e) => {
      const r = e.getBoundingClientRect();
      return { top: r.top, left: r.left, right: r.right, bottom: r.bottom, height: r.height };
    };
    const opener = panel.querySelector(".srcall");
    let opened = null;
    if (opener && stripBox && srcBody) {
      const rowsClosed = rowsOf();
      const rowBefore = rectOf(stripBox);
      const bodyBefore = rectOf(srcBody);
      opener.click();
      const shownWhileOpen = tabs.filter(shown).length;
      const rowsOpen = rowsOf();
      const listBox = rectOf(strip);
      const rowAfter = rectOf(stripBox);
      const bodyAfter = rectOf(srcBody);
      const pane = paneBody ? rectOf(paneBody) : null;
      const openHeight = Math.round(listBox.height);
      const capped = strip.scrollHeight > strip.clientHeight;
      // The marked file is still named while the list is open — a menu that
      // dropped the mark would leave the reader with no "you are here" at all.
      const markedShownWhileOpen = shown(panel.querySelector(".srctab.on"));
      opener.click();
      opened = {
        rowsClosed,
        rowsOpen,
        openHeight,
        shownWhileOpen,
        capped,
        markedShownWhileOpen,
        rowsAfterClosing: rowsOf(),
        // THE DISPLACEMENT. Rounded to whole pixels because sub-pixel layout is
        // not a thing a reader sees and not a thing this journey should gate on.
        bodyMoved: Math.round(bodyAfter.top - bodyBefore.top),
        rowGrew: Math.round(rowAfter.height - rowBefore.height),
        bodyRestored: Math.round(rectOf(srcBody).top - bodyBefore.top),
        // THE OVERLAY. Over the source, and inside the pane it belongs to.
        overSource: listBox.top < bodyAfter.bottom && listBox.bottom > bodyAfter.top,
        insidePane:
          pane === null
            ? false
            : listBox.top >= pane.top - 0.5 &&
              listBox.bottom <= pane.bottom + 0.5 &&
              listBox.left >= pane.left - 0.5 &&
              listBox.right <= pane.right + 0.5,
      };
    }

    return {
      tabCount: tabs.length,
      markedCount: marked.length,
      documents,
      reached: [...reached],
      rows: rowsOf(),
      stripHeight: Math.round(strip.getBoundingClientRect().height),
      scrollWidth: Math.round(strip.scrollWidth),
      clientWidth: Math.round(strip.clientWidth),
      activePath: on ? on.getAttribute("title") : null,
      atLeftEdge,
      atMiddle,
      atRightEdge,
      hasOpener: !!opener,
      opened,
    };
  });

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const sessions = all.filter((t) => landingOf(t.phase) === "session" && t.hasSource);
  j.subjects(sessions, 1, "sessions whose Code pane holds SOURCE");

  const readings = [];
  for (const t of sessions) {
    for (const viewport of WIDTHS) {
      const v = await visit(browser, site.origin, t.debugPath, { viewport });
      try {
        const m = await readStrip(v.page);
        readings.push({ t, viewport, m });
      } finally {
        await v.page.close();
      }
    }
  }

  // CONTROL, BEFORE ANY VERDICT. Every count below is `x.length === 0`, and an
  // empty reading set satisfies all of them; so is a set whose every panel
  // failed to render a strip. The number of tabs actually seen is printed, and
  // asserted to be more than one per reading, so the size of what was judged is
  // on the record rather than assumed.
  const broken = readings.filter((r) => r.m.error);
  for (const r of broken) j.note(`${r.t.debugPath} @${r.viewport.width}: ${r.m.error}`);
  const tabsSeen = readings.reduce((n, r) => n + (r.m.tabCount ?? 0), 0);
  j.atLeast(
    tabsSeen,
    readings.length * 2,
    `CONTROL: tabs read across ${readings.length} pane readings ` +
      `(${sessions.length} source session(s) x ${WIDTHS.length} widths), ${broken.length} unreadable`,
  );

  const ok = readings.filter((r) => !r.m.error);

  // THE SUBJECTS THE REPORT IS ABOUT: bundles with enough files that the row is
  // a question at all. Asserted non-empty, because every verdict below is
  // vacuously true over a corpus of single-file contracts.
  const many = ok.filter((r) => r.m.documents.length > 4);
  for (const r of many.slice(0, 1)) {
    j.note(
      `subject: ${r.t.debugPath} — ${r.m.documents.length} documents, ` +
        `${r.m.scrollWidth}px of tabs in a ${r.m.clientWidth}px strip`,
    );
  }
  j.atLeast(
    many.length,
    1,
    "SUBJECTS: pane readings of a bundle with more files than one row is assumed to hold",
  );

  // 1. THE COMPLAINT. One row, at every width, on every source bundle.
  const multiRow = ok.filter((r) => r.m.rows !== 1);
  for (const r of multiRow) {
    j.note(
      `${r.t.debugPath} @${r.viewport.width}: the tab strip occupies ${r.m.rows} rows ` +
        `(${r.m.stripHeight}px) for ${r.m.documents.length} documents`,
    );
  }
  j.countIs(multiRow.length, 0, "the tab strip occupies exactly one row");

  // 2. THE FILE BEING READ IS NAMED — wherever the strip is scrolled to.
  const lost = ok.filter((r) => !(r.m.atLeftEdge && r.m.atMiddle && r.m.atRightEdge));
  for (const r of lost) {
    j.note(
      `${r.t.debugPath} @${r.viewport.width}: the marked tab "${r.m.activePath}" is outside the ` +
        `strip's visible extent (left ${r.m.atLeftEdge}, middle ${r.m.atMiddle}, right ${r.m.atRightEdge})`,
    );
  }
  j.countIs(
    lost.length,
    0,
    "the marked tab is inside the strip's visible extent at every scroll position",
  );

  // 3. AND EXACTLY ONE TAB IS MARKED — the reading above is meaningless if the
  //    panel marks two, and `lib/frame.mjs` takes the first of them.
  const mismarked = ok.filter((r) => r.m.markedCount !== 1);
  for (const r of mismarked) {
    j.note(`${r.t.debugPath} @${r.viewport.width}: ${r.m.markedCount} tabs marked`);
  }
  j.countIs(mismarked.length, 0, "exactly one tab is marked in the visible panel");

  // 4. EVERY FILE STAYS REACHABLE, BY NAME.
  const unreachable = [];
  for (const r of ok) {
    const missing = r.m.documents.filter((d) => !r.m.reached.includes(d));
    if (missing.length) unreachable.push({ r, missing });
  }
  for (const { r, missing } of unreachable) {
    j.note(
      `${r.t.debugPath} @${r.viewport.width}: ${missing.length} document(s) no tab links to — ` +
        missing.slice(0, 3).join(", "),
    );
  }
  j.countIs(
    unreachable.length,
    0,
    "every document the pane holds is named by a tab that links to it",
  );

  // 5. THE CONTROL EXISTS ON THE BUNDLES THAT NEED IT.
  const noOpener = many.filter((r) => !r.m.hasOpener);
  for (const r of noOpener) {
    j.note(
      `${r.t.debugPath} @${r.viewport.width}: ${r.m.documents.length} documents and no control ` +
        "to open the whole list",
    );
  }
  j.countIs(
    noOpener.length,
    0,
    "a bundle larger than one row offers the control that opens the whole list",
  );

  // 6. AND OPENING IT SHOWS EVERY DOCUMENT, then gives the row back.
  const deadOpener = many.filter(
    (r) =>
      !r.m.opened ||
      r.m.opened.shownWhileOpen !== r.m.tabCount ||
      r.m.opened.rowsOpen <= 1 ||
      !r.m.opened.markedShownWhileOpen ||
      r.m.opened.rowsAfterClosing !== 1,
  );
  for (const r of deadOpener) {
    j.note(
      `${r.t.debugPath} @${r.viewport.width}: opening the list gave ` +
        `${r.m.opened ? `${r.m.opened.shownWhileOpen}/${r.m.tabCount} tabs over ${r.m.opened.rowsOpen} rows, ` +
          `marked file ${r.m.opened.markedShownWhileOpen ? "still named" : "NOT named"}, ` +
          `back to ${r.m.opened.rowsAfterClosing} row(s)` : "nothing"}`,
    );
  }
  for (const r of many.slice(0, 1)) {
    if (r.m.opened) {
      j.note(
        `the opened list at ${r.viewport.width}: ${r.m.opened.rowsOpen} rows, ` +
          `${r.m.opened.openHeight}px, ${r.m.opened.capped ? "capped and scrolling" : "within the cap"}`,
      );
    }
  }
  j.countIs(
    deadOpener.length,
    0,
    "opening that control shows every one of the documents, and closing it returns one row",
  );

  // 7. AND IT COSTS THE DOCUMENT NOTHING. The assertion the first fix would have
  //    failed: it unfolded IN FLOW, 196px of it at 1280, and pushed the source
  //    down by exactly that. A menu moves nothing.
  const displaced = many.filter(
    (r) =>
      !r.m.opened ||
      r.m.opened.bodyMoved !== 0 ||
      r.m.opened.rowGrew !== 0 ||
      r.m.opened.bodyRestored !== 0,
  );
  for (const r of displaced) {
    j.note(
      `${r.t.debugPath} @${r.viewport.width}: opening the list moved the source ` +
        `${r.m.opened ? `${r.m.opened.bodyMoved}px and grew the row by ${r.m.opened.rowGrew}px ` +
          `(${r.m.opened.bodyRestored}px still off after closing)` : "— it does not open"}`,
    );
  }
  for (const r of many.slice(0, 1)) {
    if (r.m.opened) {
      j.note(
        `at ${r.viewport.width} the open list is ${r.m.opened.openHeight}px over a row that ` +
          `stayed ${r.m.opened.rowGrew === 0 ? "the same height" : `${r.m.opened.rowGrew}px taller`}`,
      );
    }
  }
  j.countIs(
    displaced.length,
    0,
    "opening the file list moves neither the source nor the row it opened from",
  );

  // 8. BECAUSE IT IS DRAWN OVER THE SOURCE, AND STAYS IN ITS OWN PANE. The
  //    positive half of 7: a list that moved nothing because it rendered nothing
  //    would satisfy the deltas and fail here.
  const notOverlaid = many.filter(
    (r) => !r.m.opened || !r.m.opened.overSource || !r.m.opened.insidePane,
  );
  for (const r of notOverlaid) {
    j.note(
      `${r.t.debugPath} @${r.viewport.width}: the open list is ` +
        `${r.m.opened ? `${r.m.opened.overSource ? "over the source" : "NOT over the source"}, ` +
          `${r.m.opened.insidePane ? "inside the pane" : "OUTSIDE the pane"}` : "absent"}`,
    );
  }
  j.countIs(
    notOverlaid.length,
    0,
    "the open file list is drawn over the source, and inside the pane it belongs to",
  );
}
