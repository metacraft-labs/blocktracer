#!/usr/bin/env node
// Deploy gate — nothing the site points at is missing.
//
//   node tools/deploy/check-no-stale-neighbours.mjs --dir site
//   node tools/deploy/check-no-stale-neighbours.mjs --dir site --live-origin <dir>
//   node tools/deploy/check-no-stale-neighbours.mjs --dir site --routes <file>
//
// ── WHY IT EXISTS, BEFORE THE THING IT GUARDS ─────────────────────────────────────────
//
// `docs/INCREMENTAL-PUBLISH.md` §5 names this as the prerequisite for the first
// incremental publish, "not after", because the failure mode of an incremental publish is
// a STALE NEIGHBOUR: a list page or an index shard that names a transaction whose page was
// never written. The whole-site pass cannot produce one — it rewrites everything — so this
// gate has nothing to catch today, and that is the point of landing it now. A gate written
// after the first incremental publish is a gate written after the incident.
//
// It is the mirror of `check-recordings-named.mjs`. That one asks whether every recording
// is OFFERED by a page; this one asks whether everything a page or an index POINTS AT
// exists. The two together are the §5 rule:
//
//   A  INDEX   every hash the index resolves has a page in this tree or in the bucket
//   B  DRAWN   every entity link any page draws has a page in this tree or in the bucket
//   C  WHOLE   the index's own `meta.json` agrees with the shards actually present
//
// C is not decoration. A half-uploaded index is the one state in which A passes
// vacuously — fewer entries to check, every one of them fine — so the gate compares the
// shards it read against the count the index declares about itself, and a short read is a
// failure rather than a smaller subject set.
//
// ── IT REFUSES TO PASS OVER NOTHING ───────────────────────────────────────────────────
//
// No index, no entries, no pages drawing anything: each exits non-zero with its own name.
// `tools/journeys/README.md` rule 3 — "a test whose subject can be empty passes
// vacuously" — and this repository has shipped that exact green twice.

import { readdirSync, readFileSync, existsSync, statSync } from "node:fs";
import { join } from "node:path";
import { parseHashShard, routeFor } from "./lib/hash-shard.mjs";

// `href="/{chain}/{tx|block|address}/{id}"` — the three hash-addressable classes, which is
// `kindOfRouteSegment`'s own closed set. A fourth segment appearing here should FAIL to
// match rather than be guessed at, so the alternation is spelled out.
const ENTITY_HREF = /href="\/([a-z0-9][a-z0-9-]*)\/(tx|block|address)\/(0x[0-9a-f]+)"/g;

export function parseArgs(argv) {
  const o = { dir: "site", liveOrigin: "", routes: "", maxReport: 40 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--dir") o.dir = argv[++i];
    else if (a === "--live-origin") o.liveOrigin = argv[++i];
    else if (a === "--routes") o.routes = argv[++i];
    else if (a === "--max-report") o.maxReport = Math.max(1, Number(argv[++i]));
    else return { error: `unknown argument: ${a}` };
  }
  return o;
}

const htmlUnder = (root) => {
  const out = [];
  const walk = (d) => {
    let ents = [];
    try { ents = readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith(".html")) out.push(p);
    }
  };
  walk(root);
  return out.sort();
};

/** The index version directories under `idx/hash/`, newest-looking last. The version is
 *  read from the tree rather than passed in, because a caller naming the wrong one would
 *  check an index the site does not serve. */
const indexVersions = (dir) => {
  try {
    return readdirSync(join(dir, "idx", "hash"), { withFileTypes: true })
      .filter((e) => e.isDirectory()).map((e) => e.name).sort();
  } catch { return []; }
};

export function run({ dir, liveOrigin, routes, maxReport }) {
  const roots = [dir, ...(liveOrigin && existsSync(liveOrigin) ? [liveOrigin] : [])];
  // A PAGE IS A PAGE IN EITHER ROOT. On a render-over-live publish the neighbour a page
  // names may live only in the staged copy of the bucket, and a gate that refused that
  // would redden on every normal deploy.
  const pageExists = (route) => roots.some((r) => existsSync(join(r, route, "index.html")));
  const problems = [];
  const add = (s) => { if (problems.length < 1000) problems.push(s); };

  // ── C: is the index whole? ──────────────────────────────────────────────────────────
  const versions = indexVersions(dir);
  if (versions.length === 0) {
    console.log("::error::no idx/hash/<version>/ in this tree, so rule A would check nothing.");
    return 1;
  }
  let indexEntries = [];
  let shardsRead = 0;

  // ONE meta.json DESCRIBES EVERY VERSION, AND NOT WITH ONE SET OF NUMBERS.
  // `client/src/static_export.nim` writes the top-level `shardCount`/`entryCount` for
  // version 1 and adds a `versions` array ONLY when a second version exists, each member
  // carrying its own counts. So a version's declaration has to be LOOKED UP. Reading the
  // top-level fields for every version compared v1's counts against v2's shards, and
  // since v2 is a SUPERSET of v1 (every encoding, not just hex) that comparison could
  // never pass: the gate reddened on every tree publishing a second-format index.
  // Reported by bt-move-f0 on 2026-11-07, reproduced here before it was changed.
  const descriptorFor = (meta, v) => {
    if (!meta) return null;
    if (Array.isArray(meta.versions)) {
      return meta.versions.find((d) => String(d.version) === String(v)) ?? null;
    }
    // No `versions` array is the writer saying there is exactly one version, described by
    // the top-level fields. It still has to be the version actually on disk.
    return String(v) === String(meta.indexVersion) ? meta : null;
  };

  const metaPath = join(dir, "idx", "hash", "meta.json");
  let meta = null;
  try { meta = JSON.parse(readFileSync(metaPath, "utf8")); } catch { /* reported below */ }

  for (const v of versions) {
    const vdir = join(dir, "idx", "hash", v);
    const desc = descriptorFor(meta, v);
    const where = meta && Array.isArray(meta.versions)
      ? `idx/hash/meta.json versions[${v}]` : "idx/hash/meta.json";
    const names = readdirSync(vdir).filter((n) => n.endsWith(".bin")).sort();
    const entries = [];
    for (const n of names) {
      const parsed = parseHashShard(readFileSync(join(vdir, n)));
      if (parsed.error) {
        add(`idx/hash/${v}/${n}: ${parsed.error} — ${parsed.detail}`);
        continue;
      }
      shardsRead += 1;
      entries.push(...parsed.entries);
    }
    indexEntries.push(...entries);
    if (desc) {
      // THE CROSS-CHECK. A short read here is the state in which rule A passes over a
      // subject set the publish silently shrank.
      if (Number(desc.shardCount) !== names.length) {
        add(`${where} declares shardCount ${desc.shardCount} and `
          + `idx/hash/${v}/ holds ${names.length} shard file(s)`);
      }
      if (Number(desc.entryCount) !== entries.length) {
        add(`${where} declares entryCount ${desc.entryCount} and the shards `
          + `under ${v}/ decode to ${entries.length}`);
      }
    } else if (!meta) {
      add(`idx/hash/meta.json is missing or unreadable, so the index cannot be checked `
        + `against its own declaration — the one comparison that catches a partial index`);
    } else {
      // THE HOLE THE LOOKUP WOULD OTHERWISE OPEN. Skipping a version meta.json does not
      // describe would serve an index with nothing checking it, which is the silent pass
      // this rule exists to refuse. Name it instead.
      add(`idx/hash/${v}/ is served and idx/hash/meta.json declares no version ${v}, `
        + `so that index is published with no declaration to check it against`);
    }
    console.log(`  index ${v}: ${names.length} shard(s), ${entries.length} entry/entries`);
  }

  // ── A: every hash the index resolves has a page ─────────────────────────────────────
  let aResolved = 0;
  const indexTargets = new Set();
  for (const e of indexEntries) {
    // `candidates` and not `identifier`: format 1 cannot tell a padded zero from a real
    // one, and 13 of this repository's 288 entries resolve only under the unstripped
    // reading. See `lib/hash-shard.mjs`.
    const hit = e.candidates
      .map((c) => routeFor(e.chain, e.kind, c))
      .filter(Boolean)
      .find((r) => pageExists(r));
    if (hit) { aResolved += 1; indexTargets.add(hit); }
    else if (!routeFor(e.chain, e.kind, e.identifier)) {
      add(`index entry ${e.chain} kind ${e.kind} ${e.identifier}: kind ${e.kind} names no `
        + `route segment, so nothing can be asserted about it — the reader refuses to guess one`);
    } else {
      add(`index resolves ${e.chain} ${e.identifier} (kind ${e.kind}) and no root holds a `
        + `page for it (tried ${e.candidates.join(", ")} in ${roots.join(", ")})`);
    }
  }

  // ── B: every entity link a page draws has a page ────────────────────────────────────
  let pages = htmlUnder(dir);
  if (routes) {
    // THE INCREMENTAL SET. §5 states the rule "over the incremental set rather than the
    // whole site", because that is the set a partial publish rewrote and therefore the
    // set whose neighbours can have gone stale.
    let wanted;
    try {
      wanted = new Set(readFileSync(routes, "utf8").split("\n")
        .map((l) => l.trim()).filter(Boolean));
    } catch (e) {
      console.log(`::error::--routes ${routes} is unreadable: ${e.message}`);
      return 1;
    }
    if (wanted.size === 0) {
      console.log(`::error::--routes ${routes} names no routes, so rule B would scan nothing.`);
      return 1;
    }
    pages = pages.filter((p) => wanted.has(p.slice(dir.length + 1))
                             || wanted.has(p.slice(dir.length + 1).replace(/\/index\.html$/, "")));
    if (pages.length === 0) {
      console.log(`::error::--routes ${routes} matched none of the ${htmlUnder(dir).length} `
        + `HTML pages in ${dir}, so rule B would scan nothing.`);
      return 1;
    }
  }
  const drawn = new Map();   // route -> the first page that drew it
  let links = 0;
  for (const p of pages) {
    let html = "";
    try { html = readFileSync(p, "utf8"); } catch { continue; }
    for (const m of html.matchAll(ENTITY_HREF)) {
      links += 1;
      const route = `${m[1]}/${m[2]}/${m[3]}`;
      if (!drawn.has(route)) drawn.set(route, p.slice(dir.length + 1));
    }
  }
  for (const [route, src] of drawn) {
    if (!pageExists(route)) {
      add(`${src} draws /${route} and no root holds a page for it`);
    }
  }

  // ── the specific cause outranks the vacuity refusal ────────────────────────────────
  //
  // ORDER MATTERS AND AN ARM CAUGHT IT. A truncated shard decodes to zero entries, so
  // with the vacuity checks first the operator read "the index decoded to zero entries,
  // so rule A measured nothing" — true, useless, and three steps from the cause, which
  // this run already knew and had written down. One predicate must not stand for two
  // causes when the narrower one is in hand. The vacuity refusals below are for a tree
  // with no problems AND no subjects, which is the case they were written for.
  if (problems.length) {
    console.log(`::error::${problems.length} stale neighbour(s) / index disagreement(s):`);
    for (const p of problems.slice(0, maxReport)) console.log(`    ${p}`);
    if (problems.length > maxReport) console.log(`    … and ${problems.length - maxReport} more`);
    return 1;
  }

  // ── the vacuity refusals ────────────────────────────────────────────────────────────
  if (indexEntries.length === 0) {
    console.log("::error::the index decoded to zero entries, so rule A measured nothing. "
      + "A tree that publishes an index must have some.");
    return 1;
  }
  if (drawn.size === 0) {
    console.log(`::error::none of the ${pages.length} HTML page(s) scanned draws an entity `
      + "link, so rule B measured nothing. A site with transaction pages has pages that "
      + "link to them.");
    return 1;
  }
  const bothWays = [...drawn.keys()].filter((r) => indexTargets.has(r)).length;
  console.log(
    `nothing the site points at is missing — ${aResolved} index entry/entries over `
    + `${shardsRead} shard(s) resolve, and ${drawn.size} distinct target(s) drawn by `
    + `${pages.length} page(s) over ${links} link(s) resolve; `
    + `${bothWays} target(s) are named BOTH by the index and by a page`,
  );
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const o = parseArgs(process.argv.slice(2));
  if (o.error) { console.error(`check-no-stale-neighbours: ${o.error}`); process.exit(2); }
  try { process.exit(run(o)); }
  catch (e) { console.error(`check-no-stale-neighbours failed: ${e.stack ?? e.message}`); process.exit(2); }
}
