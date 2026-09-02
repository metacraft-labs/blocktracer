// "A visitor who steps sees the panes that changed change, and nothing else move."
//
// Page-Descriptions.md §7.0 (hydration turns a positioned frame into a stepping
// one — it does not turn the page over on every step) and §8 (a wait is shown
// because it is a wait, not because a repaint straddled a frame boundary).
//
// WHAT A VISITOR REPORTED
// -----------------------
// "The values panel is flickering between steps." Two mechanisms were found
// under that sentence, and neither was visible to any check in this repository.
//
// THE FIRST: ONE STEP WAS TWENTY-EIGHT REBUILDS.
// `renderPanes` is the only writer of the panes, and it is called by every
// event that could change one — the stop, the locals reply, the call-trace
// section, the event-log section. Measured against the published engine, a
// single forward step produced SEVEN such calls, each rewriting all four panes'
// `innerHTML`: 28 assignments, of which 21 wrote byte-identical markup. The
// Call Trace's 24 KB and the Event Log's 7.5 KB were destroyed and rebuilt
// seven times each to say exactly what they already said, and
// `scrollToCurrentLine` moved the source pane seven times with them. Not one
// DOM node in the Values pane survived a step.
//
// THE SECOND: THE PAGE PAINTED A FRAME IN WHICH IT CONTRADICTED ITSELF.
// `applyStop` knows the position; the values for it arrive about 13 ms later.
// A frame is 16.7 ms. So the new line, the new step and NO VALUES were painted
// together, one frame, on four steps out of five — the pane emptying to a
// sentence and refilling. That is what the visitor was looking at, and it was
// identical before the first fix, which is why this journey measures both.
//
// THE FALSE PASS THIS FILE IS WRITTEN AGAINST
// -------------------------------------------
// "The pane shows the right values after a step" is true whether the pane was
// updated or destroyed and rebuilt, and it was green throughout both defects —
// journey 11 asserts exactly that and never moved. A repaint is invisible to
// any reading taken after it has finished. So every verdict here is a reading
// taken DURING the step: which nodes survived it, which writes were redundant,
// and what the compositor actually put on screen while it was happening.
//
// THREE READINGS THIS SUITE HAD NEVER TAKEN
// -----------------------------------------
// DOM node identity, mutation counts, and per-animation-frame sampling. A new
// instrument is a new way to be wrong — a gesture that never fires goes green,
// and an observer attached to the wrong node counts zero for ever. So Arm 0
// below proves all three against the real page before a single verdict is
// taken, in the shape `run.mjs`'s Arm I established: the instrument is asked to
// report a change that this file causes on purpose, and must report it.
//
// WHY THE CHAIN CAPTURE AND NOT THE DEMO
// --------------------------------------
// Chosen, not fallen back to — six journeys in this directory once selected
// their subject with `find((t) => !t.real) ?? list[0]`, which prefers a
// synthetic fixture and could never reach its own second arm. Both lists are
// asserted non-empty below and the choice is stated: a rung-3 capture's Call
// Trace and Event Log come ENTIRELY from the engine (its export ships no
// navigation rows at all), and its Values pane changes at every position. That
// makes it the subject on which "only what changed was repainted" is hardest to
// satisfy by accident. The demo chain is journey 14's arm, for the opposite
// reason: it is where a step INTO a frame brings names that were not in scope.

import { visit, readFacts } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-step-repaints-only-what-it-changed";
export const claim =
  "A visitor who steps sees the panes that changed change, and nothing else move.";
export const spec = "Page-Descriptions.md §7.0, §8 — BlockTracer";
export const assertions = 21;
export const needsEngine = true;

/** How many steps the session is walked. */
const WALK = 6;

/** The four replay panes, by the id the layout model derives from its own enum. */
const PANES = ["pane-editor", "pane-calltrace", "pane-state", "pane-eventlog"];

/**
 * Install the instrument.
 *
 * Three readings, on the elements the product actually writes. `writePane`
 * assigns to each pane's `.panebody`, so that is what is observed — an observer
 * on the pane WRAPPER would still see the writes bubble up through `subtree`,
 * and would also see anything else the page did inside the wrapper, which is
 * how a mutation counter comes to measure something other than the thing it is
 * named for.
 */
const install = (page) =>
  page.evaluate((paneIds) => {
    const bodies = {};
    for (const id of paneIds) {
      const body = document.querySelector("#" + id + " .panebody");
      if (body) bodies[id] = body;
    }
    const hash = (s) => {
      let h = 0;
      for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
      return h;
    };

    const w = (window.__repaint = {
      bodies,
      // One record per childList mutation: which pane, and the markup the pane
      // held afterwards. "Redundant" is decided from these rather than inside
      // the observer, so the raw readings stay raw.
      writes: [],
      held: {},
      frames: [],
      sampling: false,
    });

    for (const [id, body] of Object.entries(bodies)) {
      new MutationObserver((recs) => {
        for (const r of recs) {
          if (r.type !== "childList") continue;
          w.writes.push({ pane: id, h: hash(body.innerHTML) });
        }
      }).observe(body, { childList: true, subtree: true });
    }

    // NODE IDENTITY, and it is identity rather than a marker. A `data-` stamp
    // asks "is there a node here with my attribute on it", which a rebuild that
    // happened to copy the attribute would answer yes to. `isConnected` asks
    // whether THIS node — the object reference taken before the step — is still
    // in the document.
    w.hold = () => {
      for (const [id, body] of Object.entries(bodies)) {
        w.held[id] = [...body.querySelectorAll("*")];
      }
    };
    w.survivors = () => {
      const out = {};
      for (const [id, nodes] of Object.entries(w.held)) {
        out[id] = { held: nodes.length, alive: nodes.filter((n) => n.isConnected).length };
      }
      return out;
    };
    w.content = () => {
      const out = {};
      for (const [id, body] of Object.entries(bodies)) out[id] = hash(body.innerHTML);
      return out;
    };

    // PER-FRAME SAMPLING: what the compositor was given, not what the code
    // wrote. A repaint that is replaced before the next frame never reaches a
    // visitor's eye, and one that is not, does.
    w.startSampling = () => {
      w.sampling = true;
      const tick = () => {
        if (!w.sampling) return;
        const pane = document.querySelector("#pane-state");
        w.frames.push({
          step: document.querySelector(".dbg")?.getAttribute("data-step") ?? "",
          rows: pane?.querySelectorAll(".strow").length ?? -1,
        });
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    };
    return Object.keys(bodies).length;
  }, PANES);

const call = (page, fn) => page.evaluate((f) => window.__repaint[f](), fn);
const writeCount = (page) => page.evaluate(() => window.__repaint.writes.length);
const writesSince = (page, from) =>
  page.evaluate((n) => window.__repaint.writes.slice(n), from);

/** Step once and wait for the position to move, then for the pane to settle. */
async function step(page) {
  const before = await readFacts(page);
  await page.click('[data-action="step-forward"]');
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    if ((await readFacts(page)).step !== before.step) break;
    await page.waitForTimeout(80);
  }
  // A predicate on STABILITY and never a fixed sleep, for the reason journey 11
  // states: a harness that sleeps measures the machine it runs on.
  let seen = "";
  let stable = 0;
  const settleBy = Date.now() + 15000;
  while (Date.now() < settleBy && stable < 3) {
    await page.waitForTimeout(120);
    const f = await readFacts(page);
    const now = JSON.stringify([f.step, f.stateRows, f.stateNote]);
    stable = now === seen ? stable + 1 : 0;
    seen = now;
  }
  return readFacts(page);
}

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const sessions = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(sessions, 3, "transactions whose landing is a session with rows in its Code pane");

  // TWO LISTS, EACH ASSERTED, NO `??` BETWEEN THEM. See the header for which is
  // driven here and why.
  const synthetic = sessions.filter((t) => !t.real);
  const realCaptures = sessions.filter((t) => t.real);
  j.atLeast(synthetic.length, 1, "SUBJECTS: synthetic sessions exist, so the corpus still has both kinds");
  j.atLeast(realCaptures.length, 1, "SUBJECTS: REAL-capture sessions, so this journey has its subject");

  const subject = realCaptures[0];
  j.note(`driving REAL capture ${subject.debugPath}`);

  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  const page = live.page;
  try {
    j.expect(
      live.settled && !live.timedOut,
      "the session went live, so the panes on screen are the bundle's to write",
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );

    const found = await install(page);
    j.note(`instrument attached to ${found} pane bodies`);
    // AND THAT NUMBER IS NOW ASSERTED, NOT MERELY PRINTED.
    //
    // It was a `j.note` and nothing else — a measurement taken and dropped,
    // which the declared-assertion count cannot see because notes are not
    // records. Arm 0 below proves the observer works, but it proves it on ONE
    // pane (`PROBE_PANE`); if the other three never attached, every verdict
    // silently ran over a quarter of the surface and verdict 2's
    // `if (!s.survivors[pane] …) continue` absorbed the rest without a word.
    //
    // `PANES` is a literal in this file, so the `want` is outside every failure
    // mode the journey judges. This is the file's own rule from its header — "a
    // new instrument is a new way to be wrong; a gesture that never fires goes
    // green" — applied to the attachment as well as to the observation.
    j.countIs(found, PANES.length, "INSTRUMENT: the observer attached to every replay pane body");

    // ── ARM 0: PROVE THE INSTRUMENT ─────────────────────────────────────────
    // Let the landing finish before anything is measured, so a write from the
    // engine's own arrival is not mistaken for one this file caused — and wait
    // for the pane to have ROWS in it rather than for a fixed interval. The
    // first draft waited 2.5 s and proved the instrument against a pane holding
    // a single element, which is a valid proof of a much weaker claim: a
    // "destroyed every node" verdict over one node is close to unfalsifiable.
    {
      const deadline = Date.now() + 20000;
      while (Date.now() < deadline) {
        if ((await readFacts(page)).stateRows.length > 0) break;
        await page.waitForTimeout(150);
      }
      await page.waitForTimeout(800);
    }

    // (i) The observer is on the node the product writes, and counts one write
    //     per assignment. The control rewrite is `innerHTML = innerHTML`, so
    //     the pane says exactly what it said and only its NODES change.
    //
    //     PROVED ON THE SOURCE PANE and not on the Values pane, although the
    //     Values pane is the subject. The source pane is drawn by the exporter
    //     and holds hundreds of nodes from the first byte, whereas the Values
    //     pane holds ONE — a sentence — until the engine answers. A first draft
    //     proved "a rewrite destroys every node the pane held" over a single
    //     node, which is a true statement about a claim far weaker than the one
    //     the verdict rests on, and it passed and then flaked. The verdicts
    //     below judge all four panes; the proof is taken where it can be
    //     substantive without waiting on an engine.
    const PROBE_PANE = "pane-editor";
    await call(page, "hold");
    const beforeControl = await writeCount(page);
    await page.evaluate((id) => {
      const b = window.__repaint.bodies[id];
      b.innerHTML = b.innerHTML;
    }, PROBE_PANE);
    await page.waitForTimeout(120);
    const controlWrites = await writesSince(page, beforeControl);
    j.countIs(
      controlWrites.filter((x) => x.pane === PROBE_PANE).length,
      1,
      "INSTRUMENT: a rewrite of one pane is counted once, on that pane",
    );
    j.countIs(
      controlWrites.filter((x) => x.pane !== PROBE_PANE).length,
      0,
      "INSTRUMENT: the same rewrite is counted on no other pane",
    );

    // (ii) A rewrite destroys the nodes the pane held. Without this, "the nodes
    //      survived" would be a reading that is true of a rebuilt pane too, and
    //      the verdict below would be satisfied by the defect.
    const afterControl = await call(page, "survivors");
    j.atLeast(
      afterControl[PROBE_PANE].held,
      20,
      `INSTRUMENT CONTROL: the pane held a substantial number of nodes for the rewrite to destroy`,
    );
    j.countIs(
      afterControl[PROBE_PANE].alive,
      0,
      "INSTRUMENT: a rewrite destroys every node the pane was holding",
    );

    // (iii) …and nodes DO survive when the pane is not rewritten. Both
    //       directions, or "alive === held" below would be a reading that
    //       cannot fail.
    await call(page, "hold");
    const beforeQuiet = await writeCount(page);
    await page.waitForTimeout(700);
    const quiet = await call(page, "survivors");
    j.countIs(
      (await writeCount(page)) - beforeQuiet,
      0,
      "INSTRUMENT CONTROL: no pane was written during the quiet window",
    );
    j.countIs(
      quiet[PROBE_PANE].alive,
      quiet[PROBE_PANE].held,
      "INSTRUMENT: every node survives a window in which the pane is not rewritten",
    );

    // ── THE WALK ────────────────────────────────────────────────────────────
    await call(page, "startSampling");
    const walkFrom = await writeCount(page);
    const readings = [await readFacts(page)];
    const perStep = [];
    for (let i = 0; i < WALK; i++) {
      const before = await call(page, "content");
      await call(page, "hold");
      const facts = await step(page);
      perStep.push({
        before,
        after: await call(page, "content"),
        survivors: await call(page, "survivors"),
        step: facts.step,
      });
      readings.push(facts);
    }
    const walkWrites = await writesSince(page, walkFrom);
    const frames = await page.evaluate(() => {
      window.__repaint.sampling = false;
      return window.__repaint.frames;
    });

    const positions = new Set(readings.map((r) => r.step));
    j.atLeast(
      positions.size,
      3,
      `CONTROL: the walk moved the session through distinct positions (${[...positions].join(" → ")})`,
    );
    j.atLeast(
      walkWrites.length,
      WALK,
      `CONTROL: the panes were written during the walk, so "no redundant write" is a measurement`,
    );

    // ── VERDICT 1: NOTHING IS REWRITTEN WITH WHAT IT ALREADY SAYS ───────────
    // The defect in its own units. This is the assertion the 21-of-28 finding
    // reduces to, and it is exact rather than a bound: a write that produces
    // markup identical to the markup already on screen is work with no product
    // meaning and a teardown with a visible cost.
    const lastSeen = {};
    const redundant = [];
    for (const wr of walkWrites) {
      if (lastSeen[wr.pane] === wr.h) redundant.push(wr);
      lastSeen[wr.pane] = wr.h;
    }
    j.countIs(
      redundant.length,
      0,
      `no pane write rewrote the markup the pane already held (${walkWrites.length} writes over ${WALK} steps)`,
    );

    // ── VERDICT 2: A PANE THAT DID NOT CHANGE KEEPS ITS NODES ───────────────
    // The discriminating reading. "The pane shows the right thing afterwards"
    // is true of a rebuild; "the nodes are the same objects" is not.
    let unchangedPaneSteps = 0;
    const rebuiltAnyway = [];
    for (const s of perStep) {
      for (const pane of PANES) {
        if (s.before[pane] !== s.after[pane]) continue;
        if (!s.survivors[pane] || s.survivors[pane].held === 0) continue;
        unchangedPaneSteps++;
        if (s.survivors[pane].alive !== s.survivors[pane].held) {
          rebuiltAnyway.push(`${pane}@${s.step}:${s.survivors[pane].alive}/${s.survivors[pane].held}`);
        }
      }
    }
    j.atLeast(
      unchangedPaneSteps,
      1,
      "CONTROL: the walk included panes whose content was the same after the step as before it",
    );
    j.countIs(
      rebuiltAnyway.length,
      0,
      `a pane whose content did not change kept every one of its nodes across the step` +
        (rebuiltAnyway.length ? ` — ${rebuiltAnyway.join(", ")}` : ""),
    );

    // ── VERDICT 3: THE VALUES PANE DOES NOT TAKE BACK WHAT IT HAS SHOWN ─────
    // `noteFor` used to key off "is a request outstanding" rather than "do I
    // hold this position's values", and `StateVM` issues more than one
    // `ct/load-locals` per move — so the pane went values → sentence → values
    // at ONE position, within a single step. A reading taken after the step
    // cannot see it; a per-write reading can.
    const stateWrites = walkWrites.filter((wr) => wr.pane === "pane-state");
    const regressions = [];
    {
      // Replay the per-frame sample rather than the write log: what matters is
      // whether a position that HAD its rows on screen was ever shown without
      // them afterwards, and the frames are where "on screen" is knowable.
      const seenRowsAt = new Set();
      for (const f of frames) {
        if (f.rows > 0) seenRowsAt.add(f.step);
        else if (seenRowsAt.has(f.step)) regressions.push(f.step);
      }
    }
    j.atLeast(
      stateWrites.length,
      1,
      "CONTROL: the Values pane was written during the walk",
    );
    j.countIs(
      regressions.length,
      0,
      "no position had the Values pane's rows taken away again after showing them",
    );

    // ── VERDICT 4: NO FRAME IS PAINTED IN WHICH THE PAGE CONTRADICTS ITSELF ─
    // The visitor's own reading, and the one that names the reported symptom.
    // A position whose settled pane HAS values must never have been painted
    // without them: that frame is the page saying "you are at step N" and "step
    // N has no values" at once, and it is the blink.
    //
    // Note what is NOT named here. Not the sentence, not a class, not a
    // duration — the expectation is a relation between two things this page
    // reported about the same position: what it settled on, and what it painted
    // on the way there.
    const settledRowsAt = new Map();
    for (const r of readings) if (r.stateRows.length > 0) settledRowsAt.set(r.step, r.stateRows.length);
    const sampledAt = new Set(frames.map((f) => f.step));
    const missing = [...positions].filter((p) => !sampledAt.has(p));
    j.countIs(
      missing.length,
      0,
      `INSTRUMENT: the frame sampler saw every position the walk visited (${frames.length} frames)`,
    );

    const blinks = frames.filter((f) => settledRowsAt.has(f.step) && f.rows === 0);
    j.atLeast(
      settledRowsAt.size,
      1,
      "CONTROL: the walk reached positions whose Values pane settled with rows on screen",
    );
    j.countIs(
      blinks.length,
      0,
      `no painted frame showed an empty Values pane at a position that has values` +
        ` (${frames.length} frames sampled across ${settledRowsAt.size} such positions)`,
    );
  } finally {
    await page.close();
  }
}
