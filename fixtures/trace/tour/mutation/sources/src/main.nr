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

// ── NOT recorded: a write through a mutable reference ─────────────────────
//
// This is correct Noir and the circuit executes it correctly — `main` asserts
// the result below and the assertion holds. What the RECORDER does not do is
// capture it: inside this frame `slot` is written as a reference whose
// dereferenced value is absent, and in the caller the bound value never moves.
//
// It is here, and it is here last and alone, because a tour of what a debugger
// can show is worth more if it also shows where the recording stops. A reader
// who sees `slot` frozen at its initial value should know that is the tracer
// and not the program.
unconstrained fn bump(slot: &mut u32, by: u32) {
    *slot = *slot + by;
}

unconstrained fn main(start: u32, step: pub u32) -> pub u32 {
    let level = ramp(start, step);
    let acc = accumulate([1, 2, 3, 4, 5]);
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

    level + acc + c.value + slot
}
