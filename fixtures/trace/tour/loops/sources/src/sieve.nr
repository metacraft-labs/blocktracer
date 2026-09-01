// A second file, so the source pane has more than one document to switch
// between and the call trace crosses a module boundary.

pub unconstrained fn is_prime(n: u32) -> bool {
    if n < 2 {
        false
    } else {
        let mut prime = true;
        let mut d: u32 = 2;
        while d * d <= n {
            if n % d == 0 {
                prime = false;
            }
            d = d + 1;
        }
        prime
    }
}
