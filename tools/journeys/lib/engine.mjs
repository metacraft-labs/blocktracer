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

import { cp, stat, mkdir, rm } from "node:fs/promises";
import { join } from "node:path";

export const CACHE_DIRNAME = ".replay-engine-cache";

const exists = (p) =>
  stat(p).then(
    () => true,
    () => false,
  );

/**
 * The three files that ARE the engine's identity, and the reason there are
 * three: `worker.js` and `db_backend.js` are the halves a partial or
 * half-overwritten copy leaves mismatched, and that is a state this directory
 * has already seen.
 */
export const ENGINE_FILES = ["worker.js", "pkg/db_backend.js", "pkg/db_backend_bg.wasm"];

/** `{ file: {bytes, sha256} | null }` for an engine ROOT (not a dist). */
export async function identityOf(engineRoot) {
  const { createHash } = await import("node:crypto");
  const { readFile } = await import("node:fs/promises");
  const out = {};
  for (const f of ENGINE_FILES) {
    try {
      const buf = await readFile(join(engineRoot, f));
      out[f] = { bytes: buf.length, sha256: createHash("sha256").update(buf).digest("hex") };
    } catch {
      out[f] = null;
    }
  }
  return out;
}

const complete = (id) => ENGINE_FILES.every((f) => id[f] !== null);
const sameEngine = (a, b) => ENGINE_FILES.every((f) => (a[f]?.sha256 ?? "a") === (b[f]?.sha256 ?? "b"));
const shortId = (id) =>
  ENGINE_FILES.map((f) => `${f} ${id[f] ? `${id[f].bytes} bytes ${id[f].sha256.slice(0, 16)}…` : "<missing>"}`).join(
    "\n                  ",
  );

/**
 * Stage the cached engine into `dist/replay-engine/`, and DECIDE WHETHER IT IS
 * ALREADY THERE BY COMPARING BYTES — never by asking whether a file exists.
 *
 * WHAT THIS USED TO BE, AND WHY IT WAS THE CAMPAIGN'S OTHER SIGNATURE DEFECT:
 *
 *     if (await exists(join(dest, "worker.js"))) return { staged: true, from: "the site tree" };
 *
 * One `stat`, on one of the three files, deciding "already staged". Existence
 * is not freshness, and here it was not even completeness:
 *
 *   * A HALF-COPY — `worker.js` written, `pkg/db_backend_bg.wasm` not — took
 *     this branch and reported `staged: true`. `enginePresent` then read the
 *     wasm, answered false, and every stepping journey SKIPPED with the reason
 *     "there is no engine in this tree", while the cache holding a complete one
 *     was never consulted. A repairable state, reported as an absent artefact.
 *
 *   * A LEFTOVER ENGINE beat a re-fetched cache in silence. `just
 *     journeys-engine` re-fetches into `client/.replay-engine-cache`; a `dist`
 *     staged from the PREVIOUS cache still has `worker.js`, so the new engine
 *     was never copied and the run measured the old one. That is not a
 *     hypothetical cost: `engineIdentity`'s header records eleven journeys
 *     flipping between two engine binaries on ONE commit, one bundle and one
 *     corpus — and this function is how the wrong one gets driven without
 *     anybody choosing it.
 *
 * SO THE PREDICATE IS BYTE IDENTITY WITH THE CACHE, and disagreement is
 * REFUSED rather than resolved by a rule nobody wrote down. Two complete but
 * different engines are available and nothing in the invocation says which was
 * meant; picking either silently is exactly what produced two opposite verdicts
 * from two careful agents. The refusal prints both hashes and the two one-line
 * remedies, which is the information neither transcript had.
 *
 * The four states are named, so "no session" is never left unexplained:
 *   staged from the cache        — the tree had no engine, or an incomplete one.
 *   already staged               — the tree's engine IS the cache's, byte for byte.
 *   unverified                   — a complete engine in the tree and no cache to
 *                                  compare it against. Reused, and SAID to be
 *                                  unverified, because a silent "present" here
 *                                  is the same lie in a smaller font.
 *   conflict                     — two different complete engines. Refused.
 */
export async function stageEngine(distDir, cacheDir) {
  const dest = join(distDir, "replay-engine");
  const inTree = await identityOf(dest);
  const inCache = await identityOf(cacheDir);

  if (!complete(inCache)) {
    if (complete(inTree))
      return {
        staged: true,
        from: "the site tree (UNVERIFIED — no cache to compare it against)",
        identity: inTree,
      };
    return {
      staged: false,
      from: null,
      identity: inTree,
      remedy:
        `no complete engine in ${cacheDir}.\n` +
        `  remedy: just journeys-engine   (once; 18 MB from the publishing origin)`,
    };
  }

  if (complete(inTree)) {
    if (sameEngine(inTree, inCache))
      return { staged: true, from: "the site tree (byte-identical to the cache)", identity: inTree };
    return {
      staged: false,
      from: null,
      identity: inTree,
      conflict: {
        dest,
        cacheDir,
        inTree,
        inCache,
        why:
          `two DIFFERENT complete replay engines are available and nothing says which was meant.\n` +
          `    in ${dest}:\n                  ${shortId(inTree)}\n` +
          `    in ${cacheDir}:\n                  ${shortId(inCache)}\n` +
          `  The engine is the one artefact this repository does not pin, and it has already\n` +
          `  decided a verdict on its own: eleven journeys flipped between two binaries on one\n` +
          `  commit, one bundle and one corpus. Reusing whichever happened to be in the tree —\n` +
          `  which is what an existence check does — is how the wrong one gets driven with\n` +
          `  nobody choosing it.\n` +
          `  remedy: drive the cache      rm -rf ${dest}      (then re-run)\n` +
          `      or: drive the tree       node tools/journeys/run.mjs --engine-cache ${dest}`,
      },
    };
  }

  // Absent, or present and INCOMPLETE — the half-copy the old existence check
  // called "staged". Overwritten from the cache, not merged into: an engine
  // assembled from two fetches is a third engine nobody published.
  await rm(dest, { recursive: true, force: true });
  await mkdir(dest, { recursive: true });
  await cp(cacheDir, dest, { recursive: true });
  return { staged: true, from: "cache", identity: await identityOf(dest) };
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

/** The same three hashes, asked of a DIST. One list of files, in `ENGINE_FILES`,
 *  so the set `stageEngine` compares and the set a verdict names cannot drift
 *  apart — they were two literals until the staging decision started reading
 *  bytes, and a comparison over a different set than the one reported is a
 *  verdict about something other than what it prints. */
export async function engineIdentity(distDir) {
  return identityOf(join(distDir, "replay-engine"));
}
