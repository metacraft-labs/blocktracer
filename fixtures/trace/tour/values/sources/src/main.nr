// TOUR: types and values
//
// Every value kind this language has, brought into scope one line at a time so
// the state pane has something of each to render. Nothing here computes
// anything interesting on purpose — the subject IS the values, and a reader
// stepping through should be able to name the type of every row they see.

struct Vec2 {
    x: Field,
    y: Field,
}

struct Body {
    label: str<6>,
    position: Vec2,
    mass: u32,
    alive: bool,
}

fn main(seed: Field, scale: pub u32) -> pub Field {
    // ── the field element, this language's native scalar ──────────────────
    let field_value: Field = seed + 17;

    // ── unsigned integers, four widths ────────────────────────────────────
    let small: u8 = 200;
    let medium: u16 = 40_000;
    let wide: u32 = scale;
    let widest: u64 = 9_000_000_000;

    // ── signed integers, which print with a sign and wrap differently ─────
    let negative: i8 = -42;
    let signed_wide: i32 = -100_000;

    // ── the boolean, and a string of fixed length ─────────────────────────
    let flag: bool = small > 100;
    let name: str<6> = "cosmos";

    // ── a fixed-size array, indexed and read back ─────────────────────────
    let weights: [u32; 4] = [3, 1, 4, 1];
    let third = weights[2];

    // ── a tuple, which the state pane renders positionally ────────────────
    let pair: (Field, bool) = (field_value, flag);

    // ── a struct, and a struct nested inside another struct ───────────────
    let origin = Vec2 { x: 0, y: 0 };
    let body = Body { label: name, position: Vec2 { x: 3, y: 4 }, mass: wide, alive: flag };

    // ── a vector, whose length grows at run time rather than being fixed
    //    by the type the way `weights` above is ─────────────────────────────
    let mut trail: [Field] = [body.position.x].as_vector();
    trail = trail.push_back(body.position.y);
    trail = trail.push_back(origin.x);

    // ── a value read back out of each compound, so the step that reads it
    //    has a scalar to show next to the compound it came from ────────────
    let from_array = weights[0] + third;
    let from_tuple = pair.1;
    let from_struct = body.position.y;
    let from_slice = trail[1];

    assert(from_array == 7);
    assert(from_tuple == flag);

    // Signed values reach `Field` only through an unsigned width — the
    // language refuses the direct cast, which is itself worth seeing written
    // down once.
    let signed_gap: i32 = negative as i32 - signed_wide;
    let signed_gap_u: u32 = signed_gap as u32;

    let total = field_value
        + from_struct
        + from_slice
        + medium as Field
        + widest as Field
        + signed_gap_u as Field;

    total
}
