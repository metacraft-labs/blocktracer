#!/usr/bin/env node
// VD verification: verify_no_badge_is_clipped_out_of_its_own_cell
//
//   node tools/capture/check-badge-legibility.mjs [--json] [--dist DIR]
//
// WHY THIS EXISTS, AND WHY assertion E COULD NOT HAVE CAUGHT IT.
//
// `check-coverage.mjs`'s assertion E proves every published chain is the
// SUBJECT of a ready view. It says nothing about whether the resulting page can
// be READ. On 2026-09-05 `/aztec-testnet-frames` shipped with a provenance
// label of 37 characters where every other real chain's was 23 —
// `Aztec testnet — live Noir call frames` against `Real Aztec testnet data` —
// and `.badge` is `white-space:nowrap` globally. `nowrap` does not make text
// fit; it makes text that does not fit OVERFLOW. In the transaction pane
// (~380px at `wide`, ~290px at `laptop`) the pill ran off the pane and was cut
// at `live Noir call f`, with no ellipsis to say it had been cut.
//
// That row is the ONLY provenance marker the debugger register has —
// `provenanceMarker` gives that register no nav, no footer and no band — so the
// clipped element was the page's whole claim to be showing real network data.
// A fourteen-character difference in a fixture, and every automated gate in the
// tree was green.
//
// ── THE INSTRUMENT MUST PROVE ITSELF, ON EVERY RUN ────────────────────────
//
// This file's first draft REPORTED NOTHING WITH THE DEFECT PRESENT. It walked
// up to each badge's nearest clipping ancestor and skipped any container whose
// computed `overflow-x` was `auto` or `scroll`, reasoning that such text is
// reachable. But the debugger pane scrolls VERTICALLY, and a box with
// `overflow-y:auto` and `overflow-x:visible` has its `overflow-x` computed to
// `auto` by the cascade — so the walk classified a pill nobody could read as
// "reachable by scrolling" and returned a clean sweep over a broken page.
//
// A gate that cannot fail is worse than no gate, because it is BELIEVED. So
// this one does not merely document that lesson, it re-derives it every run:
// two controls, driven through the SAME detector as the sweep, and a control
// that misbehaves is exit 2 — "the instrument is broken", reported as a
// different thing from "the pages are clean".
//
//   POSITIVE CONTROL. A real `.mddl dd` badge on a real debug page is given a
//   long string and an inline `white-space:nowrap` — the stylesheet as it stood
//   before the fix. The detector MUST report it. If it does not, this file has
//   regressed to its first draft and every clean sweep below is worthless.
//
//   NEGATIVE CONTROL, AND IT IS AN ASSERTION RATHER THAN AN OMISSION. Badges
//   inside `.tablewrap` genuinely do extend past the visible box — measured on
//   the blocks list at 375px, `Unfinalized` sits 99px beyond it — because that
//   container scrolls horizontally ON PURPOSE and the text is reachable. The
//   control first proves such a badge EXISTS and really is outside the box (a
//   control with no subject is vacuous, and vacuous controls are how a suite
//   comes to assert nothing), then requires the detector to stay silent about
//   it. Skipping the case instead would leave a gate that cannot tell a scroll
//   affordance from a clipped word — and a gate that cries wolf over every wide
//   table is a gate that gets switched off inside a week.
//
// ── WHAT IT MEASURES ──────────────────────────────────────────────────────
//
// A badge against ITS OWN GRID CELL — the `dd`, `td`, `th` or `li` it was
// placed in — and not against whatever happens to clip it downstream. That is
// the honest frame: a pill wider than the cell it occupies has overflowed
// regardless of who ends up cutting it, it is measurable without knowing the
// overflow chain, and it does not depend on the scroll behaviour that fooled
// the first draft.
//
// ── COVERAGE, INCLUDING THE HALF THE CORPUS CANNOT SEE ────────────────────
//
// Routes are DERIVED FROM THE BUILT REGISTRY, exactly as assertion E derives
// its chain list, and deliberately not from `views.mjs`. This is the more
// valuable half of the finding: every `tx-detail--*` view resolves through
// `ix.primaryChain`, which is the synthetic chain, so NO captured image shows a
// real chain's transaction page — and that page carries the same provenance row
// that was clipped. A screenshot corpus cannot cover a route nobody added a
// view for; a registry walk covers every chain the tree publishes, including
// ones added after this file was written.
//
// What that does NOT reach is recorded rather than assumed: this walks one
// representative transaction and one address per chain, not every entity, and
// it renders the SERVED page — so a state only a live hydrated session can
// reach is outside it. Those are gaps, and they are stated here so nobody reads
// a green run as more than it is.

import { existsSync } from "node:fs";
import { dirname, join, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";

import { chromium } from "playwright";

import { buildEntityIndex } from "./lib/entities.mjs";
import { serveDist } from "./lib/server.mjs";
import { staleness } from "./lib/build-freshness.mjs";
import { SIZES } from "./views.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");

const EXIT_OK = 0;
const EXIT_FINDINGS = 1;
const EXIT_INSTRUMENT = 2;

function parseArgs(argv) {
  const opts = { json: false, dist: join(REPO_ROOT, "client", "dist") };
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--json") opts.json = true;
    else if (argv[i] === "--dist") opts.dist = resolvePath(argv[++i]);
    else throw new Error(`unknown argument: ${argv[i]}`);
  }
  return opts;
}

/**
 * THE DETECTOR. One function, used by the sweep AND by both controls — which is
 * the whole point: a control that exercised a different code path from the
 * measurement would prove nothing about the measurement.
 *
 * Serialised into the page rather than imported, because it runs in the
 * browser. `.tablewrap` is excluded HERE, at the one place the rule lives, so
 * the negative control below is testing the real exclusion rather than a copy
 * of it.
 */
const DETECTOR = `(() => {
  const out = [];
  for (const el of document.querySelectorAll(".badge")) {
    // A horizontally scrollable table is a scroll affordance, not a clipped
    // word: the reader can reach the text. Asserted by the negative control.
    if (el.closest(".tablewrap")) continue;
    const cell = el.closest("dd, td, th, li") ?? el.parentElement;
    if (!cell || cell === el) continue;
    const b = el.getBoundingClientRect();
    const c = cell.getBoundingClientRect();
    if (b.width === 0 && b.height === 0) continue;   // not rendered
    const overRight = b.right - c.right;
    const overLeft = c.left - b.left;
    if (overRight > 1 || overLeft > 1) {
      out.push({
        text: (el.textContent || "").trim().replace(/\\s+/g, " ").slice(0, 60),
        over: Math.round(Math.max(overRight, overLeft)),
        side: overRight > 1 ? "right" : "left",
        cell: cell.tagName.toLowerCase(),
      });
    }
  }
  return out;
})()`;

/** Does a `.tablewrap` badge really sit outside the visible box? The negative
 *  control's subject check — see the header on vacuous controls. */
const TABLEWRAP_PROBE = `(() => {
  let worst = null;
  for (const el of document.querySelectorAll(".tablewrap .badge")) {
    const wrap = el.closest(".tablewrap");
    const b = el.getBoundingClientRect();
    const w = wrap.getBoundingClientRect();
    const over = b.right - w.right;
    if (over > 1 && (!worst || over > worst.over)) {
      worst = { text: (el.textContent || "").trim(), over: Math.round(over) };
    }
  }
  return worst;
})()`;

/** One representative route of each shape, per published chain. */
function routesFrom(ix) {
  const routes = [
    ["site: home", "/"],
    ["site: chains", "/chains"],
    ["site: about", "/about"],
  ];
  for (const chain of ix.chains) {
    const c = ix.byChain[chain];
    routes.push([`${chain}: overview`, `/${chain}`]);
    routes.push([`${chain}: blocks`, `/${chain}/blocks`]);
    routes.push([`${chain}: txs`, `/${chain}/txs`]);
    // Prefer a transaction whose trace opens a session: it is the one whose
    // pages carry the most rows, and the debug route only exists for it.
    const tx = c.txs.find((t) => t.availability === "ready") ?? c.txs[0];
    if (tx) {
      routes.push([`${chain}: tx detail`, `/${chain}/tx/${tx.hash}`]);
      routes.push([`${chain}: debug`, `/${chain}/tx/${tx.hash}/debug?t=1`]);
    }
    const addr = c.addresses[0];
    if (addr) routes.push([`${chain}: address`, `/${chain}/address/${addr}`]);
  }
  return routes;
}

async function measure(page, origin, route, width, height) {
  const ctxPage = page;
  await ctxPage.setViewportSize({ width, height });
  const res = await ctxPage.goto(origin + route, { waitUntil: "load" });
  if (!res || res.status() >= 400) return { status: res ? res.status() : 0, findings: [] };
  return { status: res.status(), findings: await ctxPage.evaluate(DETECTOR) };
}

async function main() {
  const opts = parseArgs(process.argv);
  const log = (s) => { if (!opts.json) console.log(s); };

  // NOT RUN rather than PASS, for the reason assertion E refuses a missing
  // build: a check that goes green because it could not find anything to
  // inspect is the failure this file is about.
  if (!existsSync(join(opts.dist, "registry", "chains.v1.json"))) {
    const msg = `no built data plane at ${opts.dist} — run the exporter first`;
    if (opts.json) console.log(JSON.stringify({ status: "not-run", reason: msg }, null, 2));
    else console.log(`NOT RUN — ${msg}`);
    return EXIT_INSTRUMENT;
  }
  const stale = staleness(opts.dist, REPO_ROOT);
  if (stale !== null && stale.why === "stale") {
    const msg =
      `the data plane at ${opts.dist} is not one this source could have produced — ` +
      `${stale.message}. Re-export first.`;
    if (opts.json) console.log(JSON.stringify({ status: "not-run", reason: msg }, null, 2));
    else console.log(`NOT RUN — ${msg}`);
    return EXIT_INSTRUMENT;
  }

  const ix = buildEntityIndex(opts.dist);
  const routes = routesFrom(ix);
  const sizes = Object.entries(SIZES);

  const server = await serveDist(opts.dist);
  const browser = await chromium.launch();
  const context = await browser.newContext();
  const page = await context.newPage();

  const report = {
    check: "verify_no_badge_is_clipped_out_of_its_own_cell",
    dist: opts.dist,
    chains: ix.chains,
    routes: routes.length,
    viewports: sizes.map(([n]) => n),
    controls: {},
    findings: [],
  };
  const instrumentProblems = [];

  try {
    // ── CONTROLS FIRST. A sweep whose detector has not been shown to work is
    //    not evidence, so nothing below is believed until these two pass.
    const debugRoute = routes.find(([label]) => label.endsWith(": debug"));
    if (!debugRoute) {
      instrumentProblems.push(
        "no debug route in the built tree, so the positive control has no subject");
    } else {
      await page.setViewportSize({ width: 1440, height: 900 });
      await page.goto(server.origin + debugRoute[1], { waitUntil: "load" });
      const planted = await page.evaluate(() => {
        const dd = [...document.querySelectorAll(".mddl dd")]
          .find((d) => d.querySelector(".badge"));
        if (!dd) return false;
        const badge = dd.querySelector(".badge");
        // The stylesheet exactly as it stood before the fix.
        badge.style.whiteSpace = "nowrap";
        badge.textContent =
          "A provenance label long enough that it cannot fit in this cell at any width";
        return true;
      });
      if (!planted) {
        instrumentProblems.push(
          `no .mddl dd carrying a badge on ${debugRoute[1]} — the positive control ` +
          `has no subject, so the detector was never exercised`);
      } else {
        const seen = await page.evaluate(DETECTOR);
        report.controls.positive = { planted: true, detected: seen.length };
        if (seen.length === 0) {
          instrumentProblems.push(
            "POSITIVE CONTROL FAILED: a badge forced to nowrap and overfilled was " +
            "NOT reported. The detector cannot see the defect it exists to find — " +
            "this is exactly the first draft's failure, where the sweep came back " +
            "clean over a page whose provenance label was cut mid-word. Every " +
            "clean result below is void.");
        }
      }

      // ── NEGATIVE CONTROL: the scroll affordance, asserted not avoided.
      const blocksRoute = routes.find(([label]) => label.endsWith(": blocks"));
      if (!blocksRoute) {
        instrumentProblems.push(
          "no blocks list in the built tree, so the negative control has no subject");
      } else {
        await page.setViewportSize({ width: 375, height: 812 });
        await page.goto(server.origin + blocksRoute[1], { waitUntil: "load" });
        const outside = await page.evaluate(TABLEWRAP_PROBE);
        const quiet = await page.evaluate(DETECTOR);
        report.controls.negative = { subject: outside, reported: quiet.length };
        if (!outside) {
          instrumentProblems.push(
            `NEGATIVE CONTROL IS VACUOUS: no badge on ${blocksRoute[1]} at 375px ` +
            `actually extends past its .tablewrap, so "the detector stays quiet ` +
            `about scrollable tables" was asserted over nothing. Re-point it at a ` +
            `table that really does overflow.`);
        } else if (quiet.length > 0) {
          instrumentProblems.push(
            `NEGATIVE CONTROL FAILED: the detector reported ${quiet.length} finding(s) ` +
            `on a horizontally scrollable table, where "${outside.text}" sits ` +
            `${outside.over}px outside the visible box BUT IS REACHABLE BY SCROLLING. ` +
            `A gate that cannot tell a scroll affordance from a clipped word gets ` +
            `switched off.`);
        }
      }
    }

    if (instrumentProblems.length === 0) {
      // ── THE SWEEP ────────────────────────────────────────────────────────
      for (const [label, route] of routes) {
        for (const [sizeName, s] of sizes) {
          const { status, findings } = await measure(page, server.origin, route, s.width, s.height);
          if (status >= 400 || status === 0) continue;   // route not published
          for (const f of findings) {
            report.findings.push({ label, route, size: sizeName, ...f });
          }
        }
      }
    }
  } finally {
    await context.close();
    await browser.close();
    await server.close();
  }

  if (opts.json) {
    console.log(JSON.stringify({ ...report, instrumentProblems }, null, 2));
  } else {
    log(`dist:       ${opts.dist}`);
    log(`chains:     ${ix.chains.join(", ")}`);
    log(`routes:     ${routes.length} (derived from the registry, not from views.mjs)`);
    log(`viewports:  ${sizes.map(([n, s]) => `${n} ${s.width}px`).join(", ")}`);
    if (report.controls.positive)
      log(`control +:  planted overflow reported ${report.controls.positive.detected} time(s)`);
    if (report.controls.negative)
      log(`control -:  "${report.controls.negative.subject?.text ?? "(none)"}" ` +
          `${report.controls.negative.subject?.over ?? 0}px outside a scrolling table, ` +
          `reported ${report.controls.negative.reported} time(s)`);
    log("");
    if (instrumentProblems.length) {
      log(`INSTRUMENT BROKEN — ${instrumentProblems.length} problem(s); THE SWEEP DID NOT RUN:`);
      for (const p of instrumentProblems) log(`  ! ${p}`);
    } else if (report.findings.length) {
      log(`FAIL — ${report.findings.length} badge(s) clipped out of their own cell:`);
      for (const f of report.findings) {
        log(`  ${f.route} @${f.size}`);
        log(`      "${f.text}" overflows its <${f.cell}> by ${f.over}px ${f.side}`);
      }
      log("");
      log("`.badge` is white-space:nowrap globally, which is right for a status word");
      log("and wrong for producer-supplied text. Do NOT widen the pane or shorten the");
      log("fixture to make this green — let the pill wrap where its text is unbounded.");
    } else {
      log(`PASS — no badge is clipped out of its own cell ` +
          `(${routes.length} route(s) x ${sizes.length} viewport(s), both controls held)`);
    }
  }

  if (instrumentProblems.length) return EXIT_INSTRUMENT;
  return report.findings.length ? EXIT_FINDINGS : EXIT_OK;
}

main()
  .then((c) => process.exit(c))
  .catch((e) => {
    console.error(`badge-legibility check failed: ${e.message}`);
    process.exit(EXIT_INSTRUMENT);
  });
