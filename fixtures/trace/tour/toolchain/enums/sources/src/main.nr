// TOOLCHAIN-ONLY: enums and `match`
//
// This program is CORRECT Noir and it EXECUTES correctly. It is not in the tour
// because the recorder cannot represent it:
//
//   nargo execute -Zenums   →  Circuit output: 6
//   nargo trace   -Zenums   →  panic, `not yet implemented: Tracing support for
//                              enums is not yet implemented`
//                              (tooling/tracer/src/tracer_glue.rs:294)
//
// So the gap is OURS — an explicit `todo!()` in our tracer's value marshaller,
// not a limit of the language and not something upstream imposes. A visitor
// cannot be shown an enum stepping until that is implemented, which is why
// there is no `enum` anywhere in the tour's eight programs.
//
// Two further things this program pins, both learned the hard way:
//
//   * `enum` and `match` are UNSTABLE. Without `-Zenums` the compiler refuses
//     both, and the message names the flag. Any claim that "enums abort the
//     recording" is wrong at the surface: without the flag nothing is recorded
//     because nothing compiles.
//   * The panic happens AFTER the streaming container is opened, so a truncated
//     `.ct` is left behind on disk. A caller that treated the file's existence
//     as success would publish a corrupt recording.

enum Shape {
    Point,
    Circle(u32),
    Rect(u32, u32),
}

unconstrained fn area(s: Shape) -> u32 {
    match s {
        Shape::Point => 0,
        Shape::Circle(r) => 3 * r * r,
        Shape::Rect(w, h) => w * h,
    }
}

unconstrained fn main(n: u32) -> pub u32 {
    let s = if n == 0 {
        Shape::Point
    } else if n == 1 {
        Shape::Circle(n)
    } else {
        Shape::Rect(n, n + 1)
    };
    area(s)
}
