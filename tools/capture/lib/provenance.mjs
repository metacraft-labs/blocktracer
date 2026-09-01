// WHICH BUILD THIS IMAGE IS OF — written once, rendered into both channels.
//
// This module exists because the same fact was needed in two places and lived
// in one, and the one it lived in is the one a reviewer is told not to read.
//
// `render-brief.mjs` has rendered a **Captured from** row and a **Replay
// engine** row into the brief's §4 block for the eight hydrated views since
// they landed. Their purpose is explicit: "a page whose engine was supplied by
// the harness must never be graded as though a real engine produced what is on
// it." But `review-prompt.mjs` inlines the expectation block itself and opens
// every prompt with *"Skip section 4; your view's block is inlined below"* —
// and its inlined copy carried the summary, the register, the spec and the
// three lists, and neither provenance row. So the sentence written to stop a
// misgrading has never been read by a reviewer.
//
// That is the same failure the rows describe, one layer up: a fact that is true
// of the artefact, recorded in the wrong artefact. vd10-r2's adversarial
// reviewer had to CATCH ITSELF on the engine-loading state, because nothing in
// its prompt said the state was a capture-build artefact — and the brief said
// so all along, in the section its prompt told it to skip.
//
// So the sentences live here, both consumers render them, and neither can
// acquire a copy that drifts from the other.

import { engineScenario, WORKER_PATH } from "./engine-stubs.mjs";

/** The plain tree, on a route the deployed build serves with the bundle. */
export const DIVERGENCE_NOTE =
  "the PLAIN build (`client/dist`, `just export`), which ships **no JavaScript**. " +
  "The deployed site (`flake.nix` `packages.default`) exports this same route with " +
  "`-d:hydrationBundle=/assets/hydrate.js`, and `debugLayout` emits that `<script>` here — " +
  "so **this image is not the page a visitor loads**. Before any engine work the bundle " +
  "upgrades every `.copyable` and `[data-copy]` value into a `role=\"button\"` copy control " +
  "and rewrites its `title`; what the live session then paints is larger still and is NOT " +
  "measured, because the replay engine is not vendored here. So this is a LOWER BOUND on " +
  "the difference. **A finding about behaviour that exists on only one of these builds must " +
  "say which build it is about.**";

/** The plain tree, on a route that is the same bytes either way. */
export const NO_DIVERGENCE_NOTE =
  "the PLAIN build (`client/dist`, `just export`). This route is served by `pageLayout`, " +
  "which emits no hydration `<script>`, so the deployed build serves these same bytes and " +
  "the image IS the page a visitor loads.";

/** No committed map — a checkout that has never built both trees. Says so
 *  rather than guessing, because a confident wrong answer here is the defect. */
export const UNMEASURED_NOTE =
  "UNMEASURED. `tools/capture/hydration-divergence.json` is missing, so which build serves " +
  "this route is not known here — run `just capture-hydration-divergence-write` over a built " +
  "pair of trees before grading anything build-dependent.";

/**
 * The provenance rows for one view, as `{ label, text }`.
 *
 * `divergence` is the committed map's `views` object, or null. Passed in rather
 * than read here so the brief renderer and the prompt renderer cannot disagree
 * about which map they consulted.
 */
export function provenanceRows(view, divergence) {
  const rows = [];
  if (view.hydrated) {
    const scenario = engineScenario(view.engine);
    rows.push({
      label: "Captured from",
      text:
        "the HYDRATED build (`client/dist-hydrated`, exported with `-d:hydrationBundle`). " +
        "The sentence this view is about is drawn by the shipped hydration bundle and can " +
        "appear on no statically exported page — which is why it had never been reviewed. " +
        "Everything else in the frame is the page the ordinary exporter writes.",
    });
    rows.push({
      label: "Replay engine",
      text:
        `STAND-IN. The capture server answers \`${WORKER_PATH}\` with ${scenario.label} ` +
        `(\`tools/capture/lib/engine-stubs.mjs\`); it stands in for ${scenario.impersonates}. ` +
        "Nothing in the image is drawn by it — the banner is " +
        "`components/debugger.renderEngineFailure` over a string from " +
        "`client/hydrate/hydrate.nim`. Grade the sentence and the treatment; do not grade " +
        "the engine.",
    });
    return rows;
  }
  if (view.status !== "ready") return rows;
  const entry = divergence?.[view.id];
  rows.push({
    label: "Captured from",
    text: !entry ? UNMEASURED_NOTE : entry.shipsBundle ? DIVERGENCE_NOTE : NO_DIVERGENCE_NOTE,
  });
  return rows;
}

/** The same rows as plain lines, for the prompt, which is not a table. */
export function provenanceLines(view, divergence) {
  return provenanceRows(view, divergence).map(
    ({ label, text }) => `${label.toUpperCase()}: ${text.replace(/`/g, "")}`,
  );
}
