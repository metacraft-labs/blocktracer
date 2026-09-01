// A trait with two implementations, in a module of its own so that stepping
// into a trait method crosses a file boundary and the call trace has to name
// which impl it entered — the thing a source view alone cannot tell you.

pub trait Shape {
    fn area(self) -> u32;

    // A DEFAULT method: `Circle` takes it as written and `Rect` overrides it,
    // so the same call spelling reaches two different bodies and the trace is
    // what distinguishes them.
    fn perimeter(self) -> u32 {
        self.area() * 2
    }
}

pub struct Circle {
    pub radius: u32,
}

pub struct Rect {
    pub w: u32,
    pub h: u32,
}

impl Shape for Circle {
    fn area(self) -> u32 {
        // 3 is a deliberately crude pi: this program is about dispatch, and a
        // value a reader can verify in their head is worth more here than a
        // correct one they cannot.
        3 * self.radius * self.radius
    }
    // `perimeter` is NOT overridden — the default body runs.
}

impl Shape for Rect {
    fn area(self) -> u32 {
        self.w * self.h
    }

    fn perimeter(self) -> u32 {
        2 * (self.w + self.h)
    }
}
