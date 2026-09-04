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
export const needsEngine = true;
export const assertions = 10;

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
    .sort((a, b) => b.calltraceFrames - a.calltraceFrames);
  j.subjects(deep, 1, "sessions whose Call Trace paints more than the two AVM-context frames");

  // The subject is the one whose SERVED rows give two or more frames the same
  // coordinate — the case a coordinate cannot decide. Read off the markup, not
  // named, and asserted rather than assumed: a corpus that lost this recording
  // must redden this journey, because the claim is then unjudgeable rather than
  // satisfied.
  let subject = null;
  let group = [];
  let baseline = null;

  for (const candidate of deep.slice(0, 4)) {
    const opened = await visit(browser, site.origin, candidate.debugPath, {
      settle: (f) => f.phase !== "fetching",
      settleMs: 30000,
    });
    const read = await readRows(opened.page);
    const byStep = new Map();
    for (const r of read.rows) {
      if (!byStep.has(r.step)) byStep.set(r.step, []);
      byStep.get(r.step).push(r);
    }
    const biggest = [...byStep.values()].sort((a, b) => b.length - a.length)[0] ?? [];
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

  j.note(`driving ${subject.debugPath}; ${group.length} rows share step ${group[0].step}`);

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
    // `phase !== "fetching"` and NOT `ready`: this claim is about what the page
    // does BEFORE the engine, and waiting for a live session would be waiting
    // for something this assertion does not need and this subject cannot reach.
    const opened = await visit(browser, site.origin, url, {
      settle: (f) => f.phase !== "fetching",
      settleMs: 30000,
    });
    const read = await readRows(opened.page);
    await opened.page.close();
    landings.push({ target, read });
  }

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
