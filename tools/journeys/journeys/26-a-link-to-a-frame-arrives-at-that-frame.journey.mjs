/**
 * A shared link that names a FRAME opens on that frame — before the engine.
 *
 * ## The claim, and why a coordinate cannot carry it
 *
 * §6.0a's recovery anchor for a call is a call PATH (`call:0.0.0.3.3.0`), and
 * §6.3 wants an incoming link resolved "before first paint, so a shared link
 * opens *at* the position rather than at the start with a visible jump". The
 * position half of that has worked for a while: `?t=` is read and the session
 * seeks to it.
 *
 * A tick is not a frame, and on this corpus it usually cannot be. The subject
 * below has forty-six frames carrying twenty-two distinct steps; six of them —
 * `Map::at` → `derive_storage_slot_in_map` → `poseidon2_hash_with_separator` →
 * `poseidon2_hash` → `Poseidon2::hash` → `Poseidon2::hash_internal` — are all
 * open at one step, because a call that immediately calls another records no
 * step in between. Six links, six different frames, one `t`. Anything that
 * resolves such a link to its coordinate has thrown the answer away.
 *
 * ## Why this is judged BEFORE the engine, and why that is not a shortcut
 *
 * `announceLanding` resolves the link against the SERVED rows and marks the
 * frame, and it runs ahead of an 18 MB download. That is not a weaker place to
 * assert it — it is the place §6.3 names, and during the download it is the
 * whole of what the visitor has.
 *
 * ## The engine is HELD, because "before the engine" was being raced for
 *
 * This journey used to settle on `phase !== "fetching"` and read once. Measured
 * on the built site, that predicate is satisfied at `opening` — 0.2–0.3 s, when
 * the engine has been ASKED for — while hydration repaints the Call Trace pane
 * from the live producer at 2.3–2.7 s. So the predicate did not hold the page
 * before the engine at all; it released 2 s early and left each read to land on
 * whichever producer happened to own the pane at that instant. `fetching` is
 * the SERVED page's own phase, so `!== "fetching"` waits for the engine rather
 * than avoiding it: the comment that stood here had it exactly backwards.
 *
 * The cost, measured over 20 runs on one unchanged tree at 779c702:
 *
 *   verdict       red 14, green 6
 *   subject step  58 on 12 runs, 59 on 8      <- the SUBJECT moved
 *   control row   [1] enqueued-call-0 on 12, [45] avm_return on 8
 *   "different source position"  1,2,3,4,5,6 — every value in range
 *
 * Each of the eight page reads raced independently, so the last count was a
 * MIXTURE: k reads on the served rows contribute k distinct positions and the
 * rest all contribute `main.nr:148`. The identity assertions were 6/6 on all 20
 * runs, which is the evidence that the PRODUCT is not the variable here.
 *
 * So the engine is now held in flight (`holdRoutes`), which makes the interval
 * §6.3 is about into a state instead of a window, and the read has no deadline
 * to beat. Every read then asserts, below, that it really was the static
 * producer's rows — because an unpinned read is invisible in a green run, and
 * that is precisely how this went unnoticed.
 *
 * It is also the only place this claim can be judged on this subject today.
 * Journey 25 asserts the same identity on the LIVE pane after a click and is
 * ledgered red, because `renderSource` overflows the JavaScript stack on this
 * transaction's 4 MB document and `renderPanes` dies before the call-trace pane
 * is written. That defect is in the Code pane, it is on unmodified `dev`, and
 * it does not touch this path: nothing here waits for a stop.
 *
 * ## The control that makes it a measurement
 *
 * With no link, the served page marks one row — the innermost frame containing
 * the served coordinate, which is the right answer to "where is the session"
 * and the wrong one to "which frame did this link name". The journey asserts
 * that unlinked mark exists and that every one of the six links moves it
 * somewhere else. Without that, six links all marking the page's default would
 * satisfy "exactly one row is marked" and assert nothing.
 *
 * spec: Debugger-Integration.md §6.0a, §6.3 — BlockTracer
 */

import { visit } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-link-to-a-frame-arrives-at-that-frame";
export const claim =
  "A shared link naming a call frame opens with that frame marked, even where several frames share the link's coordinate — and it does so before the replay engine is fetched.";
export const spec = "Debugger-Integration.md §6.0a, §6.3 — BlockTracer";
// STILL TRUE, though the engine is held: "before the engine is fetched" is only
// a state a visitor can be in if the engine is there to be fetched. What is held
// is the DELIVERY, not the request — the page under test is the deployed
// hydrated shape, whose bundle asks for the engine on load.
export const needsEngine = true;
export const assertions = 14;

/** The engine, held in flight — the interval §6.3 is about. */
const HOLD_ENGINE = ["**/replay-engine/**"];

/** Every call-trace row, with both identities and the mark. */
const readRows = (page) =>
  page.evaluate(() => {
    // `.ctview.def` and not a bare `.ctrow`: the pane renders a SECOND view,
    // the by-function cost aggregation, whose rows are `.ctrow d0 flat` and
    // carry no `data-step` because they are functions rather than frames
    // (`corpus.mjs` draws the same distinction). Grouping over both put 35
    // aggregate rows into one `step=null` bucket and measured nothing.
    const rows = [...document.querySelectorAll(".ctview.def .ctrow")];
    return {
      rows: rows.map((r, i) => ({
        i,
        step: r.getAttribute("data-step"),
        anchor: r.getAttribute("data-anchor"),
        module: r.getAttribute("data-module"),
        name: r.querySelector(".ctname")?.textContent ?? null,
        line: r.querySelector(".ctline")?.textContent?.trim() ?? null,
      })),
      // WHOSE ROWS ARE THESE. The live producer gives every frame an `href`,
      // which `renderCallTrace` draws as an `<a>`; the static export leaves it
      // empty and draws a `<div>` (`CallFrame.href` — "Empty on every statically
      // exported page and non-empty only in a hydrated one"), the same
      // discriminator journey 25 reads. Measured: 0 here on the served rows and
      // 48 once hydration has repainted. This is what makes "the read was
      // pre-engine" a fact the run states rather than one it hopes for.
      liveRows: rows.filter((r) => r.tagName === "A").length,
      markedIndex: rows.findIndex((r) => r.classList.contains("cur")),
      markedCount: rows.filter((r) => r.classList.contains("cur")).length,
      // Counted over the WHOLE document as well, because `markServedFrame`
      // clears across every `.ctrow` and a mark left behind in the other view
      // would be a second row claiming to be the position.
      markedAnywhere: document.querySelectorAll(".ctrow.cur").length,
    };
  });

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const deep = all
    .filter((t) => landingOf(t.phase) === "session" && t.calltraceFrames > 2)
    // A TOTAL ORDER, not merely a descending one. `calltraceFrames` ties across
    // this corpus, and a comparator that returns 0 leaves the winner to the
    // order `transactions()` happened to walk the tree in. The path is the
    // tie-break because it is the one field that cannot tie.
    .sort((a, b) => b.calltraceFrames - a.calltraceFrames || a.debugPath.localeCompare(b.debugPath));
  j.subjects(deep, 1, "sessions whose Call Trace paints more than the two AVM-context frames");

  // The subject is the one whose SERVED rows give two or more frames the same
  // coordinate — the case a coordinate cannot decide. Read off the markup, not
  // named, and asserted rather than assumed: a corpus that lost this recording
  // must redden this journey, because the claim is then unjudgeable rather than
  // satisfied.
  let subject = null;
  let group = [];
  let baseline = null;
  let tiedAtMax = 0;
  // Every read this journey makes, so "was it pre-engine" is one question asked
  // of all of them at the end rather than eight separate hopes.
  const reads = [];

  for (const candidate of deep.slice(0, 4)) {
    // NO SETTLE, and that is a statement rather than an omission: with the
    // engine held there is no later state to wait for. The served rows are the
    // page, `announceLanding` leaves them exactly as served when no frame was
    // named ("an ordinary visit … leaves the served mark exactly as served"),
    // and `liveRows` below proves the read was not the other producer's.
    const opened = await visit(browser, site.origin, candidate.debugPath, {
      holdRoutes: HOLD_ENGINE,
    });
    const read = await readRows(opened.page);
    reads.push({ what: `unlinked ${candidate.debugPath}`, read });
    const byStep = new Map();
    for (const r of read.rows) {
      if (!byStep.has(r.step)) byStep.set(r.step, []);
      byStep.get(r.step).push(r);
    }
    // A TOTAL ORDER over the groups too, for the same reason and a sharper one:
    // this corpus really does tie. The served rows of the deep capture give SIX
    // frames to step 59 and SIX to step 92, so "the biggest group" names two
    // things and `[0]` picked whichever the Map happened to hold first. Size
    // first, then the smaller step — stated here so the subject is a
    // consequence of a rule rather than of an insertion order.
    const groups = [...byStep.values()].sort(
      (a, b) => b.length - a.length || Number(a[0].step) - Number(b[0].step),
    );
    const biggest = groups[0] ?? [];
    tiedAtMax = groups.filter((g) => g.length === biggest.length).length;
    await opened.page.close();
    if (biggest.length > 1) {
      subject = candidate;
      group = biggest;
      baseline = read;
      break;
    }
  }

  j.expect(
    subject !== null,
    "SUBJECTS: a served Call Trace that gives two or more frames the SAME coordinate",
    subject
      ? `${subject.chain}/${subject.hash} — ${group.length} rows share step ${group[0].step}`
      : "no published transaction paints two frames at one coordinate; nothing here can judge the claim",
  );
  if (!subject) return;

  j.note(
    `driving ${subject.debugPath}; ${group.length} rows share step ${group[0].step}` +
      (tiedAtMax > 1
        ? ` (${tiedAtMax} groups tie at ${group.length} rows; the smallest step wins, by the rule above)`
        : ""),
  );

  j.atLeast(
    group.length,
    2,
    "the subject really is a case a coordinate cannot decide: several frames, one step",
  );
  j.countIs(
    new Set(group.map((r) => r.anchor)).size,
    group.length,
    "those rows carry one DISTINCT anchor each, so an identity for them exists",
  );

  // THE CONTROL. Without it, six links all leaving the page's own mark in place
  // would pass "exactly one row is marked" while resolving nothing.
  j.expect(
    baseline.markedCount === 1 && baseline.markedIndex >= 0,
    "CONTROL: with no link, the served page already marks exactly one row",
    `marked [${baseline.markedIndex}] ${baseline.rows[baseline.markedIndex]?.name}, count ${baseline.markedCount}`,
  );

  const landings = [];
  for (const target of group) {
    const url =
      `${subject.debugPath}?v=1&t=${target.step}&a=${encodeURIComponent(target.anchor)}`;
    // SETTLED ON THE PRODUCT'S OWN SENTENCE about the landing, not on a phase.
    // `announceLanding` writes `#dbg-position-notice` — §6.3's own artefact,
    // `:empty`-hidden and empty on an ordinary visit — immediately after it
    // marks the served row, so a non-empty notice means the resolution this
    // journey is about has HAPPENED. It is positive (it waits for a thing to
    // appear rather than for a thing to stop), monotone, and with the engine
    // held it stays true, so there is nothing left to race.
    //
    // Measured: 143 characters, at 155–212 ms, on all six of these links.
    const opened = await visit(browser, site.origin, url, {
      holdRoutes: HOLD_ENGINE,
      settle: (f) => f.positionNotice.length > 0,
      settleMs: 30000,
    });
    const read = await readRows(opened.page);
    reads.push({ what: `link ${target.anchor}`, read });
    await opened.page.close();
    landings.push({ target, read });
  }

  // AND THEN THE SAME LINK WITH THE ENGINE LET THROUGH, because "the mark is
  // right before the engine" and "the mark is right" are different claims and
  // this journey would otherwise only make the first.
  //
  // `Page-Descriptions.md` §7.0 — "No state renders less than the pre-hydration
  // page" — is the floor, and this pane has been through the floor once already:
  // the live render drew 48 rows with NO mark while the served page it replaced
  // drew 47 with one, so a §6.0a link marked a row and the first live paint threw
  // the mark away. That regression is what `selectLandingFrame` closed, and
  // without a reading on this side of hydration nothing here would notice it
  // coming back — pinning the read pre-engine, on its own, would have quietly
  // retired the coverage rather than kept it.
  //
  // The identity carried across is the ANCHOR and never the index: measured, the
  // two producers render 47 and 48 rows for this session, so `markedIndex` means
  // something different on each side and only the `call:` path survives the
  // change of numbering (`Click-Navigation.md` §4).
  const survived = [];
  for (const target of group) {
    const url =
      `${subject.debugPath}?v=1&t=${target.step}&a=${encodeURIComponent(target.anchor)}`;
    const opened = await visit(browser, site.origin, url, {
      settle: (f) => f.phase !== "fetching",
      settleMs: 30000,
    });
    // The phase says the session is up; it does not say this PANE has been
    // repainted, and the two are 2 s apart. Measured on the deep capture: phase
    // leaves `fetching` at 0.2–0.3 s and the call trace flips to the live
    // producer at 2.3–2.7 s. So the wait is for the producer to change, which is
    // the event actually being waited on — the same conflation, one pane over,
    // is what this whole journey was flapping on.
    let live = await readRows(opened.page);
    for (let i = 0; i < 120 && live.liveRows === 0; i++) {
      await opened.page.waitForTimeout(250);
      live = await readRows(opened.page);
    }
    await opened.page.close();
    survived.push({ target, live });
  }

  j.countIs(
    survived.filter((s) => s.live.liveRows > 0).length,
    group.length,
    "HYDRATED: the engine came and the pane was repainted by the LIVE producer",
    survived.map((s) => `${s.target.name}: ${s.live.rows.length} rows, ${s.live.liveRows} live`).join("; "),
  );
  j.countIs(
    survived.filter((s) => s.live.markedCount === 1).length,
    group.length,
    "§7.0: hydration renders no LESS — the repainted pane still marks exactly one row",
    survived.map((s) => `${s.target.name}: ${s.live.markedCount} marked`).join("; "),
  );
  j.countIs(
    survived.filter((s) => s.live.rows[s.live.markedIndex]?.anchor === s.target.anchor).length,
    group.length,
    "and it is STILL the frame the link named, carried across by anchor",
    survived
      .map((s) => `${s.target.name}->${s.live.rows[s.live.markedIndex]?.name ?? "(none)"}`)
      .join(", "),
  );

  // THE READ IS THE ONE THE CLAIM NAMES. Everything below counts rows, and a
  // count says nothing unless it is known WHOSE rows were counted: the two
  // producers disagree about what a frame's location is (#234), so a read that
  // drifted into the live pane would answer a different question in the same
  // shape. This is the assertion whose absence let the journey flap between 14
  // reds and 6 greens on one unchanged tree without ever saying why.
  j.countIs(
    reads.filter((r) => r.read.liveRows === 0).length,
    reads.length,
    "PRE-ENGINE: every read was the STATIC producer's rows, the state §6.3 is about",
    reads.map((r) => `${r.what}: ${r.read.rows.length} rows, ${r.read.liveRows} live`).join("; "),
  );

  j.countIs(
    landings.filter((l) => l.read.markedCount === 1).length,
    group.length,
    "each link leaves exactly one row marked",
  );
  j.countIs(
    landings.filter((l) => l.read.rows[l.read.markedIndex]?.anchor === l.target.anchor).length,
    group.length,
    "the row each link marks is the row that link NAMED",
    landings
      .map((l) => `${l.target.name}->${l.read.rows[l.read.markedIndex]?.name ?? "(none)"}`)
      .join(", "),
  );
  j.countIs(
    new Set(landings.map((l) => l.read.markedIndex)).size,
    group.length,
    "so links sharing ONE coordinate mark a different row each",
  );
  j.countIs(
    new Set(
      landings.map((l) => {
        const m = l.read.rows[l.read.markedIndex];
        return `${m?.module}:${m?.line}`;
      }),
    ).size,
    group.length,
    // KEPT, where journey 25 removed the same sentence, and the difference is
    // the producer rather than a change of mind. 25 asserts on the LIVE pane,
    // where the six frames sharing a tick are all given that tick's location, so
    // the count is 1 by a convention Click-Navigation §2.3 explicitly declines
    // to settle — asserting it there required an unmade decision to have gone
    // one way. Here the rows are the STATIC export's, which numbers a frame from
    // the callee's own first step, and the six really are six places in source:
    // map.nr:36, map.nr:11, hash.nr:221, hash.nr:212, poseidon2.nr:16,
    // poseidon2.nr:68. One producer, one convention, six answers.
    //
    // It is only legitimate because the read above is PINNED. Unpinned it was
    // this exact assertion that flapped 1,2,3,4,5,6 across 20 runs, and the
    // reading was true — it was measuring a mixture of both conventions.
    "and each of those rows states a different source position",
    landings
      .map((l) => {
        const m = l.read.rows[l.read.markedIndex];
        return `${m?.name}@${String(m?.module).split("/").pop()}:${m?.line}`;
      })
      .join(", "),
  );
  // THE MARK MOVED. Every one of these links must take the mark off the row the
  // unlinked page marks — otherwise the page could be ignoring the anchor and
  // still satisfy every count above.
  j.countIs(
    landings.filter((l) => l.read.markedIndex !== baseline.markedIndex).length,
    group.length,
    "every one of them moved the mark off the row an unlinked visit marks",
    `unlinked marks [${baseline.markedIndex}] ${baseline.rows[baseline.markedIndex]?.name}`,
  );
}
