// "The flow window the engine answers with is the window for the position the
//  session is at."
//
// `Omniscience-Flow.md`. This is the second half of the user's report — "I
// expect it will track the current function (like in the desktop CodeTracer)" —
// and it is a SEPARATE sentence from journey 12's for the reason journeys 03 and
// 11 are separate: 12 asks whether the recorded values reach the pane at all,
// and every assertion in it can be green while the window behind them never
// moves.
//
// IT IS RED, AND THE CAUSE IS NAMED
// ---------------------------------
// Measured on `dev`, over the built site with the published engine staged, with
// `Worker.postMessage` and the worker's message handler wrapped before the
// page's own scripts ran. Eleven positions were driven — four `step-forward`
// and six `step-in`, reaching ticks 0, 1, 5, 8, 671, 672, 673, 674, 675, 676,
// 677 — and every `ct/load-flow` carried the tick it was issued for. The engine
// answered all eleven with ONE window:
//
//     location.path          .../noir_space_ship/src/main.nr   (every time)
//     location.rrTicks       0                                 (every time)
//     location.functionName  "main"
//     location.functionFirst 0        — `main`'s body is lines 12..38
//     location.functionLast  15
//     steps                  14, on lines 1,12,13,15,17,23,24,25,27,32,35,36,37
//
// `rrTicks: 0` for a request issued at tick 677, and a function extent of 0..15
// for a function that begins on line 12, are the same defect twice: the
// engine's `find_function_location` (`expr_loader.rs`) is gated on
// `processed_files.contains_key(&location.path)`, and when the key is absent
// the body is skipped and the incoming location passes through unchanged.
//
// The key is the JOINED spelling, `workdir().join(recorded)`. This repository
// writes the BARE relative spelling into the VFS, and that is deliberate:
// `client/hydrate/live_source.nim`'s header records the measurement behind it —
// the origin classifier probes the relative path, `Path::exists()` is hardwired
// `false` on wasm32 so the engine's own probe could only ever take the relative
// branch, and writing the absolute path alone left the classifier saying
// "source unavailable" on a recording that had published its source. So the
// work-around that made the origin chain resolve is what starves the flow
// window. Two features, one key, opposite spellings.
//
// WHY THE JOURNEY EXISTS RATHER THAN A NOTE
// -----------------------------------------
// Because the pane looks healthy. Journey 12 is GREEN: values are on screen,
// they carry real numbers, they are on lines of the function the session is in,
// and the set of them changes at every step — the pane opens six lines above
// the position, so what a visitor SEES is a function of the position even when
// the window behind it is a constant. Every check short of this one passes over
// exactly the symptom that was reported.
//
// `ledger.json` carries this journey with that reason, and the ledger fails in
// BOTH directions: whoever lands the fix is told, by name, to delete the entry.
// A note in a file would not have said anything the day it started working.

import { readFacts } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "the-flow-window-follows-the-position";
export const claim =
  "The flow window the engine answers with is the window for the position the session is at.";
export const spec = "Omniscience-Flow.md — BlockTracer";
export const assertions = 1 + 8; // 9
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
  const subjects = j.subjects(
    all.filter((t) => landingOf(t.phase) === "session" && t.hasSource),
    1,
    "the tree holds a session whose Code pane shows SOURCE",
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
  j.atLeast(
    answeredTicks.size,
    2,
    "the window the engine answers with is computed for more than one position",
  );

  // A window whose location is a tick nobody asked about is the passthrough in
  // its clearest form: the request said 677, the answer says 0.
  j.countIs(
    answers.filter((a) => !askedTicks.has(String(a.rrTicks))).length,
    0,
    "every window's location is a position the session actually asked about",
  );

  // …and the function extent the engine reports is the function's real extent.
  // `functionFirst` is 0 for a function whose body begins on line 12, which is
  // the uninitialised location passing through untouched.
  j.countIs(
    answers.filter((a) => (a.functionFirst ?? 0) <= 0).length,
    0,
    "the reported function extent is a real one and not an uninitialised location",
  );

  // ── AND THE HALF A VISITOR CAN SEE ──────────────────────────────────────
  //
  // The same defect, read off the page rather than off the wire, because that
  // is the form it was reported in. Both are here rather than in journey 12
  // because they close on the same fix: a window computed for the position
  // would move with it and would carry that position's function.
  //
  // They lived in journey 12 briefly and were GREEN, and the reason is the
  // trap this whole layer keeps finding. The pane used to open six lines above
  // the position, so the SET OF LABELS ON SCREEN changed at every step even
  // though the window behind it never did, and the labels that fell outside
  // the function were exactly the ones the cut removed. When
  // `a-source-file-is-shown-whole` landed, both went red — with nothing about
  // the overlay having changed. The cut had been supplying the evidence.
  const screen = readings.filter((r) => r.labels.length > 0);
  j.atLeast(screen.length, 3, "SUBJECTS: positions with an overlay on screen");

  j.atLeast(
    new Set(screen.map((r) => r.text)).size,
    2,
    "ON SCREEN: the overlay changes as the position moves",
  );

  const framed = screen
    .map((r) => ({ ...r, fn: enclosing(headers, r.doc, r.marked) }))
    .filter((r) => r.fn !== null);
  j.countIs(
    framed.filter((r) => r.lines.some((n) => n < r.fn.first || n > r.fn.last)).length,
    0,
    "ON SCREEN: every annotated line lies inside the function the session is in",
  );

  await ctx.close();
}
