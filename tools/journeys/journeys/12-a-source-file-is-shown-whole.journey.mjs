// "A visitor reading a session's Code pane can read the WHOLE file the session
//  is stopped in — every line of it, not a window onto the position."
//
// Page-Descriptions.md §7.0 (the served frame IS the session) and §13 (a
// reduction is announced rather than silent).
//
// THE REPORT THIS EXISTS FOR
// --------------------------
// On the `loops and iteration` capture the Code pane showed `src/main.nr` cut
// off under a banner reading "Showing from line 71". The file is 83 lines and
// its `main` is at line 77, so the pane showed thirteen lines and none of the
// four functions `main` calls. The reader's question was why the functionality
// exists at all.
//
// It existed because `source_document.openAtCurrent` narrowed the active
// document to six lines of lead-in and everything below the position, and it
// did that because "the pane has no JavaScript to scroll with". That premise
// was a claim about a BUILD — true of `just export`, false of the artefact this
// journey drives — and `source_document.nim` carries the account and the
// measurements. The window is gone; this is the browser half of that.
//
// WHY THE COUNT IS THE ASSERTION AND THE BANNER IS NOT
// ---------------------------------------------------
// "No banner is on screen" proves nothing on its own. A file SHORTER than the
// six-line lead-in never carried a banner either, and neither does a pane that
// renders six rows and stops. The only assertion that separates "the whole
// file" from "some of it" is an equality against the file's own length — so the
// number of rows the pane paints is compared against the number of lines in the
// text the page itself publishes, per subject, and the banner is asserted
// afterwards and never instead.
//
// The length is taken from `#bt-session-source`, the source island the page
// inlines for hydration. That is the product's own copy of the file, it was
// always encoded from the COMPLETE documents (`pages/debug.nim` encodes before
// it renders, deliberately), and reading it here keeps every expectation a
// relation between two things the page reports — the rule
// `client/tests/test_entry_state.nim` states and the reason 115 debug-route
// cases could not see the seed defect. No line count, no file name and no
// position is written in this file.
//
// PAINTED, NOT PRESENT, AND NOT `innerText`
// -----------------------------------------
// The pane holds every document in the bundle at once and hides all but one
// with CSS, and `.src` is a scroll container, so "the row is in the DOM" and
// "the row is on the screen" are different questions and the second is the
// claim. Every row is scrolled into the pane's own scrollport and hit-tested
// with `elementFromPoint` at its own coordinates: the topmost node at that
// point has to BE that row. A row that is clipped, covered, zero-height or
// scrolled out of a container that cannot scroll fails that and passes a text
// read.
//
// The whole measurement runs inside ONE `page.evaluate`. Hydration replaces the
// pane on every stop, and a loop that awaited between rows could hit-test nodes
// that had been detached under it — a flake that would read as a product
// failure.
//
// BOTH KINDS OF CODE PANE, NEITHER PREFERRED
// ------------------------------------------
// The lead-in windowed the instruction listing too, with the same six rows and
// the same sentence in the coordinate the rows are actually in ("Showing from
// step 122"). A chain capture's pane is a listing, a demo session's is source,
// and the claim is the same for both — so both sets are selected by filter,
// both are asserted non-empty with their counts printed, and both are driven.

import { visit } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-source-file-is-shown-whole";
export const claim =
  "A visitor reading a session's Code pane can read the whole file the session is stopped in — every line of it, not a window onto the position.";
export const spec = "Page-Descriptions.md §7.0, §13 — BlockTracer";
export const assertions = 13;

/**
 * How many lines the old lead-in would have removed from a document of `lines`
 * lines with the position on `at`.
 *
 * `SourceLeadIn` was 6 and `openAtCurrent` kept `number >= at - 6`, so it
 * dropped `at - 7` lines and was a no-op at or above the seventh line. It is
 * spelled out here — the one number this file names — because it is what makes
 * the corpus's CONTROL assertion meaningful: without it, every subject could be
 * a file the window never touched and the whole journey would pass over a
 * product that still windowed.
 */
const LEAD_IN_WOULD_HAVE_CUT = (at, lines) =>
  at > 7 && lines > 0 ? Math.min(at - 7, lines) : 0;

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const sessions = all.filter((t) => landingOf(t.phase) === "session");

  // TWO SUBJECT SETS, EACH ASSERTED NON-EMPTY, NO FALLBACK BETWEEN THEM. A
  // corpus that lost either kind is a RED here rather than a green run over
  // half the claim — the shape `run.mjs`'s `refuseSubjectFallback` lint exists
  // for, and the shape six journeys in this directory were found in.
  const withSource = sessions.filter((t) => t.hasSource);
  j.subjects(withSource, 1, "sessions whose Code pane holds SOURCE");
  j.atLeast(
    sessions.filter((t) => t.instructionLevel).length,
    1,
    "sessions whose Code pane holds an instruction LISTING",
  );
  const subjectPages = sessions.filter((t) => t.hasListing);

  const seen = [];
  for (const t of subjectPages) {
    const v = await visit(browser, site.origin, t.debugPath);
    try {
      const m = await v.page.evaluate(() => {
        const shown = (e) =>
          !!e &&
          typeof e.checkVisibility === "function" &&
          e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });

        // `splitSourceLines`, in the browser: a file ending in `\n` has N lines
        // and not N+1, which is the same rule the renderer numbers rows by. Get
        // this wrong and every comparison below is off by one on every subject.
        const lineCount = (text) => {
          const a = String(text).replace(/\r\n/g, "\n").split("\n");
          if (a.length > 0 && a[a.length - 1] === "") a.pop();
          return a.length;
        };

        const islandEl = document.getElementById("bt-session-source");
        let island = null;
        try {
          island = JSON.parse(islandEl ? islandEl.textContent : "");
        } catch {
          island = null;
        }
        const docs = island && Array.isArray(island.documents) ? island.documents : [];
        const activeIndex = island ? island.activeIndex : -1;
        const active = activeIndex >= 0 && activeIndex < docs.length ? docs[activeIndex] : null;

        // The pane emits the ACTIVE document as `.srcdoc def` and every other
        // as `.srcdoc alt`, hidden until its tab is targeted. No fragment is in
        // the URL, so the one on screen is the active one — cross-checked
        // against the tab strip's own label where there is a strip, so
        // "the island's activeIndex" and "the document a visitor is looking at"
        // are not taken on trust from one another.
        const panels = [...document.querySelectorAll(".srcdoc")].filter(shown);
        const panel = panels.length === 1 ? panels[0] : null;
        const tabLabel = panel?.querySelector(".srctab.on")?.textContent?.trim() ?? null;

        const rows = panel ? [...panel.querySelectorAll(".srcline")] : [];
        const numberOf = (r) => {
          const n = r.querySelector(".n")?.textContent?.trim() ?? "";
          return /^-?\d+$/.test(n) ? parseInt(n, 10) : null;
        };

        // PAINTED, ROW BY ROW. Each row is brought into the pane's scrollport
        // and the topmost node at its own left edge and vertical middle has to
        // be that row. `left + 2` lands in `.srcline`'s own padding, so the hit
        // is on the row rather than on whichever cell happens to be widest.
        let painted = 0;
        for (const r of rows) {
          r.scrollIntoView({ block: "center", inline: "nearest" });
          const b = r.getBoundingClientRect();
          if (b.width <= 0 || b.height <= 0) continue;
          const el = document.elementFromPoint(
            Math.round(b.left + 2),
            Math.round(b.top + b.height / 2),
          );
          if (el && el.closest(".srcline") === r) painted += 1;
        }

        // THE END OF THE FILE, REACHED THE WAY A READER REACHES IT: drive the
        // pane's own scroll container to its end and hit-test the last row
        // there. A pane that renders every row into a container that cannot
        // scroll passes the count above and fails this.
        const src = panel?.querySelector(".src") ?? null;
        let lastPaintedAtEnd = false;
        const last = rows.length > 0 ? rows[rows.length - 1] : null;
        if (src && last) {
          src.scrollTop = src.scrollHeight;
          const b = last.getBoundingClientRect();
          const s = src.getBoundingClientRect();
          const inPort = b.top >= s.top - 1 && b.bottom <= s.bottom + 1;
          const el = document.elementFromPoint(
            Math.round(b.left + 2),
            Math.round(b.top + b.height / 2),
          );
          lastPaintedAtEnd = inPort && !!el && el.closest(".srcline") === last;
        }

        // …and back to the position, which is where the pane opened. Measured
        // after the scroll above rather than before it, so what is asserted is
        // that the position is REACHABLE and painted, not that it happened to
        // be the first thing drawn.
        const cur = panel?.querySelector(".srcline.cur") ?? null;
        let markedPainted = false;
        if (cur) {
          cur.scrollIntoView({ block: "center", inline: "nearest" });
          const b = cur.getBoundingClientRect();
          const el =
            b.width > 0 && b.height > 0
              ? document.elementFromPoint(
                  Math.round(b.left + 2),
                  Math.round(b.top + b.height / 2),
                )
              : null;
          markedPainted = !!el && el.closest(".srcline") === cur;
        }

        return {
          hasIsland: !!island,
          docCount: docs.length,
          activePath: active ? active.path : null,
          activeLines: active ? lineCount(active.text ?? "") : -1,
          tabLabel,
          panels: panels.length,
          rows: rows.length,
          painted,
          firstNumber: rows.length > 0 ? numberOf(rows[0]) : null,
          lastNumber: last ? numberOf(last) : null,
          lastPaintedAtEnd,
          markedNumber: cur ? numberOf(cur) : null,
          markedPainted,
          // Page-wide and not panel-wide: a banner on a hidden panel is still a
          // reduction this page claims to have made.
          banners: [...document.querySelectorAll(".srcfrom")].length,
          bannerText:
            document.querySelector(".srcfrom")?.textContent?.trim().slice(0, 120) ?? "",
        };
      });
      seen.push({ t, m });
    } finally {
      await v.page.close();
    }
  }

  // CONTROL, BEFORE ANY COMPARISON: the subjects publish files to compare
  // against. Every equality below is `rows === activeLines`, and `0 === 0` is
  // an equality — a corpus whose islands failed to parse would satisfy all of
  // them. The total is printed so the size of what was judged is on the record.
  const publishedLines = seen.reduce((n, s) => n + Math.max(0, s.m.activeLines), 0);
  j.atLeast(
    publishedLines,
    seen.length * 2,
    `CONTROL: lines of code the subject pages publish, read from their own source islands` +
      ` (${seen.length} pages)`,
  );

  // CONTROL, AND THE ONE THAT MAKES THIS JOURNEY DISCRIMINATE: at least one
  // subject is long enough, with its position far enough down, that the
  // six-line lead-in WOULD have cut it. Without this the whole run could pass
  // over short files that the removed behaviour never touched.
  const wouldHaveCut = seen
    .map((s) => ({
      s,
      cut: LEAD_IN_WOULD_HAVE_CUT(s.m.markedNumber ?? 0, s.m.activeLines),
    }))
    .filter((x) => x.cut > 0);
  const worst = wouldHaveCut.slice().sort((a, b) => b.cut - a.cut)[0];
  j.atLeast(
    wouldHaveCut.length,
    1,
    `CONTROL: subjects the six-line lead-in would have truncated` +
      (worst
        ? ` — worst is ${worst.s.t.debugPath}, where it would have removed ${worst.cut}` +
          ` of ${worst.s.m.activeLines} lines`
        : ""),
  );

  // 1. ONE ROW PER LINE OF THE FILE THE PAGE PUBLISHES. The assertion the
  //    banner cannot substitute for.
  const whole = seen.filter(
    (s) => s.m.activeLines > 0 && s.m.rows === s.m.activeLines && s.m.panels === 1,
  );
  j.countIs(
    whole.length,
    seen.length,
    `every Code pane holds one row per line of the file its page publishes` +
      (whole.length === seen.length
        ? ""
        : `; short: ${seen
            .filter((s) => !whole.includes(s))
            .map((s) => `${s.t.debugPath} (${s.m.rows} rows / ${s.m.activeLines} lines)`)
            .join("; ")}`),
  );

  // 2. …AND EVERY ONE OF THOSE ROWS IS PAINTED.
  const allPainted = seen.filter((s) => s.m.rows > 0 && s.m.painted === s.m.rows);
  j.countIs(
    allPainted.length,
    seen.length,
    `every row is painted where it says it is, hit-tested at its own coordinates` +
      (allPainted.length === seen.length
        ? ` (${seen.reduce((n, s) => n + s.m.painted, 0)} rows over ${seen.length} pages)`
        : `; unpainted: ${seen
            .filter((s) => !allPainted.includes(s))
            .map((s) => `${s.t.debugPath} (${s.m.painted}/${s.m.rows})`)
            .join("; ")}`),
  );

  // 3. THE END OF THE FILE IS REACHABLE. The reader's own gesture: scroll the
  //    pane to its end, and the file's last line is on screen there.
  const endReached = seen.filter(
    (s) => s.m.lastPaintedAtEnd && s.m.lastNumber !== null && s.m.rows === s.m.activeLines,
  );
  j.countIs(
    endReached.length,
    seen.length,
    `scrolling a Code pane to its end paints the file's last line` +
      (endReached.length === seen.length
        ? ""
        : `; not reached: ${seen
            .filter((s) => !endReached.includes(s))
            .map((s) => s.t.debugPath)
            .join(", ")}`),
  );

  // 4. NOTHING ANNOUNCES A REDUCTION, BECAUSE NONE IS MADE. Asserted AFTER the
  //    counts and never in place of them — see the header.
  const withBanner = seen.filter((s) => s.m.banners > 0);
  j.countIs(
    withBanner.length,
    0,
    `no Code pane announces a window onto the file` +
      (withBanner.length === 0
        ? ""
        : `; ${withBanner
            .map((s) => `${s.t.debugPath}: "${s.m.bannerText}"`)
            .join("; ")}`),
  );

  // 5. AND IT STILL OPENS ON THE POSITION. The whole file is the requirement;
  //    losing the position to get it would be the previous defect with the
  //    sign flipped. On this artefact two mechanisms can satisfy it — the
  //    position cell's `autofocus`, which needs no script, and
  //    `hydrate.scrollToCurrentLine` — and the claim is about the reader
  //    either way.
  //
  //    QUANTIFIED OVER THE PANES THAT MARK ONE, and the size of that set is
  //    asserted first. Not every subject has a served position: `/demo`'s
  //    capability tour publishes a program per capability whose containers the static
  //    export cannot replay, so those panes show the program's own source and
  //    report no position until hydration runs (AGENTS.md §1c, "the tour's
  //    known gap on the static route"). Demanding a mark there would be
  //    demanding the page claim a position it does not have — and quantifying
  //    over the set without counting it would let the whole assertion pass
  //    over nothing on the day the last served position went away.
  const positioned = seen.filter((s) => s.m.markedNumber !== null);
  j.atLeast(
    positioned.length,
    1,
    `CONTROL: subject panes that mark a position at all, out of ${seen.length}`,
  );
  const onPosition = positioned.filter((s) => s.m.markedPainted);
  j.countIs(
    onPosition.length,
    positioned.length,
    `every pane that marks a position paints that line, so it is still positioned` +
      (onPosition.length === positioned.length
        ? ""
        : `; missing: ${positioned
            .filter((s) => !onPosition.includes(s))
            .map((s) => s.t.debugPath)
            .join(", ")}`),
  );

  // 6. THE FILE STARTS WHERE THE FILE STARTS. The window's signature was a
  //    first row that was not the document's first row, and it is the one
  //    symptom a reader saw. Judged against the row numbering the page itself
  //    uses, which starts at 1 for source and at 0 for a listing, so this is
  //    "the first row is the first row" rather than a constant.
  const fromTheTop = seen.filter(
    (s) =>
      s.m.firstNumber !== null &&
      s.m.lastNumber !== null &&
      s.m.lastNumber - s.m.firstNumber + 1 === s.m.activeLines,
  );
  j.countIs(
    fromTheTop.length,
    seen.length,
    `the rows run unbroken from the file's first line to its last` +
      (fromTheTop.length === seen.length
        ? ""
        : `; broken: ${seen
            .filter((s) => !fromTheTop.includes(s))
            .map((s) => `${s.t.debugPath} (${s.m.firstNumber}..${s.m.lastNumber})`)
            .join("; ")}`),
  );

  // THE CROSS-CHECK IS ASSERTED, NOT NOTED.
  //
  // This block used to be a `j.note` per disagreement and nothing else, which is
  // the shape journey 07's header names: "every reading of it was printed as a
  // note and asserted by nothing". The declared-assertion count cannot see it —
  // notes are not records, so the count held whether the loop reported zero
  // disagreements or fifteen, and a run in which every pane's tab strip named a
  // different document from the one it was showing would have printed fifteen
  // lines of evidence above a green verdict.
  //
  // The reading exists for a stated reason (this file's header: so that "the
  // island's activeIndex" and "the document a visitor is looking at" are not
  // taken on trust from one another), and a reading taken for a reason is a
  // claim. `atLeast` first, because the two fields are read from different
  // places and a page that carried neither would otherwise agree vacuously.
  // THE COMPARISON IS A SUFFIX RELATION, AND IT USED TO BE EQUALITY.
  //
  // It was `s.m.tabLabel !== s.m.activePath`, which was right while a tab was
  // labelled with the whole path, and went stale the moment `tabLabel` in
  // `components/debugger.nim` started shortening a label to the shortest tail
  // of whole path segments that is still unique in the bundle — `avm.nr` where
  // that is unambiguous, `field/mod.nr` where a bundle holds two `mod.nr`. The
  // island keeps publishing the full interned path, as it must: a breakpoint
  // has to name the file to the engine exactly as the trace interned it.
  //
  // So this verdict has been RED on the mainline since that landed, over a
  // product that is behaving correctly — which is the expensive kind of red,
  // because a gate that cries wolf is the one people learn to scroll past.
  //
  // The claim itself is unchanged and is still worth making: the tab a pane
  // marks must NAME the document its island calls active. What changed is what
  // "names" means. A whole-segment suffix is exactly the relation `tabLabel`
  // produces, and it still fails on the thing this was written to catch — a
  // strip marking a different file from the one on screen — because a tail of
  // one path is not a tail of another. The boundary is checked on `/` rather
  // than by `endsWith` alone, so `shield.nr` does not satisfy `myshield.nr`.
  const namesTheSame = (label, path) => label === path || path.endsWith("/" + label);
  const withBoth = seen.filter((s) => s.m.tabLabel && s.m.activePath);
  const disagreeing = withBoth.filter((s) => !namesTheSame(s.m.tabLabel, s.m.activePath));
  for (const s of disagreeing) {
    j.note(
      `${s.t.debugPath}: the tab strip marks "${s.m.tabLabel}" and the island's active` +
        ` document is "${s.m.activePath}"`,
    );
  }
  j.atLeast(
    withBoth.length,
    1,
    "SUBJECTS: panes that name both the tab they mark and the document their island calls active",
  );
  j.countIs(
    disagreeing.length,
    0,
    "the tab a pane marks is the document its own source island calls active",
  );
}
