// A struct whose methods return a NEW value rather than writing through
// `&mut self`. The binding in `run_counter` is reassigned on every call, so the
// recording holds each intermediate struct and the Values pane shows a nested
// field moving while the binding does not.
//
// Written this way deliberately: the `&mut self` spelling is idiomatic and
// compiles, but the recorder does not currently capture writes made through a
// reference, so a counter written that way would appear never to count.

pub struct Counter {
    pub value: u32,
    pub ticks: u32,
}

impl Counter {
    pub fn new(start: u32) -> Self {
        Counter { value: start, ticks: 0 }
    }

    pub unconstrained fn tick(self) -> Self {
        Counter { value: self.value + 1, ticks: self.ticks + 1 }
    }

    // A method whose body only sometimes changes anything — so between two
    // calls the pane shows a field that moved and a field that did not, and
    // the branch marking says which arm was responsible.
    pub unconstrained fn reset_if_above(self, limit: u32) -> Self {
        if self.value > limit {
            Counter { value: 0, ticks: self.ticks }
        } else {
            Counter { value: self.value, ticks: self.ticks + 100 }
        }
    }
}
