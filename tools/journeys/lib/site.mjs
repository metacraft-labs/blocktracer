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

import { readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { serveDist } from "../../capture/lib/server.mjs";
import { transactions } from "./corpus.mjs";

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

export async function enginePresent(root) {
  return (
    (await exists(join(root, "replay-engine", "worker.js"))) &&
    (await exists(join(root, "replay-engine", "pkg", "db_backend_bg.wasm")))
  );
}

/**
 * Resolve, describe and serve the artefact under test.
 * Throws with `.exitCode = 2` for every "did not run" condition, so a missing
 * input can never be mistaken for a clean sweep.
 */
export async function openSite(root) {
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

  const engine = await enginePresent(root);
  const server = await serveDist(root);
  return {
    root,
    origin: server.origin,
    hydrated,
    engine,
    close: () => server.close(),
  };
}

export { serveDist };
