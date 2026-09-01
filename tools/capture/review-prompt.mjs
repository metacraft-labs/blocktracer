#!/usr/bin/env node
// VD.1 — generate the review sub-agent prompt for one captured image.
//
//   node tools/capture/review-prompt.mjs --view tx-detail --size wide --theme light --lens L2
//   node tools/capture/review-prompt.mjs --view tx-detail --size wide --theme light --all
//   node tools/capture/review-prompt.mjs --view tx-detail --size wide --theme light --lens ADV
//
// The prompt names the brief by path (input tokens, read once by the sub-agent)
// and inlines ONLY the one expectation block the reviewer needs. The brief's
// §4 is 62 blocks; handing a reviewer the other 61 is 30k tokens of other
// people's pages, and a reviewer that skims will skim the wrong block.
//
//   --changed "<text>"   what this iteration changed, for a follow-up review
//   --json               emit {lens, prompt} pairs instead of text
//   --image <path>       override the image path (used by break-check.mjs)

import { existsSync } from "node:fs";
import { dirname, join, relative, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";

import { VIEWS_BY_ID, SIZES, THEMES, imageName, sizesFor, themesFor } from "./views.mjs";
import { resolveExpectation } from "./expectations.mjs";
import { provenanceLines } from "./lib/provenance.mjs";
import { readMap as readDivergenceMap } from "./check-hydration-divergence.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");
const BRIEF_REL = "tools/visual-review-brief.md";

export const LENSES = {
  L1: {
    name: "Typography and hierarchy",
    looksAt:
      "the type scale and its levels; weight/size relationships; measure and line-height; monospace and numeric treatment; truncation strategy; whether the hierarchy is readable without reading",
    notYours: "colour choices, spacing between blocks, layout structure",
  },
  L2: {
    name: "Layout, alignment and spacing",
    looksAt:
      "grid adherence; edge and baseline alignment; the spacing scale and whether it is one scale; proximity as grouping; overflow, truncation and horizontal scroll; balance and eye flow at this viewport",
    notYours: "which typeface, which colour, how much information is shown",
  },
  L3: {
    name: "Colour, contrast and theme",
    looksAt:
      "palette cohesion; surface levels and borders; text emphasis levels; status/severity/diff roles and whether each means one thing; contrast of every text-on-surface pair including disabled and placeholder states; whether this theme is designed or inherited by inversion",
    notYours: "spacing, type scale, information architecture",
  },
  L4: {
    name: "Information density and legibility",
    looksAt:
      "whether the surface carries as much as it can while staying scannable; row and pane density; what is dropped at this viewport and whether the right things were dropped; behaviour at realistic volume; small-text readability",
    notYours: "brand identity, colour harmony",
  },
  L5: {
    name: "Brand and register consistency",
    looksAt:
      "whether the surface belongs to its register and to the 2026 web design direction (explorer) or the CodeTracer desktop app (debugger); consistency of shared primitives across registers; register crossings and whether they read as deliberate; the tone of the copy, which is a design property in this product",
    notYours: "pixel alignment, contrast ratios",
  },
  ADV: {
    name: "Adversarial reviewer",
    adversarial: true,
  },
};

export const ALL_LENSES = Object.keys(LENSES);

// ── The expectation block, rendered for inlining ───────────────────────────

export function expectationText(viewId) {
  const e = resolveExpectation(viewId);
  if (!e) throw new Error(`no expectation block for view '${viewId}'`);
  const out = [];
  out.push(`View: \`${viewId}\` — ${e.summary}`);
  out.push(`Register: ${e.register}  (apply rubric ${e.register === "debugger" ? "B, brief §6" : "A, brief §5"})`);
  out.push(`Spec: ${e.spec}`);
  // WHICH BUILD THIS IMAGE IS OF, in the prompt and not only in the brief.
  //
  // Every prompt below opens with "Skip section 4", and section 4 is where the
  // brief's provenance rows live — so until VD.11 the two sentences written to
  // stop an image being misgraded were in the one section their reader was told
  // not to read. `lib/provenance.mjs` holds both, and this is the channel that
  // actually reaches a reviewer.
  const view = VIEWS_BY_ID.get(viewId);
  if (view) {
    for (const line of provenanceLines(view, readDivergenceMap()?.views)) {
      out.push("");
      out.push(line);
    }
  }
  out.push("");
  out.push("MUST SHOW — any item absent, unrecognisable or a placeholder is a P1 and caps the rating at 4:");
  for (const b of e.inherited ?? []) {
    out.push(`  (inherited backbone '${b.key}' — ${b.spec})`);
    for (const i of b.items) out.push(`  - ${i}`);
  }
  for (const i of e.mustShow) out.push(`  - ${i}`);
  if (e.mustNotShow?.length) {
    out.push("");
    out.push("MUST NOT SHOW — any item present is a P1 and caps the rating at 4:");
    for (const i of e.mustNotShow) out.push(`  - ${i}`);
  }
  if (e.watchFor?.length) {
    out.push("");
    out.push("WATCH FOR — judged only after the presence check, normally P2/P3:");
    for (const i of e.watchFor) out.push(`  - ${i}`);
  }
  return out.join("\n");
}

// ── Prompts ────────────────────────────────────────────────────────────────

function lensPrompt({ lens, viewId, size, theme, imagePath, changed }) {
  const L = LENSES[lens];
  const e = resolveExpectation(viewId);
  const rubric = e.register === "debugger" ? "§6 (Rubric B — debugger register)" : "§5 (Rubric A — explorer register)";

  const head = [
    `Read the review brief at \`${BRIEF_REL}\` — sections 1, 2, 3, ${rubric}, 9 (severity) and 10 (how to report). Skip section 4; your view's block is inlined below, and the other 61 blocks are not yours.`,
    "",
    `Then view the screenshot at \`${imagePath}\`.`,
    "",
    `It is the \`${viewId}\` view at the \`${size}\` viewport (${SIZES[size].width}×${SIZES[size].height}) in the \`${theme}\` theme.`,
    "",
    "── EXPECTED ELEMENTS ──────────────────────────────────────────────",
    expectationText(viewId),
    "───────────────────────────────────────────────────────────────────",
    "",
  ];

  if (L.adversarial) {
    head.push(
      "YOUR ROLE: the adversarial reviewer (brief §8).",
      "",
      "First perform the presence check above. Then name THE SINGLE WEAKEST ELEMENT on this page and why it is the weakest.",
      "",
      "Your output is exactly that: one element, one location, one reason, one severity. Not a list. Not a summary. Not a rating out of ten. If you find yourself writing a second finding, you have not decided which one is worst.",
      "",
      "You must name something. \"Nothing is weak\" is not an available answer. If the weakest element is genuinely minor, say so by assigning it P3 — that is a strong signal about the page and far more useful than a refusal.",
      "",
      "You are not required to be fair, balanced or encouraging. You are required to be specific and to be right about the location.",
      "",
      "Report per brief §10: the first line is the `Expected elements:` line, then your single finding in prose, then the ```json ledger block with `\"reviewer\": \"ADV\"`, exactly one entry in `findings`, and `\"rating\": null` unless the presence check failed (in which case rate ≤ 4).",
    );
  } else {
    head.push(
      `YOUR LENS: ${lens} — ${L.name} (brief §7).`,
      "",
      `You look at: ${L.looksAt}.`,
      `Not your job: ${L.notYours}. Another reviewer has that lens; do not duplicate their work.`,
      "",
      "Do the presence check first regardless of lens — a lens reviewer who skips it can rate a broken render highly within its own concern. If a required element is missing, that is your first finding, it is P1, and your rating is 4 or below.",
      "",
      "Name locations. \"The gap above the section heading is too large\" is actionable; \"spacing is inconsistent\" is not.",
      "",
      "Report per brief §10: prose summary under 250 words starting with the `Expected elements:` line, then the ```json ledger block.",
    );
  }

  if (changed) {
    head.push("", `THIS ITERATION CHANGED: ${changed}`, "Say whether the change landed, and whether it caused anything else.");
  }

  return head.join("\n");
}

// ── CLI ────────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const o = { lenses: [], changed: null, json: false, image: null };
  for (let i = 0; i < argv.length; i++) {
    const next = () => argv[++i];
    switch (argv[i]) {
      case "--view": o.view = next(); break;
      case "--size": o.size = next(); break;
      case "--theme": o.theme = next(); break;
      case "--lens": o.lenses.push(...next().split(",").map((s) => s.trim()).filter(Boolean)); break;
      case "--all": o.lenses.push(...ALL_LENSES); break;
      case "--changed": o.changed = next(); break;
      case "--image": o.image = next(); break;
      case "--json": o.json = true; break;
      default: throw new Error(`unknown argument: ${argv[i]}`);
    }
  }
  return o;
}

function main(argv) {
  const o = parseArgs(argv);
  if (!o.view) throw new Error("--view is required");
  const view = VIEWS_BY_ID.get(o.view);
  if (!view) throw new Error(`unknown view: ${o.view}`);

  o.size ??= sizesFor(view)[0];
  o.theme ??= themesFor(view)[0];
  if (!SIZES[o.size]) throw new Error(`unknown size: ${o.size}`);
  if (!THEMES.includes(o.theme)) throw new Error(`unknown theme: ${o.theme}`);
  if (!o.lenses.length) o.lenses = ALL_LENSES;

  const unknown = o.lenses.filter((l) => !LENSES[l]);
  if (unknown.length) throw new Error(`unknown lens/lenses: ${unknown.join(", ")}`);

  const imagePath =
    o.image ?? relative(REPO_ROOT, join(REPO_ROOT, "screenshots", imageName(o.view, o.size, o.theme)));
  const abs = resolvePath(REPO_ROOT, imagePath);
  if (!existsSync(abs)) {
    console.error(
      `! no image at ${imagePath}\n` +
        `! capture it first:  node tools/capture/capture.mjs --view ${o.view} --size ${o.size} --theme ${o.theme}` +
        (view.status !== "ready" ? `\n! NOTE: this view is 'pending' — ${view.pendingReason}` : ""),
    );
  }

  const prompts = o.lenses.map((lens) => ({
    lens,
    prompt: lensPrompt({ lens, viewId: o.view, size: o.size, theme: o.theme, imagePath, changed: o.changed }),
  }));

  if (o.json) {
    console.log(JSON.stringify({ view: o.view, size: o.size, theme: o.theme, image: imagePath, prompts }, null, 2));
  } else {
    for (const { lens, prompt } of prompts) {
      console.log(`\n════════════════ ${lens} — ${LENSES[lens].name} ════════════════\n`);
      console.log(prompt);
    }
  }
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    process.exit(main(process.argv.slice(2)));
  } catch (err) {
    console.error(`review-prompt failed: ${err.message}`);
    process.exit(2);
  }
}

export { lensPrompt };
