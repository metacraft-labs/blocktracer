// The six questions "is the session showing its position?" decomposes into,
// asked of ONE frame.
//
// It lives here rather than in either journey because journeys 02 and 06 must
// ask the SAME questions of two different frames — the one the server sent and
// the one the hydration bundle left behind — and the whole value of 06's red is
// that 02's green was produced by this code, over that page, moments earlier.
// Two hand-written copies would let the two drift, and the difference between
// them would then be a fact about the harness rather than about the product.

export const FRAME_ASSERTIONS = 6;

export function judgeFrame(j, arm, facts) {
  j.atLeast(facts.srclinesShown, 1, `${arm}: the source pane has lines on screen`);

  // Exactly one file is open. "The debugger opened on the package manifest" is
  // a claim about this, and so is a pane that opened on all four at once —
  // which is what an unguarded re-render produces, and what `srctab.on` on
  // every tab looks like from the outside.
  j.countIs(facts.docsShown, 1, `${arm}: exactly one file is on screen`);

  j.countIs(facts.marked, 1, `${arm}: exactly one line carries the position mark`);
  j.expect(facts.markedShown, `${arm}: the marked line is on screen, not merely in the DOM`);

  // THE RELATION THAT WOULD HAVE CAUGHT THE `Nargo.toml` DEFECT. The file being
  // shown must be the file the position is in. Neither is named here; both are
  // read off the page, so a session that opened on the wrong file fails even
  // though every file it could have opened is present in the markup.
  j.expect(
    facts.markedDoc !== null && facts.markedDoc === facts.shownDoc,
    `${arm}: the file on screen is the file the position is in`,
    `showing ${facts.shownDocLabel ?? facts.shownDoc}, position is in ${facts.markedDoc}`,
  );

  j.expect(
    (facts.markedText ?? "").trim().length > 0,
    `${arm}: the marked line has source on it`,
    `line ${facts.markedNumber} reads ${JSON.stringify(facts.markedText)}`,
  );
}
