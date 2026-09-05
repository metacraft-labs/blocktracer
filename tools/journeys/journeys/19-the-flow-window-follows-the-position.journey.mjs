// "The flow window the engine answers with is the window for the position the
//  session is at."
//
// `Omniscience-Flow.md`. This is the second half of the user's report — "I
// expect it will track the current function (like in the desktop CodeTracer)" —
// and it is a SEPARATE sentence from the values-overlay journey's
// (`a-stepped-session-shows-the-values-recorded-on-its-lines`, numbered 18 today
// and 12 before the renumber in 415c20b) for the reason journeys 03 and 11 are
// separate: that one asks whether the recorded values reach the pane at all,
// and every assertion in it can be green while the window behind them never
// moves.
//
// WHAT IT ASSERTS NOW, AND WHY FOUR OF ITS ASSERTIONS WERE REPLACED
// ------------------------------------------------------------------
// `Omniscience-Flow.md` gained the section this journey had been guessing at —
// "What the flow window is a window over, and what its extent must mean" — and
// it settles, against this file, four of the ten records that used to stand
// here. The removals are recorded beside the assertions that replaced them,
// with the sentence that settled each; in summary:
//
//   * The window is over the ENCLOSING CALL, positioned at that call's ENTRY
//     step, and "`rrTicks == 0` on a flow update is a legitimate value … not an
//     unfilled field". So "every window's location is a position the session
//     actually asked about" was asking for codetracer #606 back — the defect
//     `e9242df3` removed when it restored full-call scope — and "computed for
//     more than one position" was reporting the length of this journey's own
//     walk, since a walk that never leaves a call correctly gets one window.
//   * "The window draws the entry line … suppressing it would make the product
//     hide something it recorded. A window whose extent looks wrong must be
//     fixed AT THE FIELD, never by narrowing what the overlay draws." So the
//     on-screen record now measures the overlay against the extent the window
//     DECLARED, rather than against a function range scraped off the page.
//
// WHAT REMAINS RED IS THE SPEC VERBATIM, AND THE CAUSE IS PROVEN
// --------------------------------------------------------------
// The requirement: "The declared extent is the source range of the function the
// window is over, and it contains every line the window draws. `functionFirst`
// is a 1-based source line, never `0` and never a sentinel."
//
// Measured on the staged engine (`pkg/db_backend_bg.wasm`
// 22acb8e1ccf2d7aa…, the pin in `client/hydrate/engine-pin.txt`): sixteen
// answers, every one of them `fn=main first=0 last=15` over a window drawing
// lines 1..37. Both halves fail, and they fail together.
//
// THE CAUSE IS IN THE ENGINE'S BUILD, NOT IN ITS SOURCE, which is why the fix
// that exists does not reach this. codetracer `f2ac6ed5d` re-derives the extent
// from tree-sitter and is on `cloud`; the staged wasm CARRIES it — its
// re-derivation is what calls `get_first_last_fn_lines`, and the engine's own
// log shows that call arriving from the flow path and answering `result -1 -1`
// every time. It answers `-1 -1` because `db-backend`'s `syntax-highlight`
// feature is OFF in a wasm build — `Cargo.toml`: "Disable for WASM builds where
// the C grammars cannot be cross-compiled" — so `ExprLoader::load_file` takes
// its `#[cfg(not(feature = "syntax-highlight"))]` arm, logs `loaded (no syntax
// highlighting)`, and never populates `FileInfo.functions`. `f2ac6ed5d`'s guard
// (`ts_first > 0`) then keeps the trace-record values, which for a Noir
// recording are `functionFirst = 0`.
//
// TWO CONSEQUENCES WORTH CARRYING FORWARD. The fix's own gate,
// `src/db-backend/tests/flow_window_extent_test.rs`, is a native test and
// cannot bite on the build this product loads. And the VFS key-spelling work
// the previous entry chased — writing both the bare and the joined path — is
// not what this is waiting on either: with `functions` empty, no key finds
// anything.
//
// WHY THE JOURNEY EXISTS RATHER THAN A NOTE
// -----------------------------------------
// Because the pane looks healthy. Journey 18 is GREEN: values are on screen,
// they carry real numbers, and they are on lines of the function the session is
// in. Every check short of this one passes over exactly the symptom that was
// reported.
//
// ONE LEG OF THAT ARGUMENT HAS SINCE BEEN REMOVED, and the removal is recorded
// beside the on-screen assertions below rather than papered over here. The leg
// was: "the set of values changes at every step, because the pane opens six
// lines above the position, so what a visitor SEES is a function of the position
// even when the window behind it is a constant." That cut is gone —
// `source_document.openAtCurrent` no longer exists and the pane renders the
// whole file — so it is no longer supplying the illusion of movement. What
// remains standing is the wire half: the engine's answer is a constant window,
// and no reading of the rendered page alone establishes that.
//
// `ledger.json` carries this journey with that reason, and the ledger fails in
// BOTH directions: whoever lands the fix is told, by name, to delete the entry.
// A note in a file would not have said anything the day it started working.

import { readFacts } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "the-flow-window-follows-the-position";
export const claim =
  "The flow window the engine answers with is the window for the position the session is at.";
export const spec =
  "Omniscience-Flow.md — the flow window's extent — BlockTracer";
export const assertions = 1 + 9; // 10
export const needsEngine = true;

const WALK = 8;

/**
 * Wrap the worker before the page's own scripts run.
 *
 * The verdict here is about what the ENGINE answered, which no pane publishes
 * and no pane could: a window computed for the wrong tick and a window computed
 * for the right one render identically whenever the session has not left the
 * function. So the answer is read off the wire rather than off the page — the
 * same instrument that separated "the request is never issued" from "the answer
 * is discarded" when this defect was first measured.
 *
 * Worker→main DAP traffic is a JSON *string* (`dap.rs` posts
 * `JsValue::from_str`); the worker's own bootstrap messages are objects. Both
 * shapes arrive on one port, so both are handled.
 */
const INSTRUMENT = `
window.__flowWire = { requested: [], answered: [] };
(function () {
  const Native = window.Worker;
  function note(bucket, raw) {
    let d = raw;
    if (typeof d === "string") { try { d = JSON.parse(d); } catch { return; } }
    if (!d || typeof d !== "object") return;
    const name = d.command || d.event || null;
    if (name !== "ct/load-flow" && name !== "ct/updated-flow") return;
    if (bucket === "requested") {
      const loc = (d.arguments && d.arguments.location) || {};
      window.__flowWire.requested.push({ rrTicks: loc.rrTicks, path: loc.path, line: loc.line });
    } else {
      const body = d.body || d.data || d;
      const loc = body.location || {};
      const view = (body.viewUpdates && body.viewUpdates[0]) || {};
      window.__flowWire.answered.push({
        rrTicks: loc.rrTicks,
        path: loc.path,
        functionName: loc.functionName,
        functionFirst: loc.functionFirst,
        functionLast: loc.functionLast,
        steps: (view.steps || []).length,
        lines: [...new Set((view.steps || []).map((s) => s.position))].sort((a, b) => a - b),
      });
    }
  }
  window.Worker = function (url, opts) {
    const w = new Native(url, opts);
    const post = w.postMessage.bind(w);
    w.postMessage = function (m, ...rest) { note("requested", m); return post(m, ...rest); };
    w.addEventListener("message", (e) => note("answered", e.data));
    return w;
  };
  window.Worker.prototype = Native.prototype;
})();
`;

/**
 * Accumulate the `fn` headers several readings saw, per document.
 *
 * A fact about the FILE and not about the session. Kept as an accumulation
 * rather than a single reading because it must stay correct whether or not the
 * pane cuts the file: it does not today (`a-source-file-is-shown-whole`), it did
 * until recently, and this journey's verdict must not depend on which.
 */
function mergeHeaders(into, facts) {
  for (const [doc, heads] of Object.entries(facts.fnHeaders ?? {})) {
    const seen = (into[doc] ??= new Map());
    for (const h of heads) if (h.n >= 0) seen.set(h.n, h.name);
  }
  for (const [doc, last] of Object.entries(facts.docLastLine ?? {})) {
    into.$last ??= {};
    into.$last[doc] = Math.max(into.$last[doc] ?? -1, last);
  }
  return into;
}

/** The function containing `line` in `doc`, or `null` when none does. */
function enclosing(headers, doc, line) {
  const heads = headers[doc];
  if (!heads || heads.size === 0 || !Number.isFinite(line) || line < 0) return null;
  const ns = [...heads.keys()].sort((a, b) => a - b);
  let open = null;
  for (const n of ns) if (n <= line && (open === null || n > open)) open = n;
  if (open === null) return null;
  const next = ns.find((n) => n > open);
  return {
    name: heads.get(open),
    first: open,
    last: next === undefined ? (headers.$last?.[doc] ?? open) : next - 1,
  };
}

const wire = (page) => page.evaluate(() => window.__flowWire);

async function stepAndSettle(page, action) {
  const before = await readFacts(page);
  await page.click(`[data-action="${action}"]`).catch(() => {});
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const now = await readFacts(page);
    if (now.step !== before.step) return now;
    await page.waitForTimeout(150);
  }
  return null;
}

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  // `hasRecordedValues` AND NOT `hasSource`, for the reason journey 18 records
  // at length and `corpus.mjs` documents under "the third category": a rung-2
  // chain capture displays source and records no values on it, sorts ahead of
  // every demo entry, and became `[0]` here. This journey asks where the flow
  // WINDOW is; a recording with no window at all cannot answer, and the red it
  // produced would not have been the red this journey's ledger entry describes.
  // An entry can only speak for the failure it was written about.
  const subjects = j.subjects(
    all.filter(
      (t) => landingOf(t.phase) === "session" && t.hasSource && t.hasRecordedValues,
    ),
    1,
    "the tree holds a session whose Code pane shows SOURCE with values recorded on it",
  );
  const tx = subjects[0];

  const ctx = await browser.newContext({ viewport: { width: 1920, height: 1080 } });
  await ctx.addInitScript(INSTRUMENT);
  const page = await ctx.newPage();
  await page.goto(site.origin + tx.debugPath, { waitUntil: "load", timeout: 60000 });
  for (let i = 0; i < 200 && (await readFacts(page)).phase !== "ready"; i++) {
    await page.waitForTimeout(250);
  }
  await page.waitForTimeout(2500);

  const readings = [];
  const headers = {};
  const note = async () => {
    const f = await readFacts(page);
    mergeHeaders(headers, f);
    readings.push({
      step: f.step,
      marked: Number(f.markedNumber),
      doc: f.shownDoc,
      labels: (f.flowLines ?? []).flatMap((r) => r.labels),
      lines: (f.flowLines ?? []).map((r) => r.n),
      text: (f.flowLines ?? []).map((r) => `${r.n}:${r.labels.join(",")}`).join(" | "),
    });
  };
  await note();
  // Both actions, because they leave a function by different routes and a
  // window that followed one and not the other would be a different defect.
  for (let i = 0; i < WALK; i++) {
    const moved = await stepAndSettle(page, i < WALK / 2 ? "step-forward" : "step-in");
    if (moved === null) break;
    await page.waitForTimeout(900);
    await note();
  }

  const w = await wire(page);

  // CONTROL, and it is the assertion that makes every verdict below a
  // measurement: the session really did move, and the requests really did carry
  // the moving tick. Without it, "the answer did not follow" would be true of a
  // session that never went anywhere.
  const askedTicks = new Set(w.requested.map((r) => String(r.rrTicks)));
  j.atLeast(
    askedTicks.size,
    3,
    "CONTROL: ct/load-flow was issued for several different positions",
  );

  // THE VERDICTS. Each is about what came back.
  const answers = w.answered.filter((a) => a.steps > 0);
  j.atLeast(answers.length, 3, "SUBJECTS: the engine answered with a window more than once");

  const answeredTicks = new Set(answers.map((a) => String(a.rrTicks)));

  // ── TWO ASSERTIONS WERE REMOVED HERE, AND THE SPEC IS WHY ─────────────────
  //
  // They read "the window the engine answers with is computed for more than one
  // position" and "every window's location is a position the session actually
  // asked about". Both were ledgered red for days, and `Omniscience-Flow.md`
  // now answers them in as many words, against them:
  //
  //   "In `Call` mode the window is a window over the ENCLOSING CALL,
  //    positioned at that call's ENTRY STEP … `rrTicks == 0` on a flow update
  //    is a legitimate value. It is the entry tick of the first call in the
  //    trace, not an unfilled field."
  //
  // So a window located at a tick nobody asked about is the contract, not a
  // passthrough — and a walk that never leaves the call it started in
  // correctly receives ONE window, which is what made the first of the two a
  // fact about the walk rather than about the product. The behaviour they
  // demanded is the one codetracer `e9242df3` REMOVED as #606 ("Flow in call
  // mode started at the current statement instead of the enclosing call entry
  // … the flow walk is forward-only, so the window shrank on every step"), so
  // between them they asked for a fixed defect to be restored.
  //
  // What replaces them is §10.6's own reading, which is the sentence they were
  // reaching for: "assert that the function the flow display is annotating is
  // the function the session reports being in — an equality between two page
  // readings, with no function named". Read here as an equality between the
  // WIRE's answer and the PAGE's, which is stronger in the one direction that
  // matters: a pane that pinned its overlay to the function it opened on would
  // satisfy any page-only reading of it.
  const windowFns = new Set(answers.map((a) => a.functionName).filter(Boolean));
  const framedEarly = readings
    .filter((r) => r.labels.length > 0)
    .map((r) => enclosing(headers, r.doc, r.marked))
    .filter((f) => f !== null)
    .map((f) => f.name);
  const sessionFns = new Set(framedEarly);
  j.countIs(
    [...windowFns].filter((n) => !sessionFns.has(n)).length,
    0,
    "every window the engine answered with is over a function the session reported being in",
    `windows over {${[...windowFns].join(", ")}}; session reported being in {${[...sessionFns].join(", ")}}`,
  );

  // ── AND THE ONE THAT STAYS, BECAUSE IT IS THE SPEC VERBATIM ───────────────
  //
  // `Omniscience-Flow.md`: "The declared extent is the source range of the
  // function the window is over, and it contains every line the window draws.
  // `functionFirst` is a 1-based source line, never `0` and never a sentinel."
  //
  // Two halves, and this journey asserts both — the field, then the
  // containment, because the containment "is what makes the field checkable at
  // all. Without it, an extent that describes neither the function nor the
  // window's own contents is indistinguishable from an unfilled field — and
  // beside a legitimate `rrTicks == 0` it reads as one." Which is exactly the
  // reading that cost this journey two wrong causes.
  j.countIs(
    answers.filter((a) => (a.functionFirst ?? 0) <= 0).length,
    0,
    "the reported function extent is a real one and not an uninitialised location",
    answers
      .slice(0, 3)
      .map((a) => `${a.functionName} declared ${a.functionFirst}..${a.functionLast}`)
      .join(" | "),
  );
  j.countIs(
    answers.filter((a) =>
      a.lines.some((n) => n < a.functionFirst || n > a.functionLast),
    ).length,
    0,
    "the extent a window declares contains every line that window draws",
    answers
      .slice(0, 3)
      .map(
        (a) =>
          `declared ${a.functionFirst}..${a.functionLast}, draws ` +
          `${a.lines[0]}..${a.lines[a.lines.length - 1]}`,
      )
      .join(" | "),
  );

  // ── AND THE HALF A VISITOR CAN SEE ──────────────────────────────────────
  //
  // The same defect, read off the page rather than off the wire, because that
  // is the form it was reported in. Both are here rather than in journey 18
  // because they close on the same fix: a window computed for the position
  // would move with it and would carry that position's function.
  //
  // They lived in the values-overlay journey briefly and were GREEN, and the reason is the
  // trap this whole layer keeps finding. The pane used to open six lines above
  // the position, so the SET OF LABELS ON SCREEN changed at every step even
  // though the window behind it never did, and the labels that fell outside
  // the function were exactly the ones the cut removed. When
  // `a-source-file-is-shown-whole` landed, both went red — with nothing about
  // the overlay having changed. The cut had been supplying the evidence.
  const screen = readings.filter((r) => r.labels.length > 0);
  j.atLeast(screen.length, 3, "SUBJECTS: positions with an overlay on screen");

  // THE OVERLAY IS REDRAWN EXACTLY AS OFTEN AS THE WINDOW BEHIND IT CHANGED —
  // and this replaces "ON SCREEN: the overlay changes as the position moves",
  // which was red for the same reason its wire twin above was: the window is
  // over the enclosing CALL, so a walk that stays inside one call correctly
  // sees one overlay, and a journey that demanded two was reporting the length
  // of its own walk. An equality against the wire keeps the claim — a pane
  // pinned to the function it opened on fails it — without asserting that a
  // correct product must have moved.
  j.countIs(
    new Set(screen.map((r) => r.text)).size,
    answeredTicks.size,
    "ON SCREEN: the overlay is redrawn exactly as often as the engine answered with a different window",
  );

  const framed = screen
    .map((r) => ({ ...r, fn: enclosing(headers, r.doc, r.marked) }))
    .filter((r) => r.fn !== null);
  // THE SUBJECT COUNT, WHICH MATTERS MOST ON THE DAY THIS JOURNEY'S FIX LANDS.
  //
  // `filter((r) => r.fn !== null)` drops every reading whose enclosing function
  // could not be resolved, and the assertion below then quantifies over what is
  // left — so a state in which NO function resolves anywhere is `countIs(0, 0)`,
  // a pass. That is not a remote hypothetical here: the ledgered defect this
  // journey exists for is the engine reporting `functionFirst=0` for `main`,
  // whose body begins on line 12, and the shape of a bad fix is exactly one that
  // stops resolving rather than one that resolves correctly.
  //
  // While the ledger entry stands this record is red and the vacuity is masked
  // by a failure. When the fix lands it goes green, and this is the assertion
  // that decides whether it went green for the right reason. Measured today:
  // eight readings resolve their function, and all eight violate the extent.
  j.atLeast(
    framed.length,
    3,
    "SUBJECTS: readings whose enclosing function could be resolved at all",
  );
  // THE SCREEN HALF OF THE EXTENT SENTENCE, and it is a separate record from
  // the wire half above rather than a restatement of it: the wire's half counts
  // the positions the ANSWER carried, this one counts the lines the PANE drew,
  // and a pane that drew a subset would satisfy one and not the other. Both are
  // "the declared extent contains every line the window draws".
  //
  // It replaces "every annotated line lies inside the function the session is
  // in", measured against a function range scraped off the page. That reading
  // is the one `Omniscience-Flow.md` forbids taking as a verdict on the
  // overlay: "The window draws the entry line. That line is a step the
  // recording holds values for; suppressing it would make the product hide
  // something it recorded. A window whose extent looks wrong must be fixed AT
  // THE FIELD, never by narrowing what the overlay draws." So the extent is the
  // subject and the overlay is the witness, which is the way round the spec
  // puts them — and the page-scraped range is kept only as the transcript's
  // second opinion.
  const declared = answers[answers.length - 1];
  j.countIs(
    framed.filter((r) =>
      r.lines.some((n) => n < declared.functionFirst || n > declared.functionLast),
    ).length,
    0,
    "ON SCREEN: every annotated line lies inside the extent the window declared",
    `declared ${declared.functionFirst}..${declared.functionLast}; ` +
      `the page reads the enclosing function as ` +
      framed
        .slice(0, 2)
        .map((r) => `${r.fn.name} ${r.fn.first}..${r.fn.last}`)
        .join(" / "),
  );

  await ctx.close();
}
