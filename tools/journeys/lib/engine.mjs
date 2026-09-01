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
