// A small value object with an immutable-reference method, so the tour has a
// `&T` beside its `&mut T` — the two are different forms and only one of them
// is affected by the recorder gap NR-04.

pub struct Bounds {
    pub low: u32,
    pub high: u32,
}

impl Bounds {
    pub fn new(low: u32, high: u32) -> Self {
        Bounds { low, high }
    }

    // Takes `self` by IMMUTABLE reference and returns a new value. Reading
    // through `&self` is recorded correctly; it is only writing through a
    // reference that is not (NR-04).
    pub unconstrained fn span(self: &Self) -> u32 {
        (*self).high - (*self).low
    }

    pub unconstrained fn widen(self, by: u32) -> Self {
        let grown = Bounds { low: self.low, high: self.high + by };
        assert(grown.span_by_value() >= self.span_by_value());
        grown
    }

    pub unconstrained fn span_by_value(self) -> u32 {
        self.high - self.low
    }
}
