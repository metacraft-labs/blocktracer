// TOUR: program output and the event log
//
// The subject is the event log — the stream of things the execution SAID, as
// distinct from the values it held. In this language that stream is `print`,
// `println` and format strings, and it is the only pane whose content a
// program author writes directly.
//
// The entries are deliberately varied: bare text, a single interpolated value,
// several values in one line, output from inside a loop, and output from a
// nested frame — so the log is a sequence a reader can follow rather than the
// same sentence repeated.

struct Order {
    id: u32,
    qty: u32,
    unit_price: u32,
}

unconstrained fn line_total(o: Order) -> u32 {
    let total = o.qty * o.unit_price;
    // A format string interpolates BINDINGS, not expressions — `{o.qty}` is a
    // compile error in this language, so the fields are bound first. The
    // locals that exist only to be printed are worth seeing: they are what
    // the event log's text is built from.
    let id = o.id;
    let qty = o.qty;
    let price = o.unit_price;
    // Output from a nested frame: this entry is written while the call trace
    // is one frame deeper than the entries around it.
    println(f"  line {id}: {qty} x {price} = {total}");
    total
}

unconstrained fn apply_discount(total: u32, threshold: u32) -> u32 {
    if total >= threshold {
        let discounted = total - (total / 10);
        println(f"  discount applied at threshold {threshold}: {total} -> {discounted}");
        discounted
    } else {
        println(f"  no discount: {total} is below {threshold}");
        total
    }
}

unconstrained fn main(threshold: u32, orders: pub u32) -> pub u32 {
    // A bare string with no interpolation at all.
    println("=== invoice ===");

    let mut running: u32 = 0;

    // Output from inside a loop: one entry per iteration, each carrying the
    // iteration's own values, so the log and the loop rail line up rung for
    // rung.
    for i in 0..orders {
        let line_no = i + 1;
        let o = Order { id: line_no, qty: i + 2, unit_price: 10 + i };
        let t = line_total(o);
        running = running + t;
        println(f"  running total after line {line_no}: {running}");
    }

    // `print` without a newline, then `println` completing the same line —
    // two events that a reader sees as one sentence.
    print("subtotal: ");
    println(running);

    let final_total = apply_discount(running, threshold);

    // Several values interpolated into one entry.
    println(f"orders={orders} threshold={threshold} subtotal={running} total={final_total}");
    println("=== end ===");

    final_total
}
