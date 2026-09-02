// Staging the replay engine into `dist/`, and why it needs its own file.
//
// `client/hydrate/fetch-engine.sh` copies the published engine into
// `dist/replay-engine/`, and `src/static_export.nim` REMOVES `dist/` and writes
// it again. So an export taken after a fetch silently un-does the fetch, and
// every journey that needs a session then skips.
//
// That cost this harness an hour, and it did not cost it a false pass — which
// is the only reason it is worth writing down. `selftest.mjs` rebuilds between
// arms; the first two arms came back NEVER RAN ("no assertion matched") rather
// than KILLED, because a skipped journey emits no records to match. A harness
// that had taken its verdict from `run.mjs`'s exit code would have scored both
// as kills: the run exits non-zero for a skip exactly as it does for a red
// assertion (Verification-Harness-Traps.md §1a — three verdicts, not two).
//
// The fix is a cache OUTSIDE `dist/`, and re-staging after every export. The
// cache is fetched once (`just journeys-engine`), is 18 MB, and is gitignored
// for the same reasons `fetch-engine.sh` gives for not committing it.

import { cp, stat, mkdir } from "node:fs/promises";
import { join } from "node:path";

export const CACHE_DIRNAME = ".replay-engine-cache";

const exists = (p) =>
  stat(p).then(
    () => true,
    () => false,
  );

/**
 * Copy the cached engine into `dist/replay-engine/` if it is not already there.
 * Returns what happened, so the runner can SAY which of the three states it is
 * in rather than leaving "no session" unexplained.
 */
export async function stageEngine(distDir, cacheDir) {
  const dest = join(distDir, "replay-engine");
  if (await exists(join(dest, "worker.js"))) return { staged: true, from: "the site tree" };

  const cache = cacheDir;
  if (!(await exists(join(cache, "worker.js")))) {
    return {
      staged: false,
      from: null,
      remedy:
        `no engine in ${cache}.\n` +
        `  remedy: just journeys-engine   (once; 18 MB from the publishing origin)`,
    };
  }
  await mkdir(dest, { recursive: true });
  await cp(cache, dest, { recursive: true });
  return { staged: true, from: "cache" };
}

export { CACHE_DIRNAME as cacheDirName };

/**
 * WHICH ENGINE THIS RUN MEASURED AGAINST.
 *
 * A verdict from this suite is a statement about three artefacts, and until now
 * it named two: the built site, and (since `hydrate/build.sh` learned to print
 * its own bytes) the hydration bundle. The third is the replay engine, and it is
 * the one nothing in this repository pins — `fetch-engine.sh` deliberately takes
 * whatever the publisher is serving, for the reason its header gives, so it can
 * and does change under a run.
 *
 * IT CHANGED UNDER THIS SUITE AND COST A FULL DIAGNOSIS. Journey 07
 * (`a-value-can-be-traced-to-its-origin`) was RED for three consecutive runs on
 * one commit, one pinned bundle and one corpus, and GREEN on the same three
 * against a different engine binary:
 *
 *   wasm cf79c4bf…  (what blocktracer.org serves)   GREEN  2 of 6 hops classified
 *   wasm 01bc376d…  (what the publisher served)     RED    0 of 6, 6 source-unavailable
 *
 * Two agents reached opposite verdicts on the same commit, and neither
 * transcript contained the one number that separated them. So the hashes are
 * printed on every run and written into `--json`, for the same reason the bundle
 * sha is: a verdict with no artefact identity beside it cannot be checked by
 * anyone who was not there.
 *
 * The wasm alone would nearly do, but all three are hashed because `worker.js`
 * and `db_backend.js` are the halves a partial or half-overwritten copy leaves
 * mismatched, and that is a state this directory has already seen.
 */
/**
 * WHICH BUNDLE THIS RUN MEASURED AGAINST.
 *
 * `hydrate/build.sh` prints its own `bytes:`/`sha256:`; `run.mjs` did not, and
 * the gap between those two facts cost two separate misreports of journey 07 in
 * one day. Two agents each measured that journey carefully, each reported an
 * honest verdict, and the verdicts disagreed — and neither transcript contained
 * the one number that would have settled it in a line, because the run does not
 * rebuild and will happily drive whatever `dist/` already holds.
 *
 * Asked for the sha of the bundle their run drove, one agent could only quote
 * the figure from a `build.sh` invocation that had written that `dist` at some
 * earlier point. That is a reconstruction, not a measurement, and it is exactly
 * what this removes: the bytes are hashed HERE, from the tree the browser is
 * about to load, at the moment it is loaded.
 */
export async function bundleIdentity(distDir) {
  const { createHash } = await import("node:crypto");
  const { readFile } = await import("node:fs/promises");
  try {
    const buf = await readFile(join(distDir, "assets", "hydrate.js"));
    return { bytes: buf.length, sha256: createHash("sha256").update(buf).digest("hex") };
  } catch {
    return null;
  }
}

export async function engineIdentity(distDir) {
  const { createHash } = await import("node:crypto");
  const { readFile } = await import("node:fs/promises");
  const files = ["worker.js", "pkg/db_backend.js", "pkg/db_backend_bg.wasm"];
  const out = {};
  for (const f of files) {
    try {
      const buf = await readFile(join(distDir, "replay-engine", f));
      out[f] = { bytes: buf.length, sha256: createHash("sha256").update(buf).digest("hex") };
    } catch {
      out[f] = null;
    }
  }
  return out;
}
