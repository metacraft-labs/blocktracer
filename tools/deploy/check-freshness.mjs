#!/usr/bin/env node
// Deploy gate — the artefacts this deploy publishes must be the ones THIS
// COMMIT AND THIS RUN produced, not merely files that happen to bear the right
// names.
//
//   node tools/deploy/check-freshness.mjs record --built result --staged site …
//   node tools/deploy/check-freshness.mjs verify --manifest <m> --dir site
//   node tools/deploy/check-freshness.mjs verify --manifest <m> --origin <url>
//
// ── Why this file exists, stated as the thing it is NOT ────────────────────
//
// `check-assets.mjs` is the sibling of this file and it answers a DIFFERENT
// question. It asks: does every same-origin URL a published page names resolve
// to non-empty bytes? That is an EXISTENCE claim, and existence is not
// freshness. A publish tree carrying last week's `hydrate.js` under the right
// name passes every one of A1–A5 — the reference resolves, the file is not
// empty, a page names it, the tree has an index. Every number it prints would
// be a true number about the wrong bytes.
//
// That gap is not hypothetical for this repository. The deploy log already
// prints `ok: /assets/hydrate.js (1162553 bytes)` and
// `engine wasm: vendored 18284951 bytes`, and both lines are REPORTS. Nothing
// compares either figure to anything. On 2026-09-01 both were read off the
// live site and taken as evidence of a stale deploy; they were in fact
// faithful, and it took reading four workflow logs to establish that, because
// no check anywhere had ever asserted the property.
//
// So: this file asserts freshness, and `check-assets.mjs` keeps asserting
// existence. Neither subsumes the other — an artefact can be present and stale,
// or fresh and unreferenced, and those are different defects with different
// fixes.
//
// ── "Fresh" means three different things, and they are not interchangeable ──
//
// The site publishes three classes of artefact with three different origins,
// and a check that treated them alike would be wrong about at least two:
//
//   BUILT     `/assets/hydrate.js`, every page, every stylesheet. This
//             repository builds them, from this commit, in this run. Freshness
//             is EXACT IDENTITY with `nix build .#default`'s output: the
//             staged byte and the built byte must be the same byte. Anything
//             else is a copy step that went wrong or a tree that was touched
//             after it was built.
//
//   VENDORED  `/replay-engine/**`. Built by ANOTHER REPOSITORY and fetched at
//             deploy time. This repo cannot say which engine is correct, and a
//             version pin here would make an unrelated CodeTracer release
//             break this repository's deploy — the exact trap the engine step
//             in `deploy-cloudflare-pages.yml` declined to walk into, for good
//             reason. So freshness is identity with WHAT THIS RUN FETCHED,
//             recorded by `fetch-engine.sh` at fetch time. A NEW engine
//             changes those hashes and passes. A STALE one — a leftover
//             directory, a half-written file, an edge that served the runner a
//             previous deployment — does not match and fails. That is the
//             whole shape of the judgement: the check catches staleness
//             without ever having an opinion about version.
//
//   FROZEN    `/t/**/*.ct`, the captured trace containers. These are the
//             opposite of fresh: they were captured from a chain, committed,
//             and must NEVER change. A container that differs from its
//             committed fixture is a corrupted copy or an accidental
//             regeneration, and it silently changes what a visitor replays.
//             Freshness for this class is therefore an IMMUTABILITY claim, and
//             it is checked against the committed fixtures rather than against
//             a manifest that would have to be maintained by hand — the source
//             of truth is already in git, and a new capture is a new file
//             rather than a change to a frozen one.
//
// ── Where it runs, and why twice ───────────────────────────────────────────
//
// `verify --dir site` runs BEFORE the upload, over the staged bytes. That is
// where every existing gate in this workflow runs, and it proves the tree is
// what this commit built.
//
// `verify --origin <url>` runs AFTER `wrangler pages deploy`, against the
// deployment the visitor will actually be served. This is the half no check in
// this repository has ever performed: every gate up to now inspects the bytes
// the deploy INTENDS to upload and nothing observes what the origin ends up
// serving. `wrangler pages deploy` uploads by content hash and skips what it
// believes the project already has, so "the upload succeeded" and "the origin
// serves these bytes" are two claims and only the first was ever checked.
// Post-deploy verification is what makes "a deploy silently published a stale
// artefact" a failing build rather than an unfalsifiable worry.
//
// ── What this does NOT catch, stated rather than hidden ────────────────────
//
//   * `--origin` verifies the NAMED CRITICAL SET, not all ~690 files. Fetching
//     the whole tree over the network on every deploy would cost more than it
//     is worth, so the set is explicit, listed in the manifest, and its size is
//     asserted — a critical set that silently shrank to one entry fails F6b
//     rather than passing with a smaller number nobody compared.
//   * A CDN that serves the correct bytes to this runner and stale bytes to a
//     visitor in another region is out of reach of any single-origin fetch.
//   * The BUILT class is identity with `result/`. If `nix build` itself
//     produced the wrong output, this file agrees with it. That is the flake's
//     claim to make, not this one's.

import { createHash } from "node:crypto";
import { readFileSync, readdirSync, statSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, relative, resolve as resolvePath, sep } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");

// The URL prefix the vendored engine is published under. Written as a literal
// for the same reason `check-assets.mjs` writes the bundle URL as one: this
// file reads PUBLISHED BYTES, and the published bytes are where the build
// configuration ended up. Reading the config instead would make the guard agree
// with the intent rather than with the deployment.
const ENGINE_PREFIX = "replay-engine/";
const HYDRATION_BUNDLE = "assets/hydrate.js";

// Where this repository keeps its committed trace containers. Two roots because
// it has two: chain captures live beside the chain fixtures, the language tour
// beside the trace fixtures. A root that matches nothing costs nothing; a root
// that EXISTS and is not listed is a hole, which is why F4 reports the count it
// found in each.
const FIXTURE_ROOTS = ["fixtures", join("client", "fixtures")];

const sha256 = (buf) => createHash("sha256").update(buf).digest("hex");

// ── The tree ───────────────────────────────────────────────────────────────

const statOf = (p) => { try { return statSync(p); } catch { return null; } };

export function walkFiles(dir) {
  const out = [];
  let entries;
  try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const e of [...entries].sort((a, b) => a.name.localeCompare(b.name))) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...walkFiles(p));
    else if (e.isFile()) out.push(p);
  }
  return out;
}

/** publish-relative, forward-slashed — the form a URL path takes. */
const relKey = (root, p) => relative(root, p).split(sep).join("/");

function hashTree(root) {
  const out = new Map();
  for (const f of walkFiles(root)) {
    const buf = readFileSync(f);
    out.set(relKey(root, f), { sha256: sha256(buf), bytes: buf.length });
  }
  return out;
}

// ── approxMegabytes, mirrored ──────────────────────────────────────────────

/** `client/src/debugger/replay_engine.nim`'s `approxMegabytes`, in JS.
 *
 *  Mirrored rather than imported because it is four Nim tokens and this file
 *  cannot run Nim. It is a mirror WITH A TEST: the selftest pins the two
 *  numbers this repository has actually shipped, so a drift between the two
 *  implementations fails here rather than in a visitor's browser. */
export function approxMegabytes(bytes) {
  return `${Math.floor((bytes + 500_000) / 1_000_000)} MB`;
}

/** The `ReplayEngineWasmBytes*` constant, read from the Nim source. */
export function declaredEngineBytes(nimSource) {
  const m = /ReplayEngineWasmBytes\*?\s*=\s*([0-9_]+)/.exec(nimSource);
  return m ? Number(m[1].replace(/_/g, "")) : null;
}

// ── record ─────────────────────────────────────────────────────────────────

export function record({ built, staged, engineFetch, nimSourcePath, repoRoot }) {
  const builtHashes = hashTree(built);
  const stagedHashes = hashTree(staged);

  const artefacts = {};
  for (const [rel, h] of builtHashes) artefacts[rel] = { class: "built", ...h };
  for (const [rel, h] of stagedHashes) {
    if (rel.startsWith(ENGINE_PREFIX)) artefacts[rel] = { class: "vendored", ...h };
  }
  // Frozen is a PROPERTY of a staged artefact, not a fourth tree: a container
  // is published from `result/` like everything else, so it is already recorded
  // as built. The class is overwritten because the stronger claim wins — for a
  // `.ct` the question is not "does it match this build" but "does it match the
  // capture that was frozen", and the second implies the first.
  for (const rel of Object.keys(artefacts)) {
    if (rel.startsWith("t/") && rel.endsWith(".ct")) artefacts[rel].class = "frozen";
  }

  // The committed captures, by CONTENT rather than by path. The published
  // layout sharded them into `/t/<a>/<b>/<id>/trace.ct` and the fixture keeps
  // its transaction-hash filename, so a path map would be a second place for
  // the sharding rule to live — and a second place is how two spellings of one
  // rule come to disagree. Hashes need no map.
  const frozenSource = new Map();
  for (const root of FIXTURE_ROOTS) {
    const abs = join(repoRoot, root);
    for (const f of walkFiles(abs)) {
      if (!f.endsWith(".ct")) continue;
      frozenSource.set(sha256(readFileSync(f)), relKey(repoRoot, f));
    }
  }

  let nim = null;
  try { nim = readFileSync(nimSourcePath, "utf8"); } catch { /* reported by F5 */ }

  const counts = { built: 0, vendored: 0, frozen: 0 };
  for (const a of Object.values(artefacts)) counts[a.class]++;

  // THE CRITICAL SET — what `--origin` re-fetches from the live deployment.
  // One artefact per class plus the site's entry point, so a post-deploy
  // failure names which KIND of publishing went wrong rather than just that
  // something did. Chosen by rule, not by hand, so a tree that stops producing
  // one of them shrinks the set and fails F6b.
  const critical = [];
  const add = (rel) => { if (artefacts[rel] && !critical.includes(rel)) critical.push(rel); };
  add("index.html");
  add(HYDRATION_BUNDLE);
  add(`${ENGINE_PREFIX}worker.js`);
  add(`${ENGINE_PREFIX}pkg/db_backend.js`);
  add(`${ENGINE_PREFIX}pkg/db_backend_bg.wasm`);
  // The first debug shell, in sorted order, and the first frozen container.
  const firstOf = (pred) => Object.keys(artefacts).sort().find(pred);
  const shell = firstOf((r) => /^.*\/tx\/.*\/debug\/index\.html$/.test(r));
  if (shell) add(shell);
  const ct = firstOf((r) => artefacts[r].class === "frozen");
  if (ct) add(ct);

  return {
    version: 1,
    recordedAt: new Date().toISOString(),
    commit: process.env.GITHUB_SHA ?? "(not set)",
    runId: process.env.GITHUB_RUN_ID ?? "local",
    builtFrom: built,
    stagedFrom: staged,
    artefacts,
    counts,
    critical,
    engineFetch,
    frozenSource: Object.fromEntries(frozenSource),
    declaredEngineBytes: nim ? declaredEngineBytes(nim) : null,
  };
}

// ── verify ─────────────────────────────────────────────────────────────────

/** A verification target: something that can produce the bytes for a
 *  publish-relative path, and may or may not be able to enumerate itself. */
function dirTarget(dir) {
  return {
    what: `directory ${dir}`,
    canEnumerate: true,
    list: () => [...hashTree(dir).keys()],
    read: (rel) => { try { return readFileSync(join(dir, rel)); } catch { return null; } },
  };
}

function originTarget(base) {
  const root = base.replace(/\/+$/, "");
  return {
    what: `origin ${root}`,
    canEnumerate: false,
    list: () => null,
    read: async (rel) => {
      const res = await fetch(`${root}/${rel}`, { redirect: "follow" });
      if (!res.ok) return null;
      return Buffer.from(await res.arrayBuffer());
    },
  };
}

export async function verify({ manifest, target }) {
  const checks = [];
  /** ok === true PASS, false FAIL, null NOT REQUIRED (never counted as a pass). */
  const add = (id, title, ok, detail) => checks.push({ id, title, ok, detail });

  const A = manifest.artefacts ?? {};
  const inClass = (c) => Object.keys(A).filter((r) => A[r].class === c).sort();
  const fmt = (arr, render, n = 12) =>
    arr.slice(0, n).map((v) => `        ${render(v)}`).join("\n") +
    (arr.length > n ? `\n        … and ${arr.length - n} more` : "");

  // ── F0 — the manifest describes something ────────────────────────────────
  //
  // FIRST, because every check below is a comparison AGAINST it: an empty
  // manifest makes F1 "all 0 of 0 artefacts match" and green, which is the
  // vacuous pass this whole file exists to close. The subject's emptiness is
  // itself a check.
  const total = Object.keys(A).length;
  const recorded = manifest.counts ?? {};
  const countsAgree =
    recorded.built === inClass("built").length &&
    recorded.vendored === inClass("vendored").length &&
    recorded.frozen === inClass("frozen").length;
  if (total === 0) {
    add("F0", "the manifest records artefacts, and its own counts are true", false,
      "the manifest records ZERO artefacts — every check below would pass vacuously over it");
  } else if (!countsAgree) {
    add("F0", "the manifest records artefacts, and its own counts are true", false,
      `the manifest's own counts disagree with its artefact list: it declares ` +
      `built=${recorded.built} vendored=${recorded.vendored} frozen=${recorded.frozen}, ` +
      `and it contains built=${inClass("built").length} vendored=${inClass("vendored").length} ` +
      `frozen=${inClass("frozen").length}. A manifest that miscounts itself cannot be ` +
      `the standard anything else is held to.`);
  } else if (!A[HYDRATION_BUNDLE]) {
    // The one artefact this whole investigation was about. A manifest that
    // does not record it cannot fail on it, and F1 would be green.
    add("F0", "the manifest records artefacts, and its own counts are true", false,
      `${total} artefact(s) recorded but NONE of them is /${HYDRATION_BUNDLE}. The hydration ` +
      `bundle is the artefact this gate exists for; a manifest without it holds the deploy to ` +
      `nothing on the file whose staleness is user-visible. Check that nix build produced it ` +
      `(hydrate/build.sh --require runs first in packages.default).`);
  } else {
    add("F0", "the manifest records artefacts, and its own counts are true", true,
      `${total} artefact(s): ${recorded.built} built, ${recorded.vendored} vendored, ` +
      `${recorded.frozen} frozen; /${HYDRATION_BUNDLE} is recorded ` +
      `(${A[HYDRATION_BUNDLE].bytes} bytes, sha256 ${A[HYDRATION_BUNDLE].sha256.slice(0, 12)}…)`);
  }

  if (target.canEnumerate) {
    // ── F1 — every BUILT artefact is byte-identical to this commit's build ──
    const builtRels = inClass("built");
    const wrong = [];
    const absent = [];
    for (const rel of builtRels) {
      const buf = await target.read(rel);
      if (buf === null) { absent.push(rel); continue; }
      const got = sha256(buf);
      if (got !== A[rel].sha256) {
        wrong.push({ rel, want: A[rel], gotSha: got, gotBytes: buf.length });
      }
    }
    const bad = wrong.length + absent.length;
    add("F1", "every built artefact is byte-identical to this commit's build", bad === 0,
      bad
        ? `${bad} of ${builtRels.length} built artefact(s) are NOT what this commit built — ` +
          `each is bytes a visitor would be served that this commit did not produce:\n` +
          fmt([
            ...wrong.map((w) =>
              `/${w.rel}  built ${w.want.bytes} bytes (${w.want.sha256.slice(0, 12)}…), ` +
              `${target.what} has ${w.gotBytes} bytes (${w.gotSha.slice(0, 12)}…)`),
            ...absent.map((r) => `/${r}  built, and ABSENT from ${target.what}`),
          ], (s) => s)
        : `all ${builtRels.length} built artefact(s) match` +
          (A[HYDRATION_BUNDLE]
            ? `, including /${HYDRATION_BUNDLE} at ${A[HYDRATION_BUNDLE].bytes} bytes`
            : ` (this build shipped no hydration bundle — F0 owns that)`));

    // ── F2 — nothing was published that this deploy cannot account for ─────
    //
    // The other direction, and the one F1 cannot cover: F1 walks the MANIFEST,
    // so a file added to the publish tree after the manifest was recorded is
    // invisible to it. An unaccounted file in the upload is a file no step in
    // this workflow produced, which is the shape a leftover from a previous
    // run takes on a runner whose workspace was not clean.
    const listed = target.list() ?? [];
    const unaccounted = listed.filter((r) => !A[r]);
    add("F2", "the publish tree contains nothing this deploy cannot account for",
      unaccounted.length === 0,
      unaccounted.length
        ? `${unaccounted.length} file(s) in ${target.what} are in neither the build output nor ` +
          `the vendored engine — this deploy would upload bytes no step in it produced:\n` +
          fmt(unaccounted, (r) => `/${r}`)
        : `all ${listed.length} published file(s) are accounted for by the build or the fetch`);

    // ── F3 — every vendored artefact is what THIS RUN fetched ──────────────
    const vendored = inClass("vendored");
    const fetched = manifest.engineFetch?.files ?? null;
    if (!fetched) {
      // NOT REQUIRED rather than PASS. `fetch-engine.sh` writes no manifest
      // when it has no sha256 tool, and a green verdict over hashes nobody
      // computed is precisely the reassurance this file was written to stop
      // handing out.
      add("F3", "every vendored engine artefact is what this run fetched", null,
        `no fetch manifest — fetch-engine.sh recorded no hashes, so there is nothing to hold ` +
        `the ${vendored.length} vendored artefact(s) to. Pass a manifest path as its third ` +
        `argument to enforce.`);
    } else {
      const drifted = [];
      for (const rel of vendored) {
        const key = rel.slice(ENGINE_PREFIX.length);
        const f = fetched[key];
        if (!f) { drifted.push(`/${rel}  published, and NOT among the files this run fetched`); continue; }
        const buf = await target.read(rel);
        if (buf === null) { drifted.push(`/${rel}  fetched, and ABSENT from ${target.what}`); continue; }
        const got = sha256(buf);
        if (got !== f.sha256) {
          drifted.push(
            `/${rel}  fetched ${f.bytes} bytes (${f.sha256.slice(0, 12)}…), ` +
            `${target.what} has ${buf.length} bytes (${got.slice(0, 12)}…)`);
        }
      }
      const fetchedCount = Object.keys(fetched).length;
      const countOk = fetchedCount === vendored.length;
      add("F3", "every vendored engine artefact is what this run fetched",
        drifted.length === 0 && countOk,
        drifted.length || !countOk
          ? (drifted.length
              ? `${drifted.length} vendored artefact(s) are not the bytes this run fetched from ` +
                `${manifest.engineFetch.origin} at ${manifest.engineFetch.fetchedAt}:\n` +
                fmt(drifted, (s) => s) + "\n"
              : "") +
            (countOk ? "" :
              `        the fetch recorded ${fetchedCount} file(s) and ${vendored.length} are ` +
              `published — the engine is published in a shape the fetch did not produce`)
          : `all ${vendored.length} vendored artefact(s) are the bytes this run fetched from ` +
            `${manifest.engineFetch.origin} at ${manifest.engineFetch.fetchedAt} ` +
            `(run ${manifest.engineFetch.runId}); no opinion is expressed about WHICH engine that is`);
    }

    // ── F4 — every frozen container is its committed capture, unchanged ────
    const frozen = inClass("frozen");
    const frozenSource = manifest.frozenSource ?? {};
    const known = new Set(Object.keys(frozenSource));
    if (frozen.length === 0) {
      // NOT REQUIRED, not PASS. A tree that publishes no container has nothing
      // for an immutability rule to be true OF, and calling that a pass would
      // put a green tick next to the class in exactly the deploy that lost it.
      // The vacuity direction is `check-assets.mjs`'s A3 under
      // `--require-traces`, which is the check that fails when a publish
      // claiming to carry traces names none — the two are complementary and
      // neither covers the other's half.
      add("F4", "every published trace container is its committed capture, unchanged", null,
        `no /t/**/*.ct container is published, so there is no frozen capture to hold to its ` +
        `committed bytes. check-assets.mjs's A3 --require-traces is what fails when a publish ` +
        `that should carry containers carries none; this check has no opinion about an empty set.`);
    } else if (known.size === 0) {
      add("F4", "every published trace container is its committed capture, unchanged", false,
        `${frozen.length} container(s) are published and the repository's fixture roots ` +
        `(${FIXTURE_ROOTS.join(", ")}) yielded NO committed .ct file to hold them to. ` +
        `Either the fixtures moved — in which case this list is stale — or the record step ` +
        `read the wrong repository root.`);
    } else {
      const changed = frozen.filter((r) => !known.has(A[r].sha256));
      add("F4", "every published trace container is its committed capture, unchanged",
        changed.length === 0,
        changed.length
          ? `${changed.length} of ${frozen.length} published container(s) match NO committed ` +
            `capture. A frozen container that changed is a different recording under the same ` +
            `URL, and every visitor replays the new one without being told:\n` +
            fmt(changed, (r) => `/${r}  (${A[r].bytes} bytes, ${A[r].sha256.slice(0, 12)}…)`)
          : `all ${frozen.length} published container(s) are byte-identical to one of the ` +
            `${known.size} committed capture(s) under ${FIXTURE_ROOTS.join(", ")}`);
    }

    // ── F5 — the engine size the page TELLS a visitor is true ──────────────
    //
    // THE JUDGEMENT THIS CHECK ENCODES. The deploy's engine step declined to
    // assert `ReplayEngineWasmBytes` against the vendored bytes, and its reason
    // was right: the engine comes from another repository, so a byte-exact
    // assertion would make an unrelated CodeTracer release break this
    // repository's deploy.
    //
    // But "report and continue" is the other extreme, and it left a number the
    // page SHOWS A VISITOR unverified for as long as it has existed. So the
    // assertion is made at the granularity the page actually renders:
    // `approxMegabytes` shows whole decimal megabytes, so an engine bump of a
    // few hundred KB passes exactly as the comment intended, and a divergence
    // large enough to make the page tell a visitor the wrong number fails.
    // The claim asserted is the one the product makes, not the one the
    // constant happens to hold.
    const wasmRel = `${ENGINE_PREFIX}pkg/db_backend_bg.wasm`;
    const declared = manifest.declaredEngineBytes;
    const actual = A[wasmRel]?.bytes ?? null;
    if (declared === null || actual === null) {
      add("F5", "the engine size the page shows a visitor is true of the engine it ships", null,
        `not checked — ${declared === null ? "ReplayEngineWasmBytes was not readable" : ""}` +
        `${declared === null && actual === null ? " and " : ""}` +
        `${actual === null ? "no engine wasm is published" : ""}`);
    } else {
      const shown = approxMegabytes(declared);
      const truth = approxMegabytes(actual);
      add("F5", "the engine size the page shows a visitor is true of the engine it ships",
        shown === truth,
        shown === truth
          ? `the page renders "${shown}" (ReplayEngineWasmBytes = ${declared}); the engine it ` +
            `ships is ${actual} bytes, which also renders "${truth}". The ${Math.abs(actual - declared)}-byte ` +
            `drift between them is invisible to a visitor, which is the tolerance this check is set to.`
          : `the page renders "${shown}" from ReplayEngineWasmBytes = ${declared}, and the engine ` +
            `it actually ships is ${actual} bytes — "${truth}". The page is telling every visitor a ` +
            `number that is not true of the file it is about to make them download. Re-measure the ` +
            `constant in client/src/debugger/replay_engine.nim.`);
    }

    add("F6", "the origin serves the bytes this run published", null,
      `not required against a directory — pass --origin <url> after the upload to check the ` +
      `deployment a visitor is served`);
  } else {
    // ── Origin mode ────────────────────────────────────────────────────────
    for (const id of ["F1", "F2", "F3", "F4", "F5"]) {
      add(id, `(directory-only check)`, null,
        `not required against an origin — these read the whole staged tree, which only exists ` +
        `on the runner. They ran before the upload.`);
    }

    // ── F6 — the origin serves exactly what this run published ─────────────
    //
    // THE CHECK NO GATE IN THIS REPOSITORY HAS EVER PERFORMED. Everything else
    // in this workflow inspects the bytes the deploy INTENDS to upload.
    // `wrangler pages deploy` uploads by content hash and skips what it
    // believes the project already holds, so a successful upload is a claim
    // about the upload and not about the origin. This fetches what a visitor
    // gets and compares it to what this run recorded.
    const critical = manifest.critical ?? [];
    const results = [];
    for (const rel of critical) {
      const want = A[rel];
      if (!want) { results.push({ rel, why: "in the critical set and not in the manifest" }); continue; }
      let buf;
      try { buf = await target.read(rel); }
      catch (e) { results.push({ rel, why: `fetch threw: ${e.message}` }); continue; }
      if (buf === null) { results.push({ rel, why: `the origin does not serve it (non-2xx)` }); continue; }
      const got = sha256(buf);
      if (got !== want.sha256) {
        results.push({
          rel,
          why: `published ${want.bytes} bytes (${want.sha256.slice(0, 12)}…), ` +
               `the origin serves ${buf.length} bytes (${got.slice(0, 12)}…)`,
        });
      }
    }
    add("F6", "the origin serves the bytes this run published", results.length === 0,
      results.length
        ? `${results.length} of ${critical.length} critical artefact(s) are NOT what this run ` +
          `published. The deploy reported success and the origin is serving something else:\n` +
          fmt(results, (r) => `/${r.rel}  ${r.why}`)
        : `all ${critical.length} critical artefact(s) at ${target.what} are byte-identical to ` +
          `what this run published`);

    // ── F6b — the critical set is not vacuous ──────────────────────────────
    //
    // F6 over an empty critical set is "all 0 of 0 match", green, and worth
    // nothing. The set is built by rule in `record`, so a tree that stopped
    // producing the bundle or the engine would quietly shrink it — and that is
    // exactly the deploy this check must not bless.
    const MUST = ["index.html", HYDRATION_BUNDLE, `${ENGINE_PREFIX}pkg/db_backend_bg.wasm`];
    const absent = MUST.filter((r) => !critical.includes(r));
    add("F6b", "the critical set names one artefact of every class that must be checked",
      absent.length === 0,
      absent.length
        ? `the critical set (${critical.length} entries) is missing ${absent.length} artefact(s) ` +
          `that must always be in it: ${absent.map((r) => "/" + r).join(", ")}. F6 above passed ` +
          `over a set that does not include them, which is a green verdict about nothing.`
        : `${critical.length} artefact(s), covering the entry point, the built bundle, the ` +
          `vendored engine and a frozen container: ${critical.map((r) => "/" + r).join(", ")}`);
  }

  return checks;
}

// ── main ───────────────────────────────────────────────────────────────────

export function parseArgs(argv) {
  const mode = argv[0];
  if (mode !== "record" && mode !== "verify") {
    throw new Error(
      `first argument must be "record" or "verify" (got ${mode ?? "nothing"})\n` +
      `usage: check-freshness.mjs record --built <dir> --staged <dir> [--engine-fetch <json>] --out <json>\n` +
      `       check-freshness.mjs verify --manifest <json> (--dir <dir> | --origin <url>)`);
  }
  const o = { mode, repoRoot: REPO_ROOT };
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    const take = (name) => {
      const v = argv[++i];
      if (v === undefined) throw new Error(`${name} needs a value`);
      return v;
    };
    if (a === "--built") o.built = take(a);
    else if (a === "--staged") o.staged = take(a);
    else if (a === "--engine-fetch") o.engineFetch = take(a);
    else if (a === "--nim-source") o.nimSource = take(a);
    else if (a === "--repo-root") o.repoRoot = resolvePath(take(a));
    else if (a === "--out") o.out = take(a);
    else if (a === "--manifest") o.manifest = take(a);
    else if (a === "--dir") o.dir = take(a);
    else if (a === "--origin") o.origin = take(a);
    else throw new Error(`unknown argument: ${a}`);
  }
  if (mode === "record") {
    for (const k of ["built", "staged", "out"]) {
      if (!o[k]) throw new Error(`record needs --${k}`);
    }
    o.nimSource ??= join(o.repoRoot, "client", "src", "debugger", "replay_engine.nim");
  } else {
    if (!o.manifest) throw new Error("verify needs --manifest");
    if (!!o.dir === !!o.origin) throw new Error("verify needs exactly one of --dir or --origin");
  }
  return o;
}

async function main(argv) {
  const o = parseArgs(argv);

  if (o.mode === "record") {
    let engineFetch = null;
    if (o.engineFetch) {
      try { engineFetch = JSON.parse(readFileSync(o.engineFetch, "utf8")); }
      catch { engineFetch = null; }
    }
    const m = record({
      built: resolvePath(o.built),
      staged: resolvePath(o.staged),
      engineFetch,
      nimSourcePath: o.nimSource,
      repoRoot: o.repoRoot,
    });
    mkdirSync(dirname(resolvePath(o.out)), { recursive: true });
    writeFileSync(o.out, JSON.stringify(m, null, 2) + "\n");
    console.log(`recorded:     ${o.out}`);
    console.log(`  built from  ${m.builtFrom}`);
    console.log(`  staged from ${m.stagedFrom}`);
    console.log(`  ${m.counts.built} built, ${m.counts.vendored} vendored, ${m.counts.frozen} frozen`);
    console.log(`  engine fetch: ${engineFetch ? `${engineFetch.origin} at ${engineFetch.fetchedAt}` : "(none recorded)"}`);
    console.log(`  critical set: ${m.critical.map((r) => "/" + r).join(", ") || "(empty)"}`);
    return 0;
  }

  const manifest = JSON.parse(readFileSync(o.manifest, "utf8"));
  const target = o.dir ? dirTarget(resolvePath(o.dir)) : originTarget(o.origin);
  const checks = await verify({ manifest, target });

  console.log(`manifest:     ${o.manifest}`);
  console.log(`              recorded ${manifest.recordedAt} from commit ${manifest.commit} (run ${manifest.runId})`);
  console.log(`target:       ${target.what}`);
  console.log("");
  for (const c of checks) {
    const verdict = c.ok === null ? "NOT REQUIRED" : c.ok ? "PASS" : "FAIL";
    console.log(`  ${c.id.padEnd(3)} ${verdict}  ${c.title}`);
    console.log(`        ${c.detail}`);
  }
  console.log("");
  const failed = checks.filter((c) => c.ok === false);
  const notRun = checks.filter((c) => c.ok === null);
  const passes = checks.filter((c) => c.ok === true).length;
  const required = checks.filter((c) => c.ok !== null).length;
  if (notRun.length) {
    console.log(`${notRun.length} check(s) NOT REQUIRED and therefore never counted as passes: ` +
                `${notRun.map((c) => c.id).join(", ")}`);
  }
  console.log(failed.length === 0
    ? `check-freshness: PASS — ${passes}/${required} checks`
    : `check-freshness: FAIL — ${failed.length} check(s) failed: ${failed.map((c) => c.id).join(", ")}`);
  return failed.length === 0 ? 0 : 1;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (e) => { console.error(`check-freshness failed: ${e.stack ?? e.message}`); process.exit(2); },
  );
}
