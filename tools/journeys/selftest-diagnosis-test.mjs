#!/usr/bin/env node
// selftest-diagnosis-test.mjs — proof that a NEVER RAN says WHY the journey
// stopped, and not only WHERE.
//
//   node tools/journeys/selftest-diagnosis-test.mjs
//
// WHY THIS EXISTS
// ---------------
// `selftest.mjs` scores an arm NEVER RAN when the mutated journey ran but never
// reached the assertion the arm names. That verdict has two causes with opposite
// remedies:
//
//   · the mutation reached FURTHER than its target, so the journey broke
//     upstream of the assertion — the arm is too broad and must be narrowed; or
//   · a gesture timed out on this runner, in a phase the mutation's own code
//     path never executes — the arm is fine and the run is not.
//
// `logMissDiagnosis` printed the names of the assertions the mutated run DID
// record, which locates the stop, and dropped their details, which is the only
// thing that names its cause. `run.mjs` records a thrown journey as the
// assertion "the journey threw" with the STACK as its detail, so the deciding
// datum existed and was discarded one function before the log.
//
// MEASURED, not hypothetical. On PR #105 shard 4, arm
// `Y/reversing-rewinds-to-the-first-breakpoint` scored NEVER RAN with its
// recorded list ending `· the journey threw`. Deciding between the two readings
// took the shard journal, the arm's `find`/`replace` text, the scope of the
// enclosing Nim proc, a forward-declaration check and the journey's statement
// order — to establish what one stack line says directly.
//
// THE CONTROL IS THE POINT. A section that printed on every miss would say
// nothing, so probe 3 asserts it is ABSENT when no record went red.
import { redRecords, logMissDiagnosis } from "./selftest.mjs";

let pass = 0;
let fail = 0;
const ck = (claim, ok, detail = "") => {
  if (ok) {
    console.log(`  [OK]     ${claim}`);
    pass += 1;
  } else {
    console.log(`  [FAILED] ${claim}${detail ? ` — ${detail}` : ""}`);
    fail += 1;
  }
};

/** Run `logMissDiagnosis` and return everything it printed, as one string. */
function captured(miss, arm = { journey: "j12", file: "x.nim" }, phase = "mutated") {
  const lines = [];
  const real = console.log;
  console.log = (s = "") => lines.push(String(s));
  try {
    logMissDiagnosis(miss, arm, phase);
  } finally {
    console.log = real;
  }
  return lines.join("\n");
}

const THREW = {
  ok: false,
  what: "the journey threw",
  detail:
    "TimeoutError: locator.click: Timeout 30000ms exceeded.\n" +
    "    at clickGutter (file:///x/tools/journeys/journeys/12-continuing-stops-at-a-breakpoint.journey.mjs:131:15)",
};
const missWith = (records) => ({
  found: false,
  why: "no-record",
  ambiguous: 0,
  records: records.length,
  texts: records.map((r) => r.what),
  failures: redRecords(records),
});

console.log("selftest-diagnosis-test — does a NEVER RAN name its cause?\n");

// ── 1. THE DECIDING DATUM REACHES THE LOG ──────────────────────────────────
// The whole defect, stated as one claim: the stack was captured by `run.mjs`
// and thrown away by the diagnosis. Under the implementation this test was
// written against, every assertion below held except these.
{
  const out = captured(missWith([{ ok: true, what: "three lines were chosen" }, THREW]));
  ck("a thrown journey's exception TYPE reaches the log", out.includes("TimeoutError"));
  ck(
    "and the frame it threw in, which is what names the phase",
    out.includes("clickGutter"),
  );
  ck(
    "and the section says a stack here is the runner, not the arm",
    /this runner and not this arm/.test(out),
  );
  ck(
    "the assertion-name list is still printed, so the stop is still located",
    out.includes("three lines were chosen") && out.includes("WHAT IT DID ASSERT"),
  );
}

// ── 2. NOT THROW-SPECIFIC ──────────────────────────────────────────────────
// A journey can also stop because a guard above the assertion stopped holding,
// which arrives as an ordinary red record. Keying the section on the text
// "the journey threw" would have covered probe 1 and missed this entirely.
{
  const guard = {
    ok: false,
    what: "CONTROL: three `setBreakpoints` frames reached the engine",
    detail: "counted 0, the claim says 3",
  };
  const out = captured(missWith([{ ok: true, what: "a session opens unmarked" }, guard]));
  ck(
    "an ordinary red record's detail is printed too, not just a throw's",
    out.includes("counted 0, the claim says 3"),
  );
}

// ── 3. THE CONTROL: SILENCE WHEN THERE IS NOTHING TO SAY ───────────────────
// If this printed unconditionally it would be a heading with no content on
// every miss, and a reader would stop looking at it — which is how the
// original gap would come back wearing a header.
{
  const out = captured(missWith([{ ok: true, what: "a session opens unmarked" }]));
  ck(
    "a miss with NO red record prints no cause section at all",
    !out.includes("AND WHY IT STOPPED THERE"),
  );
  ck(
    "...while still printing the assertion-name list",
    out.includes("a session opens unmarked"),
  );
}

// ── 4. THE CAP IS STATED, NOT SILENT ───────────────────────────────────────
// A truncated list that does not say it is truncated is the same class of
// defect as a dropped detail: the reader cannot tell a complete report from a
// partial one.
{
  const many = Array.from({ length: 7 }, (_, i) => ({
    ok: false,
    what: `red ${i}`,
    detail: `detail ${i}`,
  }));
  const out = captured(missWith(many));
  ck("the first five red records are printed", out.includes("detail 4"));
  ck("the sixth is not", !out.includes("detail 5"));
  ck("and the log SAYS two were withheld", /and 2 more red record\(s\)/.test(out));
}

// ── 5. THE HELPER'S OWN CONTRACT ───────────────────────────────────────────
// `redRecords` is what `verdictFor` puts in the miss, so its polarity is the
// one place a sign error would make every section above vacuous rather than
// wrong — it would print nothing and probe 3 would still pass.
{
  const rs = redRecords([
    { ok: true, what: "green", detail: "g" },
    { ok: false, what: "red", detail: "r" },
    { ok: false, what: "red2" },
  ]);
  ck("redRecords keeps exactly the records that are NOT ok", rs.length === 2, `got ${rs.length}`);
  ck("it keeps no green one", !rs.some((r) => r.what === "green"));
  ck("it carries the detail through", rs[0].detail === "r");
  ck("and a record with no detail becomes an empty string, never undefined", rs[1].detail === "");
  ck("redRecords([]) is [], and an absent list does not throw", redRecords().length === 0);
}

// ── 6. THE UNMUTATED PHASE, WHICH IS THE ONE THAT FAILS A WHOLE SHARD ──────
// A miss on the UNMUTATED tree used to print three lines of prose and NO data,
// and those lines asserted a cause it cannot know: "The assertion was reworded
// and this arm still names the old wording". On blocktracer #108 that was
// false — journey 12 names the assertion verbatim in its source and makes 30
// records in a full `journeys` run against 12 under a single-journey bite run,
// so it never reached the assertion and the arm was right. Every arm behind an
// unmutated miss reads the same refusal, so this is the branch whose silence
// costs the most.
{
  const out = captured(
    missWith([{ ok: true, what: "three lines were chosen" }, THREW]),
    { journey: "j12", file: "x.nim" },
    "unmutated",
  );
  ck(
    "an UNMUTATED miss now reaches the stack too, not only a mutated one",
    out.includes("TimeoutError") && out.includes("clickGutter"),
  );
  ck(
    "and it prints what the run DID assert, so the stop is located",
    out.includes("three lines were chosen") && out.includes("WHAT IT DID ASSERT"),
  );
  ck(
    "it no longer asserts the arm is at fault",
    !/The assertion was reworded and this arm/.test(out),
    out.slice(0, 120),
  );
  ck(
    "it names BOTH causes, because the count cannot separate them",
    /REWORDED/.test(out) && /STOPPED EARLY/.test(out),
  );
  ck(
    "and says which reading a short record count supports",
    /FEWER records/.test(out),
  );
}

// ── 7. CONTROL: THE MUTATED PHASE STILL SAYS ITS OWN THING ─────────────────
// Sharing the evidence between the phases could have flattened them into one
// message. The two prose headers are what tell a reader WHICH tree stopped, so
// an arm that passes only because both branches now print the same text would
// be a regression wearing a green tick.
{
  const mutated = captured(missWith([THREW]));
  const unmutated = captured(missWith([THREW]), { journey: "j12", file: "x.nim" }, "unmutated");
  ck(
    "CONTROL: the mutated header still says the unmutated run recorded it GREEN",
    /though the unmutated run recorded it and/.test(mutated),
  );
  ck(
    "CONTROL: and the unmutated header does not claim that",
    !/though the unmutated run recorded it and/.test(unmutated),
  );
  ck(
    "CONTROL: the two phases do not print identical text",
    mutated !== unmutated,
  );
}

const total = pass + fail;
console.log(`\nassertion count: ${total} (as declared)`);
if (total !== 23) {
  console.log(`REFUSED: this suite declares 23 assertions and ran ${total}`);
  process.exit(1);
}
if (fail) {
  console.log(`\nFAILED — ${fail} of ${total}`);
  process.exit(1);
}
console.log(`\nPASS — a NEVER RAN names its cause (${pass} assertions)`);
