#!/usr/bin/env node
// Deploy gate — a published recording and the page that should offer it must
// agree about each other.
//
//   node tools/deploy/check-recordings-named.mjs --dir site
//   node tools/deploy/check-recordings-named.mjs --dir site --live-origin <dir>
//
// ── Why this exists, as the thing that happened ────────────────────────────
//
// Run 41420602459 published the whole site over production's data plane and
// left every Aztec transaction serving an empty `data-trace`. Every post-check
// in `publish-r2.yml` passed, and each was right about what it asked: the
// containers were uploaded, the pointers were byte-identical to the bucket's,
// the global index had not shrunk, and the bucket held every site key the tree
// did. NOTHING COMPARED A PAGE AGAINST THE CONTAINER IT SHOULD HAVE NAMED, so a
// tree whose recordings and pages disagreed was indistinguishable from a
// correct one.
//
// The cause was one missing prefix in the staging loop: without `registry/` on
// the data origin, `blocktracer_client/trace.resolveExec` cannot derive a trace
// address (`if not session.hasPin: trkUnresolvable`), `containerPath` stays
// empty, `session_view.canShare` is false, and `pages/debug` writes
// `data-trace=""` — which is how a page declines the engine. Silently.
//
// ── The two claims, and why they are two ──────────────────────────────────
//
// R1  Every transaction whose TraceSelection overlay says `availability:
//     "ready"` has a debug page whose `data-trace` names a container.
//
//     The overlay is the PRODUCER saying a recording is published; `data-trace`
//     is the PAGE offering it to the engine. Different code, different inputs —
//     which is the whole reason comparing them is worth anything.
//
// R2  Every container a page names RESOLVES — in this tree, or in the staged
//     copy of the live bucket when there is one.
//
//     R1 alone would pass a tree whose pages name containers that do not exist:
//     it only looks at the rows the overlay calls ready. R2 is the converse and
//     it is the claim that covers a DIVERGENT row — one whose validation is not
//     `match` — whose page names a container anyway. That case is REPORTED
//     rather than refused: a divergent recording is a real recording and the
//     product may legitimately offer its bytes; what must never happen is a
//     page naming bytes nobody holds. Suggested by the Aptos producer's author,
//     whose tree has two divergent rows and two replayed ones.
//
// On a `render-over-live` publish the containers are the live bucket's and this
// tree carries none of them, which is why `--live-origin` exists and why
// `check-assets.mjs` A1 stops counting those references when
// `--require-traces` is absent. R2 is where that coverage went.
//
// ── It refuses to pass over nothing ───────────────────────────────────────
//
// No chain pointer, or no ready overlay anywhere, exits 1 rather than reporting
// success over an empty set — `tools/journeys/README.md` rule 3, "a test whose
// subject can be empty passes vacuously", which this repository has been bitten
// by often enough to spell out.

import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

export function parseArgs(argv) {
  const o = { dir: "site", liveOrigin: "" };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--dir") o.dir = argv[++i];
    else if (argv[i] === "--live-origin") o.liveOrigin = argv[++i];
    else if (argv[i] === "--help" || argv[i] === "-h") o.help = true;
    else return { error: `unknown argument: ${argv[i]}` };
  }
  return o;
}

const dirs = (p) => {
  try {
    return readdirSync(p, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name).sort();
  } catch { return []; }
};
const files = (p) => {
  try {
    return readdirSync(p, { withFileTypes: true }).filter((d) => d.isFile()).map((d) => d.name).sort();
  } catch { return []; }
};
const readJson = (p) => { try { return JSON.parse(readFileSync(p, "utf8")); } catch { return null; } };

export function run({ dir, liveOrigin }) {
  const roots = [dir, ...(liveOrigin && existsSync(liveOrigin) ? [liveOrigin] : [])];
  const resolvesIn = (ref) => roots.some((r) => existsSync(join(r, ref)));

  const chains = [];
  const problems = [];
  let readyTotal = 0, namedTotal = 0, resolvedTotal = 0, divergentNamed = 0;

  for (const chain of dirs(join(dir, "d"))) {
    const cur = readJson(join(dir, "d", chain, "current.json"));
    if (cur === null) { problems.push(`${chain}: current.json is missing or unreadable`); continue; }
    const ver = String(cur.traceSelectionVersion ?? "");
    if (!ver) { problems.push(`${chain}: current.json names no traceSelectionVersion`); continue; }

    let ready = 0, named = 0, divergent = 0;
    const tsRoot = join(dir, "d", chain, "ts", ver);
    for (const shard of dirs(tsRoot)) {
      for (const name of files(join(tsRoot, shard))) {
        if (!name.endsWith(".json")) continue;
        const o = readJson(join(tsRoot, shard, name));
        const trace = o?.trace ?? {};
        const tx = o?.tx ?? name.replace(/\.json$/, "");
        const isReady = trace.availability === "ready";
        const isDivergent = trace.validation != null && trace.validation.status !== "match";
        const page = join(dir, chain, "tx", tx, "debug", "index.html");

        if (isReady) ready += 1;
        if (!isReady && !existsSync(page)) continue;

        if (!existsSync(page)) {
          problems.push(`${chain} ${tx}: overlay says ready and there is no debug page`);
          continue;
        }
        const html = readFileSync(page, "utf8");
        const m = /data-trace="([^"]*)"/.exec(html);
        const ref = m ? m[1].replace(/^\//, "") : null;

        // R1 — a ready recording must be offered.
        if (isReady) {
          if (m === null) problems.push(`${chain} ${tx}: page carries no data-trace attribute at all`);
          else if (ref === "") problems.push(`${chain} ${tx}: overlay says ready, page declines the engine (empty data-trace)`);
        }
        // R2 — whatever a page names must resolve, ready or not.
        if (ref) {
          named += 1;
          if (isDivergent) divergent += 1;
          if (resolvesIn(ref)) resolvedTotal += 1;
          else problems.push(`${chain} ${tx}: page names ${ref} and no root holds it (looked in ${roots.join(", ")})`);
        }
      }
    }
    readyTotal += ready; namedTotal += named; divergentNamed += divergent;
    chains.push({ chain, ready, named, divergent });
    console.log(`  ${chain}: ${ready} ready, ${named} named by a page${divergent ? `, ${divergent} of them divergent` : ""}`);
  }

  if (chains.length === 0) {
    console.log("::error::no chain published a current.json; this check measured nothing.");
    return 1;
  }
  if (readyTotal === 0) {
    console.log("::error::no transaction in any chain has a ready TraceSelection entry, so this check measured nothing. A tree that publishes recordings must have some.");
    return 1;
  }
  if (problems.length) {
    console.log(`::error::${problems.length} disagreement(s) between a recording and the page that should offer it:`);
    for (const p of problems.slice(0, 40)) console.log(`    ${p}`);
    if (problems.length > 40) console.log(`    … and ${problems.length - 40} more`);
    return 1;
  }
  console.log(
    `every ready recording is named by its own page — ${readyTotal} ready over ${chains.length} chain(s); ` +
    `${namedTotal} named container(s), ${resolvedTotal} resolved in the tree or the staged bucket` +
    (divergentNamed ? `; ${divergentNamed} named by a DIVERGENT row, reported and not refused` : ""),
  );
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const o = parseArgs(process.argv.slice(2));
  if (o.error) { console.error(o.error); process.exit(2); }
  if (o.help) { console.log("usage: check-recordings-named.mjs --dir <publish-dir> [--live-origin <staged-bucket-dir>]"); process.exit(0); }
  try { process.exit(run(o)); }
  catch (e) { console.error(`check-recordings-named failed: ${e.stack ?? e.message}`); process.exit(2); }
}
