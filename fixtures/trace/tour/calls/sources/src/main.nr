// TOUR: calls and recursion
//
// The subject is the call trace. This program builds a call tree that is worth
// looking at rather than a flat list: recursion that goes several frames deep,
// two functions that call each other, and a helper called from three different
// places so the same frame appears in the tree under three different parents.
//
// Stepping into, over and out of a frame all need somewhere to go, and a
// program whose deepest call is one frame gives them nowhere.

mod arith;

unconstrained fn factorial(n: u32) -> u32 {
    // Direct recursion. Frame depth is `n + 1`, so calling it with 5 puts six
    // frames of the same function on the stack, each with a different `n` —
    // which is the case that distinguishes a call trace from a source view.
    if n <= 1 {
        1
    } else {
        n * factorial(n - 1)
    }
}

unconstrained fn is_even(n: u32) -> bool {
    // Mutual recursion, the pair. `is_even` and `is_odd` alternate all the way
    // down, so the trace shows two names interleaving rather than one repeating.
    if n == 0 {
        true
    } else {
        is_odd(n - 1)
    }
}

unconstrained fn is_odd(n: u32) -> bool {
    if n == 0 {
        false
    } else {
        is_even(n - 1)
    }
}

unconstrained fn fib(n: u32) -> u32 {
    // Tree recursion: each call makes TWO calls, so the trace branches instead
    // of descending. `fib(6)` is 25 calls — small enough to read, large enough
    // that the shape is a tree and not a line.
    if n < 2 {
        n
    } else {
        fib(n - 1) + fib(n - 2)
    }
}

unconstrained fn checksum(values: [u32; 4]) -> u32 {
    // A frame that calls into another module, so stepping in crosses a file
    // boundary and the source pane has to follow.
    let mut total: u32 = 0;
    for i in 0..4 {
        total = arith::mix(total, values[i]);
    }
    arith::finish(total)
}

unconstrained fn main(n: u32, seed: pub u32) -> pub u32 {
    let f = factorial(5);
    let even = is_even(n);
    let t = fib(6);
    let c = checksum([seed, seed + 1, seed + 2, seed + 3]);

    // `arith::mix` is reached from `checksum` above and directly from here, so
    // the same function has two distinct parents in the call trace.
    let direct = arith::mix(f, t);

    assert(f == 120);
    assert(t == 8);
    assert(even);

    // Both halves are folded into a small range before being added: this
    // program is about the shape of the call tree, and an arithmetic overflow
    // in its last line would end the recording somewhere uninteresting.
    (direct % 1000) + (c % 1000)
}
