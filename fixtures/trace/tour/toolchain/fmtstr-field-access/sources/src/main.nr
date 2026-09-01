// TOOLCHAIN-ONLY: a format string interpolates bindings, not expressions
//
// Expected outcome: COMPILE FAILURE.
//
//   error: Invalid format string: expected '}', found '.'
//          Field access isn't supported in format strings
//
// `f"a={p.a}"` looks like it should work and does not: the interpolation syntax
// accepts an identifier and nothing else — no field access, no index, no call.
//
// This is the rule that shapes `tour/events` and `tour/constraints` more than
// any other. Every value those two programs print is bound to a local first,
// and a reader who did not know this rule would take those locals for clutter.
// They are not: they are what the event log's text is built from, and they are
// there because the language requires them to be.

struct P {
    a: u32,
}

unconstrained fn main(x: u32) -> pub u32 {
    let p = P { a: x };
    println(f"a={p.a}");
    p.a
}
