// IS THIS BUILT TREE OF THIS SOURCE TREE? — one implementation, three callers.
//
// WHY THIS FILE EXISTS. An audit of both repositories found the same defect in
// fifteen places and it has one shape: an EXISTENCE test standing in for a
// FRESHNESS claim.
//
//     if (existsSync(dist)) { /* capture it / reuse it / skip the build */ }
//
// `existsSync` answers "is there a directory of that name". The decision made
// on the answer is "these are the bytes this source produces". Those are
// different sentences, and every artefact this repository builds is written IN
// PLACE into a gitignored directory that nothing cleans between runs — so the
// gap is not theoretical. `.github/workflows/ci.yml` records a run that "fell
// back to capturing whatever was already in client/dist" after the exporter
// failed; every image in it was a true photograph of the wrong build.
//
// The correct question is a comparison against an INPUT, and the cheapest
// honest one available without a build system is: does every artefact that a
// rebuild must rewrite post-date the newest source it is a function of?
//
// WHAT THIS IS NOT. It is not commit identity. A tree built from a different
// commit whose files happen to carry older mtimes than this checkout's is not
// caught here, and no caller should say it is. It IS enough for the cases that
// actually occur, because `git checkout` and `git rebase` rewrite the mtime of
// every file they change: a `dist/` built on another branch is almost always
// older than some source this checkout moved. Callers that can do better —
// `tools/journeys/lib/site.mjs`, which reads a stamped commit out of
// `build-info.json` when the deploy wrote one — do better first and fall back
// to this.
//
// EQUAL MTIMES ARE FRESH. A build written in the same second as its last input
// is the ordinary clean case, and a gate that cried wolf on it would be
// switched off, and then it would not be there for the real one. Same rule, and
// the same sentence, as `tools/design/check-tokens.mjs:staleBuild`, which asked
// this question correctly for D1 before this file generalised it.
//
// SYNCHRONOUS, deliberately: two of the three callers are sync-flavoured
// command-line tools, and the whole walk is ~120 files and measures at 6 ms.

import { readdirSync, statSync } from "node:fs";
import { join } from "node:path";

/**
 * The source roots the exported site is a function of: one exporter and three
 * `nim js` bundles are compiled out of these five, and `flake.nix` builds the
 * same five.
 */
export const BUILD_INPUT_ROOTS = [
  ["src"],
  ["client", "src"],
  ["client", "hydrate"],
  ["client", "searchboot"],
  ["client", "settingsboot"],
];

/** Compiler scratch and build output that live INSIDE those roots. */
const SKIP_DIRS = new Set(["nimcache", "nimcache-hydrated", "node_modules", "dist", ".git"]);

/**
 * `.nim`/`.nims`/`.cfg`/`.json` only. `client/hydrate/hydrate.js`,
 * `client/searchboot/search.js` and `client/settingsboot/settings.js` sit in
 * these roots and are OUTPUT: a walk that counted them would compare a build
 * against itself and could never report stale.
 */
const BUILD_INPUT_EXT = /\.(nim|nims|cfg|json)$/;

/**
 * The artefacts a rebuild must have rewritten, as paths relative to a built
 * tree. Callers pass their own set; this is the exported site's.
 */
export const SITE_ARTEFACTS = [
  ["index.html"],
  ["assets", "hydrate.js"],
  ["assets", "search.js"],
  ["assets", "settings.js"],
];

/** Nix writes every file in the store with mtime 1 (1970-01-01T00:00:01Z), on
 *  purpose. An mtime read off a store path is not OLD, it is ABSENT, and
 *  reporting "stale" about it would be a confident wrong answer. Callers that
 *  can meet a store path must detect this and say which sentence they mean. */
export const MTIME_FLOOR_MS = Date.UTC(1980, 0, 1);

/** Second precision, so two of these can be compared by eye in a refusal. */
export const when = (ms) => new Date(ms).toISOString().replace("T", " ").slice(0, 19) + "Z";

/** `{ path, mtimeMs }` for the most recently modified source, or null. */
export function newestBuildInput(repoRoot, roots = BUILD_INPUT_ROOTS) {
  let newest = null;
  const walk = (dir) => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const p = join(dir, e.name);
      if (e.isDirectory()) {
        if (!SKIP_DIRS.has(e.name)) walk(p);
        continue;
      }
      if (!e.isFile() || !BUILD_INPUT_EXT.test(e.name)) continue;
      let st;
      try {
        st = statSync(p);
      } catch {
        continue;
      }
      if (newest === null || st.mtimeMs > newest.mtimeMs) newest = { path: p, mtimeMs: st.mtimeMs };
    }
  };
  for (const parts of roots) walk(join(repoRoot, ...parts));
  return newest;
}

/**
 * The OLDEST of the artefacts a rebuild must rewrite — not the newest.
 *
 * A partial rebuild (the exporter re-run without `hydrate`, which is exactly
 * what `just export` after `just export-hydrated` leaves behind) has a fresh
 * `index.html` beside a stale `assets/hydrate.js`. Taking the newest would call
 * that tree current; taking the oldest is the question actually being asked.
 * Artefacts that are absent are skipped, not treated as infinitely old: their
 * absence is a different check's business.
 */
export function oldestBuiltArtefact(root, artefacts = SITE_ARTEFACTS) {
  let oldest = null;
  for (const parts of artefacts) {
    const p = join(root, ...parts);
    let st;
    try {
      st = statSync(p);
    } catch {
      continue;
    }
    if (oldest === null || st.mtimeMs < oldest.mtimeMs) oldest = { path: p, mtimeMs: st.mtimeMs };
  }
  return oldest;
}

/**
 * THE ONE CALL MOST CALLERS WANT.
 *
 * Returns null when the tree is fresh, and otherwise an object that SAYS WHICH
 * of the four not-fresh answers it is — because "this tree is stale" and "this
 * question cannot be asked here" are different sentences and a caller that
 * printed one for the other would be lying in the reassuring direction.
 *
 *   { why: "no-artefacts" }  none of `artefacts` is in the tree.
 *   { why: "no-mtime" }      the tree carries Nix store epoch mtimes.
 *   { why: "no-inputs" }     the source roots are unreadable or empty.
 *   { why: "stale", built, source, message }
 */
export function staleness(root, repoRoot, { artefacts = SITE_ARTEFACTS, roots = BUILD_INPUT_ROOTS } = {}) {
  const built = oldestBuiltArtefact(root, artefacts);
  if (built === null)
    return { why: "no-artefacts", message: `${root} holds none of ${artefacts.map((p) => join(...p)).join(", ")}` };
  if (built.mtimeMs < MTIME_FLOOR_MS)
    return {
      why: "no-mtime",
      built,
      message:
        `${built.path} has mtime ${when(built.mtimeMs)} — the epoch stamp Nix gives every file ` +
        `in the store, so an mtime comparison here carries no information at all`,
    };
  const source = newestBuildInput(repoRoot, roots);
  if (source === null)
    return {
      why: "no-inputs",
      built,
      message: `no build inputs found under ${roots.map((p) => join(...p)).join(", ")} in ${repoRoot}`,
    };
  if (source.mtimeMs <= built.mtimeMs) return null;
  return {
    why: "stale",
    built,
    source,
    message:
      `${built.path} was written ${when(built.mtimeMs)}, but ${source.path} changed ${when(source.mtimeMs)}`,
  };
}
