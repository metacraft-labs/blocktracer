// The probe: load a URL in a real browser and report FACTS. It asserts nothing.
//
// WHY IT ASSERTS NOTHING
// ----------------------
// Every judgement lives in a journey file, so that one function produces the
// numbers both the control arm and the mutation arm are judged on. A probe that
// decided anything would be a second place for a verdict to come from, and the
// two would drift — which is the shape `ci/test/client-sdk-boundary.sh` and its
// self-test exist to keep apart in this repository already.
//
// It is modelled on CodeTracer's `ci/test/web_renderer_probe.mjs`, and copies
// its two load-bearing decisions:
//
//   * `visibleText` is `innerText` — what is RENDERED. `textContent` (the DOM's
//     text) is reported beside it as `domText` and is asserted by NOTHING. On a
//     browser with no fonts a correct page lays out zero glyphs, and reading
//     `textContent` instead would make every gate here pass over exactly the
//     blank page it exists to catch. That is not hypothetical: it cost that
//     repository a blocked deploy on 2026-08-31. `run.mjs`'s Arm I is the
//     control that catches the same condition here.
//
//   * `pageErrors` is the single most important field. A module that fails to
//     load leaves no in-page error, because the `catch` that would record one is
//     inside the module that did not run (Verification-Harness-Traps.md §3). The
//     page's own uncaught exceptions are the only record, so they are collected
//     from the first navigation and printed on failure rather than summarised.

// Playwright is resolved from `tools/capture/node_modules` — the ONE pinned
// install in this repository (`just capture-setup`, `tools/capture/package-lock.json`,
// version-matched against the Nix browser bundle by `tools/capture/lib/pinned-env.mjs`).
//
// A second `package.json` here would be a second pin, and a skewed pair
// "usually WORKS and silently changes the pixels" — which is why that file
// refuses a skew rather than hashing it. One pin, resolved explicitly.
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const captureRequire = createRequire(pathToFileURL(join(HERE, "..", "..", "capture", "package.json")));
// `require`, not `await import`: playwright ships CommonJS, and its named
// exports are only sometimes recovered by the ESM-CJS interop — `chromium` came
// back `undefined` here on the first attempt, which fails much later and much
// less clearly than a resolve error.
let chromium;
try {
  ({ chromium } = captureRequire("playwright"));
  if (!chromium) throw new Error("playwright resolved but exports no `chromium`");
} catch (err) {
  const e = new Error(
    "playwright is not installed.\n" +
      "  This layer uses the single pinned install in tools/capture.\n" +
      "  remedy: just capture-setup\n" +
      `  (resolver said: ${err && err.message ? err.message : err})`,
  );
  e.exitCode = 2;
  throw e;
}

/** Launch one browser for a whole run. Journeys share it; each gets a fresh page. */
export async function openBrowser() {
  return chromium.launch({ chromiumSandbox: false });
}

/**
 * Read the facts a journey judges, out of a live page.
 *
 * Kept in ONE function, and called both before and after an interaction, so a
 * "the position moved" claim compares two readings taken by the same code. Two
 * bespoke readings would let a step that changed nothing look like a step that
 * changed something the second reading happened to spell differently.
 */
export const readFacts = (page) =>
  page.evaluate(() => {
    const root = document.querySelector(".dbg");
    const count = (sel) => document.querySelectorAll(sel).length;
    const text = (sel) => document.querySelector(sel)?.textContent?.trim() ?? null;

    // The marked line is read as a RELATION — its own number and its own text —
    // and never compared against a constant written in a test. The defect this
    // suite was seeded from survived 115 cases whose fixture supplied the line
    // number the cases then asserted back.
    const cur = document.querySelector(".srcline.cur");

    // RENDERED, NOT PRESENT. The source pane holds every document in the bundle
    // at once and hides all but one with CSS (`:target` tabs, so the session
    // stays navigable with scripting off). So `.srcline` counts lines that
    // EXIST, and most of them are `display:none`.
    //
    // The first version of this probe read the first `.srcline` in the DOM and
    // reported `[package]` — the hidden Nargo.toml — for a page that was
    // showing `src/shield.nr` correctly. It called a correct page broken, which
    // is the more expensive direction of wrong: a gate that cries wolf is
    // switched off, and then it is not there for the real one.
    //
    // `checkVisibility` is asked of the element, so `display:none`, zero size
    // and `visibility:hidden` are all one question with one answer.
    const shown = (e) =>
      !!e && typeof e.checkVisibility === "function"
        ? e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })
        : false;
    const shownDocs = [...document.querySelectorAll(".srcdoc")].filter(shown);

    return {
      // ---- the session's own account of where it is -------------------------
      phase: root?.getAttribute("data-session-phase") ?? null,
      step: root?.getAttribute("data-step") ?? null,
      totalSteps: root?.getAttribute("data-total-steps") ?? null,
      trace: root?.getAttribute("data-trace") ?? null,

      // ---- the source pane ---------------------------------------------------
      srclines: count(".srcline"),
      srclinesShown: [...document.querySelectorAll(".srcline")].filter(shown).length,
      marked: count(".srcline.cur"),
      markedShown: shown(cur),
      markedNumber: cur?.querySelector(".n")?.textContent?.trim() ?? null,
      markedText: cur?.querySelector(".t")?.textContent ?? null,
      markedDoc: cur?.closest(".srcdoc")?.id ?? null,

      // Which FILE the visitor is looking at, and how many are on screen at
      // once. "The debugger opened on the package manifest" is a statement
      // about this, and the manifest is in the DOM of a correct page too.
      docsShown: shownDocs.length,
      shownDoc: shownDocs.length === 1 ? shownDocs[0].id : null,
      shownDocLabel:
        shownDocs.length === 1
          ? (shownDocs[0].querySelector(".srctab.on")?.textContent?.trim() ?? null)
          : null,
      firstShownLineText:
        [...document.querySelectorAll(".srcline")].filter(shown)[0]?.querySelector(".t")
          ?.textContent?.trim() ?? null,

      // ---- WHERE THE SOURCE PANE IS SCROLLED TO ------------------------------
      //
      // A visitor reported that stepping scrolled the pane on every step and
      // pinned the position to its top edge, and the assertion that would have
      // caught it is a reading of `scrollTop` — NOT "the marked line is
      // visible", which is true of the defect and true of the fix and therefore
      // certifies neither. Journey 13 owns the judgement; this reports the
      // numbers.
      //
      // THE SCROLLER IS FOUND, NOT NAMED. `#pane-editor .panebody` is the
      // element the hydration bundle holds and it is NOT where the lines
      // overflow: `.src` is, and on the demo pane `.panebody` has a scroll range
      // of ZERO (539 == 539) while `.src` has 886 against a 512 box. A probe
      // that read `.panebody.scrollTop` would have reported 0 before the fix and
      // 0 after it — a constant, from which any assertion at all can be written
      // green. So this walks out from the marked line and takes the first
      // ancestor that actually scrolls, which is the element the visitor's
      // wheel turns.
      //
      // `sourceInView` is reported and is deliberately NOT the verdict, for the
      // reason above: it is the assertion that passes under both behaviours.
      sourceScroll: (() => {
        const pane = document.querySelector("#pane-editor .panebody");
        if (!pane || !cur) return null;
        const scrollers = [];
        for (let e = cur; e; e = e.parentElement) {
          const oy = getComputedStyle(e).overflowY;
          if ((oy === "auto" || oy === "scroll") && e.scrollHeight > e.clientHeight + 1) scrollers.push(e);
          if (e === pane) break;
        }
        if (scrollers.length === 0) return { scrollable: false, top: 0, range: 0 };
        const s = scrollers[0];
        const r = s.getBoundingClientRect();
        const top = r.top + s.clientTop;
        const bottom = top + s.clientHeight;
        const cr = cur.getBoundingClientRect();

        // The lines ON SCREEN in this scroller, in document order, so the
        // position's place among them can be stated as an index rather than as
        // a pixel count that means nothing without the line pitch.
        const band = [...document.querySelectorAll(".srcline")].filter((l) => {
          const lr = l.getBoundingClientRect();
          return lr.top >= top - 0.5 && lr.bottom <= bottom + 0.5;
        });
        const numberOf = (e) => e?.querySelector(".n")?.textContent?.trim() ?? null;
        return {
          scrollable: true,
          top: Math.round(s.scrollTop),
          range: Math.round(s.scrollHeight - s.clientHeight),
          boxHeight: Math.round(s.clientHeight),
          lineHeight: Math.round(cr.height),
          // The position's distance from the top and bottom of the box. "Not
          // flush against either edge" is a claim about these two numbers.
          fromTop: Math.round(cr.top - top),
          fromBottom: Math.round(bottom - cr.bottom),
          inView: cr.top >= top && cr.bottom <= bottom,
          onScreen: band.length,
          indexOnScreen: band.indexOf(cur),
          firstOnScreen: numberOf(band[0]),
          lastOnScreen: numberOf(band[band.length - 1]),
        };
      })(),

      // ---- the Values pane ---------------------------------------------------
      // Scoped to `#pane-state`, not to `.strow` document-wide. The transaction
      // page renders the same rows outside the debugger, and a journey that
      // counted both would report a pane that had not changed as one that had.
      //
      // The pane is read as three things and NEVER as an expected value: how
      // many rows it has, what each row's three cells say, and — when it has no
      // rows — the sentence it shows instead. That last field is the whole
      // point of reading the pane here rather than counting rows: "no values"
      // and "the values of some other frame" are the two answers a Values pane
      // can give wrongly, and a row count cannot tell them apart.
      stateRows: [...(document.querySelector("#pane-state")?.querySelectorAll(".strow") ?? [])]
        .filter(shown)
        .map((r) => ({
          name: r.querySelector(".stname")?.textContent?.trim() ?? "",
          value: r.querySelector(".stval")?.textContent?.trim() ?? "",
          type: r.querySelector(".sttype")?.textContent?.trim() ?? "",
          // WHAT THE LAST MOTION DID TO THIS ROW, as the pane marks it. Read as
          // two independent booleans and not as one tri-state, so a row that
          // somehow carried both classes is visible to a journey rather than
          // being resolved here into whichever the probe happened to test
          // first — the renderer's mutual exclusion is a claim to assert, not
          // an assumption to build the instrument on.
          changed: r.classList.contains("chg"),
          appeared: r.classList.contains("new"),
        })),
      stateNote: document.querySelector("#pane-state .panenote")?.textContent?.trim() ?? "",

      // THE FUNCTION HEADERS THIS PAGE RENDERED, per document, as raw rows.
      //
      // A FACT ABOUT THE FILE and not about the session, which is why it is
      // reported per document rather than resolved here.
      //
      // The justification this comment used to give — `source_document
      // .openAtCurrent` narrows the ACTIVE document to six lines above the
      // position, so at the demo session's later positions `fn main` has
      // scrolled out of the window entirely — NO LONGER HOLDS: that proc is gone
      // and `renderSource` emits every line of every document, so a debug page
      // read once now carries every header. What survives is the weaker and
      // still-true version: which headers a page renders is a property of the
      // PAGE, `windowAround` still narrows the home page's embed, and a probe
      // that resolved "the enclosing function" here would be deciding on one
      // page's behalf.
      //
      // So the rows are handed over and the journey merges what several
      // readings saw. That is also what keeps this the probe's job: headers are
      // observations, "which function is the session in" is a judgement.
      //
      // Noir functions are top-level and do not nest, so a header list plus a
      // line number is enough to answer it. A brace matcher would be more
      // general and would also be a second, subtler thing to be wrong about
      // inside a function that is supposed to assert nothing.
      fnHeaders: Object.fromEntries(
        [...document.querySelectorAll(".srcdoc")].map((d) => [
          d.id,
          [...d.querySelectorAll(".srcline")]
            .map((ln) => ({
              n: Number(ln.querySelector(".n")?.textContent?.trim() ?? -1),
              t: ln.querySelector(".t")?.textContent ?? "",
            }))
            .filter((r) => /^\s*(pub\s+)?(unconstrained\s+)?fn\s+[A-Za-z_]/.test(r.t))
            .map((r) => ({
              n: r.n,
              name: (r.t.match(/fn\s+([A-Za-z_]\w*)/) ?? [null, null])[1],
            })),
        ]),
      ),

      // The last row each document rendered, so a consumer can bound the final
      // function without inventing an end for it.
      docLastLine: Object.fromEntries(
        [...document.querySelectorAll(".srcdoc")].map((d) => {
          const rows = [...d.querySelectorAll(".srcline")];
          return [
            d.id,
            rows.length
              ? Number(rows[rows.length - 1].querySelector(".n")?.textContent?.trim() ?? -1)
              : -1,
          ];
        }),
      ),

      // ---- the omniscience overlay -------------------------------------------
      // Read out of the SHOWN document only, and per line. The source pane holds
      // every document in the bundle at once and hides all but one, so a
      // document-wide count would report the values of a file the visitor is not
      // looking at — the same trap `shownDocs` above exists for.
      //
      // Reported as (line number, label texts), never as an expected value. The
      // question a journey asks of this is whether it CHANGES with the position
      // and whether the lines it lands on are the lines of the function the
      // session is in; both are relations between two readings of the page, and
      // neither is a number written in a test.
      //
      // `.fv` and not `.ann`: one `.ann` span holds a line's whole run of
      // labels, so reading its `textContent` would concatenate them and make
      // "three labels" and "one label spelling all three" indistinguishable.
      // `.fv` is one chip, and now every `.fv` is a label: the `+N` elision
      // pill this reading used to separate out is gone, along with the width
      // budget that produced it (see the "Why there is no width budget here"
      // header in `client/src/debugger/flow_view.nim`).
      //
      // Filtered by `shown`, which is load-bearing here rather than tidy: every
      // pass the window carries is in the markup at once and the stylesheet
      // shows one. Reading the DOM instead of the render would report every
      // pass's values on screen simultaneously.
      flowLines: shownDocs.length === 1
        ? [...shownDocs[0].querySelectorAll(".srcline")]
            .map((ln) => ({
              n: Number(ln.querySelector(".n")?.textContent?.trim() ?? -1),
              // Every `.fv` on the row, with no exclusion. There used to be
              // one — `.fv.fvmore`, the `+N` count of the values that did not
              // fit — and its removal is why `labels` and `values` now have
              // the same selector as each other and as the page.
              labels: [...ln.querySelectorAll(".fv")]
                .filter(shown)
                .map((a) => a.textContent.trim())
                .filter(Boolean),
              // The VALUE half of each label, read from the `.fvv` spans rather
              // than by splitting the label's text on a separator.
              //
              // Structural because the split is not reliable and the failure it
              // has to catch is exactly the one a split misses: a renderer that
              // produced the empty string for a kind it did not recognise emits
              // `x=` for a scalar — which any split notices — and `x=[, , ]` for
              // an array of them, which has a non-empty right-hand side and
              // reads as a value. `renderAnnotations` puts the value, and only
              // the value, in `.fvv`, so this is the same string the stylesheet
              // draws at full strength.
              values: [...ln.querySelectorAll(".fv")]
                .filter(shown)
                .map((a) =>
                  [...a.querySelectorAll(".fvv")].map((v) => v.textContent).join(""),
                ),
              // Kept as a field, and kept EMPTY, on purpose. A journey that
              // asserted `pills.length === 0` must keep meaning that, and a
              // reading that dropped the key would make such an assertion pass
              // against `undefined.length` errors or silently against nothing.
              // If a `+N` ever comes back this reports it.
              pills: [...ln.querySelectorAll(".fvmore")]
                .filter(shown)
                .map((a) => a.textContent.trim())
                .filter(Boolean),
            }))
            .filter((r) => r.labels.length > 0 || r.pills.length > 0)
        : [],
      flowRails: count(".flowrail"),

      // ---- the stepping controls --------------------------------------------
      controlsLive: count(".dcbtn:not(.off)"),
      controlsInert: count(".dcbtn.off"),
      buttons: count("button"),

      // ---- THE TIMELINE'S PLAYHEAD -------------------------------------------
      //
      // WHY THIS FACT EXISTS AT ALL. It did not, and the cost is on the record:
      // `projectControls` read the store's `rrTicks` as a position and
      // `positioned` as `step > 0`, so a session the engine had parked on tick 0
      // drew 48 ticks with NOT ONE of them marked — no playhead, on a page whose
      // served frame had just drawn one on its correct tick. Nothing in this
      // directory could see it, because nothing in this directory read a tick.
      // Journey 06's header recorded the landing as an observation it chose not
      // to assert, and its one implication was guarded by `step > 0` — false
      // exactly when the defect was present.
      //
      // THREE NUMBERS, NOT ONE, AND THE POINT IS THE RELATION BETWEEN THEM.
      //
      //   ticks  how many the control drew. 48 is `session_view.TimelineTicks`
      //          and is a fixed number by design (a filled bar would need a
      //          per-render `style`, which `tools/design/check-tokens.mjs` A5
      //          refuses), so a count that is not 48 is a control that is not
      //          this control.
      //   at     WHICH tick carries the playhead — 1-based, matching
      //          `markedTick`'s own numbering, and 0 for "no playhead drawn".
      //   on     how many carry the elapsed run BEHIND the playhead.
      //
      // Either of the last two alone is forgeable. A renderer that marked tick 1
      // always satisfies "a playhead exists"; a progress bar with no playhead at
      // all satisfies "the elapsed run grows". Together with the session's own
      // `step`/`totalSteps` they are not: `at` must be the tick that step names
      // and `on` must be exactly the ticks before it, so a step of 128 in a
      // 1315-step trace has to put `.at` on tick 5 of 48 with 4 ticks elapsed,
      // and there is no single wrong answer that satisfies both.
      //
      // `atCount` is separate from `at` deliberately. `at` is a `findIndex` and
      // would report the FIRST of several marked ticks as though it were the
      // only one — resolving a control that had drawn two playheads into a
      // reading that looks correct. The judgement "exactly one" belongs to a
      // journey; this reports what is there.
      //
      // `null` when there is no track, never a zero-filled record: a page with
      // no timeline and a timeline with no playhead are different statements,
      // and a consumer that could not tell them apart would assert over the
      // first believing it was judging the second.
      timeline: (() => {
        const track = document.querySelector(".dctl");
        if (!track) return null;
        const ticks = [...track.querySelectorAll(".tick")];
        return {
          ticks: ticks.length,
          at: ticks.findIndex((t) => t.classList.contains("at")) + 1,
          atCount: ticks.filter((t) => t.classList.contains("at")).length,
          on: ticks.filter((t) => t.classList.contains("on")).length,
          // The affordance, beside the readout, because the two are stamped by
          // different builds: `components/debugger` renders the track on every
          // build and `hydrate.markScrubberSeekable` adds the gesture on the one
          // that can honour it. A journey comparing the served frame with the
          // hydrated one needs both halves from one reading.
          seekable: track.classList.contains("seekable"),
          role: track.getAttribute("role"),
        };
      })(),

      // ---- the frame at large -----------------------------------------------
      paneTitles: [...document.querySelectorAll(".panetitle")].map((e) => e.textContent.trim()),
      reasonText: text(".reason"),
      engineNotice: text("#dbg-engine-failure") ?? "",
      positionNotice: text("#dbg-position-notice") ?? "",

      // ---- rendered vs DOM text; see the header ------------------------------
      visibleText: (document.body?.innerText ?? "").trim().length,
      domText: (document.body?.textContent ?? "").trim().length,

      // ---- the address bar ---------------------------------------------------
      urlPath: location.pathname,
      urlQuery: location.search,
    };
  });

/**
 * Navigate, wait for a condition, and hand back the facts plus the page.
 *
 * `settle` is a predicate over the facts rather than a fixed sleep. A fixed
 * sleep is how a suite comes to measure the machine it runs on; a predicate
 * that never fires is a timeout, and a timeout is reported as one rather than
 * as a product failure — Verification-Harness-Traps.md §3: "a timeout is a
 * symptom, not a diagnosis".
 */
/**
 * The same page, with SCRIPTING OFF — the served frame and nothing else.
 *
 * This exists for exactly one comparison and should not be reached for by
 * anything else. `just export` ships a build with no JS at all, and on the
 * hydrated build the served frame is still what a reader sees until the bundle
 * runs; the source pane opens at the position on that frame through `autofocus`
 * on the marked row plus a `scroll-margin-block-start`, with no code involved.
 *
 * Turning scripting off is the only way to read what THAT mechanism did on its
 * own. With the bundle running, the hydrated reveal has already had its say by
 * the time any probe can look, and the two would be indistinguishable — which is
 * precisely the confusion a journey about their interaction must not be built
 * on.
 *
 * It returns facts only. There is no settling to do: nothing on this page will
 * ever change.
 */
export async function visitWithoutScript(browser, origin, path, { timeoutMs = 45000 } = {}) {
  const context = await browser.newContext({ javaScriptEnabled: false });
  const page = await context.newPage();
  await page.goto(origin + path, { waitUntil: "load", timeout: timeoutMs });
  // `autofocus` scrolls before the first paint, but the READING is a round trip
  // and must see the settled layout rather than race it.
  await page.waitForTimeout(400);
  const facts = await readFacts(page);
  await context.close();
  return facts;
}

export async function visit(
  browser,
  origin,
  path,
  {
    settle = null,
    timeoutMs = 45000,
    // THE SETTLE BUDGET IS NOT THE NAVIGATION TIMEOUT, and it must OUTLIVE the
    // product's own watchdog.
    //
    // These were one number, 45000, and that is exactly `EngineDeadlineMs` in
    // `client/hydrate/hydrate.nim:83`. The watchdog is armed during bundle
    // startup — before `page.goto(…, {waitUntil:"load"})` resolves — so the two
    // countdowns start within milliseconds of each other with the SAME budget,
    // and the product's fires first. `h.fail` then calls `markUnavailable`,
    // which resets `data-session-phase` to `spFetching`: the phase a session
    // that is still ARRIVING also carries. So the harness gave up at the moment
    // the state it was reading had just been tidied, and "the engine is still
    // coming at 45s" and "the engine failed at 45s" produced the same reading.
    //
    // Above it, deliberately, rather than below. Below would make the harness
    // give up first and report a timeout of its own, which is a different way
    // of not knowing. Outliving the watchdog means the failure has ALREADY been
    // written by the time this loop ends, and `facts.engineNotice`
    // (`#dbg-engine-failure`, read by `readFacts`) then carries the product's
    // own sentence naming which of the two faults it was — the engine never
    // loaded, or it loaded and refused the container.
    //
    // THE GENERAL RULE, because "keep the harness budget under the product's"
    // is NOT one and stating it as one would get this line "fixed" back:
    //
    //   BELOW the product's deadline when you need to catch the condition
    //   BEFORE the product tidies it away. A cleared spinner, a reset phase, a
    //   pane the product blanked on giving up — sample after that and you read
    //   the tidy-up and call it success. This is a false PASS and it is
    //   invisible in a green run.
    //
    //   ABOVE it when the product WRITES ITS OWN FAILURE RECORD and you want to
    //   read that record. Giving up first only tells you that you gave up
    //   first; outliving it tells you what happened, in the product's own
    //   words.
    //
    // Which one applies is decided by ONE question — does the product leave
    // evidence behind when its deadline fires? Here it does (`h.fail` ->
    // `#dbg-engine-failure`), so above. Where it does not, go below.
    //
    // 60s = EngineDeadlineMs + 15s. The margin is for the watchdog's own
    // handler to run and paint, not for more waiting.
    settleMs = 60000,
    initScript = null,
    viewport = null,
  } = {},
) {
  // A VIEWPORT ONLY WHEN THE CALLER NAMES ONE, and then it is a fact about the
  // run rather than the launcher's default. It matters for anything read out of
  // a container query: the inline values overlay publishes every pane width's
  // answer at once and the stylesheet picks one, so "how many values are on
  // screen" is a question about a width, and a journey that did not state its
  // width would be measuring whichever one Playwright shipped with. Journeys
  // that name none are byte-for-byte unaffected.
  const page = viewport
    ? await (await browser.newContext({ viewport })).newPage()
    : await browser.newPage();
  const pageErrors = [];
  const consoleErrors = [];
  const consoleLines = [];
  page.on("pageerror", (e) => pageErrors.push(String(e && e.message ? e.message : e)));
  // EVERY LINE, not only the errors — this filter threw away the product's one
  // diagnostic channel.
  //
  // It kept `type() === "error"` and dropped the rest, and the rest is not
  // noise. Measured on one debug route, load only, no stepping: 1099 console
  // messages, of which 23 `log`, 355 `warning`, 721 `info`, and ZERO errors.
  // Everything this filter admitted was empty and everything it rejected was
  // the session describing itself.
  //
  // Two things in there are directly useful to the settle problem this file has
  // elsewhere. The hydration bundle emits `[PIPELINE]` lines — 12 fired in that
  // run, including `updateDebuggerPosition: … setting rrTicks=…` — and the
  // replay engine logs its DAP traffic, `stopped` and `stackTrace` among it. A
  // `stopped` event is the signal a stepping journey actually wants, and it was
  // being discarded by severity while the journeys waited on durations instead.
  //
  // The strings are char-array encoded in the generated `hydrate.js`, which is
  // why a source grep for `console.log` over `client/**/*.nim` finds nothing
  // and why "the product emits no console output" was believed and repeated.
  // It is captured here so the next person can look rather than grep.
  //
  // `consoleErrors` is unchanged and still error-only: callers assert on it.
  page.on("console", (m) => {
    const text = m.text().slice(0, 300);
    consoleLines.push({ type: m.type(), text });
    if (m.type() === "error") consoleErrors.push(text);
  });
  // ATTACHED TO THE PAGE, so a helper that only receives `page` can wait on the
  // product's own announcements. `walk(page)`, `stepOnce(page, before)` and the
  // rest take no visit result, and threading one through every signature to
  // reach a buffer is churn that would put people off using it.
  page.__ctConsole = consoleLines;

  // INSTALLED BEFORE ANY PAGE SCRIPT RUNS, which is the only moment that is any
  // use: the hydration bundle constructs its worker during its own startup, so
  // a wrapper added after navigation would be installed around a `Worker` that
  // had already been built and would observe nothing.
  //
  // It exists because some claims are not visible in the DOM at all. "The click
  // painted a mark" and "the click painted a mark AND told the engine" render
  // identically, and the second is the one a breakpoint journey depends on —
  // the build this repository shipped for months painted nothing and sent
  // nothing, and a DOM-only instrument would have called a mark-only
  // implementation correct. Journeys that need no such reading pass nothing
  // and are byte-for-byte unaffected.
  if (initScript) await page.addInitScript(initScript);

  await page.goto(origin + path, { waitUntil: "load", timeout: timeoutMs });

  let settled = settle === null;
  let timedOut = false;
  if (settle) {
    const deadline = Date.now() + settleMs;
    for (;;) {
      if (settle(await readFacts(page))) {
        settled = true;
        break;
      }
      if (Date.now() > deadline) {
        timedOut = true;
        break;
      }
      await page.waitForTimeout(250);
    }
  }

  return {
    page,
    facts: await readFacts(page),
    pageErrors,
    consoleErrors,
    consoleLines,
    settled,
    timedOut,
  };
}

// ---------------------------------------------------------------------------
// WAITING ON WHAT THE PRODUCT SAYS, rather than on what the DOM has become.
//
// The hydration bundle announces its own pipeline on the console, and until
// this layer stopped filtering by severity nobody could see it. Two lines
// matter here, both measured firing in a live session:
//
//   [PIPELINE] updateDebuggerPosition: storeId=1 setting rrTicks=1 (was 0)
//              file=/aztec/0x….avm line=5
//   [PIPELINE] updateLocals: setting 5 variables
//
// WHY THIS BEATS POLLING THE DOM FOR A CHANGE, which is what the step waits in
// journeys 03, 09 and 16 did. They loop until `step` or `markedNumber` differs
// from before, so they cannot tell "the engine has not answered yet" from "the
// engine answered and the position legitimately did not move" — two steps
// landing on one line, a step at the end of a range. The first is a wait, the
// second is a RESULT, and a loop that treats them alike spins its full 15s and
// then hands back the reading it started with.
//
// `updateDebuggerPosition` is emitted on every stop whether or not anything
// moved, and it carries the tick, the file and the line. So the wait becomes
// "the engine answered this gesture" and the ASSERTION becomes "and here is
// what moved" — which is the separation these journeys were written to have.
// ---------------------------------------------------------------------------

/** How many console lines have been seen. Take before a gesture. */
export function consoleMark(page) {
  return (page.__ctConsole || []).length;
}

/**
 * Wait for a console line matching `test` to arrive AFTER `sinceIndex`.
 *
 * Returns the line, or `null` on timeout — never throws, because a timeout is a
 * result the caller has to be able to report. It DOES throw when no buffer is
 * attached, which is not the same thing: that means the page did not come from
 * `visit()` and the wait would silently be a no-op, which is the shape of check
 * that passes by not running.
 */
export async function waitForConsoleLine(page, test, { sinceIndex = 0, budgetMs = 20000 } = {}) {
  const buf = page.__ctConsole;
  if (!buf) {
    throw new Error(
      "waitForConsoleLine: no console buffer on this page — it did not come from visit()",
    );
  }
  const deadline = Date.now() + budgetMs;
  for (;;) {
    for (let i = sinceIndex; i < buf.length; i += 1) {
      if (test(buf[i].text)) return buf[i].text;
    }
    if (Date.now() >= deadline) return null;
    await page.waitForTimeout(100);
  }
}

/** The engine answered a gesture with a position. */
export const POSITION_ANSWERED = (t) => t.includes("[PIPELINE] updateDebuggerPosition:");

/** The engine answered a position with its locals. */
export const LOCALS_ANSWERED = (t) => t.includes("[PIPELINE] updateLocals:");

/**
 * Poll `readFacts` until `test` holds. Returns the facts either way, plus
 * whether the condition was reached — never a bare boolean, because a caller
 * that times out still has to report WHAT it saw.
 */
export async function waitForFacts(page, test, budgetMs = 8000) {
  const deadline = Date.now() + budgetMs;
  let facts = await readFacts(page);
  while (!test(facts) && Date.now() < deadline) {
    await page.waitForTimeout(100);
    facts = await readFacts(page);
  }
  return { facts, reached: test(facts) };
}

/** The tick `updateDebuggerPosition` says it moved to, or null. */
export function tickOf(positionLine) {
  const m = positionLine && positionLine.match(/rrTicks=(\d+)/);
  return m ? m[1] : null;
}
