// TOUR: bounds, limits and overflow
//
// The subject is what happens at the EDGES of a type. In a circuit this is not
// a curiosity: an addition that overflows is a failed constraint, and the
// difference between "this wrapped" and "this aborted" is the difference
// between a proof and no proof. A debugger is where that becomes visible.
//
// This program exists because `tools/noir-coverage.mjs` enumerates the
// compiler's own AST and reported a cluster of forms as neither demonstrated
// nor explained — globals, type aliases, shadowing, `loop`, the shift and
// compound-assignment operators, `Option`, `u32::max_value()` and the wrapping
// arithmetic traits. They are gathered here rather than sprinkled about because
// they share a subject: every one of them is about the boundary of a type.

mod checked;

use checked::Bounds;
use std::ops::WrappingAdd;

// ── a global constant, and a type alias over it ───────────────────────────
// A `global` is evaluated once at compile time and is in scope everywhere; the
// alias gives the width a name that says what it is FOR rather than how wide it
// is, which is the whole reason aliases exist.
global HEADROOM: u32 = 8;
type Counter = u32;

// ── a NUMERIC type alias: the alias computes a length ─────────────────────
// `Window<N>` is `N * 2` used in array-length position. The generic is a value,
// not a type, so this is arithmetic the compiler performs on types.
type Window<let N: u32>: u32 = N * 2;

unconstrained fn saturating_add(a: u32, b: u32) -> u32 {
    // `u32::max_value()` is a method reached through the TYPE rather than
    // through a value — a path form of its own.
    let ceiling = u32::max_value();
    if a > ceiling - b {
        ceiling
    } else {
        a + b
    }
}

unconstrained fn wrapping_walk(start: u32) -> u32 {
    // The wrapping traits are the language's way of asking for modular
    // arithmetic explicitly, instead of getting it by accident. `wrapping_add`
    // past the ceiling comes back to zero, and the recording shows it doing so
    // one step at a time.
    let mut v = start;
    for _ in 0..3 {
        v = v.wrapping_add(u32::max_value() / 2);
    }
    v
}

unconstrained fn shift_ladder(seed: u32) -> u32 {
    // Every compound assignment operator the language has, in one place, plus
    // both shifts. `seed` is masked first so the ladder cannot overflow —
    // which is itself the point of the mask.
    let mut v = seed & 0xff;
    v <<= 3;
    v |= 1;
    v ^= 10;
    v &= 0xfff;
    v >>= 2;
    v += HEADROOM;
    v -= 1;
    v *= 2;
    v /= 3;
    v %= 1000;
    v
}

unconstrained fn first_over(limit: u32) -> Option<u32> {
    // `loop` — unconstrained only, and it must contain a reachable `break`.
    // The trip count is in no bound anywhere in the source, so the recording is
    // the only place it exists.
    //
    // `Option` is how a Noir function says "there may be no answer" without a
    // sentinel value a caller could mistake for a real one.
    let mut n: Counter = 1;
    loop {
        n = n * 3;
        if n > limit {
            break;
        }
    }
    if n > limit {
        Option::some(n)
    } else {
        Option::none()
    }
}

unconstrained fn main(seed: u32, limit: pub u32) -> pub u32 {
    let sat = saturating_add(u32::max_value() - 2, 10);
    let wrapped = wrapping_walk(seed);
    let laddered = shift_ladder(seed);

    // SHADOWING: the second `bounds` is a new binding with the same name, and
    // the first is still in the recording at the steps before this line. That
    // is the case a values pane has to get right and a printout cannot show at
    // all.
    let bounds = Bounds::new(0, HEADROOM);
    let bounds = bounds.widen(limit);

    // Destructuring a struct, and a tuple pattern beside it.
    // `span` takes `&self` — reading THROUGH a reference, which the recorder
    // handles correctly. Only writing through one does not (NR-04).
    let by_ref = bounds.span();
    let Bounds { low, high } = bounds;
    let (span, midpoint) = (high - low, (high + low) / 2);

    // A window whose length is computed by the numeric alias: N = 3, so 6.
    // The turbofish is required in array-length position.
    let window: [u32; Window::<3>] = [0, 1, 2, 3, 4, 5];

    // `_` discards a value the program does not need, which is a binding form
    // rather than an absence of one.
    let _ = window[5];

    let found = first_over(limit);
    let reached = if found.is_some() { found.unwrap() } else { 0 };

    assert_eq(sat, u32::max_value());
    assert(span >= HEADROOM);
    assert_eq(by_ref, span);
    assert(window.len() == 6);

    sat / 1000 + wrapped % 1000 + laddered + span + midpoint + reached % 1000
}
