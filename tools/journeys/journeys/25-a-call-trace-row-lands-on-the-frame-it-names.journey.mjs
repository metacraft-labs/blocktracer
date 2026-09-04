/**
 * A reader clicks a row in the Call Trace, and the session goes to THAT frame.
 *
 * ## The claim, and why it needed its own journey
 *
 * Journey 09 already asserts that a call-trace click moves the position and
 * that "the session's reported step is the step the call-trace row named". Both
 * are true and neither is this claim, because a step does not name a frame.
 *
 * On the transaction this repository publishes, forty-six frames carry
 * twenty-two distinct steps. Six of them —
 *
 *     Map<K, V, Context>::at          map.nr:36
 *     derive_storage_slot_in_map      map.nr:11
 *     poseidon2_hash_with_separator   hash.nr:221
 *     poseidon2_hash                  hash.nr:212
 *     Poseidon2::hash                 poseidon2.nr:16
 *     Poseidon2::hash_internal        poseidon2.nr:68
 *
 * are all open at the same step, because a call that immediately calls another
 * records no step in between. Journey 09's assertion is satisfied by clicking
 * any of the six and landing on any of the six: they all name the same step, so
 * "the reported step is the step the row named" is green whichever frame the
 * session actually went to, and green when it went to none of them.
 *
 * That is the hole. This journey asserts the thing the coordinate cannot: that
 * the row the reader clicked is the row that comes back MARKED, and that six
 * rows sharing one coordinate land on six different places.
 *
 * ## Why the subject is chosen by collision and not by name
 *
 * The recording with the collision is the one that can judge this; a recording
 * without one cannot, because on it the coordinate and the frame identify the
 * same row and a product keyed on either passes. The synthetic demo corpus is
 * exactly that shape — its frames carry distinct steps — which is why the
 * corpus that runs most often never caught any of this. So the subject is
 * selected by measuring the live pane for a shared coordinate, and the
 * measurement is asserted (`SUBJECTS:` below) rather than assumed: a corpus
 * that lost its colliding recording must turn this journey RED, because the
 * journey can no longer judge its own claim.
 *
 * ## What is deliberately not asserted
 *
 * Not the coordinate's VALUE, and not that the tick moves. Six frames sharing a
 * step means a click between two of them legitimately moves the session
 * nowhere in TIME — the stack is what changed, not the clock. Asserting a tick
 * change here would be asserting that a correct product is broken. What is
 * asserted is the frame: which row is marked, and which position the panes are
 * showing.
 *
 * spec: Debugger-Integration.md §3, §6.0a — a row is a jump target, and the
 * anchor is what identifies the frame it targets.
 */

import { visit, consoleMark, waitForConsoleLine, POSITION_ANSWERED } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-call-trace-row-lands-on-the-frame-it-names";
export const claim =
  "A reader who clicks a call-trace row lands on the frame that row names, and that row is the one marked — even where several frames share a coordinate.";
export const spec = "Debugger-Integration.md §3, §6.0a — BlockTracer";
export const needsEngine = true;
export const assertions = 11;

/** Every live call-trace row, with the two identities it carries. */
const readRows = (page) =>
  page.evaluate(() => {
    const rows = [...document.querySelectorAll(".ctview.def .ctrow")];
    return rows.map((r, i) => ({
      i,
      step: r.getAttribute("data-step"),
      anchor: r.getAttribute("data-anchor"),
      name: r.querySelector(".ctname")?.textContent ?? null,
      current: r.classList.contains("cur"),
      // WHOSE ROW IS THIS. The live producer gives every frame an `href`, which
      // `renderCallTrace` draws as an `<a>`; the static export leaves it empty
      // and draws a `<div>` (`CallFrame.href` — "Empty on every statically
      // exported page and non-empty only in a hydrated one"). So the tag name
      // is the producer, and the CONTROL below reads it.
      live: r.tagName === "A",
    }));
  });

/** What the page says it is showing, after a gesture has settled. */
const readMarked = (page) =>
  page.evaluate(() => {
    const cur = document.querySelector(".ctview.def .ctrow.cur");
    const src = document.querySelector(".srcline.cur");
    const doc = src?.closest(".srcdoc");
    return {
      curAnchor: cur?.getAttribute("data-anchor") ?? null,
      curName: cur?.querySelector(".ctname")?.textContent ?? null,
      curCount: document.querySelectorAll(".ctview.def .ctrow.cur").length,
      // THE POSITION AS THE MARKED ROW STATES IT. Read off the row and not out
      // of the Code pane, because these frames are library code — poseidon2 and
      // the Noir stdlib — and a transaction publishes the CONTRACT's sources,
      // not nargo's. The Code pane may legitimately have no document for
      // `poseidon2.nr` to show, and asserting on it would make the journey red
      // for a source-availability reason that is not this claim. The row's own
      // `data-module` and line are what the product states about where it
      // landed, and they exist on every row at every rung.
      curModule: cur?.getAttribute("data-module") ?? null,
      curLine: cur?.querySelector(".ctline")?.textContent?.trim() ?? null,
      // Carried for the transcript only. Where the sources ARE published this
      // says so, and where they are not a reader can see that is why.
      srcLine: src?.querySelector(".n")?.textContent?.trim() ?? null,
      srcDoc: doc?.getAttribute("data-path") ?? doc?.id ?? null,
    };
  });

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const withSession = all.filter(
    (t) => landingOf(t.phase) === "session" && t.calltraceFrames > 2,
  );
  j.subjects(withSession, 1, "sessions whose Call Trace paints more than the two AVM-context frames");

  // THE SUBJECT IS THE ONE THAT CAN JUDGE THE CLAIM, found by measuring.
  // Opened, its live pane read, and kept only if its coordinates really do
  // collide. No `?? list[0]`: a corpus with no colliding recording leaves
  // `subject` null and the assertion below goes red, which is honest — the
  // claim is unjudgeable on such a corpus, not satisfied by it.
  let subject = null;
  let page = null;
  let live = null;
  let group = [];

  // RICHEST FIRST, AND BOUNDED. Opening a session costs an 18 MB engine and a
  // real replay, so this must not walk the corpus: a collision needs a deep
  // tree, the served frame count is already on every transaction, and four is
  // well past the one recording in the published corpus that has forty-six
  // frames. A corpus that grew a second deep recording would still be reached;
  // one that lost the deep recording fails the assertion below rather than
  // spending twenty sessions discovering it.
  const candidates = [...withSession]
    .sort((a, b) => b.calltraceFrames - a.calltraceFrames)
    .slice(0, 4);

  for (const candidate of candidates) {
    const opened = await visit(browser, site.origin, candidate.debugPath, {
      settle: (f) => f.phase === "ready" && f.controlsLive > 0,
    });
    const rows = opened.settled ? await readRows(opened.page) : [];
    const byStep = new Map();
    for (const r of rows) {
      if (!byStep.has(r.step)) byStep.set(r.step, []);
      byStep.get(r.step).push(r);
    }
    const biggest = [...byStep.values()].sort((a, b) => b.length - a.length)[0] ?? [];
    if (biggest.length > 1) {
      subject = candidate;
      live = opened;
      page = opened.page;
      group = biggest;
      break;
    }
    await opened.page.close();
  }

  j.expect(
    subject !== null,
    "SUBJECTS: a live session whose Call Trace gives two or more frames the SAME coordinate",
    subject
      ? `${subject.chain}/${subject.hash} — ${group.length} rows share step ${group[0].step}`
      : "no session in the corpus paints two frames at one coordinate; the claim cannot be judged here",
  );
  if (!subject) return;

  try {
    j.note(`driving ${subject.debugPath}; ${group.length} rows share step ${group[0].step}`);

    // THE CONTROL, AND IT COMES FIRST SO A FAILURE NAMES THE RIGHT THING.
    //
    // Everything below judges what a click does to the LIVE pane. If the live
    // pane never painted, the rows under the cursor are the static export's,
    // every assertion below fails, and the reading "the anchor is not being
    // honoured" would be wrong — the anchor never got the chance. Journey 09
    // makes the same check for the same reason, and its subject is a small
    // capture where it passes.
    //
    // Measured on 2026-09-04 against this deep capture: it FAILS, and the cause
    // is not the call trace. `renderSource` overflows the JavaScript stack on
    // this transaction's 4 MB source document — Nim-JS builds a string as a
    // char-code array and joins it, which does not scale to a document this
    // size — and it throws out of `renderPanes` BEFORE the call-trace pane is
    // written. So the served rows stand, no live row is ever marked, and seven
    // `Maximum call stack size exceeded` errors are on the page. That is a
    // separate defect in a separate pane, it is present on unmodified `dev`,
    // and it blocks this claim from being judged on the only capture in the
    // corpus that can judge it.
    const anchorRows = (await readRows(page)).filter((r) => r.live).length;
    j.expect(
      anchorRows > 0,
      "CONTROL: the Call Trace rows are the engine's, not the export's",
      `${anchorRows} of ${group.length ? (await readRows(page)).length : 0} rows are live links;` +
        " 0 means renderPanes never wrote this pane and nothing below judges a live session",
    );

    // THE PREMISE, COUNTED. The collision is what makes the coordinate
    // insufficient, and a subject that quietly stopped colliding would leave
    // every assertion below green while measuring nothing.
    j.atLeast(
      group.length,
      2,
      "the subject really is a case a coordinate cannot decide: several frames, one step",
    );
    j.countIs(
      new Set(group.map((r) => r.anchor)).size,
      group.length,
      "those same rows carry one DISTINCT anchor each, so an identity for them exists",
    );

    // OPEN THE FOLDS FIRST. The deepest of these frames is inside a subtree the
    // pane starts CLOSED — poseidon2, by the `vendored-crate` fold rule — so it
    // is in the DOM and not on screen, and a click on it times out. A reader
    // reaches it by opening the triangle, and this is that gesture.
    //
    // `open = true` rather than clicking the `<summary>`: a folded row IS the
    // summary, so clicking it would both toggle the disclosure and count as
    // choosing that frame, and the journey would be unable to say which of the
    // two the mark came from.
    const folds = await page.evaluate(() => {
      const d = [...document.querySelectorAll(".ctview.def details.ctfold")];
      d.forEach((e) => (e.open = true));
      return d.length;
    });
    j.note(`opened ${folds} folded subtree(s) so every one of the six is on screen`);

    const landings = [];
    for (const target of group) {
      await page.evaluate(
        (i) => document.querySelectorAll(".ctview.def .ctrow")[i].scrollIntoView({ block: "center" }),
        target.i,
      );
      const mark = consoleMark(page);
      await page.click(`.ctview.def .ctrow >> nth=${target.i}`);
      // The engine answers every gesture with a position line whether or not
      // anything moved — which is exactly the case here, since these rows share
      // a tick. Waiting on a DOM change instead would time out on a correct
      // product. See journey 09's `jump` for the same reasoning.
      await waitForConsoleLine(page, POSITION_ANSWERED, { sinceIndex: mark, budgetMs: 15000 });
      await page.waitForTimeout(600);
      landings.push({ target, got: await readMarked(page) });
    }

    j.countIs(
      landings.filter((l) => l.got.curCount === 1).length,
      group.length,
      "after each click exactly one call-trace row carries the position mark",
    );
    j.countIs(
      landings.filter((l) => l.got.curAnchor === l.target.anchor).length,
      group.length,
      "the row that is marked is the row that was clicked",
      landings
        .map((l) => `${l.target.name}->${l.got.curName ?? "(none marked)"}`)
        .join(", "),
    );
    j.countIs(
      landings.filter((l) => l.got.curName === l.target.name).length,
      group.length,
      "the marked row names the function the reader chose",
    );
    j.countIs(
      new Set(landings.map((l) => l.got.curAnchor)).size,
      group.length,
      "clicking each of them marks a DIFFERENT frame, not the same one every time",
    );
    j.countIs(
      new Set(landings.map((l) => `${l.got.curModule}:${l.got.curLine}`)).size,
      group.length,
      "…and each of those frames states a DIFFERENT source position",
      landings.map((l) => `${l.target.name}@${l.got.curModule}:${l.got.curLine}`).join(", "),
    );
    j.expect(
      landings.every((l) => l.got.curModule),
      "every one of those landings names the file its frame is in",
      landings
        .map((l) => `${l.got.curModule}:${l.got.curLine} (code pane: ${l.got.srcDoc}:${l.got.srcLine})`)
        .join(", "),
    );
  } finally {
    await page.close();
  }
}
