// TOUR: mutation over time
//
// The subject is a value that CHANGES. Everything else in this tour shows
// values being computed and bound once; this one shows the same binding
// holding a different value at a different time, which is the case a
// time-travelling debugger answers and a printout of the final state does not.
//
// The program is arranged so that the forms the recorder captures come first
// and can be relied on, and the one form it does NOT capture is last, on its
// own, labelled. A demo that mixed them would leave a reader unable to tell a
// value that did not change from a change that was not recorded — which is the
// single worst thing a values pane can do.

mod counter;

use counter::Counter;

struct Acc {
    total: u32,
    hits: u32,
}

// ── recorded: plain reassignment ──────────────────────────────────────────
// Each statement rebinds `level`, so the trace holds its whole history and
// stepping backward through this block walks it in reverse.
unconstrained fn ramp(start: u32, step: u32) -> u32 {
    let mut level = start;
    level = level + step;
    level = level * 2;
    level = level - 1;
    level
}

// ── recorded: compound assignment inside a loop ───────────────────────────
// `total += ...` is its own kind of statement, and a tracer that did not
// instrument it would show this variable frozen at 0 while the program
// computed the right answer. That is a defect this fork has actually shipped
// and fixed, so it is demonstrated here rather than assumed: the recording
// carries every intermediate value, not just the result.
unconstrained fn accumulate(values: [u32; 5]) -> u32 {
    let mut total: u32 = 0;
    for i in 0..5 {
        total += values[i];
        total -= 1;
    }
    total
}

// ── recorded: assignment INTO a compound, by field and by index ───────────
// `a.total = …`, `a.hits += 1` and `arr[1] = …` are three distinct kinds of
// assignment target — a member, a compound member, and an index — and the
// recorder captures all three, holding the whole struct and the whole array at
// every step. They are here because the language HAS them, not because anybody
// remembered them: `tools/noir-coverage.mjs` enumerates the compiler's own
// `LValue` variants and reported these as neither demonstrated nor explained.
unconstrained fn tally(n: u32) -> u32 {
    let mut a = Acc { total: 0, hits: 0 };
    for i in 0..n {
        a.total = a.total + i;
        a.hits += 1;
    }
    let mut arr: [u32; 3] = [0, 0, 0];
    arr[1] = a.total;
    arr[2] = a.hits;
    assert_eq(arr[1], a.total);
    arr[1] + arr[2]
}

// ── recorded: a compound value whose FIELD moves ──────────────────────────
// The methods return a new `Counter` rather than writing through `&mut self`,
// so each step rebinds the whole struct and the recording holds the field's
// history. The Values pane shows one row whose nested field changes while the
// binding's name and type do not.
unconstrained fn run_counter(start: u32) -> Counter {
    let mut c = Counter::new(start);
    c = c.tick();
    c = c.tick();
    c = c.tick();
    c = c.reset_if_above(start + 2);
    c = c.tick();
    c
}

// ── a write through a mutable reference — KNOWN FAILURE, defect NR-04 ─────
//
// WHAT SHOULD HAPPEN: `bump` is called three times, so the recording should
// show `slot` taking 5, 12, 19 and 26 in `main`, and `*slot` should have a
// value inside this frame.
//
// What happens instead: `slot` is recorded once, as 5, and never again, and
// inside `bump` the reference records with no dereferenced value at all. The
// circuit is correct — `main` asserts the result below and the assertion holds —
// so every one of the three writes happened. Only the recording is missing them.
//
// The defect is UPSTREAM Noir's, not ours: its debug instrumenter emits a
// literal `0` where the assignment oracle should go, the stub it would have
// called is named `__debug_dereference_assign` while the debugger dispatches on
// `__debug_deref_assign`, and the handler behind that is `unimplemented!()`.
// See `docs/NOIR-RECORDER-DEFECTS.md` NR-04.
//
// This is stated as what SHOULD happen rather than as an assertion that the
// value stays frozen, and that is deliberate: a corpus asserting the broken
// behaviour would teach the next reader that absence is correct, and would go
// red the day somebody fixed it. `check-corpus.sh` carries the entry and fails
// LOUDLY the moment `slot` reaches 26.
unconstrained fn bump(slot: &mut u32, by: u32) {
    *slot = *slot + by;
}

unconstrained fn main(start: u32, step: pub u32) -> pub u32 {
    let level = ramp(start, step);
    let acc = accumulate([1, 2, 3, 4, 5]);
    let t = tally(4);
    let c = run_counter(start);

    // The one unrecorded form, exercised three times.
    let mut slot = start;
    bump(&mut slot, step);
    bump(&mut slot, step);
    bump(&mut slot, step);

    // The circuit did the work even though the recording does not show it, and
    // this assertion is the proof: 5 + 7 + 7 + 7.
    assert(slot == start + 3 * step, "the reference writes did happen");
    assert(level == 23, "ramp: (5 + 7) * 2 - 1");
    assert(acc == 10);
    assert(c.value == 1);
    assert(c.ticks == 4);
    assert_eq(t, 10);

    level + acc + c.value + slot + t
}
