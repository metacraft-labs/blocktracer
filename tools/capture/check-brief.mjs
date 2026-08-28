#!/usr/bin/env node
// VD.1 — `verify_brief_has_expectation_block_per_view`.
//
//   node tools/capture/check-brief.mjs
//
// "Every named view has an expected-elements block in the brief; a view without
// one fails the check."
//
// The check is deliberately made against the RENDERED BRIEF, not against
// `expectations.mjs`. Checking the data module against `views.mjs` would prove
// that the data is complete; it would not prove that a reviewer reading
// `tools/visual-review-brief.md` — which is the artefact reviewers actually
// read — finds a block for the view they were handed. So this reads the
// markdown back off disk and greps it, and separately proves the markdown is
// not stale with respect to its source.
//
// Five checks, each failing for a distinct reason:
//
//   A  every view in views.mjs has a block heading in the brief
//   B  every block heading in the brief names a real view      (no orphans)
//   C  every block is non-empty and carries real requirements  (no stubs)
//   D  the brief's generated section matches expectations.mjs  (not stale)
//   E  every block names a spec anchor and a register          (traceable)

import { readFile } from "node:fs/promises";

import { VIEWS, VIEWS_BY_ID } from "./views.mjs";
import { EXPECTATIONS_BY_ID, resolveExpectation } from "./expectations.mjs";
import { BRIEF_PATH, renderSection, blockHeading, BEGIN, END } from "./render-brief.mjs";

// A block heading looks like:  ### View: `home`
const HEADING_RE = /^### View: `([^`]+)`$/gm;

/** Split the brief into { viewId -> block text } by its `### View:` headings. */
function sliceBlocks(text) {
  const blocks = new Map();
  const hits = [...text.matchAll(HEADING_RE)];
  for (let i = 0; i < hits.length; i++) {
    const start = hits[i].index;
    const end = i + 1 < hits.length ? hits[i + 1].index : text.length;
    blocks.set(hits[i][1], text.slice(start, end));
  }
  return blocks;
}

async function main(argv) {
  const json = argv.includes("--json");
  const problems = [];
  const brief = await readFile(BRIEF_PATH, "utf8");

  // The section boundaries, so an accidental `### View:` outside the generated
  // region cannot satisfy the check.
  const b = brief.indexOf(BEGIN);
  const e = brief.indexOf(END);
  if (b < 0 || e < 0 || e < b) {
    console.error(`${BRIEF_PATH}: generated markers missing or out of order`);
    return 2;
  }
  const section = brief.slice(b + BEGIN.length, e);
  const blocks = sliceBlocks(section);

  // ── A. every named view has a block ──────────────────────────────────────
  const withoutBlock = VIEWS.filter((v) => !blocks.has(v.id));

  // ── B. no orphan blocks ──────────────────────────────────────────────────
  const orphans = [...blocks.keys()].filter((id) => !VIEWS_BY_ID.has(id));

  // ── C. no stub blocks ────────────────────────────────────────────────────
  // A block satisfies the check only if it actually carries requirements. The
  // failure this guards against is a block added to silence check A.
  const stubs = [];
  for (const view of VIEWS) {
    const text = blocks.get(view.id);
    if (!text) continue;
    const exp = resolveExpectation(view.id);
    const own = exp ? exp.mustShow.length : 0;
    const inherited = (exp?.inherited ?? []).reduce((n, i) => n + i.items.length, 0);
    const bulletCount = (text.match(/^\s*-\s+\S/gm) || []).length;
    if (!text.includes("**Must show**")) {
      stubs.push({ view: view.id, why: "no `Must show` list" });
    } else if (own === 0) {
      stubs.push({ view: view.id, why: "`mustShow` is empty in expectations.mjs" });
    } else if (own + inherited < 3) {
      stubs.push({
        view: view.id,
        why: `only ${own + inherited} required element(s) — too few to distinguish a broken render from a rough design`,
      });
    } else if (bulletCount < 3) {
      stubs.push({ view: view.id, why: `only ${bulletCount} bullet(s) rendered` });
    }
  }

  // ── D. the brief is not stale with respect to its source ────────────────
  const expected = "\n<!-- regenerate with: node tools/capture/render-brief.mjs -->\n\n" +
    renderSection() + "\n";
  const stale = section !== expected;

  // ── E. every block is traceable ─────────────────────────────────────────
  const untraceable = [];
  for (const view of VIEWS) {
    const exp = EXPECTATIONS_BY_ID.get(view.id);
    if (!exp) continue;
    if (!exp.spec || !/§|Design-System|Debugger-Integration|VD\./.test(exp.spec)) {
      untraceable.push({ view: view.id, why: `spec anchor missing or unrecognisable: ${exp.spec}` });
    }
    if (exp.register !== view.register) {
      untraceable.push({
        view: view.id,
        why: `register disagrees with views.mjs: block says '${exp.register}', view says '${view.register}'`,
      });
    }
  }

  if (withoutBlock.length) {
    problems.push(
      `A: ${withoutBlock.length} named view(s) have NO expected-elements block in the brief:\n` +
        withoutBlock.map((v) => `     ${v.id}`).join("\n"),
    );
  }
  if (orphans.length) {
    problems.push(
      `B: ${orphans.length} block(s) name a view that does not exist:\n` +
        orphans.map((id) => `     ${id}`).join("\n"),
    );
  }
  if (stubs.length) {
    problems.push(
      `C: ${stubs.length} block(s) are stubs rather than expectations:\n` +
        stubs.map((s) => `     ${s.view}: ${s.why}`).join("\n"),
    );
  }
  if (stale) {
    problems.push(
      `D: the brief's generated section is STALE with respect to expectations.mjs\n` +
        `     run: node tools/capture/render-brief.mjs`,
    );
  }
  if (untraceable.length) {
    problems.push(
      `E: ${untraceable.length} block(s) are not traceable to a spec/register:\n` +
        untraceable.map((s) => `     ${s.view}: ${s.why}`).join("\n"),
    );
  }

  const summary = {
    check: "verify_brief_has_expectation_block_per_view",
    brief: BRIEF_PATH,
    namedViews: VIEWS.length,
    blocksInBrief: blocks.size,
    viewsWithoutBlock: withoutBlock.map((v) => v.id),
    orphanBlocks: orphans,
    stubBlocks: stubs,
    briefStale: stale,
    untraceable,
    ok: problems.length === 0,
  };

  if (json) {
    console.log(JSON.stringify(summary, null, 2));
  } else {
    console.log(`brief:       ${BRIEF_PATH}`);
    console.log(`named views: ${VIEWS.length}`);
    console.log(`blocks:      ${blocks.size}`);
    console.log("");
    const line = (ok, s) => console.log(`  ${ok ? "✓" : "✗"} ${s}`);
    line(!withoutBlock.length, `A  every named view has an expected-elements block (${VIEWS.length - withoutBlock.length}/${VIEWS.length})`);
    line(!orphans.length, `B  every block names a real view (${orphans.length} orphan(s))`);
    line(!stubs.length, `C  no block is a stub (${stubs.length} stub(s))`);
    line(!stale, `D  the brief matches expectations.mjs`);
    line(!untraceable.length, `E  every block names a spec anchor and the right register`);
    console.log("");
    if (problems.length) {
      console.log(`FAIL — ${problems.length} problem(s):`);
      for (const p of problems) console.log(`  ${p}`);
    } else {
      console.log(`PASS — ${VIEWS.length}/${VIEWS.length} named views have an expectation block.`);
    }
  }
  return problems.length ? 1 : 0;
}

main(process.argv.slice(2))
  .then((c) => process.exit(c))
  .catch((err) => {
    console.error(`check-brief failed: ${err.message}`);
    process.exit(2);
  });
