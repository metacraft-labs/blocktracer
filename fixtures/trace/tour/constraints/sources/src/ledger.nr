// The module holding the account type and the solvency check whose constraint
// the recording ends on.

pub struct Account {
    pub id: u32,
    pub balance: u64,
}

// Returns the amount by which the two accounts together exceed `floor`.
//
// `main` calls this with a floor no pair of accounts in that program can reach,
// so the assertion on its result is unsatisfiable BY CONSTRUCTION. That is the
// point: a reader who steps into this frame can see the two balances and the
// floor side by side, and work out for themselves why the next line stops the
// execution — rather than being told.
pub unconstrained fn solvency_margin(a: Account, b: Account, floor: u64) -> u64 {
    let combined = a.balance + b.balance;
    if combined > floor {
        combined - floor
    } else {
        0
    }
}
