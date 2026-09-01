// "A visitor who opens a transaction the chain publishes no source for still
//  sees the code that ran — as the instructions the recording carries, with the
//  one it is stopped at marked."
//
// Page-Descriptions.md §14's fidelity ladder, and §7.0's promise of "the
// debugging interface" for `ready`/`divergent` without a promise of source text.
//
// THE DEFECT THIS IS FILED AGAINST
// -------------------------------
// The Code pane on a real chain transaction rendered PROSE AND NOTHING ELSE. It
// said, correctly, that the recording is at instruction level and that "every
// step is a program counter" — and then rendered no program counters. The
// recording has hundreds of steps, each carrying one, and the pane whose whole
// question is "where is this stopped" had nothing on screen to be stopped at.
//
// That is not a styling gap. It is a pane describing its own contents instead of
// showing them, on every transaction this site publishes from a real chain.
//
// WHAT THIS ASSERTS THAT NO OTHER LAYER DOES
// -----------------------------------------
// Journey 05 asks whether a positioned session SAYS where it is; it is satisfied
// by a sentence. This asks whether the pane SHOWS the coordinates it claims to
// have — rendered, visible, and related to the step the page publishes — which
// is the difference between describing an instruction listing and rendering one.
//
// Everything is read as a RELATION between two things the page reports: the
// marked row's gutter number against the session's own `data-step`, the row
// count against `data-total-steps`. No fixture is named and no number is
// written here, because the defect that seeded this layer survived 115 cases
// whose fixture supplied the position they asserted back.

import { visit, readFacts } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-recording-with-no-source-still-shows-its-instructions";
export const claim =
  "A visitor who opens a transaction the chain publishes no source for still sees the code that ran — as the instructions the recording carries, with the one it is stopped at marked.";
export const spec = "Page-Descriptions.md §7.0, §14 — BlockTracer";
export const assertions = 13;
export const needsEngine = true;

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const sessions = all.filter((t) => landingOf(t.phase) === "session");
  // The subject set is "a session with no source", read off the markup. A
  // corpus in which every contract's artifact resolved would fail HERE, by
  // name, rather than reporting a green run over an empty loop — and that is
  // the right failure, because it means this journey has become untestable and
  // somebody has to say so out loud.
  const noSource = sessions.filter((t) => !t.hasSource);
  j.subjects(noSource, 1, "sessions the chain publishes no source for");

  // …and the other half of the coexistence rule. A build that hard-coded "chain
  // data never has source" would satisfy every assertion below and would be
  // exactly the assumption being corrected.
  j.atLeast(
    sessions.filter((t) => t.hasSource).length,
    1,
    "some session DOES resolve to source, so the listing has not replaced it",
  );

  const seen = [];
  for (const t of noSource) {
    const v = await visit(browser, site.origin, t.debugPath);
    try {
      const pane = await v.page.evaluate(() => {
        const shown = (e) =>
          !!e &&
          typeof e.checkVisibility === "function" &&
          e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
        const rows = [...document.querySelectorAll(".src.instr .srcline")].filter(shown);
        const cur = document.querySelector(".src.instr .srcline.cur");
        const caption = document.querySelector(".instrcap");
        const reason = document.querySelector(".srcnone .panenote");
        return {
          rowsShown: rows.length,
          // The rows' own text, so "shows a program counter" is judged on what
          // is painted rather than on a class being present.
          rowTexts: rows.slice(0, 400).map((r) => r.querySelector(".t")?.textContent ?? ""),
          markedShown: shown(cur),
          markedNumber: cur?.querySelector(".n")?.textContent?.trim() ?? null,
          markedText: cur?.querySelector(".t")?.textContent ?? "",
          // The position glyph has a cell of its own; a branch mark must never
          // be able to take it, which is what `.m` holding a `▶` would mean.
          markedPositionGlyph: cur?.querySelector(".p")?.textContent?.trim() ?? "",
          markerCellHasPosition: (cur?.querySelector(".m")?.textContent ?? "").includes("▶"),
          captionShown: shown(caption),
          captionText: shown(caption) ? (caption.innerText ?? "").trim() : "",
          reasonShown: shown(reason),
          reasonText: shown(reason) ? (reason.innerText ?? "").trim() : "",
        };
      });
      seen.push({ t, facts: v.facts, pane });
    } finally {
      await v.page.close();
    }
  }

  // 1. THE ROWS ARE THERE, AND THEY ARE RENDERED. `checkVisibility`, not a
  //    selector count: the pane holds documents it hides with CSS, and a
  //    listing nobody can see is the defect with extra markup.
  const withRows = seen.filter((s) => s.pane.rowsShown > 0);
  j.countIs(
    withRows.length,
    seen.length,
    `every session with no source renders instruction rows` +
      (withRows.length === seen.length
        ? ""
        : `; empty: ${seen
            .filter((s) => s.pane.rowsShown === 0)
            .map((s) => s.t.txPath)
            .join(", ")}`),
  );

  // 2. THE ROWS CARRY PROGRAM COUNTERS. The pane's own sentence is that every
  //    step is one; this is the assertion that the sentence is now describing
  //    what is on screen. An address per row, in every row.
  const allRowsAddressed = seen.filter((s) =>
    s.pane.rowTexts.length > 0 && s.pane.rowTexts.every((t) => /^\s*0x[0-9a-f]+\s/.test(t)),
  );
  j.countIs(
    allRowsAddressed.length,
    seen.length,
    "every rendered row opens with the program counter it is at",
  );

  // 3. EXACTLY ONE ROW IS MARKED, AND IT IS RENDERED.
  const marked = seen.filter((s) => s.facts.marked === 1 && s.pane.markedShown);
  j.countIs(
    marked.length,
    seen.length,
    `every session marks exactly one instruction${
      marked.length === seen.length
        ? ""
        : `; wrong: ${seen
            .filter((s) => !marked.includes(s))
            .map((s) => `${s.t.txPath} (marked=${s.facts.marked}, shown=${s.pane.markedShown})`)
            .join("; ")}`
    }`,
  );

  // 4. AND IT IS THE STEP THE PAGE ITSELF PUBLISHES. A relation between two
  //    things the page reports, so a renderer that marked a fixed row would
  //    fail on every subject whose step is not that row.
  const agrees = seen.filter(
    (s) => s.pane.markedNumber !== null && s.pane.markedNumber === String(s.facts.step),
  );
  j.countIs(
    agrees.length,
    seen.length,
    `the marked instruction is the step the session reports` +
      (agrees.length === seen.length
        ? ""
        : `; disagreeing: ${seen
            .filter((s) => !agrees.includes(s))
            .map((s) => `${s.t.txPath} (row ${s.pane.markedNumber} vs step ${s.facts.step})`)
            .join("; ")}`),
  );

  // 5. THE POSITION GLYPH IS IN ITS OWN CELL. A sibling moved `▶` out of the
  //    marker cell because CSS was resolving the collision by hiding it — on
  //    the current row, which is the row whose glyph matters most. A listing
  //    that put it back would look exactly like a listing with no marker.
  const glyphPlaced = seen.filter(
    (s) => s.pane.markedPositionGlyph === "▶" && !s.pane.markerCellHasPosition,
  );
  j.countIs(
    glyphPlaced.length,
    seen.length,
    "the position glyph is in the position cell and not in the branch cell",
  );

  // 6. THE COLUMNS ARE NAMED. Three columns of hex and integers with no header
  //    is a grid a reader has to guess at, and the caption is also where the
  //    OBJECT the counters index is stated — the fact that separates "this
  //    listing is unpositioned" from "this listing is unlabelled".
  const captioned = seen.filter(
    (s) =>
      s.pane.captionShown &&
      /program counter/.test(s.pane.captionText) &&
      /recorded steps/.test(s.pane.captionText),
  );
  j.countIs(
    captioned.length,
    seen.length,
    "the listing names its columns and what its counters are offsets into",
  );

  // 7. THE PROSE IS STILL THERE, BESIDE THE ROWS RATHER THAN INSTEAD OF THEM.
  //    A reader deserves to know why there is no source; what they may not be
  //    given is the explanation as the whole pane.
  const explained = seen.filter(
    (s) => s.pane.reasonShown && s.pane.reasonText.length > 0 && s.pane.rowsShown > 0,
  );
  j.countIs(
    explained.length,
    seen.length,
    "the reason there is no source is shown beside the listing, not instead of it",
  );

  // 8. AND IT NO LONGER CLAIMS THE CHAIN CAN NEVER HAVE SOURCE. The retired
  //    sentence is scoped to the on-chain class object and reads as a claim
  //    about availability, which is false — `artifactHash` exists so a client
  //    can verify an artifact fetched off-chain, and verified artifacts
  //    resolve. Asserted on RENDERED text, on the page a visitor loads.
  const honest = seen.filter(
    (s) => !/no debug symbols, no file map and no source text/.test(s.pane.reasonText),
  );
  j.countIs(
    honest.length,
    seen.length,
    "no page tells a reader the chain publishes no source for any contract",
  );

  // 9. AND IT STEPS. Everything above is the SERVED frame, which is the artefact
  //    the capture harness photographs; the one a visitor loads runs the
  //    hydration bundle, and this route is where the two builds diverge. A
  //    listing that survived the served frame and vanished on the first stop
  //    would satisfy every count above and be broken for everyone.
  //
  //    Journey 03 already asserts that stepping moves the position — on a
  //    SYNTHETIC subject, because it takes the first non-real session it finds.
  //    The instruction path is a different join: the source pane resolves a stop
  //    by file and line, and a listing has neither, so it is joined on the tick
  //    instead. That join has never had a subject in this layer.
  const driven = noSource[0];
  j.note(`stepping ${driven.debugPath}`);
  const live = await visit(browser, site.origin, driven.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  try {
    j.expect(
      live.settled && !live.timedOut,
      "an instruction-level session goes live, so there is something to step",
      `phase=${live.facts.phase} live=${live.facts.controlsLive} rows=${live.facts.srclines}`,
    );

    // THE LANDING FRAME MARKS A ROW. The engine lands at its own head, and a
    // hydrated pane that marked nothing there would render less than the page it
    // replaced — which §7.0 forbids, and which is what happens if the engine's
    // zero-based tick is used as a step ordinal without conversion.
    const before = live.facts;
    j.countIs(
      before.marked,
      1,
      `the live session marks one instruction on landing (row ${before.markedNumber}: ${
        (before.markedText ?? "").trim()
      })`,
    );

    await live.page.click('[data-action="step-forward"]');
    // A predicate, never a sleep — journey 03's rule, for its reason: a step
    // that moves nothing must time out with what it saw, not lose a race.
    const deadline = Date.now() + 15000;
    let after = before;
    while (Date.now() < deadline) {
      after = await readFacts(live.page);
      if (after.step !== before.step || after.markedNumber !== before.markedNumber) break;
      await live.page.waitForTimeout(200);
    }
    j.expect(
      after.markedNumber !== null && after.markedNumber !== before.markedNumber,
      "a step moves the mark to the next instruction",
      `row ${before.markedNumber} "${(before.markedText ?? "").trim()}" -> row ${
        after.markedNumber
      } "${(after.markedText ?? "").trim()}"`,
    );
  } finally {
    await live.page.close();
  }

  j.note(
    seen
      .map(
        (s) =>
          `${s.t.txPath}: ${s.pane.rowsShown} rows shown of ${s.facts.totalSteps} steps, ` +
          `marked ${s.pane.markedNumber} = "${s.pane.markedText.trim()}"`,
      )
      .join(" | "),
  );
}
