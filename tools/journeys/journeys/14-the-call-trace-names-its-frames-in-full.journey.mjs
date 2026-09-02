// "A visitor reading the Call Trace sees every frame's function name in full,
//  can reach its path on hover, and reads the selected frame's whole context
//  beside the transaction."
//
// Page-Descriptions.md §7.1 — the metadata pane is "a pane in the session,
// beside the debugger's own panes".
//
// THE FALSE PASS THIS FILE IS BUILT TO EXCLUDE
// -------------------------------------------
// "The path is absent from the row" is satisfied by a row that renders
// NOTHING. So the absence of the path is never asserted on its own here.
// Every arm asserts the positive first — that the PAINTED function name is the
// WHOLE function name — and only then that the path left the paint without
// leaving the page.
//
// "The painted name is the whole name" is not "the name is in the DOM"
// either. `textContent` is identical whether the name is drawn in full or
// ellipsised to a third of itself; CSS truncation is invisible to it. The
// measurement is the element's own overflow — `scrollWidth > clientWidth` —
// taken at a real viewport with the real stylesheet, which is the same thing
// the eye is reporting when it says the pane is cut.
//
// AND IT IS HIT-TESTED AT ITS OWN CENTRE
// --------------------------------------
// A width reading says a box is big enough. It does not say anything is
// visible in it: an element can measure correctly and be covered by a sticky
// header, an overlay or its own neighbour. `document.elementFromPoint` at the
// element's centre is what distinguishes "painted" from "present", and this
// campaign has already had painted content wrongly reported ABSENT for want of
// it. Rows are scrolled into view before the reading, because a row below the
// fold hit-tests as covered and that would be this file making the same
// mistake in the other direction.
//
// SUBJECTS ARE PROPERTIES, NEVER FIXTURES
// ---------------------------------------
// No transaction, chain, file or function is named below. The served arm takes
// the session whose Call Trace paints the MOST rows; the live arm takes the
// session whose Call Trace repeats the most function names, which is what
// recursion IS and is what makes it the subject worth judging — every frame
// shares a name, so a truncated name identifies nothing at all.
//
// WHY THE LIVE ARM EXISTS AT ALL
// ------------------------------
// A tour program's replay panes are empty on the static route — `demo_session`
// describes one program and `withPublishedSources` refuses to draw another
// program's frames beside it. So the deepest call trees this product can show
// are painted by the hydration bundle or by nothing, and a file that judged
// only the served page would never have seen one.

import { visit, openBrowser } from "../lib/probe.mjs";
import { transactions } from "../lib/corpus.mjs";

export const id = "call-trace-names-its-frames-in-full";
export const claim =
  "A visitor reading the Call Trace sees every frame's function name in full, can reach its path on hover, and reads the selected frame's whole context beside the transaction.";
export const spec = "Page-Descriptions.md §7.1 — BlockTracer";
export const needsEngine = true;
// 2 subject counts + 2 x 8 shared row questions + 4 served-only + 4 live-only.
export const assertions = 26;

// ── the one reading both arms are judged on ────────────────────────────────
//
// Returned from a single `page.evaluate` so that every number describes ONE
// layout. Reading widths in one call and text in another lets a re-render
// between them produce a pair that never coexisted.
const READ_ROWS = () => {
  const shown = (e) =>
    !!e && typeof e.checkVisibility === "function"
      ? e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })
      : false;

  // The call-ORDER view only. The aggregate view is a `:target` alternate that
  // CSS hides, and its rows are functions rather than frames.
  const view = document.querySelector(".ctview.def");
  if (!view) return { rows: [], selection: null };

  const rows = [...view.querySelectorAll(".ctrow")].filter(shown).map((row) => {
    const name = row.querySelector(".ctname");
    if (!name) return { noName: true };

    // Into view FIRST, then measure and hit-test. A row below the fold is not
    // covered; it is simply not on screen, and testing it where it is not
    // would report a defect this pane does not have.
    row.scrollIntoView({ block: "center" });
    const r = name.getBoundingClientRect();
    const hit = document.elementFromPoint(
      Math.round(r.left + r.width / 2),
      Math.round(r.top + r.height / 2),
    );

    return {
      text: name.textContent,
      // +1px absorbs sub-pixel layout. A real ellipsis overflows by far more —
      // the measured case before this change needed 217px in a 152px box.
      truncated: name.scrollWidth > name.clientWidth + 1,
      paintedAtCentre: !!hit && (name === hit || name.contains(hit)),
      shown: shown(name),
      pathElements: row.querySelectorAll(".ctmod").length,
      title: row.getAttribute("title"),
      dataModule: row.getAttribute("data-module"),
      dataStep: row.getAttribute("data-step"),
      line: row.querySelector(".ctline")?.textContent ?? null,
      current: row.classList.contains("cur"),
    };
  });

  // WOULD THE WIDEST NAME HAVE BEEN CUT BEFORE?
  //
  // Rebuilt in the page, at this viewport, in this stylesheet: the row's own
  // `.ctfn` is cloned, the retired `.ctmod` span is put back beside the name
  // with the path the row still carries as data, and the two retired
  // declarations are restored on it. If the name overflows THAT, the subject
  // is a case this change actually fixed rather than one that always fit.
  let witness = null;
  const widest = rows
    .filter((r) => !r.noName && r.dataModule)
    .sort((a, b) => b.text.length - a.text.length)[0];
  if (widest) {
    const row = [...view.querySelectorAll(".ctrow")].find(
      (e) => e.querySelector(".ctname")?.textContent === widest.text,
    );
    const fn = row?.querySelector(".ctfn");
    if (fn) {
      const clone = fn.cloneNode(true);
      clone.style.overflow = "hidden";
      const nm = clone.querySelector(".ctname");
      nm.style.whiteSpace = "nowrap";
      nm.style.overflow = "hidden";
      nm.style.textOverflow = "ellipsis";
      const mod = document.createElement("span");
      mod.textContent = widest.dataModule;
      mod.style.whiteSpace = "nowrap";
      mod.style.fontSize = getComputedStyle(document.documentElement)
        .getPropertyValue("--bt-type-label-size");
      clone.appendChild(mod);
      fn.parentElement.insertBefore(clone, fn);
      witness = {
        name: widest.text,
        cutWithPath: nm.scrollWidth > nm.clientWidth + 1,
        needed: nm.scrollWidth,
        had: nm.clientWidth,
      };
      clone.remove();
    }
  }

  const sel = document.querySelector("#dbg-selection");
  const selection = !sel
    ? null
    : {
        shown: shown(sel),
        heading: sel.querySelector(".mdexectitle")?.textContent ?? null,
        note: sel.querySelector(".panenote")?.textContent ?? null,
        facts: Object.fromEntries(
          [...sel.querySelectorAll("dt")].map((dt, i) => [
            dt.textContent,
            sel.querySelectorAll("dd")[i]?.textContent ?? null,
          ]),
        ),
      };

  return { rows, selection, witness };
};

/** The five questions asked of any Call Trace, served or live. */
function judgeRows(j, arm, rows, witness) {
  j.atLeast(rows.length, 1, `${arm}: the Call Trace painted frame rows`);

  const named = rows.filter((r) => !r.noName);
  j.countIs(
    named.length,
    rows.length,
    `${arm}: every painted row carries a function name`,
  );

  // THE CLAIM. Not "a name exists" — no name is cut off.
  j.countIs(
    named.filter((r) => r.truncated).length,
    0,
    `${arm}: no painted function name is truncated`,
  );

  // The painted text IS the whole name, checked against the other place the
  // page states it: the tooltip, which the producer derives from the same
  // field. Two things the page reports, related — not a constant this file
  // supplied and asserted back.
  j.countIs(
    named.filter((r) => (r.title ?? "").split("\n")[0] !== r.text).length,
    0,
    `${arm}: the painted name equals the name the row's tooltip leads with`,
  );

  j.countIs(
    named.filter((r) => !r.paintedAtCentre).length,
    0,
    `${arm}: every name is painted at its own centre, not merely in the DOM`,
  );

  // The path left the PAINT. Asserted only after the positive above, because
  // on its own a row that rendered nothing would satisfy it.
  j.countIs(
    named.reduce((n, r) => n + r.pathElements, 0),
    0,
    `${arm}: no row paints a path`,
  );

  // …and did not leave the PAGE. Reachable on hover, and as data for the
  // deep-link reader that used to scrape the retired element.
  const withPath = named.filter((r) => (r.dataModule ?? "") !== "");
  j.atLeast(withPath.length, 1, `${arm}: rows carry their path as data`);
  j.countIs(
    withPath.filter((r) => !(r.title ?? "").includes(r.dataModule)).length,
    0,
    `${arm}: every row's hover text contains that row's own path`,
  );
}

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);

  // ── SERVED ───────────────────────────────────────────────────────────────
  const served = all
    .map((t) => ({ ...t, frames: t.calltraceFrames }))
    .filter((t) => t.frames > 0)
    .sort((a, b) => b.frames - a.frames);
  j.subjects(served, 1, "served sessions whose Call Trace paints frame rows");

  const s = served[0];
  j.note(`SERVED: ${s.debugPath} (${s.frames} rows in the served markup)`);
  const page = await visit(browser, site.origin, s.debugPath);
  try {
    const read = await page.page.evaluate(READ_ROWS);
    judgeRows(j, "SERVED", read.rows, read.witness);

    // The subject is a case that WOULD have been cut before this change.
    // Without this the arm above could be green on a pane whose names always
    // fitted, which would prove nothing about the defect.
    j.expect(
      !!read.witness && read.witness.cutWithPath,
      "SERVED: the widest name would have been cut with the path restored",
      read.witness
        ? `${JSON.stringify(read.witness.name)} needs ${read.witness.needed}px, had ${read.witness.had}px beside its path`
        : "no row carried both a name and a path",
    );

    j.expect(
      !!read.selection && read.selection.shown,
      "SERVED: the selection area is rendered beside the transaction",
      read.selection ? `heading=${read.selection.heading}` : "absent",
    );
    // It describes the frame the pane MARKS, and it names it — the content the
    // row stopped painting is readable here.
    const marked = read.rows.find((r) => r.current);
    j.expect(
      !!marked && read.selection?.facts?.Function === marked.text,
      "SERVED: the selection area names the frame the pane marks as current",
      `marked=${JSON.stringify(marked?.text)} panel=${JSON.stringify(read.selection?.facts?.Function)}`,
    );
    // THE FALLBACK WAS DOING HALF THE JOB, AND THE HALF IT MISSED IS THE DEFECT.
    //
    // It read `marked?.dataModule ?? "\u0000"` — a NUL sentinel, chosen so that
    // a MISSING marked row fails rather than passes, which is right and is the
    // same care journey 12's `-1`/`-2` sentinels take. But `??` catches only
    // `null` and `undefined`, and `dataModule` is `getAttribute("data-module")`,
    // which is the EMPTY STRING for an attribute that is present and empty.
    // That is exactly what "the path is gone" looks like on the attribute the
    // row still carries — and `"anything".includes("")` is true, so the plainest
    // form of the defect this assertion exists for passed it unconditionally.
    //
    // The non-emptiness is now lifted into the assertion where it can be read,
    // and the literal NUL is gone with it: a NUL byte makes this file BINARY to
    // grep, so `grep -n "atLeast(" *.journey.mjs` silently skipped all 383 lines
    // of it. An instrument that cannot be searched is one nobody audits.
    j.expect(
      !!marked &&
        (marked.dataModule ?? "") !== "" &&
        (read.selection?.facts?.Source ?? "").includes(marked.dataModule),
      "SERVED: the selection area states the path the row no longer paints",
      `row data-module=${JSON.stringify(marked?.dataModule)} ` +
        `panel=${JSON.stringify(read.selection?.facts?.Source)}`,
    );
  } finally {
    await page.page.close();
  }

  // ── LIVE: the recursion subject ──────────────────────────────────────────
  //
  // Selected by the property that makes recursion hard to read — the same
  // function name appearing on many frames — rather than by naming a program.
  const own = await openBrowser();
  const live = await own.newPage({ viewport: { width: 1440, height: 900 } });
  try {
    // The sessions whose frames exist ONLY live: a container to replay, and a
    // served Call Trace with no frames in it. Ranked by the recording's length
    // and capped, because hydrating a session costs a worker and an 18 MB wasm
    // and the arm must not walk the whole corpus to find one. The ranking is a
    // budget, not the claim — the subject is chosen below by the property that
    // matters, which is how many frames share a name.
    const candidates = all
      .filter((x) => x.hasContainer && x.calltraceFrames === 0)
      .sort((a, b) => b.totalSteps - a.totalSteps)
      .slice(0, 4);
    j.note(`LIVE: hydrating ${candidates.length} candidate session(s)`);

    let best = null;
    for (const t of candidates) {
      await live.goto(site.origin + t.debugPath, { waitUntil: "load" });
      const deadline = Date.now() + 90_000;
      let n = 0;
      while (Date.now() < deadline) {
        n = await live.evaluate(() => document.querySelectorAll(".ctview.def .ctrow").length);
        if (n > 0) break;
        await live.waitForTimeout(500);
      }
      if (!n) continue;
      const repeats = await live.evaluate(() => {
        const names = [...document.querySelectorAll(".ctview.def .ctname")].map(
          (e) => e.textContent,
        );
        return new Set(names.filter((x, i) => names.indexOf(x) !== i)).size;
      });
      if (!best || repeats > best.repeats) best = { t, repeats, rows: n };
    }
    j.subjects(
      best ? [best] : [],
      1,
      "a LIVE session whose Call Trace repeats function names (recursion)",
    );

    if (best) {
      j.note(`LIVE: ${best.t.debugPath} — ${best.rows} frames, ${best.repeats} repeated names`);
      await live.goto(site.origin + best.t.debugPath, { waitUntil: "load" });
      const deadline = Date.now() + 90_000;
      while (Date.now() < deadline) {
        if (await live.evaluate(() => document.querySelectorAll(".ctview.def .ctrow").length)) break;
        await live.waitForTimeout(500);
      }
      j.atLeast(
        best.repeats,
        1,
        "LIVE: the subject really is a recursion trace — one function, many frames",
      );

      const read = await live.evaluate(READ_ROWS);
      judgeRows(j, "LIVE", read.rows, read.witness);

      // THE PANEL IS WHAT MAKES TWO FRAMES OF ONE FUNCTION TELLABLE APART.
      // Click a frame whose name is shared with another frame, and the panel
      // must name THAT function and THAT frame's own coordinate — the fact the
      // line number cannot supply, because a function is declared once.
      const target = await live.evaluate(() => {
        const rows = [...document.querySelectorAll(".ctview.def .ctrow")];
        const names = rows.map((r) => r.querySelector(".ctname")?.textContent);
        const i = names.findIndex(
          (n, k) => n && names.indexOf(n) !== k && rows[k].getAttribute("data-step") !== "0",
        );
        if (i < 0) return null;
        rows[i].scrollIntoView({ block: "center" });
        return { index: i, name: names[i], step: rows[i].getAttribute("data-step") };
      });
      j.expect(
        !!target,
        "LIVE: a repeated frame is reachable to select",
        JSON.stringify(target),
      );

      if (target) {
        await live.click(`.ctview.def .ctrow >> nth=${target.index}`);
        const settle = Date.now() + 20_000;
        let facts = null;
        while (Date.now() < settle) {
          facts = await live.evaluate(() => {
            const sel = document.querySelector("#dbg-selection");
            if (!sel) return null;
            return Object.fromEntries(
              [...sel.querySelectorAll("dt")].map((dt, i) => [
                dt.textContent,
                sel.querySelectorAll("dd")[i]?.textContent ?? null,
              ]),
            );
          });
          if (facts?.Function === target.name) break;
          await live.waitForTimeout(250);
        }
        j.expect(
          facts?.Function === target.name,
          "LIVE: selecting a repeated frame makes the panel name that function",
          `clicked=${JSON.stringify(target.name)} panel=${JSON.stringify(facts?.Function)}`,
        );
        j.expect(
          !!facts?.["Starts at step"],
          "LIVE: the panel states the coordinate that tells two frames of one function apart",
          `panel step=${JSON.stringify(facts?.["Starts at step"])} row data-step=${target.step}`,
        );
      }
    }
  } finally {
    await live.close();
    await own.close();
  }
}
