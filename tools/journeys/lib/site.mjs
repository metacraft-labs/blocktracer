// Which artefact this suite drives, and how it says so.
//
// THE ARTEFACT IS THE DEPLOYED ONE, AND THE SUITE REFUSES THE OTHER
// ----------------------------------------------------------------
// This repository builds the site two ways and they are not the same product:
//
//   `just export`            no `-d:hydrationBundle`. Pages carry NO <script>.
//                            The debug route serves its pre-hydration frame and
//                            nothing ever changes it.
//   `just export-hydrated`   what `flake.nix packages.default` builds, and
//                            therefore what CI deploys: `hydrate/build.sh
//                            --require` first, then the exporter with
//                            `-d:hydrationBundle=/assets/hydrate.js`.
//
// A journey run against the first would be a journey run against a product no
// visitor is served. Worse, the two DISAGREE — measured on `dev` at the time
// this file was written, the pre-hydration frame marks the execution position
// and the hydrated bundle then replaces it with the package manifest and marks
// nothing. A suite that drove `dist/` without checking which build wrote it
// would have reported that page as correct.
//
// So `requireHydrated` is not a convenience. It reads the served bytes and
// refuses a tree whose pages carry no hydration <script>, with exit 2 — "this
// gate did not run" — rather than judging the wrong subject.
//
// THE REPLAY ENGINE IS A SEPARATE INPUT AND ITS ABSENCE IS LOUD
// ------------------------------------------------------------
// `/replay-engine/` is 18 MB fetched from another origin and is deliberately
// not committed (see `client/hydrate/fetch-engine.sh`). Without it, hydration
// constructs a worker that 404s, reports it, and leaves the served page
// standing — a real and specified state (§7.0: "No state renders less than the
// pre-hydration page"), but NOT the state in which a session steps. Journeys
// that need a stepping session declare `needsEngine`, and the runner SKIPS
// them with a stated reason rather than passing them over a session that could
// never have stepped. A skip is reported in the verdict and is not a pass.
//
// AND THE ARTEFACT NAMES WHICH SOURCE IT IS OF, OR THE SUITE DOES NOT RUN
// ----------------------------------------------------------------------
// Everything above asks what SHAPE the tree is. None of it asked WHICH TREE it
// is. `client/dist` is a shared, gitignored directory that this runner never
// builds: `just journeys` drives whatever is already sitting there. Nothing
// pinned it — no hash, no manifest, no build id — so a run could grade a bundle
// exported from a different commit, by a different worktree, hours earlier, and
// the verdict would be typographically identical to a correct one. That is this
// layer's own signature defect (a check that passes by not running) in its other
// form: a check that runs perfectly over the wrong subject.
//
// `bundleIdentity` was not that assertion. It HASHES `assets/hydrate.js` and
// PRINTS the hash, which settles an argument after the fact but compares the
// bytes to nothing, so no run has ever failed because of it.
//
// WHAT ACTUALLY STAMPS A COMMIT INTO A TREE HERE, measured before this was
// written:
//
//   `.github/workflows/deploy-cloudflare-pages.yml`, step "Stamp the published
//   tree with what built it", writes `site/build-info.json` (a `commit` field)
//   and `site/build-id.txt` (`builtFrom <sha> branch=… run=…`). Those are the
//   ONLY artefacts in this repository that name a commit, and they are written
//   at DEPLOY time, into the wrangler upload directory — after `nix build`, by
//   CI, never by a local export.
//
//   `src/static_export.nim` stamps nothing. `client/hydrate/build.sh` prints its
//   bundle's `bytes:`/`sha256:` to stdout and writes no sidecar. `just export`,
//   `just export-hydrated` and `flake.nix packages.default` all produce a
//   `dist/` with no commit in it anywhere.
//
// SO THE STRONG CHECK IS MADE WHEN IT CAN BE, AND IS NOT FAKED WHEN IT CANNOT.
// `bundleProvenance` below is graded, and it says which grade it reached:
//
//   STAMPED   `build-info.json` / `build-id.txt` is present (a deployed or
//             CI-staged tree). Its commit is compared to the checkout's HEAD by
//             equality, and a mismatch is a refusal that PRINTS BOTH SHAS.
//
//   FRESH     No stamp — the ordinary local case. Then the real, weaker claim
//             is asserted instead: every built artefact post-dates the newest
//             source file it is a function of. This is not commit identity, and
//             the header of a run says so. It does catch the dominant real
//             cases, because `git checkout`/`git rebase` rewrites the mtime of
//             every file it changes: a `dist/` built on another commit is
//             almost always older than some source this checkout moved. It does
//             NOT catch a tree built from an identical-mtime checkout of a
//             different commit, and nothing here pretends otherwise.
//
// WHAT WOULD MAKE THE STRONG CHECK ALWAYS POSSIBLE: one line in the exporter or
// in `client/Justfile`'s `export-hydrated` writing `dist/build-info.json` with
// `git rev-parse HEAD` and the porcelain status of the build inputs — the same
// two files the deploy already writes, written by the build instead of by the
// deploy. Then this function's STAMPED branch covers every run and the mtime
// branch becomes a fallback for trees that predate the change. That is a build
// change, and this file deliberately does not make one: it reports the grade it
// reached rather than a grade it wishes for.
//
// The mtime comparison is the same judgement `tools/design/check-tokens.mjs`
// makes for D1 (`staleBuild`/`newestBuildInput`), and it is spelled the same way
// on purpose, including the rule that EQUAL mtimes are fresh — a build written
// in the same second as its last input is the ordinary clean case, and a gate
// that cried wolf on it would be switched off.

import { readFile, stat } from "node:fs/promises";
import { join, relative } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { serveDist } from "../../capture/lib/server.mjs";
import {
  BUILD_INPUT_ROOTS,
  SITE_ARTEFACTS,
  newestBuildInput,
  oldestBuiltArtefact,
  staleness,
  when,
} from "../../capture/lib/build-freshness.mjs";
import { transactions } from "./corpus.mjs";

const run = promisify(execFile);

const exists = (p) =>
  stat(p).then(
    () => true,
    () => false,
  );

/**
 * Is this tree the deployed shape — i.e. did the exporter emit the <script>?
 *
 * The tag is on the DEBUG ROUTE only, and deliberately: `client/hydrate/` is the
 * one compilation that links a debugger, and `components/layout.nim` emits the
 * script for the debugger register alone. So this is asked of a debug page, not
 * of `index.html` — which carries no script in either build and would have
 * answered "not hydrated" for both.
 *
 * The asset is checked too. `installHydrationBundle` already fails the BUILD
 * rather than shipping a <script> for a file it did not write, so a tree with
 * the tag and no bundle should be impossible; asserting it anyway costs one
 * `stat` and is the difference between trusting that invariant and observing it.
 */
export async function hydrationTagPresent(root, debugIndex) {
  if (!debugIndex) return false;
  const html = await readFile(debugIndex, "utf8").catch(() => "");
  const tagged = /<script[^>]+src="\/assets\/hydrate\.js"/.test(html);
  return tagged && (await exists(join(root, "assets", "hydrate.js")));
}

/**
 * Is `/settings`'s preset chooser a control, or a dead one the build forgot?
 *
 * THE SECOND WAY THIS TREE CAN FAIL TO BE THE DEPLOYED SHAPE, and it cost a
 * journey four hours of being read as a product defect. `renderPresetChooser`
 * serves the chooser `hidden` UNCONDITIONALLY — it never consults
 * `SettingsBundle` — and `client/settingsboot` is the only code that unhides
 * it. So a build that omits the settings bundle ships a `/settings` whose only
 * control cannot be seen or operated, which is exactly the page that was
 * deleted from that address and exactly what `installSettingsBundle`'s comment
 * says a build must never ship.
 *
 * `client/Justfile`'s `export-hydrated` omitted it while `flake.nix` and `just
 * export` both shipped it, so the LOCAL build and the DEPLOYED build disagreed
 * about `/settings` — the same class of divergence the hydration check above
 * exists for, at a different address. Journey 22 then timed out waiting for a
 * chooser that no script would ever unhide, and reported it as sixteen
 * assertions of which seven ran: a `waitForSelector` timeout, which reads as
 * "the product is broken" and was "this is not the artefact anyone deploys".
 *
 * `installSettingsBundle` cannot catch it, because its guard is
 * `if SettingsBundle.len == 0: return` — it fires when the define names a file
 * that was not built, not when the define is absent. And it must stay that
 * way: CI's screenshot tier compiles the exporter with no bundle defines at
 * all, on purpose. So the check belongs HERE, where the question is not "did
 * this build do something illegal" but "is this tree the one a visitor gets".
 *
 * Asked of the served bytes, exactly as `hydrationTagPresent` is.
 */
export async function settingsChooserLive(root) {
  const html = await readFile(join(root, "settings", "index.html"), "utf8").catch(() => "");
  // No settings page, or no chooser on it: not a question this tree can be
  // asked, and NOT a silent pass disguised as one — `applicable` says which.
  if (!/data-kb-chooser/.test(html)) return { applicable: false, ok: true };

  // Served live already (the debug route's dialog spelling). Nothing to unhide.
  if (!/data-kb-chooser[^>]*\bhidden\b/.test(html))
    return { applicable: true, ok: true, why: "the chooser is served live" };

  const tag = html.match(/<script[^>]+src="([^"]*settings[^"]*\.js)"/);
  if (!tag)
    return {
      applicable: true,
      ok: false,
      why: "the chooser is served `hidden` and the page carries no <script> for a settings bundle",
    };
  if (!(await exists(join(root, tag[1].replace(/^\/+/, "")))))
    return {
      applicable: true,
      ok: false,
      why: `the page carries <script src="${tag[1]}"> and the build did not write that file`,
    };
  return { applicable: true, ok: true };
}

export async function enginePresent(root) {
  return (
    (await exists(join(root, "replay-engine", "worker.js"))) &&
    (await exists(join(root, "replay-engine", "pkg", "db_backend_bg.wasm")))
  );
}

// ── provenance: which source is this tree of? ──────────────────────────────
//
// The mtime half lives in `../../capture/lib/build-freshness.mjs`, because the
// capture harness needs the identical judgement about the identical trees and
// the fifteen-site audit that produced this work is a story about one question
// being answered fifteen slightly different ways. Journeys already import
// `capture/lib/server.mjs`, so this is the direction that dependency runs.

/** The two files the deploy stamps, read in the order the deploy writes them. */
async function stampedCommit(root) {
  const info = await readFile(join(root, "build-info.json"), "utf8").catch(() => null);
  if (info !== null) {
    try {
      const j = JSON.parse(info);
      if (typeof j.commit === "string" && /^[0-9a-f]{7,40}$/.test(j.commit))
        return { commit: j.commit, from: "build-info.json", branch: j.branch ?? null, builtAt: j.builtAt ?? null };
    } catch {
      /* a stamp that does not parse is no stamp; the mtime branch still runs */
    }
  }
  const line = await readFile(join(root, "build-id.txt"), "utf8").catch(() => null);
  if (line !== null) {
    const m = /\bbuiltFrom\s+([0-9a-f]{7,40})\b/.exec(line);
    if (m) return { commit: m[1], from: "build-id.txt", branch: null, builtAt: null };
  }
  return null;
}

async function headCommit(repoRoot) {
  try {
    const { stdout } = await run("git", ["-C", repoRoot, "rev-parse", "HEAD"]);
    return stdout.trim() || null;
  } catch {
    return null;
  }
}

async function dirtyInputCount(repoRoot) {
  try {
    const { stdout } = await run("git", [
      "-C",
      repoRoot,
      "status",
      "--porcelain",
      "--",
      ...BUILD_INPUT_ROOTS.map((parts) => join(...parts)),
    ]);
    return stdout.split("\n").filter((l) => l.trim() !== "").length;
  } catch {
    return null;
  }
}

/**
 * WHICH SOURCE THIS TREE IS OF — asserted, not reported.
 *
 * Returns `{ ok, signal, detail, remedy }`. `ok` is only ever the boolean
 * `true` when a grade was actually reached; every other path sets it false and
 * fills `detail` with the evidence. The caller compares with `!== true` — a
 * strict equality, for the same reason `run.mjs` made `countOk` one: a field
 * that is missing, undefined or a truthy string must refuse, never pass.
 *
 * See this file's header for what a stamp is, who writes one, and why the
 * unstamped grade is the weaker claim it says it is.
 */
export async function bundleProvenance(root, repoRoot) {
  const stale = staleness(root, repoRoot);
  if (stale && stale.why === "no-artefacts") {
    return {
      ok: false,
      signal: "no-artefacts",
      detail:
        `${root} contains none of ${SITE_ARTEFACTS.map((p) => join(...p)).join(", ")}, so there is\n` +
        `  nothing whose provenance could be asked about.`,
      remedy: "cd client && just export-hydrated",
    };
  }

  const head = await headCommit(repoRoot);
  const stamp = await stampedCommit(root);

  if (stamp) {
    if (head === null) {
      return {
        ok: false,
        signal: "stamped-but-no-head",
        detail:
          `${root}/${stamp.from} says this tree was built from commit ${stamp.commit},\n` +
          `  and ${repoRoot} does not answer \`git rev-parse HEAD\`, so the two cannot be\n` +
          `  compared. A stamped tree whose stamp nothing checks is the state this gate exists\n` +
          `  to end; it refuses rather than driving it unverified.`,
        remedy: "run this from a git checkout of the commit the tree was built from",
      };
    }
    // Prefix, not equality: `build-id.txt` may carry a short sha, and the
    // deploy writes both a full `commit` and a `shortCommit`.
    const same = head.startsWith(stamp.commit) || stamp.commit.startsWith(head);
    if (!same) {
      return {
        ok: false,
        signal: "commit-mismatch",
        detail:
          `the tree at ${root} was built from a DIFFERENT COMMIT than this checkout.\n` +
          `    found (${stamp.from}):  ${stamp.commit}${stamp.branch ? `  branch=${stamp.branch}` : ""}${
            stamp.builtAt ? `  builtAt=${stamp.builtAt}` : ""
          }\n` +
          `    expected (HEAD):     ${head}\n` +
          `  Every journey below would be a true sentence about the wrong artefact.`,
        remedy: `cd client && just export-hydrated   (or check out ${stamp.commit} and re-run)`,
      };
    }
    return {
      ok: true,
      signal: "stamped",
      detail: `${stamp.from} names commit ${stamp.commit}, which is this checkout's HEAD`,
      remedy: null,
    };
  }

  // No stamp. Say so, and assert the weaker claim that IS available.
  if (stale && stale.why === "no-mtime") {
    return {
      ok: false,
      signal: "no-mtime-and-no-stamp",
      detail:
        `${relative(repoRoot, stale.built.path) || stale.built.path} has mtime ${when(stale.built.mtimeMs)} — the\n` +
        `  epoch stamp Nix gives every file in the store. So this tree is a store path (or a\n` +
        `  copy that preserved store mtimes), it carries no build-info.json, and NEITHER of\n` +
        `  the two ways of establishing what built it can speak. Nothing is judged.`,
      remedy:
        "copy the store path out before driving it, as `just journeys-deployed` does\n" +
        "          (cp -R result/. .journey-site/ && chmod -R u+w .journey-site)",
    };
  }

  if (stale && stale.why === "no-inputs") {
    return {
      ok: false,
      signal: "no-inputs",
      detail:
        `no build inputs found under ${BUILD_INPUT_ROOTS.map((p) => join(...p)).join(", ")} in ${repoRoot}.\n` +
        `  With no source to compare against, "this build is current" is a claim about nothing —\n` +
        `  the vacuous pass this whole layer is written against.`,
      remedy: "point --dist at a tree exported from THIS checkout, and run from the checkout",
    };
  }

  if (stale && stale.why === "stale") {
    return {
      ok: false,
      signal: "stale",
      detail:
        `the tree at ${root} PREDATES its own source.\n` +
        `    built:  ${relative(root, stale.built.path) || stale.built.path}  ${when(stale.built.mtimeMs)}\n` +
        `    source: ${relative(repoRoot, stale.source.path)}  ${when(stale.source.mtimeMs)}\n` +
        `  Nothing here stamps a commit into a local export (see lib/site.mjs's header), so the\n` +
        `  strongest available statement is this one — and it is enough: the bytes about to be\n` +
        `  driven cannot contain that source change. This checkout's HEAD is ${head ?? "<unknown>"}.`,
      remedy: "cd client && just export-hydrated",
    };
  }

  // NO CATCH-ALL PASS. `staleness` is the only thing that can produce a `why`,
  // and every one it defines is answered above; a `why` this function does not
  // know is a new not-fresh state and must refuse rather than fall through into
  // the green return below. Same lock as `run.mjs`'s `countOk`, at a different
  // door.
  if (stale) {
    return {
      ok: false,
      signal: `unhandled-${stale.why}`,
      detail: `build-freshness reported a state this function does not know how to grade: ${stale.message}`,
      remedy: "teach lib/site.mjs:bundleProvenance about this state",
    };
  }

  const built = oldestBuiltArtefact(root);
  const newest = newestBuildInput(repoRoot);
  const dirty = await dirtyInputCount(repoRoot);
  return {
    ok: true,
    signal: "fresh-unstamped",
    detail:
      `no build-info.json in this tree — NOTHING STAMPS A COMMIT INTO A LOCAL EXPORT, so this\n` +
      `                 is NOT commit identity. What is asserted: every built artefact post-dates the newest\n` +
      `                 source under ${BUILD_INPUT_ROOTS.map((p) => join(...p)).join(", ")}.\n` +
      `                 oldest artefact ${relative(root, built.path) || built.path} ${when(built.mtimeMs)} >= newest source\n` +
      `                 ${relative(repoRoot, newest.path)} ${when(newest.mtimeMs)}; HEAD ${head ?? "<unknown>"}` +
      (dirty ? `, ${dirty} uncommitted build input(s)` : ""),
    remedy: null,
  };
}

/**
 * Resolve, describe and serve the artefact under test.
 * Throws with `.exitCode = 2` for every "did not run" condition, so a missing
 * input can never be mistaken for a clean sweep.
 */
export async function openSite(root, repoRoot) {
  if (!(await exists(join(root, "index.html")))) {
    const e = new Error(
      `no exported site at ${root}\n` +
        `  remedy: cd client && just export-hydrated   (and, for stepping journeys,\n` +
        `          ./hydrate/fetch-engine.sh dist/replay-engine)`,
    );
    e.exitCode = 2;
    throw e;
  }

  // The tag lives on the debug route, so a debug page has to be found before
  // the question can be asked. A tree with no debug page at all is itself a
  // "did not run" condition: every journey here quantifies over that route, and
  // all of them would pass vacuously over a tree that has none.
  const txs = await transactions(root);
  if (txs.length === 0) {
    const e = new Error(
      `the exported site at ${root} contains no /{chain}/tx/{hash}/debug page.\n` +
        `  Every journey quantifies over that route; all of them would pass over nothing.`,
    );
    e.exitCode = 2;
    throw e;
  }
  const hydrated = await hydrationTagPresent(root, join(root, txs[0].chain, "tx", txs[0].hash, "debug", "index.html"));
  if (!hydrated) {
    const e = new Error(
      `the site at ${root} carries no hydration <script>.\n` +
        `  This is the \`just export\` build, which ships zero JS. The deployed\n` +
        `  build — flake.nix packages.default — ships the hydration bundle, and the\n` +
        `  two DISAGREE about the debug route. Driving this one would judge a\n` +
        `  product no visitor is served.\n` +
        `  remedy: cd client && just export-hydrated`,
    );
    e.exitCode = 2;
    throw e;
  }

  // The same refusal as the hydration tag, at the other address the local and
  // deployed builds were found to disagree about. Exit 2 — "this gate did not
  // run" — because a journey that drives this tree is not driving the product.
  const settings = await settingsChooserLive(root);
  if (settings.applicable && !settings.ok) {
    const e = new Error(
      `the site at ${root} serves /settings with a chooser no script can unhide:\n` +
        `  ${settings.why}.\n` +
        `  \`renderPresetChooser\` serves it \`hidden\` and client/settingsboot is the\n` +
        `  only code that unhides it, so this build ships a control a visitor can\n` +
        `  neither see nor operate — while flake.nix packages.default, the artefact\n` +
        `  CI deploys, ships the bundle. Driving this tree would judge /settings as\n` +
        `  broken when what is broken is the build that wrote it.\n` +
        `  remedy: cd client && just export-hydrated`,
    );
    e.exitCode = 2;
    throw e;
  }

  // WHICH SOURCE THESE BYTES ARE OF. Last of the refusals and the widest: the
  // three above ask what shape the tree is, this one asks whether it is a tree
  // of THIS checkout at all. `!== true` and not `!prov.ok`, so a verdict that
  // came back without the field refuses instead of being waved through — the
  // same strictness `run.mjs` gives `countOk`.
  const provenance = await bundleProvenance(root, repoRoot);
  if (provenance.ok !== true) {
    const e = new Error(
      `PROVENANCE REFUSED (${provenance.signal}): ${provenance.detail}\n` +
        (provenance.remedy ? `  remedy: ${provenance.remedy}\n` : "") +
        `  This gate DID NOT RUN. A journey run over a tree of unknown origin is a true\n` +
        `  sentence about an artefact nobody chose, and reads exactly like a clean sweep.`,
    );
    e.exitCode = 2;
    throw e;
  }

  const engine = await enginePresent(root);
  const server = await serveDist(root);
  return {
    root,
    provenance,
    // The repository, not the built site: the tour manifest is a fixture in
    // the source tree, not an exported asset, and a journey that reads it needs
    // to be told where the tree is rather than guessing from `dist`.
    repoRoot,
    origin: server.origin,
    hydrated,
    engine,
    close: () => server.close(),
  };
}

export { serveDist };
