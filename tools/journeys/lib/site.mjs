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

  const engine = await enginePresent(root);
  const server = await serveDist(root);
  return {
    root,
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
