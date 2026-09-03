// The assertion vocabulary, and the counting that makes a green run mean
// something.
//
// THE RULE THIS FILE ENFORCES
// ---------------------------
// A journey declares how many assertions it makes. The runner compares the
// declared number against the number actually recorded, and a mismatch is a
// FAILURE — in both directions.
//
// This is not bookkeeping. Every gate in this repository that has quietly gone
// wrong went wrong by making FEWER assertions than its author believed:
// `assertion F` printed PASS over 4 images of a 304-image corpus; a fork scan
// answered `0` by construction for months. An early `return`, a `continue` that
// skipped a case, a set that turned out empty — all of them shorten the run and
// none of them fails. Counting the assertions is the cheapest thing that
// notices, and it is why `expect` is the only way to record one.
//
// `atLeast`/`countIs` exist as separate verbs on purpose. Verification-Harness-
// Traps.md §4b: an existential control ("at least one") is satisfied by one
// member of five. Where the size of a set is knowable, `countIs` is the verb.

export class Journey {
  constructor(id, claim, spec) {
    this.id = id;
    this.claim = claim;
    this.spec = spec;
    this.records = [];
    this.notes = [];
  }

  note(msg) {
    this.notes.push(String(msg));
  }

  /** Record one assertion. The ONLY way an assertion enters the count. */
  expect(ok, what, detail = "") {
    this.records.push({ ok: !!ok, what, detail: String(detail) });
    return !!ok;
  }

  /**
   * AN IMPLICATION IS ONLY AS STRONG AS ITS ANTECEDENT — ENFORCED, NOT ARGUED.
   *
   * `countIs(0, 0)` is green. So is `atLeast(0, 0)`. Both are the same verdict:
   * a relation between two numbers that are zero because THE SET THEY WERE
   * COUNTED OVER IS EMPTY. Where the population is genuinely non-empty this is
   * a real absence claim and correct — `countIs(pageErrors.length, 0)` is a
   * measurement whose honest answer is zero. Where the population collapsed,
   * it is a pass over nothing.
   *
   * The harness cannot tell those apart from the numbers alone, and it does not
   * have to, because THE DANGEROUS CASE HAS A SIGNATURE IT CAN SEE: a
   * zero-against-zero verdict recorded in a journey that has ALREADY FAILED.
   * The failure upstream is what emptied the set, and the greenness downstream
   * is what hid it.
   *
   * THIS IS NOT HYPOTHETICAL, AND IT IS NOT ONE LINE. Measured over a full run
   * of this suite: 34 zero-against-zero verdicts stood GREEN after their own
   * journey had already recorded a failure, across 8 of the 23 journeys. One of
   * them — journey 07's "each control names the origin it would trace to" — is
   * why `O4/the-control-does-not-say-what-it-would-answer` was scored SURVIVED
   * by a selftest pass: the mutation removed the expression from the title, the
   * count of titles naming an expression was 0, the count of controls was 0
   * because the engine upstream had answered nothing, and `0 === 0` certified a
   * defect as guarded. Its own comment argued it could not pass vacuously
   * "because `classified` is asserted `>= 1` two verdicts above". That argument
   * assumes a red assertion STOPS the journey. It does not.
   *
   * WHY THE JOURNEY IS NOT SIMPLY HALTED AT ITS FIRST FAILURE, which is the
   * obvious fix and is the wrong one. Halting would shorten the run, and a run
   * that stops early is exactly what `declared === j.total` exists to catch —
   * every red journey would then fail its own count check for a second,
   * spurious reason. Worse, `selftest.mjs` resolves a mutation arm's target by
   * NAME in the recorded report: an assertion that never ran cannot be found,
   * so every arm aimed past the first failure would score NEVER RAN. That is
   * the disease `O1/the-engine-never-gets-the-source` already has, generalised
   * to the whole suite. The assertion must still RUN and still be RECORDED. It
   * must simply not be allowed to be GREEN.
   *
   * AND IT IS TAGGED `vacuous`, NOT MERELY FAILED, because the mirror-image
   * error is manufacturing kills. A mutation that reddens some earlier
   * assertion would otherwise redden every zero-against-zero verdict after it
   * and score a kill the arm did not earn — a false KILLED, which this
   * directory calls the worse of the two, "an assertion certified as biting
   * when it does not". `selftest.mjs` reads the flag and scores such a flip
   * NEVER RAN: you cannot certify that an assertion bites using a run in which
   * something else was already broken.
   */
  #vacuityCheck(vacuous, what, detail) {
    if (!vacuous || this.passed) return null;
    const antecedent = this.records.find((r) => !r.ok);
    this.records.push({
      ok: false,
      vacuous: true,
      what,
      detail:
        `VACUOUS — ${detail}, and both are zero because this journey had ` +
        `already failed at "${antecedent.what}". The set this verdict was ` +
        `taken over is empty, so it measures nothing. An implication is only ` +
        `as strong as its antecedent.`,
    });
    return false;
  }

  /** `actual === want`, with both numbers in the message. Fails in both directions. */
  countIs(actual, want, what) {
    const detail = `counted ${actual}, the claim says ${want}`;
    const poisoned = this.#vacuityCheck(actual === 0 && want === 0, what, detail);
    if (poisoned !== null) return poisoned;
    return this.expect(actual === want, what, detail);
  }

  /**
   * `actual >= min`. Use ONLY where the exact size is genuinely not knowable —
   * a corpus that grows with the chain data, a pane set a layout may extend.
   * Where it is knowable, use `countIs`.
   */
  atLeast(actual, min, what) {
    const detail = `counted ${actual}, the claim needs at least ${min}`;
    const poisoned = this.#vacuityCheck(actual === 0 && min === 0, what, detail);
    if (poisoned !== null) return poisoned;
    return this.expect(actual >= min, what, detail);
  }

  /**
   * Assert a set is non-empty BEFORE anything quantifies over it.
   *
   * Universal quantification over an empty set is a pass, and it is the
   * cheapest false green in any harness (Verification-Harness-Traps.md §4).
   * Every journey below that loops over a corpus calls this first, and the
   * subject count it asserts is itself one of the counted assertions.
   */
  subjects(list, min, what) {
    this.atLeast(list.length, min, `SUBJECTS: ${what}`);
    return list;
  }

  get passed() {
    return this.records.every((r) => r.ok);
  }
  get total() {
    return this.records.length;
  }
  get failures() {
    return this.records.filter((r) => !r.ok);
  }
}

/**
 * Assertion texts inside ONE journey where one CONTAINS another.
 *
 * `selftest.mjs` resolves a mutation arm's target with
 * `r.what.includes(assertion)` and treats any count but one as no match, so an
 * assertion whose text is a substring of a sibling's makes every arm aimed at
 * the shorter one AMBIGUOUS AND NEVER-RUN — a mutation that scores NEVER RAN
 * rather than SURVIVED, which reads as a harness problem and not as an
 * unguarded defect.
 *
 * It is a real hazard and not a hypothetical: the shape arrives whenever a
 * journey grows a REAL-capture arm and names its assertions `"REAL: " + <the
 * demo arm's text>`. Three such pairs existed in journeys 03 and 09 the day
 * this was written — none of them yet targeted by an arm, which is exactly the
 * window in which it is cheap to refuse.
 *
 * Refused HERE, over the assertions a run actually recorded, rather than by
 * reading the sources: the texts are built at run time out of counts and paths,
 * so the only place the real strings exist is the report.
 */
export function nameCollisions(j) {
  const out = [];
  const texts = j.records.map((r) => r.what);
  for (const a of texts) {
    for (const b of texts) {
      if (a !== b && b.includes(a)) out.push({ inner: a, outer: b });
    }
  }
  return out;
}

/** Format one journey's result block for the transcript. */
export function renderJourney(j, declared) {
  const out = [];
  out.push(`  ${j.passed ? "GREEN" : "RED  "}  ${j.id}`);
  out.push(`         "${j.claim}"`);
  out.push(`         ${j.spec}`);
  for (const n of j.notes) out.push(`         · ${n}`);
  for (const r of j.records) {
    // A vacuous verdict is marked as such rather than printed as an ordinary
    // failure. It is NOT evidence that the thing it names is broken — it is
    // evidence that this run could not say, and a reader who mistakes the two
    // goes looking for a defect that the transcript has already attributed to
    // an earlier line.
    const tag = r.ok ? "[OK]    " : r.vacuous ? "[VACUOUS]" : "[FAILED]";
    out.push(`         ${tag} ${r.what}${r.detail ? ` — ${r.detail}` : ""}`);
  }
  if (declared !== undefined && declared !== j.total) {
    out.push(
      `         [FAILED] the journey declares ${declared} assertions and made ${j.total}` +
        ` — a run that stopped early reports fewer passes, not a failure, unless the count is checked`,
    );
  }
  for (const c of nameCollisions(j)) {
    out.push(
      `         [FAILED] two assertions collide by name — "${c.inner}" is contained in` +
        ` "${c.outer}", so a selftest arm aimed at the first resolves to two records and never runs.` +
        ` Reword the longer one.`,
    );
  }
  return out.join("\n");
}
