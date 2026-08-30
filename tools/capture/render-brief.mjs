#!/usr/bin/env node
// VD.1 — render the per-view expected-elements section of the review brief
// from `expectations.mjs`, in place, between the generated markers.
//
//   node tools/capture/render-brief.mjs           rewrite the brief
//   node tools/capture/render-brief.mjs --check    exit 1 if it would change
//   node tools/capture/render-brief.mjs --stdout   print the section only
//
// The section is generated rather than hand-maintained because it has to stay
// in step with `views.mjs` — 62 blocks that must be re-checked whenever a view
// is added, renamed or split is exactly the kind of bookkeeping that rots.

import { readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";

import { VIEWS, VIEWS_BY_ID, sizesFor, themesFor } from "./views.mjs";
import { EXPECTATIONS, resolveExpectation } from "./expectations.mjs";
import { engineScenario, WORKER_PATH } from "./lib/engine-stubs.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");
export const BRIEF_PATH = join(REPO_ROOT, "tools", "visual-review-brief.md");

export const BEGIN = "<!-- BEGIN GENERATED: expectations — do not edit by hand -->";
export const END = "<!-- END GENERATED -->";
const REGEN = "<!-- regenerate with: node tools/capture/render-brief.mjs -->";

/** The heading a view's block is found under. `check-brief.mjs` greps for this. */
export const blockHeading = (id) => `### View: \`${id}\``;

function renderBlock(view) {
  const e = resolveExpectation(view.id);
  if (!e) throw new Error(`no expectation block for view '${view.id}'`);

  const out = [];
  out.push(blockHeading(view.id));
  out.push("");
  out.push(`> ${e.summary}`);
  out.push("");

  const axes = `${sizesFor(view).join(" · ")} × ${themesFor(view).join(" · ")}`;
  const state =
    view.status === "ready"
      ? "`ready`"
      : `\`pending\` — ${view.pendingReason}`;
  out.push(
    `| | |`,
    `| --- | --- |`,
    `| **Register** | ${e.register} — apply rubric ${e.register === "debugger" ? "B (§6)" : "A (§5)"} |`,
    `| **Spec** | ${e.spec} |`,
    `| **Captured at** | ${axes} |`,
    `| **Capture status** | ${state} |`,
  );
  // The provenance rows, for the views whose sentences exist only under
  // hydration. They are in the BRIEF and not only in a source comment because
  // the brief is what a reviewer reads, and both facts change how the image may
  // be graded: an absence is only meaningful if the script ran, and a page
  // whose engine was supplied by the harness must never be graded as though a
  // real engine produced what is on it.
  if (view.hydrated) {
    const scenario = engineScenario(view.engine);
    out.push(
      `| **Captured from** | the HYDRATED build (\`client/dist-hydrated\`, exported with \`-d:hydrationBundle\`). The sentence this view is about is drawn by the shipped hydration bundle and can appear on no statically exported page — which is why it had never been reviewed. Everything else in the frame is the page the ordinary exporter writes |`,
    );
    out.push(
      `| **Replay engine** | STAND-IN. The capture server answers \`${WORKER_PATH}\` with ${scenario.label} (\`tools/capture/lib/engine-stubs.mjs\`); it stands in for ${scenario.impersonates}. Nothing in the image is drawn by it — the banner is \`components/debugger.renderEngineFailure\` over a string from \`client/hydrate/hydrate.nim\`. Grade the sentence and the treatment; do not grade the engine |`,
    );
  }
  out.push("");

  out.push("**Must show** — absent ⇒ P1, rating ≤ 4:");
  out.push("");
  for (const b of e.inherited ?? []) {
    out.push(`- *Inherited backbone \`${b.key}\` (${b.spec}):*`);
    for (const item of b.items) out.push(`  - ${item}`);
  }
  for (const item of e.mustShow) out.push(`- ${item}`);
  out.push("");

  if (e.mustNotShow?.length) {
    out.push("**Must not show** — present ⇒ P1, rating ≤ 4:");
    out.push("");
    for (const item of e.mustNotShow) out.push(`- ${item}`);
    out.push("");
  }

  if (e.watchFor?.length) {
    out.push("**Watch for** — judged after the presence check, normally P2/P3:");
    out.push("");
    for (const item of e.watchFor) out.push(`- ${item}`);
    out.push("");
  }

  return out.join("\n");
}

export function renderSection() {
  const ready = VIEWS.filter((v) => v.status === "ready");
  const out = [];

  out.push(
    `*${VIEWS.length} named views, ${VIEWS.length} blocks — generated from \`tools/capture/expectations.mjs\`.` +
      ` ${ready.length} are currently \`ready\` to capture; the rest are listed with the reason their route or state is not served yet,` +
      ` because a view that cannot be captured still has to have an expectation before it can be.*`,
  );
  out.push("");

  const groups = [
    ["Explorer register — entry and navigation", (v) => v.register === "explorer" && ENTRY.has(v.id)],
    ["Explorer register — the transaction page", (v) => v.register === "explorer" && TX.has(v.id)],
    ["Explorer register — address, source, search, utility", (v) => v.register === "explorer" && UTIL.has(v.id)],
    ["Debugger register", (v) => v.register === "debugger"],
    ["Degraded states on the transaction page", (v) => v.register === "explorer" && DEGRADED.has(v.id)],
    ["Shell-level degraded state", (v) => v.register === "explorer" && SHELL.has(v.id)],
  ];

  const placed = new Set();
  for (const [title, pred] of groups) {
    const members = VIEWS.filter((v) => !placed.has(v.id) && pred(v));
    if (!members.length) continue;
    out.push(`#### ${title}`);
    out.push("");
    for (const v of members) {
      placed.add(v.id);
      out.push(renderBlock(v));
    }
  }
  const leftover = VIEWS.filter((v) => !placed.has(v.id));
  if (leftover.length) {
    out.push("#### Uncategorised");
    out.push("");
    for (const v of leftover) out.push(renderBlock(v));
  }

  return out.join("\n").trimEnd() + "\n";
}

// Grouping is presentational only; membership is derived from the view ids so
// a new view lands in a group without editing a list twice.
const ENTRY = new Set([
  "home", "home--live-demo", "chains-index", "chain-overview", "chain-overview--stale",
  "blocks-list", "blocks-list--row-expanded", "block-detail", "block-detail--genesis-edge",
  "txs-list", "txs-list--cards",
]);
const TX = new Set([
  "tx-detail", "tx-detail--session", "tx-detail--dense", "tx-detail--hydrated", "tx-detail--decoded-input",
  "tx-detail--events", "tx-detail--internal-calls", "tx-detail--state-changes", "tx-detail--raw",
]);
const UTIL = new Set([
  "address", "contract-source", "contract-source--unverified", "search", "search--ambiguous",
  "search--cross-chain", "search--not-found", "settings", "static-content", "not-found",
]);
const SHELL = new Set(["shell--cdn-unreachable"]);
const DEGRADED = new Set(
  VIEWS.filter(
    (v) => v.id.startsWith("tx-detail--") && !TX.has(v.id),
  ).map((v) => v.id),
);

// ── main ───────────────────────────────────────────────────────────────────

async function main(argv) {
  const check = argv.includes("--check");
  const toStdout = argv.includes("--stdout");

  const section = renderSection();
  if (toStdout) {
    process.stdout.write(section);
    return 0;
  }

  const brief = await readFile(BRIEF_PATH, "utf8");
  const b = brief.indexOf(BEGIN);
  const e = brief.indexOf(END);
  if (b < 0 || e < 0 || e < b) {
    console.error(`${BRIEF_PATH}: generated markers missing or out of order`);
    return 2;
  }

  const next =
    brief.slice(0, b) + BEGIN + "\n" + REGEN + "\n\n" + section + "\n" + brief.slice(e);

  if (next === brief) {
    console.log(`brief is up to date (${EXPECTATIONS.length} blocks)`);
    return 0;
  }
  if (check) {
    console.error(
      `${BRIEF_PATH} is STALE — the generated section does not match expectations.mjs.\n` +
        `run: node tools/capture/render-brief.mjs`,
    );
    return 1;
  }
  await writeFile(BRIEF_PATH, next);
  console.log(`rewrote ${BRIEF_PATH} (${EXPECTATIONS.length} blocks, ${VIEWS_BY_ID.size} views)`);
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv.slice(2))
    .then((c) => process.exit(c))
    .catch((err) => {
      console.error(`render-brief failed: ${err.message}`);
      process.exit(2);
    });
}
