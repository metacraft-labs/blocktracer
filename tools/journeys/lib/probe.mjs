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
        })),
      stateNote: document.querySelector("#pane-state .panenote")?.textContent?.trim() ?? "",

      // ---- the stepping controls --------------------------------------------
      controlsLive: count(".dcbtn:not(.off)"),
      controlsInert: count(".dcbtn.off"),
      buttons: count("button"),

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
  { settle = null, timeoutMs = 45000, initScript = null } = {},
) {
  const page = await browser.newPage();
  const pageErrors = [];
  const consoleErrors = [];
  page.on("pageerror", (e) => pageErrors.push(String(e && e.message ? e.message : e)));
  page.on("console", (m) => {
    if (m.type() === "error") consoleErrors.push(m.text().slice(0, 300));
  });

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
    const deadline = Date.now() + timeoutMs;
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

  return { page, facts: await readFacts(page), pageErrors, consoleErrors, settled, timedOut };
}
