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

  /** `actual === want`, with both numbers in the message. Fails in both directions. */
  countIs(actual, want, what) {
    return this.expect(
      actual === want,
      what,
      `counted ${actual}, the claim says ${want}`,
    );
  }

  /**
   * `actual >= min`. Use ONLY where the exact size is genuinely not knowable —
   * a corpus that grows with the chain data, a pane set a layout may extend.
   * Where it is knowable, use `countIs`.
   */
  atLeast(actual, min, what) {
    return this.expect(actual >= min, what, `counted ${actual}, the claim needs at least ${min}`);
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
    out.push(`         ${r.ok ? "[OK]    " : "[FAILED]"} ${r.what}${r.detail ? ` — ${r.detail}` : ""}`);
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
