// A second module, so a step-in crosses a file boundary and the call trace
// shows a frame whose source lives in a document the pane was not already
// displaying.

pub unconstrained fn mix(acc: u32, value: u32) -> u32 {
    let rotated = rotate(acc, 7);
    rotated ^ value
}

pub unconstrained fn finish(acc: u32) -> u32 {
    let folded = rotate(acc, 13);
    folded + 1
}

// The deepest frame in this module, and the only one with a loop in it — so a
// step-out from here has a loop iteration to return into.
unconstrained fn rotate(value: u32, by: u8) -> u32 {
    let mut out = value;
    for _ in 0..by {
        let carry = out & 1;
        out = (out >> 1) | (carry * 0x8000_0000);
    }
    out
}
