// TOUR: branches and conditions
//
// The subject is which arm ran. Every `if` below is written so that BOTH arms
// are reachable and the inputs decide, and the program calls each classifier
// more than once with values that land in different arms — so the same source
// line is marked taken on one visit and not-taken on another.
//
// A branch that can only go one way is a branch the marking cannot teach
// anything about, so there are none of those here.

struct Reading {
    sensor: u8,
    value: i32,
}

unconstrained fn classify(value: i32) -> u8 {
    // A three-way chain. Exactly one arm runs per call, and the three calls in
    // `main` between them run all three.
    if value < -50 {
        0 // under
    } else if value > 50 {
        2 // over
    } else {
        1 // nominal
    }
}

unconstrained fn clamp(value: i32, lo: i32, hi: i32) -> i32 {
    // Nested conditions: the outer test decides whether the inner one is
    // reached at all, so a not-taken outer arm hides an inner branch that was
    // never evaluated rather than one that was evaluated and went the other
    // way. Those are different facts and the marking distinguishes them.
    let mut out = value;
    if value < lo {
        out = lo;
    } else {
        if value > hi {
            out = hi;
        }
    }
    out
}

unconstrained fn describe(r: Reading) -> u8 {
    // Boolean operators in the condition itself, so the condition is worth
    // inspecting and not just its outcome.
    let known = (r.sensor == 1) | (r.sensor == 2);
    let extreme = (r.value < -50) | (r.value > 50);
    if known & extreme {
        9
    } else if known {
        classify(r.value)
    } else {
        255 // unknown sensor
    }
}

unconstrained fn main(low: i32, high: pub i32) -> pub u32 {
    // Three readings chosen so the three arms of `classify` each run once and
    // `describe`'s unknown-sensor arm runs exactly once.
    let a = describe(Reading { sensor: 1, value: low });
    let b = describe(Reading { sensor: 2, value: 12 });
    let c = describe(Reading { sensor: 7, value: high });

    let clamped_low = clamp(low, -10, 10);
    let clamped_mid = clamp(3, -10, 10);
    let clamped_high = clamp(high, -10, 10);

    assert(clamped_mid == 3);
    assert(clamped_low == -10);
    assert(clamped_high == 10);

    // Widened before summing: `describe` answers in a `u8` and three of its
    // answers do not fit in one.
    a as u32 + b as u32 + c as u32
}
