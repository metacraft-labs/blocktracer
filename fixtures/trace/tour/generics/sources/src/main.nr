// TOUR: generics and traits
//
// The subject is what the debugger shows you when the source is written once
// and executed several times over different types. A generic function has one
// body and many instantiations; a trait method has one name and many bodies.
// Both are places where "which code is running" is a real question, and the
// call trace is where it gets answered.

mod shapes;

use shapes::{Circle, Rect, Shape};

// A type generic. One body, three instantiations — `u32`, `u64` and `i32` —
// and the call trace names the frame each time it is entered.
//
// The bound is `Ord`, which `Field` deliberately does NOT implement: field
// elements wrap, so "greater than" is not a question they answer. That refusal
// is a language fact worth meeting here rather than in a compiler error later.
unconstrained fn largest<T>(a: T, b: T) -> T
where
    T: std::cmp::Ord,
{
    if a > b {
        a
    } else {
        b
    }
}

// A NUMERIC generic: `N` is a value, not a type, and the same source runs over
// arrays of two different lengths. The loop bound is the generic, so the loop
// rail has a different number of rungs per instantiation.
unconstrained fn sum_all<let N: u32>(values: [u32; N]) -> u32 {
    let mut total: u32 = 0;
    for i in 0..N {
        total = total + values[i];
    }
    total
}

// A generic constrained by a trait this package defines. Which `area` runs is
// decided by the argument's type, and the only place a reader can SEE which
// one ran is the trace.
unconstrained fn describe<T>(shape: T) -> u32
where
    T: Shape,
{
    let a = shape.area();
    let p = shape.perimeter();
    a + p
}

unconstrained fn main(side: u32, radius: pub u32) -> pub u32 {
    // Three instantiations of one generic function, over three types.
    let big_u = largest(side, 17);
    let big_w = largest(side as u64, 4_000_000_000);
    // The suffix is load-bearing: a bare negative literal is a `Field`, and
    // `Field` has no `Ord`.
    let big_i = largest(-3_i32, -9_i32);

    // Two instantiations of a numeric generic, N = 3 and N = 5.
    let three = sum_all([1, 2, 3]);
    let five = sum_all([side, side, side, side, side]);

    // Two impls of one trait, dispatched by type.
    let c = describe(Circle { radius });
    let r = describe(Rect { w: side, h: side + 1 });

    assert(big_u >= 17);
    assert(three == 6);
    assert(big_i == -3);
    assert(big_w == 4_000_000_000);

    big_u + three + five + c + r + big_w as u32
}
