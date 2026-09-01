// TOOLCHAIN-ONLY: an oracle call
//
// An oracle is how an unconstrained Noir function asks the outside world for a
// value it then constrains. It is a headline feature of the language and it is
// absent from the tour, for a reason worth stating exactly rather than
// summarising as "oracles do not work".
//
//   nargo execute                    →  refuses, and says why:
//                                       "No handler could be found for foreign
//                                        call `get_hint`"
//   nargo execute --oracle-resolver  →  works: the flag exists, and so does
//                                       --oracle-file
//   nargo trace                      →  HAS NEITHER FLAG. It does not refuse —
//                                       it writes a recording that stops at the
//                                       call, whose only error entry reads
//                                       "Failed assertion".
//
// So there are two separate defects here and they are both OURS, because
// `nargo trace` is our command:
//
//   1. `nargo trace` does not expose the oracle-resolution flags that
//      `nargo execute` already has, so no oracle program can be recorded
//      faithfully at all.
//   2. When the call goes unresolved, the recorded error loses its cause. The
//      execution path knows the precise, actionable sentence — it prints it —
//      and the recorded one says "Failed assertion", which sends a reader
//      looking for a constraint that never failed.
//
// The second is the worse of the two: a missing flag is discoverable, and a
// recording that misattributes its own ending is not.
//
// When (1) is fixed this program moves into the tour, because an oracle call is
// exactly the kind of thing a visitor should be able to step through: the hint
// arrives from outside and the circuit then proves it was the right one.

#[oracle(get_hint)]
unconstrained fn get_hint_oracle(x: u32) -> u32 {}

unconstrained fn get_hint(x: u32) -> u32 {
    get_hint_oracle(x)
}

unconstrained fn main(x: u32) -> pub u32 {
    // The shape every oracle use has: take an answer from outside, then
    // CONSTRAIN it, so that a wrong answer cannot be passed off as a right one.
    let hint = get_hint(x);
    assert(hint * hint == x * x, "the hint must be a square root of x squared");
    hint
}
