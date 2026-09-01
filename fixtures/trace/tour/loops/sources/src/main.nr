// TOUR: loops and iteration
//
// The subject is the loop rail. Everything here exists so that a reader who
// opens this program sees iterations they can move between one at a time, and
// values that DIFFER from one iteration to the next — a loop whose variables
// never change is a rail with nothing on it.
//
// Three shapes, because the rail has to cope with all three:
//   * a flat `for` with a carried accumulator,
//   * a `for` nested inside a `for`, so an iteration of the outer rail
//     contains a whole inner rail,
//   * a `while` whose bound is computed, so the iteration count is not
//     readable off the source.

mod sieve;

unconstrained fn triangular(n: u32) -> u32 {
    // A flat loop with one carried variable. Iteration i adds i, so the
    // accumulator takes a different value on every rung of the rail and the
    // sequence 0, 0, 1, 3, 6, 10 ... is derivable from the source alone.
    let mut acc: u32 = 0;
    for i in 0..n {
        acc = acc + i;
    }
    acc
}

unconstrained fn grid_sum(rows: u32, cols: u32) -> u32 {
    // Nested loops. The outer rail has `rows` rungs; each one contains an
    // inner rail of `cols` rungs. `row_total` resets at the top of every outer
    // iteration, which is the thing per-iteration navigation makes visible and
    // a single "current value" cannot show.
    let mut total: u32 = 0;
    for r in 0..rows {
        let mut row_total: u32 = 0;
        for c in 0..cols {
            row_total = row_total + (r * cols + c);
        }
        total = total + row_total;
    }
    total
}

unconstrained fn collatz_steps(start: u32) -> u32 {
    // A `while` whose trip count depends on the values, not on the bounds.
    // Reading the source tells you what each step does; only the recording
    // tells you how many there were.
    let mut n = start;
    let mut steps: u32 = 0;
    while n != 1 {
        if n % 2 == 0 {
            n = n / 2;
        } else {
            n = 3 * n + 1;
        }
        steps = steps + 1;
    }
    steps
}

unconstrained fn first_gap(limit: u32) -> u32 {
    // `break` and `continue` in one loop, so the rail has to show iterations
    // that did nothing and an iteration that ended the loop early.
    let mut found: u32 = 0;
    for candidate in 2..limit {
        if candidate % 2 == 0 {
            continue;
        }
        if !sieve::is_prime(candidate) {
            found = candidate;
            break;
        }
    }
    found
}

unconstrained fn main(rows: u32, cols: pub u32) -> pub u32 {
    let t = triangular(6);
    let g = grid_sum(rows, cols);
    let c = collatz_steps(27);
    let f = first_gap(30);
    t + g + c + f
}
