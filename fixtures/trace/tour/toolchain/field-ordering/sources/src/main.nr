// TOOLCHAIN-ONLY: `Field` has no ordering, and the compiler says so
//
// Expected outcome: COMPILE FAILURE.
//
//   error: No matching impl found for `Field: Ord`
//
// This is not a defect in anything. A field element is a residue modulo the
// prime — it wraps — so "greater than" is not a question it answers, and the
// standard library deliberately provides no `Ord` impl for it. The rule is a
// language fact, and it is the reason `tour/generics` instantiates `largest`
// over `u32`, `u64` and `i32` and never over `Field`.
//
// It is pinned here rather than left as a comment in the tour because a rule
// nobody exercises is a rule that quietly stops being true. If a future Noir
// gives `Field` an `Ord`, this program starts compiling and the toolchain suite
// says so.

fn largest<T>(a: T, b: T) -> T
where
    T: std::cmp::Ord,
{
    if a > b {
        a
    } else {
        b
    }
}

unconstrained fn main(x: u32) -> pub Field {
    largest(x as Field, 4)
}
