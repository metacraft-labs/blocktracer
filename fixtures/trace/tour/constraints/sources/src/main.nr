// TOUR: constraints, and an execution that fails one
//
// The subject is what a recording looks like when the program does NOT finish.
// This is the case a zero-knowledge debugger exists for: a constraint did not
// hold, and the question is which one, on which values, reached from where.
//
// The recording therefore ENDS at the failing assertion. Everything before it
// is ordinary stepping; the last thing in the event log is the assertion's own
// message. A tour that only ever showed successful executions would leave the
// most useful thing this product does undemonstrated.
//
// Assertions that HOLD come first and are stepped over normally, so the
// contrast between "checked and passed" and "checked and stopped" is visible
// inside one recording.

mod ledger;

use ledger::Account;

unconstrained fn transfer(from: Account, to: Account, amount: u64) -> (Account, Account) {
    // These three hold for every call below, so a reader sees an assertion
    // being satisfied and stepped past before they see one that is not.
    assert(amount > 0, "transfer amount must be positive");
    assert(from.id != to.id, "cannot transfer to the same account");
    assert(from.balance >= amount, "insufficient balance");

    let debited = Account { id: from.id, balance: from.balance - amount };
    let credited = Account { id: to.id, balance: to.balance + amount };

    // The invariant that makes this a ledger: no value is created or destroyed.
    let before = from.balance + to.balance;
    let after = debited.balance + credited.balance;
    assert(before == after, "transfer must conserve the total balance");

    (debited, credited)
}

unconstrained fn main(opening: u64, transfer_amount: pub u64) -> pub u64 {
    let alice = Account { id: 1, balance: opening };
    let bob = Account { id: 2, balance: 50 };

    // A format string interpolates bindings, not field accesses, so each
    // balance is bound before it is printed.
    let a0 = alice.balance;
    let b0 = bob.balance;
    println(f"opening: alice={a0} bob={b0}");

    // Two transfers that succeed. Every assertion in `transfer` is evaluated
    // and holds, twice.
    let (alice2, bob2) = transfer(alice, bob, transfer_amount);
    let a1 = alice2.balance;
    let b1 = bob2.balance;
    println(f"after 1: alice={a1} bob={b1}");

    let (bob3, alice3) = transfer(bob2, alice2, 10);
    let a2 = alice3.balance;
    let b2 = bob3.balance;
    println(f"after 2: alice={a2} bob={b2}");

    let total = alice3.balance + bob3.balance;
    assert(total == opening + 50, "the ledger total is unchanged by transfers");

    // ── the failing constraint ────────────────────────────────────────────
    //
    // `ledger::solvency_margin` returns the amount by which the accounts
    // exceed the reserve floor. The floor is set higher than the accounts can
    // possibly hold, so this assertion CANNOT hold — it is not a bug that
    // happens to be here, it is the subject of this program.
    //
    // The recording stops on the next line. Its last event log entry is this
    // message, and the position where the session ends is this assertion's.
    let margin = ledger::solvency_margin(alice3, bob3, 1_000_000);
    assert(margin > 0, "accounts must clear the reserve floor");

    total
}
