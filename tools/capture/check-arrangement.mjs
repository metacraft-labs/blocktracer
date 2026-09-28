#!/usr/bin/env node
// verify_the_arrangement_did_not_move — a two-tree element-geometry diff.
//
// ## Why this exists
//
// The operator's constraint on both finish passes over the explorer register is
// one sentence: "The special arrangement on the blockexplorer page stays (i.e.
// the top bar, the transaction details panel, etc)." Until now the evidence for
// it was a person reading before/after captures, and docs/EXPLORER-TINT.md §5
// says so in as many words: "Structural identity was then read by eye on five
// before/after pairs … That is a sample, not a proof; there is no automated
// check that could make it one."
//
// This is that check. It is not a perceptual comparison and it deliberately
// does not look at a single pixel — a finish pass is ALLOWED to change every
// pixel. What it must not change is where anything sits, how many of anything
// there are, or what order they come in. So this measures the page-absolute box
// of every structural element in two built trees and prints every box that
// differs, with its before and after.
//
// It is NOT a gate and it is not in CI, for a reason that is a property of the
// check and not an omission: it needs a SECOND build to compare against, and CI
// has one tree. It is run by hand across a change, and its output is the
// evidence a reviewer reads instead of the sentence "I verified the layout".
//
// ## What a difference means
//
// Three kinds, and only the first is a failure of the constraint:
//
//   * a box whose x or width moved, or a COUNT that changed, or a DOM-order
//     change — something was moved, resized, added, removed or reordered;
//   * a box whose y moved by the same amount as everything below it — something
//     above it changed height, which is a knock-on and not a move;
//   * a box whose height changed by a pixel or two — a line box grew, usually
//     because an inline element's vertical alignment changed.
//
// The tool does not classify them, because classifying them is the reading and
// the reading belongs in the change's own document. It prints them.
//
// ## Usage
//
//   node tools/capture/check-arrangement.mjs <before-dist> <after-dist> [routes.json]
//
// Build the two trees with the same exporter, e.g.
//
//   git stash push -- <the changed file>
//   (cd client && just export) && cp -R client/dist /tmp/dist-before
//   git stash pop
//   (cd client && just export)
//   node tools/capture/check-arrangement.mjs /tmp/dist-before client/dist
//
// Exit 0 when every box is identical, 1 when anything moved, 2 when the tool
// could not run — a missing tree, a route that does not resolve. The three are
// distinct for the reason tools/capture/require-deterministic.mjs gives about
// its own five refusals: "nobody can tell" is a different verdict from "it
// changed", and collapsing them produces exactly the failure the check exists
// to prevent.

import { existsSync } from "node:fs";
import { chromium } from "playwright";
import { serveDist } from "./lib/server.mjs";

// The routes are the explorer's shapes rather than all 348 pages: one of each
// kind is what the constraint is about, and a per-page sweep would measure the
// demo generator's row counts rather than the arrangement.
const DEFAULT_ROUTES = [
  "/",
  "/chains",
  "/demo",
  "/demo/txs",
  "/demo/tx/0x27a6c250bda5f426cac12790abe9cff80fb29a6c",
  "/demo/address/0x10ebe5500330a167fd7fd88b2aa67bf9d3d799e5/code",
  "/demo/tx/0x0000000000000000000000000000000000000000",
];

// Every structural element the constraint names, plus the scaffolding each page
// is built out of. The two the operator called out BY NAME lead the list, and
// they are enumerated part by part rather than as one box: a nav whose outer
// box is unchanged while the brand and the field inside it have swapped places
// would pass a one-box check and fail the instruction.
const SELECTORS = [
  // the top bar, part by part
  ".nav", ".nav .inner", ".nav .brand", ".nav form", ".nav input", ".nav .links",
  // the transaction details panel, row by row
  ".dl", ".dl dt", ".dl dd",
  // the page scaffolding
  "html", "body", ".pagebody", ".pagebody > .inner",
  "section.sec", "section.sec > .inner",
  // everything else that occupies space on an explorer page
  ".crumbs", ".eyebrow", "h1", ".sec-title", ".lead", ".measure",
  ".hero", ".search", ".search input", ".chainstrip", ".chaincard",
  ".stats", ".stat", ".titlerow", ".badgerow", ".copyfield",
  ".tablewrap", "table.tbl", "table.tbl thead", "table.tbl tbody",
  "table.tbl tr", "table.tbl th", "table.tbl td", ".empty",
  ".debugcard", ".notice", ".noticehead", ".provchip", ".stub", ".execlist",
  ".filetree", ".filetree a", ".codefile", ".codehead", ".codeview", ".codeline",
  ".pager", ".pagerbtns", ".btn", ".badge", ".linklist", ".linkrow",
  ".foot", ".foot .inner", ".footlinks", ".footcredit",
  // the product-register embed, which an explorer change must not disturb
  ".livedemo",
];

function fail(msg) { console.error(msg); process.exit(2); }

const [beforeDist, afterDist, routesFile] = process.argv.slice(2);
if (!beforeDist || !afterDist) fail("usage: check-arrangement.mjs <before-dist> <after-dist> [routes.json]");
for (const d of [beforeDist, afterDist]) if (!existsSync(d)) fail(`not a built tree: ${d}`);

let routes = DEFAULT_ROUTES;
if (routesFile) {
  const { readFileSync } = await import("node:fs");
  routes = JSON.parse(readFileSync(routesFile, "utf8"));
}

async function measure(page, origin, route) {
  const res = await page.goto(origin + route, { waitUntil: "load" });
  // A 404 is not a refusal here: §14's "not on this chain" IS an explorer
  // surface, it is served as `404.html` under its real status, and it is one of
  // the routes below. What must not be tolerated is nothing at all, or a
  // server error, because both render a page that is not the product's.
  if (!res) fail(`${route} returned no response in one of the trees`);
  if (res.status() >= 500) fail(`${route} answered ${res.status()} in one of the trees`);
  // Fonts decide line boxes, and a box measured before they load is a
  // measurement of the fallback stack.
  await page.evaluate(() => document.fonts.ready);
  return page.evaluate((sels) => {
    const out = {};
    for (const sel of sels) {
      out[sel] = [...document.querySelectorAll(sel)].map((n) => {
        const r = n.getBoundingClientRect();
        return [r.x + scrollX, r.y + scrollY, r.width, r.height].map(Math.round).join(",");
      });
    }
    // Not geometry: the document's own shape. A rule cannot change this, so a
    // difference here means a VIEW changed and the diff below is measuring two
    // different pages.
    out.__shape = [...document.querySelectorAll("body *")]
      .map((n) => n.tagName.toLowerCase() + "." + String(n.className || "").trim().replace(/\s+/g, "."))
      .join("|");
    return out;
  }, SELECTORS);
}

async function readTree(dist) {
  const server = await serveDist(dist);
  const browser = await chromium.launch({
    args: ["--hide-scrollbars", "--force-device-scale-factor=1", "--disable-lcd-text"],
  });
  const ctx = await browser.newContext({
    viewport: { width: 1920, height: 1080 },
    reducedMotion: "reduce",
    timezoneId: "UTC",
    locale: "en-US",
  });
  const page = await ctx.newPage();
  const out = {};
  for (const r of routes) out[r] = await measure(page, server.origin, r);
  await browser.close();
  await server.close();
  return out;
}

const before = await readTree(beforeDist);
const after = await readTree(afterDist);

let compared = 0, unchanged = 0, moved = 0, shapeChanges = 0;
for (const route of routes) {
  const A = before[route], B = after[route];
  const diffs = [];
  if (A.__shape !== B.__shape) { diffs.push("  THE DOCUMENT'S OWN SHAPE CHANGED — these are two different pages, not two finishes of one"); shapeChanges++; }
  for (const sel of SELECTORS) {
    const x = A[sel] || [], y = B[sel] || [];
    compared += Math.max(x.length, y.length);
    if (x.length !== y.length) { diffs.push(`  ${sel}: COUNT ${x.length} -> ${y.length}`); moved += Math.max(x.length, y.length); continue; }
    for (let i = 0; i < x.length; i++) {
      if (x[i] === y[i]) unchanged++;
      else { diffs.push(`  ${sel}[${i}]: ${x[i]} -> ${y[i]}`); moved++; }
    }
  }
  console.log(`\n${route}  ${diffs.length ? diffs.length + " difference(s)" : "IDENTICAL"}`);
  for (const d of diffs) console.log(d);
}

console.log(`\nroutes ${routes.length}   boxes ${compared}   unchanged ${unchanged}   differing ${moved}   document-shape changes ${shapeChanges}`);
console.log(moved || shapeChanges
  ? "DIFFERENCES — read each one against the change; x, width, count and shape are never finish"
  : "UNCHANGED — every box in every route is in the same place, at the same size");
process.exit(moved || shapeChanges ? 1 : 0);
