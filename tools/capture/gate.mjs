#!/usr/bin/env node
// VD.1 — `verify_gate_definition_is_machine_checkable`.
//
//   node tools/capture/gate.mjs                    gate every view in gateScope
//   node tools/capture/gate.mjs --view tx-detail   gate one view
//   node tools/capture/gate.mjs --explain          print the ledger schema
//   node tools/capture/gate.mjs --json             machine-readable verdict
//   node tools/capture/gate.mjs --ledger <path>    use a different ledger
//   node tools/capture/gate.mjs --foundations      VD.2 — gate on the FOUNDATIONS
//                                                  criteria alone, and report the
//                                                  full gate alongside it
//
// The gate's STRUCTURAL conditions — the ones a script can decide — are
// evaluated here over `reviews/ledger.json`. The conditions a script cannot
// decide are not faked: the reference-parity verdict and the human sign-off are
// checked for EXISTENCE and WELL-FORMEDNESS, never computed. A script that
// claimed to have judged reference parity would be the exact failure the
// four-tier hierarchy warns about — one mechanism asked to do a job it cannot
// bear (Methodologies/visual-design-iteration.md §"Automated Checks").
//
// ── What is a gate condition and what is not ───────────────────────────────
//
// The rating is deliberately absent from every condition below. "9/10" is not
// a gate; "zero unresolved P1 and P2" is. The gate REPORTS the ratings so the
// number is visible, and then ignores them.
//
// ── Fail-closed, everywhere ────────────────────────────────────────────────
//
// A missing ledger, an unparseable ledger, a review for a view that does not
// exist, a finding with an unknown severity, a resolution pointing at no
// finding, a sign-off with no name: every one of these FAILS. An unknown state
// is never a pass. The one thing this gate must never do is go green because
// it could not find anything to check.

import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";

import { VIEWS_BY_ID, SIZES, THEMES, imageName } from "./views.mjs";
import { EXPECTATIONS_BY_ID } from "./expectations.mjs";
import { ALL_LENSES } from "./review-prompt.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");
const DEFAULT_LEDGER = join(REPO_ROOT, "reviews", "ledger.json");

const SEVERITIES = ["P1", "P2", "P3"];
const BLOCKING = ["P1", "P2"];
const EXPECTED_VERDICTS = ["present", "missing", "replaced", "forbidden-present"];

// ── VD.2: the foundations scope ────────────────────────────────────────────
//
// `verify_foundations_round_reaches_bar` asks whether a representative page
// from each register "passes the gate on FOUNDATIONS CRITERIA ALONE, before
// page-specific work begins". That is a narrower question than the full gate,
// and the narrowing has to be written down rather than argued each time —
// otherwise "foundations" becomes whatever is left after the failures are
// removed.
//
// A criterion is in scope when VD.2's deliverables can fix it: the type scale,
// the spacing rhythm, colour roles, numeric/monospace treatment, focus, hover
// and active states, and the register's density. It is out of scope when the
// fix is content or per-page layout, which VD.3–VD.6 own.
//
// The enumeration is EXHAUSTIVE over both rubrics — every criterion is named
// with a verdict, so a criterion cannot be quietly omitted and thereby escape.

export const FOUNDATIONS_CRITERIA = {
  A1: "whitespace and restraint — how much space, and which step of the one scale",
  A2: "vertical rhythm — the four --bt-rhythm-* roles and their separation",
  A4: "type hierarchy — the levels of the type scale and their weights",
  A5: "numeric and monospace treatment — tabular figures, and mono meaning 'machine value'",
  A7: "colour roles and status semantics — the surface, text-emphasis, border and status token sets",
  A10: "shipping polish — focus, hover and active states, and alignment to one grid",
  B1: "information density — the register's density parametrisation",
  B2: "legibility at small sizes — type scale and contrast in the dense register",
  B7: "numeric and code treatment — the same tokens, judged under the tool rubric",
};

export const PAGE_CRITERIA = {
  A3: "measure and column structure — MIXED. The measure half is a token (--bt-measure-*) and is foundations; the column-structure half is a per-page layout decision. Excluded rather than split, because a criterion that is half in scope would let either half be argued into the other.",
  A6: "table quality — a component decision: which columns, in what order, with the primary action where",
  A8: "brand identity — MIXED. The theme's existence is foundations and is asserted separately by check-tokens.mjs D2; whether the page LOOKS like the 2026 direction is judged against the reference at G4 and is VD.11's",
  A9: "empty, degraded and error treatments — copy and state design, VD.6",
  B3: "hierarchy under load — depends on the pane's content model",
  B4: "pane structure and proportion — the debugger's layout, VD.5",
  B5: "current-position and state indication — a debugger behaviour",
  B6: "nesting and depth — a debugger component",
  B8: "honest loading and state — copy and state design, VD.6",
  B9: "desktop-app continuity — a comparison, not a token",
  B10: "control ergonomics — a debugger interaction design",
};

const SCHEMA = `
reviews/ledger.json
───────────────────

{
  "ledgerRevision": "2026-08-28.1",     // bumped whenever anything below changes;
                                        // a sign-off names the revision it signed
  "gateScope": [                        // the {view,size,theme} triples under gate.
    { "view": "tx-detail", "size": "wide", "theme": "light" }
  ],

  "reviews": [                          // one per reviewer per image — exactly the
    {                                   // JSON block brief §10 Part 2 defines
      "view": "tx-detail", "size": "wide", "theme": "light",
      "image": "screenshots/tx-detail__wide__light.png",
      "reviewer": "L2",                 // L1..L5 or ADV
      "expectedElements": "present",    // present|missing|replaced|forbidden-present
      "missing": [],                    // non-empty iff expectedElements != present
      "rating": 7,                      // reported, never gated on; null allowed for ADV
      "findings": [
        { "id": "tx-detail/wide/light/L2/1",
          "severity": "P2",             // P1|P2|P3
          "location": "overview grid, label column",
          "finding": "…",
          "criterion": "A2" }           // optional rubric id
      ]
    }
  ],

  "resolutions": [                      // one per finding id
    { "findingId": "tx-detail/wide/light/L2/1",
      "status": "fixed",                // fixed | waived | accepted | open
      "reason": "…",                    // REQUIRED for waived and accepted
      "evidence": "commit abc123",      // REQUIRED for fixed
      "signedOffBy": "Jane Doe" }       // REQUIRED for waived (a human, not an agent)
  ],

  "referenceParity": [                  // G4 — recorded, never computed
    { "view": "tx-detail",
      "register": "explorer",
      "reference": "codetracer2026.webflow.io, 2026-08-28",
      "verdict": "pass",                // pass | fail
      "notes": "…",
      "by": "Jane Doe", "date": "2026-08-28" }
  ],

  "signOffs": [                         // G5 — a human, never an agent
    { "view": "tx-detail",
      "by": "Jane Doe",
      "date": "2026-08-28",
      "ledgerRevision": "2026-08-28.1" }
  ]
}

Resolution statuses
───────────────────
  fixed      the finding no longer holds; 'evidence' names what changed.
  waived     P2 or P3 only. Deliberately not fixed; needs 'reason' AND
             'signedOffBy'. A P1 can never be waived.
  accepted   P3 only. Read, judged not worth acting on; needs 'reason'.
  open       not resolved. Blocks the gate for P1 and P2.

Gate conditions (brief §11)
───────────────────────────
  G1  expectations present   every gated view has an expectation block, and every
                             review of it reports expectedElements: "present"
  G2  full lens coverage     L1..L5 and ADV have all reviewed the exact image
  G3  zero unresolved P1/P2  across all six reviewers
  G4  reference parity       recorded, with a verdict of "pass"
  G5  human sign-off         recorded, naming a person, a date and the ledger
                             revision they signed — and that revision is current
`;

// ── Loading and validating the ledger ──────────────────────────────────────

function fail(problems, code, msg) {
  problems.push({ code, msg });
}

function validateLedger(L, problems) {
  const arr = (k) => (Array.isArray(L[k]) ? L[k] : (fail(problems, "SCHEMA", `ledger.${k} must be an array`), []));

  if (typeof L.ledgerRevision !== "string" || !L.ledgerRevision) {
    fail(problems, "SCHEMA", "ledger.ledgerRevision must be a non-empty string");
  }
  const scope = arr("gateScope");
  const reviews = arr("reviews");
  const resolutions = arr("resolutions");
  const referenceParity = arr("referenceParity");
  const signOffs = arr("signOffs");

  for (const [i, t] of scope.entries()) {
    if (!VIEWS_BY_ID.has(t.view)) fail(problems, "SCHEMA", `gateScope[${i}]: unknown view '${t.view}'`);
    if (!SIZES[t.size]) fail(problems, "SCHEMA", `gateScope[${i}]: unknown size '${t.size}'`);
    if (!THEMES.includes(t.theme)) fail(problems, "SCHEMA", `gateScope[${i}]: unknown theme '${t.theme}'`);
  }

  const seenFindingIds = new Set();
  for (const [i, r] of reviews.entries()) {
    const at = `reviews[${i}] (${r.view}/${r.size}/${r.theme}/${r.reviewer})`;
    if (!VIEWS_BY_ID.has(r.view)) fail(problems, "SCHEMA", `${at}: unknown view`);
    if (!ALL_LENSES.includes(r.reviewer)) fail(problems, "SCHEMA", `${at}: unknown reviewer '${r.reviewer}' (expect ${ALL_LENSES.join("|")})`);
    if (!EXPECTED_VERDICTS.includes(r.expectedElements)) {
      fail(problems, "SCHEMA", `${at}: expectedElements must be one of ${EXPECTED_VERDICTS.join("|")}`);
    }
    // The brief's own consistency rule, enforced rather than trusted: a
    // non-present verdict REQUIRES a named missing element and a rating <= 4.
    if (r.expectedElements && r.expectedElements !== "present") {
      if (!Array.isArray(r.missing) || r.missing.length === 0) {
        fail(problems, "INCONSISTENT", `${at}: expectedElements='${r.expectedElements}' but 'missing' is empty`);
      }
      if (typeof r.rating === "number" && r.rating > 4) {
        fail(problems, "INCONSISTENT", `${at}: expectedElements='${r.expectedElements}' but rating is ${r.rating} (brief §4 caps it at 4)`);
      }
    }
    if (r.expectedElements === "present" && Array.isArray(r.missing) && r.missing.length) {
      fail(problems, "INCONSISTENT", `${at}: expectedElements='present' but 'missing' names ${r.missing.length} item(s)`);
    }
    for (const [j, f] of (r.findings ?? []).entries()) {
      const fat = `${at} finding[${j}]`;
      if (!f.id) fail(problems, "SCHEMA", `${fat}: missing 'id'`);
      else if (seenFindingIds.has(f.id)) fail(problems, "SCHEMA", `${fat}: duplicate finding id '${f.id}'`);
      else seenFindingIds.add(f.id);
      if (!SEVERITIES.includes(f.severity)) fail(problems, "SCHEMA", `${fat}: severity must be P1|P2|P3, got '${f.severity}'`);
      if (!f.location) fail(problems, "SCHEMA", `${fat}: missing 'location' — a finding without one cannot be fixed or verified`);
    }
    if (r.reviewer === "ADV" && (r.findings ?? []).length > 1) {
      fail(problems, "INCONSISTENT", `${at}: the adversarial reviewer reported ${r.findings.length} findings; §8 allows exactly one`);
    }
  }

  const byId = new Map();
  for (const [i, res] of resolutions.entries()) {
    const at = `resolutions[${i}] (${res.findingId})`;
    if (!res.findingId) { fail(problems, "SCHEMA", `${at}: missing 'findingId'`); continue; }
    if (!seenFindingIds.has(res.findingId)) fail(problems, "ORPHAN", `${at}: resolves a finding that no review reported`);
    if (byId.has(res.findingId)) fail(problems, "SCHEMA", `${at}: duplicate resolution`);
    byId.set(res.findingId, res);
    if (!["fixed", "waived", "accepted", "open"].includes(res.status)) {
      fail(problems, "SCHEMA", `${at}: status must be fixed|waived|accepted|open, got '${res.status}'`);
    }
    if (res.status === "fixed" && !res.evidence) fail(problems, "SCHEMA", `${at}: 'fixed' requires 'evidence'`);
    if (res.status === "waived" && (!res.reason || !res.signedOffBy)) {
      fail(problems, "SCHEMA", `${at}: 'waived' requires both 'reason' and 'signedOffBy'`);
    }
    if (res.status === "accepted" && !res.reason) fail(problems, "SCHEMA", `${at}: 'accepted' requires 'reason'`);
  }

  for (const [i, p] of referenceParity.entries()) {
    const at = `referenceParity[${i}] (${p.view})`;
    if (!VIEWS_BY_ID.has(p.view)) fail(problems, "SCHEMA", `${at}: unknown view`);
    if (!["pass", "fail"].includes(p.verdict)) fail(problems, "SCHEMA", `${at}: verdict must be pass|fail`);
    if (!p.reference) fail(problems, "SCHEMA", `${at}: 'reference' must name what it was compared against`);
    if (!p.by || !p.date) fail(problems, "SCHEMA", `${at}: 'by' and 'date' are required — parity is judged, not computed`);
  }

  for (const [i, s] of signOffs.entries()) {
    const at = `signOffs[${i}] (${s.view})`;
    if (!VIEWS_BY_ID.has(s.view)) fail(problems, "SCHEMA", `${at}: unknown view`);
    if (!s.by) fail(problems, "SCHEMA", `${at}: 'by' is required — a named person, not an agent`);
    if (!s.date) fail(problems, "SCHEMA", `${at}: 'date' is required`);
    if (!s.ledgerRevision) fail(problems, "SCHEMA", `${at}: 'ledgerRevision' is required — a sign-off is of a specific ledger`);
  }

  return { scope, reviews, resolutions: byId, referenceParity, signOffs };
}

// ── The five structural conditions ─────────────────────────────────────────

function gateTarget(target, L, model, opts = {}) {
  const foundations = !!opts.foundations;
  const { view, size, theme } = target;
  const key = `${view}/${size}/${theme}`;
  const conds = [];
  const push = (id, ok, detail) => conds.push({ id, ok, detail });

  const reviews = model.reviews.filter(
    (r) => r.view === view && r.size === size && r.theme === theme,
  );

  // ── G1: expectations present ────────────────────────────────────────────
  //
  // In FOUNDATIONS scope this becomes G1f. A required element that is absent is
  // absent because nobody has built it, not because the type scale is wrong —
  // it is content, and it is VD.3/VD.4's. What G1f still insists on is that the
  // presence check was PERFORMED against the view's own expectation block, by
  // every reviewer: a foundations round on a page nobody checked for content
  // would be a round on an unknown page. The unmet full-gate G1 is reported
  // beside the foundations verdict, never in place of it.
  const hasBlock = EXPECTATIONS_BY_ID.has(view);
  const notPresent = reviews.filter((r) => r.expectedElements !== "present");
  const performed = reviews.filter((r) => EXPECTED_VERDICTS.includes(r.expectedElements));
  if (foundations) {
    push(
      "G1f",
      hasBlock && reviews.length > 0 && performed.length === reviews.length,
      !hasBlock
        ? `no expected-elements block for view '${view}'`
        : reviews.length === 0
          ? "no reviews recorded, so nobody performed the presence check"
          : performed.length !== reviews.length
            ? `${reviews.length - performed.length} reviewer(s) recorded no presence verdict at all`
            : `${reviews.length}/${reviews.length} reviewer(s) performed the §4 presence check` +
              (notPresent.length
                ? `; ${notPresent.length} report missing content, which the FULL gate holds against this page and VD.3/VD.4 own`
                : "; all report the expected elements present"),
    );
  } else {
    push(
      "G1",
      hasBlock && reviews.length > 0 && notPresent.length === 0,
      !hasBlock
        ? `no expected-elements block for view '${view}'`
        : reviews.length === 0
          ? "no reviews recorded, so no reviewer confirmed the expected elements"
          : notPresent.length
            ? `${notPresent.length} reviewer(s) did not find the expected elements: ` +
              notPresent.map((r) => `${r.reviewer}=${r.expectedElements}`).join(", ")
            : `${reviews.length} reviewer(s) confirmed present`,
    );
  }

  // ── G2: full lens coverage ──────────────────────────────────────────────
  const seen = new Set(reviews.map((r) => r.reviewer));
  const absent = ALL_LENSES.filter((l) => !seen.has(l));
  push(
    "G2",
    absent.length === 0,
    absent.length ? `missing reviewer(s): ${absent.join(", ")}` : `all ${ALL_LENSES.length} reviewers present`,
  );

  // ── G3: zero unresolved P1 and P2 ───────────────────────────────────────
  //
  // In FOUNDATIONS scope this becomes G3f and considers only findings whose
  // `criterion` is in FOUNDATIONS_CRITERIA. A finding with NO criterion is a
  // pure presence failure — a missing element is content by definition — and is
  // out of scope, but it is counted and named rather than dropped.
  const allFindings = reviews.flatMap((r) => (r.findings ?? []).map((f) => ({ ...f, reviewer: r.reviewer })));
  const inScope = (f) => !foundations || (f.criterion && Object.hasOwn(FOUNDATIONS_CRITERIA, f.criterion));
  const findings = allFindings.filter(inScope);
  const outOfScope = allFindings.filter((f) => !inScope(f));
  const blocking = findings.filter((f) => BLOCKING.includes(f.severity));
  const unresolved = [];
  let waivedCount = 0;
  for (const f of blocking) {
    const res = model.resolutions.get(f.id);
    if (!res || res.status === "open") {
      unresolved.push({ ...f, why: res ? "status=open" : "no resolution recorded" });
      continue;
    }
    if (f.severity === "P1" && res.status !== "fixed") {
      unresolved.push({ ...f, why: `P1 resolved as '${res.status}' — a P1 can only be fixed` });
      continue;
    }
    if (res.status === "waived") waivedCount++;
    if (res.status === "accepted" && f.severity !== "P3") {
      unresolved.push({ ...f, why: `'accepted' is P3-only; this is ${f.severity}` });
    }
  }
  const p3 = findings.filter((f) => f.severity === "P3");
  const p3Unread = p3.filter((f) => {
    const res = model.resolutions.get(f.id);
    return !res || res.status === "open";
  });
  const outBlocking = outOfScope.filter((f) => BLOCKING.includes(f.severity));
  const outUnresolved = outBlocking.filter((f) => {
    const res = model.resolutions.get(f.id);
    return !res || res.status === "open" || (f.severity === "P1" && res.status !== "fixed");
  });
  push(
    foundations ? "G3f" : "G3",
    unresolved.length === 0,
    (unresolved.length
      ? `${unresolved.length} unresolved blocking ${foundations ? "FOUNDATIONS " : ""}finding(s):\n` +
        unresolved.map((f) => `        ${f.severity} ${f.id} [${f.reviewer}] ${f.criterion ? `(${f.criterion}) ` : ""}${f.location} — ${f.why}`).join("\n")
      : `${blocking.length} blocking ${foundations ? "foundations " : ""}finding(s), all resolved` +
        (waivedCount ? ` (${waivedCount} by waiver)` : "")) +
    (foundations
      ? `\n        SCOPE: ${Object.keys(FOUNDATIONS_CRITERIA).join(", ")}. Excluded from this verdict and NOT resolved by it: ` +
        `${outBlocking.length} blocking finding(s) outside the foundations criteria, ${outUnresolved.length} of them unresolved` +
        (outUnresolved.length
          ? `:\n` + outUnresolved.map((f) => `        · ${f.severity} ${f.id} [${f.reviewer}] ${f.criterion ? `(${f.criterion}) ` : "(no criterion — a presence failure) "}${f.location}`).join("\n")
          : "")
      : ""),
  );

  // ── G4: reference parity ────────────────────────────────────────────────
  const parity = model.referenceParity.filter((p) => p.view === view);
  const passed = parity.filter((p) => p.verdict === "pass");
  push(
    "G4",
    parity.length > 0 && passed.length === parity.length,
    parity.length === 0
      ? "no reference-parity check recorded"
      : passed.length === parity.length
        ? `parity recorded against ${parity.map((p) => p.reference).join("; ")} by ${parity.map((p) => p.by).join(", ")}`
        : `${parity.length - passed.length} parity check(s) recorded a FAIL verdict`,
  );

  // ── G5: human sign-off ──────────────────────────────────────────────────
  const offs = model.signOffs.filter((s) => s.view === view);
  const current = offs.filter((s) => s.ledgerRevision === L.ledgerRevision);
  push(
    "G5",
    current.length > 0,
    offs.length === 0
      ? "no human sign-off recorded"
      : current.length === 0
        ? `sign-off(s) exist but for ledger revision(s) ${[...new Set(offs.map((s) => s.ledgerRevision))].join(", ")}, not the current ${L.ledgerRevision} — the ledger changed after signing`
        : `signed by ${current.map((s) => `${s.by} (${s.date})`).join(", ")}`,
  );

  const ratings = reviews.map((r) => r.rating).filter((n) => typeof n === "number");
  return {
    key, view, size, theme,
    scope: foundations ? "foundations" : "full",
    conditions: conds,
    pass: conds.every((c) => c.ok),
    reviewers: [...seen].sort(),
    findings: { total: findings.length, p1: findings.filter((f) => f.severity === "P1").length, p2: findings.filter((f) => f.severity === "P2").length, p3: p3.length, unresolvedBlocking: unresolved.length, p3Unread: p3Unread.length },
    outOfScope: foundations
      ? { total: outOfScope.length, blocking: outBlocking.length, unresolvedBlocking: outUnresolved.length, ids: outUnresolved.map((f) => f.id) }
      : null,
    // Reported, never gated on.
    rating: ratings.length ? { min: Math.min(...ratings), max: Math.max(...ratings), mean: +(ratings.reduce((a, b) => a + b, 0) / ratings.length).toFixed(1) } : null,
  };
}

// ── main ───────────────────────────────────────────────────────────────────

async function main(argv) {
  if (argv.includes("--explain")) {
    console.log(SCHEMA);
    return 0;
  }
  const json = argv.includes("--json");
  const vi = argv.indexOf("--view");
  const onlyView = vi >= 0 ? argv[vi + 1] : null;
  const li = argv.indexOf("--ledger");
  const ledgerPath = li >= 0 ? resolvePath(argv[li + 1]) : DEFAULT_LEDGER;

  const problems = [];

  if (!existsSync(ledgerPath)) {
    // Fail closed. No ledger is not "nothing to check"; it is "nothing was reviewed".
    const msg =
      `no findings ledger at ${ledgerPath}\n` +
      `the gate cannot pass a view that has not been reviewed.\n` +
      `see the schema:  node tools/capture/gate.mjs --explain`;
    if (json) console.log(JSON.stringify({ ok: false, error: "no-ledger", ledger: ledgerPath }, null, 2));
    else console.error(msg);
    return 1;
  }

  let L;
  try {
    L = JSON.parse(await readFile(ledgerPath, "utf8"));
  } catch (e) {
    if (json) console.log(JSON.stringify({ ok: false, error: "unparseable-ledger", detail: e.message }, null, 2));
    else console.error(`ledger is not valid JSON: ${e.message}`);
    return 1;
  }

  const model = validateLedger(L, problems);

  let scope = model.scope;
  if (onlyView) {
    if (!VIEWS_BY_ID.has(onlyView)) {
      console.error(`unknown view: ${onlyView}`);
      return 2;
    }
    scope = scope.filter((t) => t.view === onlyView);
    if (!scope.length) {
      console.error(`view '${onlyView}' is not in the ledger's gateScope`);
      return 1;
    }
  }

  const foundations = argv.includes("--foundations");

  const results = scope.map((t) => gateTarget(t, L, model, { foundations }));
  const passing = results.filter((r) => r.pass);
  const ok = problems.length === 0 && results.length > 0 && passing.length === results.length;

  // The full gate is ALWAYS computed and reported. A foundations verdict that
  // could be read on its own would be a weaker gate wearing the same name; here
  // "foundations passed" is only ever printed next to what the full gate still
  // holds against the page.
  const fullResults = foundations ? scope.map((t) => gateTarget(t, L, model, { foundations: false })) : null;
  const fullPassing = fullResults ? fullResults.filter((r) => r.pass).length : null;

  const verdict = {
    check: foundations ? "verify_foundations_round_reaches_bar" : "verify_gate_definition_is_machine_checkable",
    mode: foundations ? "foundations" : "full",
    ledger: ledgerPath,
    ledgerRevision: L.ledgerRevision ?? null,
    schemaProblems: problems,
    scope: results.length,
    passing: passing.length,
    results,
    ...(foundations
      ? {
          foundationsCriteria: FOUNDATIONS_CRITERIA,
          excludedCriteria: PAGE_CRITERIA,
          fullGate: { passing: fullPassing, scope: fullResults.length, results: fullResults },
        }
      : {}),
    // Stated on every run rather than left to be discovered: the tier-1
    // determinism precondition is not part of this gate's arithmetic.
    tier1: {
      condition: "G6 — pinned-container determinism verdict",
      enforced: false,
      why: "VD.0's pinned capture container has never been built or run (no working Docker daemon), so no tier-1 verdict exists. `require-deterministic.mjs` refuses the host-only advisory verdict. G1–G5 are properties of the review ledger and do not depend on it; what is unavailable is any conclusion of the form 'this page did not change'.",
    },
    ok,
  };

  if (json) {
    console.log(JSON.stringify(verdict, null, 2));
    return ok ? 0 : 1;
  }

  console.log(`ledger:    ${ledgerPath}`);
  console.log(`revision:  ${L.ledgerRevision ?? "(none)"}`);
  console.log(`scope:     ${results.length} {view, size, theme} target(s)`);
  if (foundations) {
    console.log(`mode:      FOUNDATIONS — verify_foundations_round_reaches_bar`);
    console.log(`           G1 is relaxed to G1f (the presence check was performed, not that it passed)`);
    console.log(`           G3 is narrowed to G3f (only findings carrying a foundations criterion)`);
    console.log(`           G2, G4 and G5 are unchanged: a foundations round is still a full six-lens`);
    console.log(`           round with a recorded parity check and a human sign-off.`);
    console.log(`           IN SCOPE:  ${Object.keys(FOUNDATIONS_CRITERIA).join(", ")}`);
    console.log(`           EXCLUDED:  ${Object.keys(PAGE_CRITERIA).join(", ")}, and every finding with no criterion`);
  }
  console.log("");

  if (problems.length) {
    console.log(`LEDGER SCHEMA PROBLEMS (${problems.length}) — the gate fails closed on all of them:`);
    for (const p of problems) console.log(`  [${p.code}] ${p.msg}`);
    console.log("");
  }

  for (const r of results) {
    console.log(`${r.pass ? "PASS" : "FAIL"}  ${r.key}`);
    for (const c of r.conditions) {
      console.log(`  ${c.ok ? "✓" : "✗"} ${c.id}  ${c.detail}`);
    }
    console.log(
      `      findings: ${r.findings.p1} P1, ${r.findings.p2} P2, ${r.findings.p3} P3` +
        (r.findings.p3Unread ? ` (${r.findings.p3Unread} P3 unread — not blocking until VD.11)` : "") +
        (r.rating ? `   rating ${r.rating.min}–${r.rating.max} (mean ${r.rating.mean}) — reported, not gated on` : ""),
    );
    console.log("");
  }

  console.log(`G6 (tier-1 determinism): NOT ENFORCED — ${verdict.tier1.why}\n`);

  if (foundations) {
    console.log(
      ok
        ? `FOUNDATIONS GATE PASSED — ${passing.length}/${results.length}`
        : `FOUNDATIONS GATE FAILED — ${passing.length}/${results.length} passing`,
    );
    // Never printed on its own.
    console.log(`FULL GATE (reported alongside, never replaced by the above) — ${fullPassing}/${fullResults.length} passing`);
    for (const r of fullResults.filter((x) => !x.pass)) {
      console.log(`  ${r.key}: ${r.conditions.filter((c) => !c.ok).map((c) => c.id).join(", ")} still failing — the page-level work VD.3-VD.6 own`);
    }
    return ok ? 0 : 1;
  }

  console.log(ok ? `GATE PASSED — ${passing.length}/${results.length}` : `GATE FAILED — ${passing.length}/${results.length} passing`);
  return ok ? 0 : 1;
}

// Run only when invoked directly. `gate-selftest.mjs` imports this module for
// FOUNDATIONS_CRITERIA / PAGE_CRITERIA, and a module that gates on import would
// print a verdict in the middle of someone else's output — and, worse, would
// exit their process.
if (import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv.slice(2))
    .then((c) => process.exit(c))
    .catch((err) => {
      console.error(`gate failed: ${err.message}`);
      process.exit(2);
    });
}
