// TOOLCHAIN-ONLY: a signed integer cannot be cast straight to `Field`
//
// Expected outcome: COMPILE FAILURE.
//
//   error: Only unsigned integer types may be casted to Field
//
// Also a language fact rather than a defect, and one with a real consequence
// for anybody reading a recording: a negative signed value has no
// representation as a field element that agrees with arithmetic, so the
// language refuses the cast rather than picking a convention silently.
//
// `tour/values` routes its signed values through an unsigned width to reach
// `Field`, and demonstrates the related RECORDING behaviour — a recorded `i8`
// of -42 reads 214, because the recorder writes the two's-complement bit
// pattern. The language refusing the cast and the recorder showing the bit
// pattern are two different things about the same underlying fact, and having
// both written down is what keeps them from being conflated.

unconstrained fn main(x: u32) -> pub Field {
    let n: i32 = -(x as i32);
    n as Field
}
