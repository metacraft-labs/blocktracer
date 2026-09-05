#!/usr/bin/env node
// VD verification: verify_copy_result_is_shown_without_colour_alone
//
//   node tools/capture/check-copy-affordance.mjs [--json] [--dist DIR]
//
// WHAT H2 ESTABLISHES, AND THE PART IT STRUCTURALLY CANNOT.
//
// `check-hydration-divergence.mjs`'s H2 asserts that every class the shipped
// bundle adds has a rule in the stylesheet those pages inline. It found
// `.copybtn`, `.copied` and `.copyfailed` undrawn — a real defect, because
// `hydrate.nim`'s `bindCopy` writes:
//
//     e.classList.add(if ok: "copied" else: "copyfailed")
//
// directly under a comment promising "The result is SHOWN, both ways …  a copy
// control that silently failed would be the affordance-that-lies defect wearing
// a tick". Nothing drew either class, so neither result was shown and a copy
// that failed — `writeText` rejects in a non-secure context and when the
// document is not focused — said nothing at all.
//
// BUT H2 IS A TEXTUAL PRESENCE TEST, AND CAN BE SATISFIED BY A RULE THAT DRAWS
// NOTHING. `stylesheetDrawsClass` is one regex for `.<name>` over the
// comment-stripped stylesheet, so `.copied{}` — an empty rule — turns H2 green
// while changing not one pixel. That is not a criticism of H2, which is
// answering "can the page draw this at all"; it is the reason this file exists,
// and the gap is recorded here rather than left for someone to discover by
// shipping an empty rule. This check asserts what H2 cannot: that the three
// states RENDER, that they render DIFFERENTLY FROM EACH OTHER, and that the
// difference survives the removal of colour.
//
// ── WHY "WITHOUT COLOUR ALONE" IS THE ASSERTION AND NOT A GUIDELINE ───────
//
// This project has already shipped contrast defects that made a state
// invisible in one theme. A green tick and a red cross that are otherwise
// identical glyphs are exactly that defect waiting to happen: they read as
// distinct to most people on a good monitor in light mode, and as one
// undifferentiated mark otherwise. So the check reads each state's `::after`
// content — the TEXT channel — and requires it to be non-empty and different
// between the two results, and then confirms empirically that a greyscale
// rasterisation of the element still differs. Colour may carry the meaning
// SECOND; it may not carry it alone.
//
// ── THE INSTRUMENT PROVES ITSELF, SAME PATTERN AS check-badge-legibility ──
//
// Exit 2 is "the instrument is broken", a distinct verdict from exit 1, "a
// state is not drawn". Two controls run before the assertions:
//
//   NEGATIVE  the same element photographed twice in the same state must be
//             BYTE-IDENTICAL. Without this, antialiasing noise would make
//             every comparison "different" and the whole check would pass by
//             accident, reporting nothing whatever the stylesheet said.
//   POSITIVE  with `::after { content:'' }` injected — the exact shape of the
//             defect this file guards, a rule present but drawing no text —
//             the check MUST report it. If it does not, it cannot see the
//             regression it exists to catch.
//
// This tests THE STYLESHEET, by applying the classes directly. That the bundle
// actually adds them is H2's question, and the two are complementary: H2 owns
// "the page can draw it", this owns "what it draws means something".

import { existsSync } from "node:fs";
import { dirname, join, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";

import { chromium } from "playwright";

import { buildEntityIndex } from "./lib/entities.mjs";
import { serveDist } from "./lib/server.mjs";
import { THEMES } from "./views.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");

const EXIT_OK = 0;
const EXIT_FINDINGS = 1;
const EXIT_INSTRUMENT = 2;

/** The states `bindCopy` produces, in the order a visitor meets them. */
const RESULT_STATES = ["copied", "copyfailed"];

function parseArgs(argv) {
  const opts = { json: false, dist: join(REPO_ROOT, "client", "dist") };
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--json") opts.json = true;
    else if (argv[i] === "--dist") opts.dist = resolvePath(argv[++i]);
    else throw new Error(`unknown argument: ${argv[i]}`);
  }
  return opts;
}

/** THE CLIP IS COMPUTED ONCE AND REUSED FOR EVERY STATE.
 *
 *  It used to be recomputed per shot from the element's own bounding box, and
 *  that made the check's own positive control fail: an `::after` with
 *  `content:''` still generates a box, its `margin-left` widens the
 *  `inline-block` it sits in, the element's rect moves, and a clip derived from
 *  that rect photographs a DIFFERENT REGION OF THE SCREEN. Every comparison was
 *  then "these differ" for a reason that had nothing to do with whether
 *  anything was drawn — which is the same class of fault as measuring a badge
 *  against a scroll container: an instrument reporting on its own frame of
 *  reference rather than on the product. A fixed rectangle is the fix. */
async function clipFor(page) {
  const box = await (await page.$("[data-copy]")).boundingBox();
  return {
    x: Math.max(0, box.x - 4),
    y: Math.max(0, box.y - 4),
    // Wide enough to include the marker, which is an ::after OUTSIDE the
    // element's own text: clipping to the element's rect would photograph the
    // defect away.
    width: Math.min(box.width + 320, page.viewportSize().width - box.x),
    height: box.height + 8,
  };
}

/** Put the element in one state and photograph the fixed region. */
async function shoot(page, clip, { classes = [], grayscale = false } = {}) {
  await page.evaluate(
    ({ classes, grayscale }) => {
      const el = document.querySelector("[data-copy]");
      el.className = el.dataset.btBaseClass;
      for (const c of classes) el.classList.add(c);
      document.documentElement.style.filter = grayscale ? "grayscale(1)" : "";
    },
    { classes, grayscale },
  );
  return page.screenshot({ clip });
}

async function afterContent(page, classes) {
  return page.evaluate((classes) => {
    const el = document.querySelector("[data-copy]");
    el.className = el.dataset.btBaseClass;
    for (const c of classes) el.classList.add(c);
    return getComputedStyle(el, "::after").content;
  }, classes);
}

async function main() {
  const opts = parseArgs(process.argv);
  const log = (s) => { if (!opts.json) console.log(s); };

  if (!existsSync(join(opts.dist, "registry", "chains.v1.json"))) {
    const msg = `no built data plane at ${opts.dist} — run the exporter first`;
    if (opts.json) console.log(JSON.stringify({ status: "not-run", reason: msg }, null, 2));
    else console.log(`NOT RUN — ${msg}`);
    return EXIT_INSTRUMENT;
  }

  const ix = buildEntityIndex(opts.dist);
  // Any transaction page carries the truncated hash with `data-copy`.
  const chain = ix.primaryChain;
  const tx = ix.byChain[chain].txs[0];
  if (!tx) {
    console.log(`NOT RUN — no transaction on "${chain}" to carry a copy affordance`);
    return EXIT_INSTRUMENT;
  }
  const route = `/${chain}/tx/${tx.hash}`;

  const server = await serveDist(opts.dist);
  const browser = await chromium.launch();
  const problems = [];
  const instrumentProblems = [];
  const observed = {};

  try {
    for (const theme of THEMES) {
      const ctx = await browser.newContext({
        viewport: { width: 1440, height: 900 },
        colorScheme: theme,
      });
      const page = await ctx.newPage();
      await page.emulateMedia({ colorScheme: theme });
      await page.goto(server.origin + route, { waitUntil: "load" });
      await page.evaluate((t) => {
        document.documentElement.setAttribute("data-theme", t);
        const el = document.querySelector("[data-copy]");
        if (el) el.dataset.btBaseClass = el.className;
      }, theme);

      if (!(await page.$("[data-copy]"))) {
        instrumentProblems.push(
          `no [data-copy] element on ${route} — the check has no subject, so ` +
          `nothing about the copy affordance was tested`);
        await ctx.close();
        continue;
      }

      // The frame every comparison in this theme is measured against.
      const clip = await clipFor(page);

      // ── NEGATIVE CONTROL: the same state twice must be byte-identical.
      const twiceA = await shoot(page, clip, { classes: ["copybtn"] });
      const twiceB = await shoot(page, clip, { classes: ["copybtn"] });
      if (!twiceA.equals(twiceB)) {
        instrumentProblems.push(
          `NEGATIVE CONTROL FAILED (${theme}): the same element in the same state ` +
          `photographed twice was not byte-identical, so every "these states differ" ` +
          `result below could be rendering noise rather than a stylesheet rule.`);
      }

      const base = await shoot(page, clip, { classes: ["copybtn"] });
      const baseGrey = await shoot(page, clip, { classes: ["copybtn"], grayscale: true });
      const shots = {};
      for (const st of RESULT_STATES) {
        shots[st] = {
          colour: await shoot(page, clip, { classes: ["copybtn", st] }),
          grey: await shoot(page, clip, { classes: ["copybtn", st], grayscale: true }),
          after: await afterContent(page, ["copybtn", st]),
        };
      }
      observed[theme] = Object.fromEntries(
        RESULT_STATES.map((st) => [st, shots[st].after]));

      // ── POSITIVE CONTROL: blind the marker exactly as an empty rule would.
      await page.addStyleTag({
        content: `.copied::after,.copyfailed::after{content:'' !important}`,
      });
      const blinded = await shoot(page, clip, { classes: ["copybtn", "copied"], grayscale: true });
      if (!blinded.equals(baseGrey)) {
        instrumentProblems.push(
          `POSITIVE CONTROL FAILED (${theme}): with the result marker's content ` +
          `emptied — the exact shape of an H2-satisfying rule that draws nothing — ` +
          `the greyscale rendering still differed from the base state, so this ` +
          `check cannot tell a drawn state from an undrawn one.`);
      }
      await page.reload({ waitUntil: "load" });   // drop the injected style
      await page.evaluate((t) => {
        document.documentElement.setAttribute("data-theme", t);
        const el = document.querySelector("[data-copy]");
        if (el) el.dataset.btBaseClass = el.className;
      }, theme);

      // ── THE ASSERTIONS ──────────────────────────────────────────────────
      for (const st of RESULT_STATES) {
        const s = shots[st];
        if (s.colour.equals(base)) {
          problems.push(
            `${theme}: .${st} renders IDENTICALLY to the un-clicked control. The ` +
            `state is not drawn at all — a visitor who pressed copy is told nothing.`);
          continue;
        }
        if (s.grey.equals(baseGrey)) {
          problems.push(
            `${theme}: .${st} differs from the control ONLY IN COLOUR — with colour ` +
            `removed the two are byte-identical. Colour may carry this second, not ` +
            `alone; add a glyph or a word.`);
        }
        if (!s.after || s.after === "none" || s.after === '""' || s.after === "''") {
          problems.push(
            `${theme}: .${st} has no ::after text, so the only channel left is ` +
            `colour. The result must say something a reader can read.`);
        }
      }
      // The two RESULTS must differ from each other, not merely from the base:
      // "it worked" and "it did not" are the pair §14.1a exists to keep apart.
      const [ok, bad] = RESULT_STATES;
      if (shots[ok].grey.equals(shots[bad].grey)) {
        problems.push(
          `${theme}: .${ok} and .${bad} are indistinguishable with colour removed. ` +
          `Success and failure would read as one state to anyone who cannot rely ` +
          `on hue — which is the affordance-that-lies defect wearing a tick.`);
      }
      if (shots[ok].after === shots[bad].after) {
        problems.push(
          `${theme}: .${ok} and .${bad} render the same ::after text ` +
          `(${shots[ok].after}). A copy that failed would claim it succeeded.`);
      }

      await ctx.close();
    }
  } finally {
    await browser.close();
    await server.close();
  }

  if (opts.json) {
    console.log(JSON.stringify({ route, observed, problems, instrumentProblems }, null, 2));
  } else {
    log(`route:      ${route}`);
    log(`themes:     ${THEMES.join(", ")}`);
    for (const [theme, states] of Object.entries(observed)) {
      for (const [st, content] of Object.entries(states)) {
        log(`  ${theme.padEnd(6)} .${st.padEnd(11)} ::after ${content}`);
      }
    }
    log("");
    if (instrumentProblems.length) {
      log(`INSTRUMENT BROKEN — ${instrumentProblems.length} problem(s); the verdict below is void:`);
      for (const p of instrumentProblems) log(`  ! ${p}`);
    } else if (problems.length) {
      log(`FAIL — ${problems.length} problem(s) with the copy affordance:`);
      for (const p of problems) log(`  ${p}`);
    } else {
      log(`PASS — both copy results are drawn, differ from the control and from ` +
          `each other, and stay distinct with colour removed (${THEMES.length} theme(s))`);
    }
  }

  if (instrumentProblems.length) return EXIT_INSTRUMENT;
  return problems.length ? EXIT_FINDINGS : EXIT_OK;
}

main()
  .then((c) => process.exit(c))
  .catch((e) => {
    console.error(`copy-affordance check failed: ${e.message}`);
    process.exit(EXIT_INSTRUMENT);
  });
