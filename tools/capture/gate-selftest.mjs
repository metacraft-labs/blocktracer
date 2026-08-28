#!/usr/bin/env node
// VD.1 — proof that `gate.mjs` DECIDES rather than merely reports.
//
//   node tools/capture/gate-selftest.mjs
//
// A gate script that has only ever been run against one ledger has not been
// shown to gate anything: it might return the same verdict for every input.
// This drives it over synthetic ledgers, one per condition, and asserts that
// each condition independently turns a passing ledger into a failing one — and
// that the complete ledger passes.
//
// It also drives the four fail-closed paths (absent ledger, unparseable
// ledger, orphan resolution, malformed severity), because the failure this
// gate must never have is going green because it found nothing to check.

import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const HERE = dirname(fileURLToPath(import.meta.url));
const GATE = join(HERE, "gate.mjs");

const REV = "selftest.1";

/** A ledger that satisfies every structural condition. */
function completeLedger() {
  return {
    ledgerRevision: REV,
    gateScope: [{ view: "tx-detail", size: "wide", theme: "light" }],
    reviews: ["L1", "L2", "L3", "L4", "L5", "ADV"].map((reviewer, i) => ({
      view: "tx-detail",
      size: "wide",
      theme: "light",
      image: "screenshots/tx-detail__wide__light.png",
      reviewer,
      expectedElements: "present",
      missing: [],
      rating: reviewer === "ADV" ? null : 7,
      findings: [
        {
          id: `tx-detail/wide/light/${reviewer}/1`,
          severity: i % 2 === 0 ? "P2" : "P3",
          location: "overview grid, label column",
          finding: "synthetic finding",
          criterion: "A2",
        },
      ],
    })),
    resolutions: ["L1", "L2", "L3", "L4", "L5", "ADV"].map((reviewer, i) =>
      i % 2 === 0
        ? { findingId: `tx-detail/wide/light/${reviewer}/1`, status: "fixed", evidence: "commit deadbeef" }
        : { findingId: `tx-detail/wide/light/${reviewer}/1`, status: "accepted", reason: "nitpick, judged not worth acting on" },
    ),
    referenceParity: [
      {
        view: "tx-detail",
        register: "explorer",
        reference: "codetracer2026.webflow.io, 2026-08-28",
        verdict: "pass",
        notes: "synthetic",
        by: "A Human",
        date: "2026-08-28",
      },
    ],
    signOffs: [{ view: "tx-detail", by: "A Human", date: "2026-08-28", ledgerRevision: REV }],
  };
}

const clone = (o) => JSON.parse(JSON.stringify(o));

// Each case mutates the complete ledger in exactly one way and names the
// condition that must catch it.
const CASES = [
  {
    name: "complete ledger passes",
    expect: "pass",
    mutate: (L) => L,
  },
  {
    name: "G1 — a reviewer did not find the expected elements",
    expect: "fail",
    condition: "G1",
    mutate: (L) => {
      L.reviews[2].expectedElements = "missing";
      L.reviews[2].missing = ["the Debug button"];
      L.reviews[2].rating = 3;
      return L;
    },
  },
  {
    name: "G1 — a view with no expectation block cannot be gated",
    expect: "schema",
    mutate: (L) => {
      L.gateScope[0].view = "no-such-view";
      return L;
    },
  },
  {
    name: "G2 — one lens missing is not a pass, it is an unreviewed view",
    expect: "fail",
    condition: "G2",
    mutate: (L) => {
      const dropped = L.reviews.pop().reviewer;
      L.resolutions = L.resolutions.filter((r) => !r.findingId.includes(`/${dropped}/`));
      return L;
    },
  },
  {
    name: "G2 — the adversarial reviewer alone is not coverage",
    expect: "fail",
    condition: "G2",
    mutate: (L) => {
      L.reviews = L.reviews.filter((r) => r.reviewer === "ADV");
      L.resolutions = L.resolutions.filter((r) => r.findingId.includes("/ADV/"));
      return L;
    },
  },
  {
    name: "G3 — an unresolved P2 blocks",
    expect: "fail",
    condition: "G3",
    mutate: (L) => {
      L.resolutions = L.resolutions.filter((r) => r.findingId !== "tx-detail/wide/light/L1/1");
      return L;
    },
  },
  {
    name: "G3 — a P2 left 'open' blocks",
    expect: "fail",
    condition: "G3",
    mutate: (L) => {
      L.resolutions.find((r) => r.findingId === "tx-detail/wide/light/L1/1").status = "open";
      return L;
    },
  },
  {
    name: "G3 — a P1 cannot be waived, only fixed",
    expect: "fail",
    condition: "G3",
    mutate: (L) => {
      L.reviews[0].findings[0].severity = "P1";
      const r = L.resolutions.find((x) => x.findingId === "tx-detail/wide/light/L1/1");
      r.status = "waived";
      r.reason = "we would rather not";
      r.signedOffBy = "A Human";
      return L;
    },
  },
  {
    name: "G3 — a P2 waived WITH a reason and a sign-off passes, and is counted",
    expect: "pass",
    mutate: (L) => {
      const r = L.resolutions.find((x) => x.findingId === "tx-detail/wide/light/L1/1");
      r.status = "waived";
      r.reason = "deliberate divergence, recorded in DESIGN-DIVERGENCES-WEB.md";
      r.signedOffBy = "A Human";
      delete r.evidence;
      return L;
    },
  },
  {
    name: "G3 — a P2 waived WITHOUT a sign-off is a schema failure, not a pass",
    expect: "schema",
    mutate: (L) => {
      const r = L.resolutions.find((x) => x.findingId === "tx-detail/wide/light/L1/1");
      r.status = "waived";
      r.reason = "because";
      delete r.evidence;
      return L;
    },
  },
  {
    name: "G4 — no reference-parity record blocks",
    expect: "fail",
    condition: "G4",
    mutate: (L) => {
      L.referenceParity = [];
      return L;
    },
  },
  {
    name: "G4 — a recorded parity FAIL blocks",
    expect: "fail",
    condition: "G4",
    mutate: (L) => {
      L.referenceParity[0].verdict = "fail";
      return L;
    },
  },
  {
    name: "G4 — a parity record with no human attribution is a schema failure",
    expect: "schema",
    mutate: (L) => {
      delete L.referenceParity[0].by;
      return L;
    },
  },
  {
    name: "G5 — no human sign-off blocks",
    expect: "fail",
    condition: "G5",
    mutate: (L) => {
      L.signOffs = [];
      return L;
    },
  },
  {
    name: "G5 — a sign-off of a SUPERSEDED ledger revision blocks",
    expect: "fail",
    condition: "G5",
    mutate: (L) => {
      L.ledgerRevision = "selftest.2";
      return L;
    },
  },
  {
    name: "fail-closed — a review claiming 'present' while naming missing items",
    expect: "schema",
    mutate: (L) => {
      L.reviews[1].missing = ["the Debug button"];
      return L;
    },
  },
  {
    name: "fail-closed — a review reporting 'missing' with a rating above 4",
    expect: "schema",
    mutate: (L) => {
      L.reviews[1].expectedElements = "missing";
      L.reviews[1].missing = ["the Debug button"];
      L.reviews[1].rating = 8;
      return L;
    },
  },
  {
    name: "fail-closed — an unknown severity",
    expect: "schema",
    mutate: (L) => {
      L.reviews[0].findings[0].severity = "minor";
      return L;
    },
  },
  {
    name: "fail-closed — a finding with no location",
    expect: "schema",
    mutate: (L) => {
      delete L.reviews[0].findings[0].location;
      return L;
    },
  },
  {
    name: "fail-closed — a resolution for a finding nobody reported",
    expect: "schema",
    mutate: (L) => {
      L.resolutions.push({ findingId: "tx-detail/wide/light/L9/7", status: "fixed", evidence: "x" });
      return L;
    },
  },
  {
    name: "fail-closed — the adversarial reviewer reporting more than one finding",
    expect: "schema",
    mutate: (L) => {
      const adv = L.reviews.find((r) => r.reviewer === "ADV");
      adv.findings.push({ id: "tx-detail/wide/light/ADV/2", severity: "P3", location: "footer", finding: "a second" });
      return L;
    },
  },
];

// ── VD.2: the foundations-scoped mode ──────────────────────────────────────
//
// A narrower gate is only worth having if it is still a gate. These cases prove
// three things about `--foundations`, and the third is the one that matters:
//
//   1. It still FAILS on a foundations defect.
//   2. It correctly does NOT fail on a page-level defect — the narrowing is
//      real rather than cosmetic.
//   3. In that same run the FULL gate is computed and reported as failing, so
//      "foundations passed" can never be read as "this page is done".
//
// G2, G4 and G5 are asserted to be UNCHANGED by the narrowing: a foundations
// round that skipped a lens or a sign-off would be a different, weaker thing
// wearing the same name.

const FOUNDATION_CASES = [
  {
    name: "--foundations — the complete ledger passes",
    expect: "pass",
    mutate: (L) => L,
  },
  {
    name: "--foundations — an unresolved P2 carrying a FOUNDATIONS criterion (A2) blocks",
    expect: "fail",
    condition: "G3f",
    mutate: (L) => {
      L.reviews[0].findings[0].criterion = "A2";
      L.resolutions = L.resolutions.filter((r) => r.findingId !== L.reviews[0].findings[0].id);
      return L;
    },
  },
  {
    name: "--foundations — an unresolved P2 carrying A5 (numeric/monospace) blocks",
    expect: "fail",
    condition: "G3f",
    mutate: (L) => {
      L.reviews[2].findings[0].criterion = "A5";
      L.reviews[2].findings[0].severity = "P2";
      L.resolutions = L.resolutions.filter((r) => r.findingId !== L.reviews[2].findings[0].id);
      return L;
    },
  },
  {
    name: "--foundations — an unresolved P1 with NO criterion (a presence failure) does NOT block",
    expect: "pass",
    mutate: (L) => {
      L.reviews[1].findings.push({
        id: "tx-detail/wide/light/L2/9",
        severity: "P1",
        location: "hero, where the age should be",
        finding: "the age is absent — content nobody has built",
      });
      return L;
    },
    alsoAssert: (r) => {
      const full = r.parsed?.fullGate;
      return full && full.passing === 0
        ? null
        : `the FULL gate should still fail on the same ledger; it reported ${full?.passing}/${full?.scope}`;
    },
  },
  {
    name: "--foundations — an unresolved P1 carrying an EXCLUDED criterion (A6) does NOT block, but the full gate does",
    expect: "pass",
    mutate: (L) => {
      L.reviews[1].findings.push({
        id: "tx-detail/wide/light/L2/9",
        severity: "P1",
        location: "transactions table, the primary action column",
        finding: "the primary action is the last column of a scrolling row",
        criterion: "A6",
      });
      return L;
    },
    alsoAssert: (r) =>
      r.parsed?.fullGate?.passing === 0 ? null : `the FULL gate should still fail; it reported ${r.parsed?.fullGate?.passing}`,
  },
  {
    name: "--foundations — missing CONTENT relaxes G1 to G1f but is reported, and the full gate still fails on G1",
    expect: "pass",
    mutate: (L) => {
      L.reviews[3].expectedElements = "missing";
      L.reviews[3].missing = ["Hero: age", "Overview grid: nonce"];
      L.reviews[3].rating = 4;
      return L;
    },
    alsoAssert: (r) => {
      const g1f = r.parsed?.results?.[0]?.conditions?.find((c) => c.id === "G1f");
      const fullG1 = r.parsed?.fullGate?.results?.[0]?.conditions?.find((c) => c.id === "G1");
      if (!g1f?.ok) return "G1f should pass when the presence check was performed";
      if (!/report missing content/.test(g1f.detail)) return "G1f must SAY that content is missing, not hide it";
      if (fullG1?.ok !== false) return "the FULL gate's G1 must still fail on the missing content";
      return null;
    },
  },
  {
    name: "--foundations — a missing lens still blocks (G2 is NOT relaxed)",
    expect: "fail",
    condition: "G2",
    mutate: (L) => {
      L.reviews = L.reviews.filter((r) => r.reviewer !== "L3");
      L.resolutions = L.resolutions.filter((r) => !r.findingId.includes("/L3/"));
      return L;
    },
  },
  {
    name: "--foundations — a missing reference-parity record still blocks (G4 is NOT relaxed)",
    expect: "fail",
    condition: "G4",
    mutate: (L) => { L.referenceParity = []; return L; },
  },
  {
    name: "--foundations — a missing human sign-off still blocks (G5 is NOT relaxed)",
    expect: "fail",
    condition: "G5",
    mutate: (L) => { L.signOffs = []; return L; },
  },
  {
    name: "--foundations — a P1 resolved as 'waived' still blocks (a P1 can only be fixed)",
    expect: "fail",
    condition: "G3f",
    mutate: (L) => {
      L.reviews[0].findings[0].severity = "P1";
      L.reviews[0].findings[0].criterion = "A7";
      L.resolutions = L.resolutions.filter((r) => r.findingId !== L.reviews[0].findings[0].id);
      L.resolutions.push({ findingId: L.reviews[0].findings[0].id, status: "waived", reason: "later", signedOffBy: "A Human" });
      return L;
    },
  },
];

function runGate(ledgerPath, extra = []) {
  const r = spawnSync("node", [GATE, "--ledger", ledgerPath, "--json", ...extra], { encoding: "utf8" });
  let parsed = null;
  try {
    parsed = JSON.parse(r.stdout);
  } catch { /* leave null */ }
  return { status: r.status, stdout: r.stdout, stderr: r.stderr, parsed };
}

async function main() {
  const dir = await mkdtemp(join(tmpdir(), "vd1-gate-"));
  let pass = 0;
  const failures = [];

  try {
    for (const [i, c] of CASES.entries()) {
      const L = c.mutate(clone(completeLedger()));
      const p = join(dir, `case-${i}.json`);
      await writeFile(p, JSON.stringify(L, null, 2));
      const r = runGate(p);

      let ok;
      let why = "";
      if (c.expect === "pass") {
        ok = r.status === 0 && r.parsed?.ok === true && r.parsed.schemaProblems.length === 0;
        why = ok ? "" : `exit ${r.status}, ok=${r.parsed?.ok}, schemaProblems=${r.parsed?.schemaProblems?.length}`;
      } else if (c.expect === "schema") {
        ok = r.status === 1 && (r.parsed?.schemaProblems?.length ?? 0) > 0;
        why = ok ? "" : `expected a schema problem; exit ${r.status}, schemaProblems=${r.parsed?.schemaProblems?.length ?? 0}`;
      } else {
        // A condition failure: the named condition must be the one that failed.
        const res = r.parsed?.results?.[0];
        const failed = (res?.conditions ?? []).filter((x) => !x.ok).map((x) => x.id);
        ok = r.status === 1 && r.parsed?.ok === false && failed.includes(c.condition);
        why = ok ? "" : `expected ${c.condition} to fail; failing conditions = [${failed.join(", ")}], exit ${r.status}`;
      }

      console.log(`  ${ok ? "✓" : "✗"} ${c.name}${ok ? "" : `\n        ${why}`}`);
      if (ok) pass++;
      else failures.push(c.name);
    }

    // ── The two paths that are not ledgers at all ─────────────────────────
    const absent = runGate(join(dir, "does-not-exist.json"));
    const okAbsent = absent.status === 1;
    console.log(`  ${okAbsent ? "✓" : "✗"} fail-closed — a missing ledger is a FAIL, never "nothing to check"`);
    okAbsent ? pass++ : failures.push("missing ledger");

    const bad = join(dir, "bad.json");
    await writeFile(bad, "{ this is not json");
    const unparseable = runGate(bad);
    const okBad = unparseable.status === 1;
    console.log(`  ${okBad ? "✓" : "✗"} fail-closed — an unparseable ledger is a FAIL`);
    okBad ? pass++ : failures.push("unparseable ledger");

    // ── VD.2 — the foundations-scoped mode ────────────────────────────────
    console.log("");
    for (const [i, c] of FOUNDATION_CASES.entries()) {
      const L = c.mutate(clone(completeLedger()));
      const p = join(dir, `foundations-${i}.json`);
      await writeFile(p, JSON.stringify(L, null, 2));
      const r = runGate(p, ["--foundations"]);

      let ok;
      let why = "";
      if (c.expect === "pass") {
        ok = r.status === 0 && r.parsed?.ok === true;
        why = ok ? "" : `exit ${r.status}, ok=${r.parsed?.ok}, failing=[${(r.parsed?.results?.[0]?.conditions ?? []).filter((x) => !x.ok).map((x) => x.id).join(", ")}]`;
      } else {
        const failed = (r.parsed?.results?.[0]?.conditions ?? []).filter((x) => !x.ok).map((x) => x.id);
        ok = r.status === 1 && r.parsed?.ok === false && failed.includes(c.condition);
        why = ok ? "" : `expected ${c.condition} to fail; failing = [${failed.join(", ")}], exit ${r.status}`;
      }
      if (ok && c.alsoAssert) {
        const problem = c.alsoAssert(r);
        if (problem) { ok = false; why = problem; }
      }
      console.log(`  ${ok ? "✓" : "✗"} ${c.name}${ok ? "" : `\n        ${why}`}`);
      if (ok) pass++;
      else failures.push(c.name);
    }

    // The scope enumeration must be exhaustive and disjoint over both rubrics.
    // A criterion in neither set would escape BOTH the narrowing and the
    // review of the narrowing — which is exactly how a scope quietly shrinks.
    const { FOUNDATIONS_CRITERIA, PAGE_CRITERIA } = await import("./gate.mjs")
      .catch(() => ({ FOUNDATIONS_CRITERIA: null, PAGE_CRITERIA: null }));
    const all = [...Array(10)].flatMap((_, i) => [`A${i + 1}`, `B${i + 1}`]);
    const inF = new Set(Object.keys(FOUNDATIONS_CRITERIA ?? {}));
    const inP = new Set(Object.keys(PAGE_CRITERIA ?? {}));
    const uncovered = all.filter((c) => !inF.has(c) && !inP.has(c));
    const overlap = all.filter((c) => inF.has(c) && inP.has(c));
    const exhaustive = uncovered.length === 0 && overlap.length === 0;
    console.log(`  ${exhaustive ? "✓" : "✗"} the foundations scope is exhaustive and disjoint over A1-A10 and B1-B10`);
    if (!exhaustive) console.log(`        uncovered: [${uncovered.join(", ")}]  overlapping: [${overlap.join(", ")}]`);
    exhaustive ? pass++ : failures.push("foundations scope enumeration");

    // And every reason must actually be a reason.
    const reasoned = [...inF, ...inP].every((k) => ((FOUNDATIONS_CRITERIA ?? {})[k] ?? (PAGE_CRITERIA ?? {})[k] ?? "").length > 30);
    console.log(`  ${reasoned ? "✓" : "✗"} every criterion in the scope enumeration carries a stated reason`);
    reasoned ? pass++ : failures.push("foundations scope reasons");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }

  const total = CASES.length + 2 + FOUNDATION_CASES.length + 2;
  console.log(`\n${failures.length ? "FAIL" : "PASS"} — ${pass}/${total} gate self-test cases`);
  if (failures.length) for (const f of failures) console.log(`  failed: ${f}`);
  return failures.length ? 1 : 0;
}

main()
  .then((c) => process.exit(c))
  .catch((e) => {
    console.error(`gate-selftest failed: ${e.message}`);
    process.exit(2);
  });
