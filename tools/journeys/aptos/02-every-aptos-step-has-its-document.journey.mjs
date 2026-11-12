// "A visitor debugging an Aptos transaction is shown every step on a document: the Move
//  source line where the module's source was proved against its bytes, the module's
//  disassembly where it was not."
//
// Recorder-Move CXP-MOVE-7, source resolution through the account module REST provider
// (Source-Resolution.md §3, §4), and §7's last row: "source-level stepping where sources
// exist, instruction-level elsewhere, with the boundary visible in the source pane rather
// than silent".
//
// THE DEFECT THIS WAS WRITTEN AGAINST. The Aptos producer publishes one bundle per module
// a transaction enters — the transfer enters 16, a Decibel order 45 — and positions every
// step in one of their files under `move-positions/1`. The debug page read the FIRST code
// hash's bundle only, and read per-step positions only for the AVM and CASM schemas. So the
// transfer served one module's seven files with no position, and the three Decibel
// transactions served "No source resolved … instruction level" over a recording that
// places every one of its steps.
//
// WHAT IS JUDGED, AND FROM WHAT. The subjects are every Aptos transaction the site
// publishes. The stepped files are read from each recording's own `positions.json` beside
// its container, so "every step has a document" is a relation between two published
// objects and names no file. The served frame is read with no script; the live frame is
// the hydrated session, which lands on source and is then moved, by a click on the Call
// Trace row of the first frame the recording opened in a module's disassembly, onto a
// disassembly line. A Sui session is the control: its recording is all disassembly, and
// it is held to the same claim.
//
//   just journeys-aptos

import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { visit, consoleMark, waitForConsoleLine, POSITION_ANSWERED, tickOf, waitForFacts }
  from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "every-aptos-step-has-its-document";
export const claim =
  "A visitor debugging an Aptos transaction is shown every step on a document: the Move " +
  "source line where the module's source was proved, the module's disassembly where not.";
export const spec =
  "Recorder-Move CXP-MOVE-7 (source resolution); Source-Resolution.md §3, §4, §6, §7";
export const assertions = 14;
export const needsEngine = true;

const isDisassembly = (p) => /\.(masm|mvb)$/.test(p);

/** Every published trace manifest, by `chain/tx`, with the directory it sits in. */
async function manifests(root) {
  const out = new Map();
  const t = join(root, "t");
  for (const a of await readdir(t).catch(() => [])) {
    for (const b of await readdir(join(t, a)).catch(() => [])) {
      for (const id of await readdir(join(t, a, b)).catch(() => [])) {
        const dir = join(t, a, b, id);
        const m = await readFile(join(dir, "manifest.json"), "utf8").then(JSON.parse, () => null);
        if (m && m.chain && m.tx) out.set(`${m.chain}/${m.tx}`, { dir, manifest: m });
      }
    }
  }
  return out;
}

/** The recording's own stream: each step's file, or null. */
async function stepsOf(dir) {
  const p = await readFile(join(dir, "positions.json"), "utf8").then(JSON.parse, () => null);
  if (!p || !Array.isArray(p.pathId)) return null;
  return p.pathId.map((id) => (Number.isInteger(id) ? p.paths[id] : null));
}

/** The served frame, read with scripting off: what a crawler and a no-JS reader get. */
async function served(browser, origin, path) {
  const context = await browser.newContext({ javaScriptEnabled: false });
  const page = await context.newPage();
  try {
    await page.goto(origin + path, { waitUntil: "load", timeout: 60000 });
    return await page.evaluate(READ);
  } finally {
    await context.close();
  }
}

const READ = () => {
  const cur = [...document.querySelectorAll(".srcline.cur")];
  return {
    docs: [...document.querySelectorAll(".srcdoc")].map((d) => d.getAttribute("data-path")),
    marked: cur.length,
    markedPath: cur[0]?.closest(".srcdoc")?.getAttribute("data-path") ?? null,
    markedLine: cur[0]?.querySelector(".n")?.textContent?.trim() ?? null,
    step: document.querySelector(".dbg")?.getAttribute("data-step") ?? null,
    noSource: (document.body.innerText || "").includes("No source resolved"),
    cause: document.querySelector(".srccause")?.textContent?.trim() ?? "",
  };
};

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const sessions = all.filter((t) => landingOf(t.phase) === "session");
  const aptos = sessions.filter((t) => t.chain === "aptos-mainnet");
  j.subjects(aptos, 4, "Aptos sessions this site publishes (the window's four)");
  const byTx = await manifests(site.root);

  // ── SERVED: every stepped file has a document, and the position is marked ──────────
  const reads = [];
  let missing = 0, unmarked = 0, saysNoSource = 0, mixed = 0, mixedStated = 0;
  let onSource = null, onDis = null;   // one tick of each kind, on one transaction
  for (const t of aptos) {
    const m = byTx.get(`${t.chain}/${t.hash}`);
    const steps = m ? await stepsOf(m.dir) : null;
    if (!steps) { missing += 1; j.note(`${t.hash}: no positions.json beside its manifest`); continue; }
    const r = await served(browser, site.origin, t.debugPath);
    reads.push(r);
    const docs = new Set(r.docs);
    const stepped = [...new Set(steps.filter(Boolean))];
    const absent = stepped.filter((p) => !docs.has(p));
    missing += absent.length;
    if (r.marked !== 1) unmarked += 1;
    if (r.noSource) saysNoSource += 1;
    const dis = steps.findIndex((p) => p && isDisassembly(p));
    const src = steps.findIndex((p) => p && !isDisassembly(p));
    if (dis >= 0 && src >= 0) {
      mixed += 1;
      if (/disassembly/.test(r.cause)) mixedStated += 1;
      if (!onDis) { onDis = { t, step: dis, path: steps[dis] }; onSource = { t, step: src, path: steps[src] }; }
    }
    j.note(`SERVED ${t.hash.slice(0, 10)}…: ${r.docs.length} documents, ${stepped.length} ` +
      `stepped file(s), ${absent.length} without a document; marked ${r.marked} at ` +
      `${r.markedPath}:${r.markedLine} (step ${r.step})`);
  }
  j.countIs(missing, 0, "SERVED: every file a step of an Aptos recording is on has a document on its page");
  j.countIs(unmarked, 0, "SERVED: every Aptos page marks exactly one row, the step it serves");
  j.countIs(saysNoSource, 0, "SERVED: no Aptos page says no source resolved");
  j.atLeast(mixed, 1, "SUBJECTS: Aptos recordings with steps on BOTH source and disassembly");
  j.countIs(mixedStated, mixed, "SERVED: each of those states the source/disassembly boundary in the pane");

  // ── LIVE: the landing is on source; a jump to a disassembly frame moves it there ──
  //
  // The frame is taken from the recording's own `calltrace.json`: the first frame it
  // opened whose file is a disassembly. Its Call Trace row is the visitor's way there,
  // and the engine's answer is the verdict: the mark has to move into that file.
  let disFrames = [];
  if (onDis) {
    const m = byTx.get(`${onDis.t.chain}/${onDis.t.hash}`);
    const ct = await readFile(join(m.dir, "calltrace.json"), "utf8").then(JSON.parse, () => null);
    disFrames = (Array.isArray(ct?.frame) ? ct.frame : []).filter((f) => f.path && isDisassembly(f.path));
  }
  j.subjects(disFrames, 1, "frames the recording opened in a module's disassembly, to jump to");
  const frame = disFrames[0];
  if (onDis && frame) {
    const live = await visit(browser, site.origin, onDis.t.debugPath, {
      settle: (f) => f.phase === "ready" && f.controlsLive > 0,
      settleMs: 60000,
    });
    try {
      j.expect(live.settled && !live.timedOut,
        "LIVE: the session reached ready with live controls", `phase=${live.facts.phase}`);
      // The engine's first stop arrives after `ready`; wait for a mark.
      let r = await live.page.evaluate(READ);
      for (let i = 0; i < 40 && r.marked !== 1; i++) {
        await live.page.waitForTimeout(250);
        r = await live.page.evaluate(READ);
      }
      j.note(`LIVE landing: step ${r.step}, marked ${r.marked} at ${r.markedPath}:${r.markedLine}`);
      j.expect(r.marked === 1 && r.markedPath !== null && !isDisassembly(r.markedPath),
        "LIVE: the hydrated session lands on a Move source line, marked",
        `marked ${r.marked} in ${r.markedPath}`);
      // The live Call Trace renders a window of its rows, so the row is scrolled to:
      // the pane's own scroller is moved a screen at a time until a row naming the
      // frame's tick is in the DOM, as a visitor scrolling down to it would.
      let row = -1;
      for (let pass = 0; pass < 200 && row < 0; pass++) {
        row = await live.page.evaluate((step) => {
          const rows = [...document.querySelectorAll(".calltrace-call-line")];
          const at = rows.findIndex((e) => e.getAttribute("data-rr-ticks") === String(step));
          if (at >= 0) return at;
          let sc = rows[0]?.parentElement;
          while (sc && sc.scrollHeight <= sc.clientHeight + 1) sc = sc.parentElement;
          if (sc) sc.scrollTop += Math.max(sc.clientHeight - 40, 40);
          return -1;
        }, frame.step);
        if (row < 0) await live.page.waitForTimeout(100);
      }
      j.expect(row >= 0, "LIVE: the Call Trace shows that frame's row",
        `step ${frame.step}, row ${row}`);
      if (row >= 0) {
        // By the row's own tick and not by an index: the window re-renders as it
        // scrolls, so an index taken before the scroll can name another row after it.
        const loc = live.page.locator(`.calltrace-call-line[data-rr-ticks="${frame.step}"]`).first();
        await loc.scrollIntoViewIfNeeded();
        const mark = consoleMark(live.page);
        // FOUND AND CLICKED IN ONE TASK. A pointer click lands on whatever is under
        // the pointer when it arrives, and the window can re-render between the
        // scroll above and that moment: measured, a click aimed at the row for tick
        // 358 arrived on `0x1::cmp::compare` at tick 464, which then failed the
        // assertion below as a wrong jump. Dispatching on the element just found,
        // with no await in between, leaves no gap for a re-render to fill, and the
        // event is the same click the pane's handlers take.
        const clicked = await live.page.evaluate((step) => {
          const r = document.querySelector(`.calltrace-call-line[data-rr-ticks="${step}"]`);
          if (!r) return null;
          (r.querySelector(".call-text") ?? r).click();
          return r.getAttribute("data-rr-ticks");
        }, frame.step);
        j.note(`LIVE clicked the row for tick ${clicked}`);
        const answered = await waitForConsoleLine(live.page, POSITION_ANSWERED,
          { sinceIndex: mark, budgetMs: 20000 });
        const tick = tickOf(answered);
        if (tick !== null) await waitForFacts(live.page, (f) => f.step === tick, 8000);
        let after = await live.page.evaluate(READ);
        for (let i = 0; i < 20 && after.markedPath !== frame.path; i++) {
          await live.page.waitForTimeout(250);
          after = await live.page.evaluate(READ);
        }
        j.note(`LIVE after the jump: step ${after.step}, marked ${after.marked} at ${after.markedPath}:${after.markedLine}`);
        // The recording's own stream says which file the reported step is in.
        const disSteps = await stepsOf(byTx.get(`${onDis.t.chain}/${onDis.t.hash}`).dir);
        const want = disSteps?.[Number(after.step)] ?? null;
        j.expect(after.marked === 1 && Number(after.step) === frame.step &&
                 after.markedPath === want && isDisassembly(want ?? ""),
          "LIVE: after the jump the session is at the frame's tick and marks one row, in the module's disassembly the recording places it in",
          `step ${after.step} (wanted ${frame.step}), marked ${after.marked} in ${after.markedPath}, stream says ${want}`);
      }
      j.countIs(live.pageErrors.length, 0, "LIVE: no uncaught page errors");
    } finally {
      await live.page.close();
    }
  }

  // ── CONTROL: Sui, whose recording is all disassembly ───────────────────────────────
  const sui = sessions.filter((t) => t.chain === "sui" || t.chain === "sui-mainnet");
  j.subjects(sui, 1, "Sui sessions, the all-disassembly control");
  const s = sui[0];
  const sm = byTx.get(`${s.chain}/${s.hash}`);
  const ssteps = sm ? await stepsOf(sm.dir) : null;
  const sr = await served(browser, site.origin, s.debugPath);
  const sDocs = new Set(sr.docs);
  const sAbsent = ssteps ? [...new Set(ssteps.filter(Boolean))].filter((p) => !sDocs.has(p)) : [null];
  j.note(`SUI ${s.hash}: ${sr.docs.length} documents, marked ${sr.marked} at ${sr.markedPath}:${sr.markedLine}`);
  j.expect(sAbsent.length === 0 && sr.marked === 1 && isDisassembly(sr.markedPath ?? ""),
    "CONTROL (Sui): every stepped file has a document and the served row is a disassembly line",
    `${sAbsent.length} stepped file(s) without a document, marked ${sr.marked} in ${sr.markedPath}`);
}
