// WHICH SUBTREES OF A NOIR CALL TREE THE CALL TRACE PANE STARTS WITH CLOSED.
//
// ── Folding, not elision. The difference is the whole feature. ───────────────
//
// A trace of an Aztec public function spends a large share of its steps inside
// poseidon2 — on this repository's published snapshot, 28 of the 86 positioned
// steps, a third of everything the reader is shown, for a hash. The tree reads
// better with that subtree closed. There are two ways to get there and they are
// not variations on one idea:
//
//   * ELIDE — leave the frames out. The trace then no longer says what
//     executed, and no reader, on any day, can get it back.
//   * FOLD — carry every frame, and let the default view show one of them
//     CLOSED. The frame is present, named, at its real depth, carrying the
//     count of what is inside it. A reader who wants the inside opens it.
//
// The recorders write every frame — `aztec-avm-runtime` states this in
// `ct-host/src/frame_fold.ts` and neither recorder imports the policy. This file
// is the render-time half, and `derive-calltrace.mjs` is where it is applied.
//
// ── Why the policy is applied at DERIVATION and not in the Nim renderer ──────
//
// Because the counts have to be the CONTAINER's. `hiddenDescendants` and
// `hiddenSteps` are properties of the whole recorded tree, and the derivation is
// the only place that holds the whole recorded tree — it reads every `Call`,
// `Return` and `Step` event in the container, in order. A renderer that counted
// what it happened to have loaded would answer a different question, and would
// answer it differently depending on what else was on the page. So the tool
// writes the marks and the counts into `calltrace.json` and the renderer paints
// what it is told; `session_view.CallFrame` has no arithmetic in it.
//
// The reader's control is not a switch, it is the disclosure itself: opening the
// frame is how folding gets turned off, one subtree at a time, which is the
// gesture that opens any node in any tree.
//
// ── The rule is NAMED, not the instance ─────────────────────────────────────
//
// `name === 'poseidon2_hash'` would be the brittle version: it breaks on a
// rename, misses `poseidon2_permutation` beside it, and says nothing about the
// next primitive that swamps a trace. The class these frames belong to is CODE
// THE CONTRACT AUTHOR DID NOT WRITE — Noir's standard library, and crates
// vendored in through nargo.
//
// Measured against the published container's own eighteen interned paths, that
// predicate selects `std/hash/mod.nr` and
// `nargo/github.com/noir-lang/poseidon/v0.3.0/src/poseidon2.nr` — which between
// them carry the 28 poseidon2 steps — plus `std/cmp.nr`, `std/option.nr`,
// `std/ops/arith.nr` and `std/panic.nr`.
//
// It deliberately does NOT fold `aztec_sublib`, `noir-protocol-circuits` or the
// contract itself: those are Aztec's own code and are what a reader came for.
//
// ── Provenance, and the duplication this file admits to ─────────────────────
//
// The rule is stated twice: here, and in `aztec-avm-runtime`'s
// `ct-host/src/frame_fold.ts` at 255a61e. That is a real duplication and it is
// deliberate — the site build is hermetic and cannot import from that checkout,
// the same reason `derive-positions.mjs` re-states the pseudo-path convention.
// What keeps the two from drifting silently is that both are checked against the
// same measurable consequence on the same transaction: the two `Poseidon2::hash`
// fold points hide exactly 28 steps between them. `calltrace-fold-selftest.mjs`
// asserts that number here, so a drift shows up as a red rather than as two
// files quietly meaning different things.

/**
 * One reason a frame's subtree starts folded.
 *
 * `foldRuleFor` returns the RULE and not a boolean, so the pane can show WHICH
 * rule closed a node and a reader is never left guessing why something came up
 * shut. A fold the reader cannot account for is indistinguishable from missing
 * data, which is the thing this whole design exists to avoid.
 */
export const DEFAULT_FOLD_RULES = [
  {
    id: 'noir-stdlib',
    why: "Noir's standard library — hashing, comparison, Option and operator "
      + 'machinery that the contract calls but does not contain',
    // `std/…` is how Noir spells its own library in a `file_map`: no leading
    // slash, no package prefix. ANCHORED, so a contract at `…/my_std/…` is not
    // swept up by a substring test.
    matches: (path) => path.startsWith('std/'),
  },
  {
    id: 'vendored-crate',
    why: 'a third-party crate vendored in through nargo — poseidon2 is here, and '
      + 'it is the single largest consumer of steps in a typical Aztec public call',
    // `/home/aztec-dev/nargo/github.com/noir-lang/poseidon/v0.3.0/src/poseidon2.nr`
    // and its siblings. The `/nargo/` segment is nargo's dependency cache and is
    // what makes a file third-party regardless of host or version.
    matches: (path) => path.includes('/nargo/'),
  },
];

/**
 * The rule that folds a frame in `path`, or `null` when none does.
 *
 * Pass `rules: []` to turn folding off entirely, which is what
 * `derive-calltrace.mjs --no-fold` does. A DEFAULT THAT CANNOT BE TURNED OFF IS
 * NOT A DEFAULT, and the self-test drives both directions.
 *
 * A frame with no path — the AVM's own `<toplevel>` and `enqueued-call-0` sit on
 * the recorder's pseudo-path and have none — is never folded. There is no file
 * to judge, and guessing from the name is the brittle version this rule exists
 * instead of.
 */
export function foldRuleFor(path, rules = DEFAULT_FOLD_RULES) {
  if (typeof path !== 'string' || path.length === 0) return null;
  for (const rule of rules) {
    if (rule.matches(path)) return rule;
  }
  return null;
}
