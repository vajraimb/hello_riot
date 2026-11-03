// calculus.rs
// Efficient numerical calculus in Rust:
//   - dual numbers (forward-mode automatic differentiation): exact derivatives
//   - Gauss-Legendre quadrature (7-point, composite)
//   - adaptive Simpson integration with reused function evaluations
//   - Richardson-extrapolated central differences, O(h^4)
// Build: rustc -O calculus.rs -o calculus && ./calculus

#![allow(dead_code)]

use std::ops::{Add, Div, Mul, Sub};

// ---------- Dual numbers ----------

#[derive(Clone, Copy)]
struct Dual {
    v: f64,
    d: f64,
}

#[inline]
fn var(x: f64) -> Dual {
    Dual { v: x, d: 1.0 }
}
#[inline]
fn c(x: f64) -> Dual {
    Dual { v: x, d: 0.0 }
}

impl Dual {
    #[inline] fn sin(self) -> Dual { Dual { v: self.v.sin(), d: self.d * self.v.cos() } }
    #[inline] fn cos(self) -> Dual { Dual { v: self.v.cos(), d: -self.d * self.v.sin() } }
    #[inline] fn exp(self) -> Dual { let e = self.v.exp(); Dual { v: e, d: self.d * e } }
    #[inline] fn ln(self) -> Dual { Dual { v: self.v.ln(), d: self.d / self.v } }
    #[inline] fn sqrt(self) -> Dual { let s = self.v.sqrt(); Dual { v: s, d: self.d / (2.0 * s) } }
    #[inline] fn powf(self, n: f64) -> Dual { Dual { v: self.v.powf(n), d: self.d * n * self.v.powf(n - 1.0) } }
}

impl Add for Dual {
    type Output = Dual;
    #[inline] fn add(self, o: Dual) -> Dual { Dual { v: self.v + o.v, d: self.d + o.d } }
}
impl Sub for Dual {
    type Output = Dual;
    #[inline] fn sub(self, o: Dual) -> Dual { Dual { v: self.v - o.v, d: self.d - o.d } }
}
impl Mul for Dual {
    type Output = Dual;
    #[inline] fn mul(self, o: Dual) -> Dual { Dual { v: self.v * o.v, d: self.v * o.d + self.d * o.v } }
}
impl Div for Dual {
    type Output = Dual;
    #[inline] fn div(self, o: Dual) -> Dual {
        let inv = 1.0 / o.v;
        Dual { v: self.v * inv, d: (self.d - self.v * o.d * inv) * inv }
    }
}

fn diff(f: impl Fn(Dual) -> Dual, x: f64) -> f64 {
    f(var(x)).d
}

// ---------- Gauss-Legendre quadrature (7-point) ----------

const GL7_X: [f64; 7] = [
    0.9491079123427585,
    0.7415311855993945,
    0.4058451513773972,
    0.0,
    -0.4058451513773972,
    -0.7415311855993945,
    -0.9491079123427585,
];
const GL7_W: [f64; 7] = [
    0.1294849661688697,
    0.2797053914892766,
    0.3818300505051189,
    0.4179591836734694,
    0.3818300505051189,
    0.2797053914892766,
    0.1294849661688697,
];

// exact for polynomials up to degree 13 on [a,b]; 7 evaluations
fn gauss_legendre(f: impl Fn(f64) -> f64, a: f64, b: f64) -> f64 {
    let mid = 0.5 * (a + b);
    let half = 0.5 * (b - a);
    let mut s = 0.0;
    for i in 0..7 {
        s += GL7_W[i] * f(mid + half * GL7_X[i]);
    }
    half * s
}

fn gauss_legendre_composite(f: impl Fn(f64) -> f64, a: f64, b: f64, n: usize) -> f64 {
    let h = (b - a) / n as f64;
    (0..n)
        .map(|i| {
            let x0 = a + i as f64 * h;
            gauss_legendre(&f, x0, x0 + h)
        })
        .sum()
}

// ---------- Adaptive Simpson ----------

// a, fa, m, fm, b, fb, s, depth
type Panel = (f64, f64, f64, f64, f64, f64, f64, u32);

// Each panel carries its 3 known values (fa, fm, fb), so a subdivision
// costs 2 new evaluations instead of 5.
fn adaptive_simpson(f: impl Fn(f64) -> f64, a: f64, b: f64, tol: f64) -> f64 {
    let (fa, fb) = (f(a), f(b));
    let m = 0.5 * (a + b);
    let fm = f(m);
    let s = (b - a) / 6.0 * (fa + 4.0 * fm + fb);

    let mut stack: Vec<Panel> = Vec::with_capacity(64);
    stack.push((a, fa, m, fm, b, fb, s, 0));
    let mut total = 0.0;
    while let Some((a, fa, m, fm, b, fb, s, depth)) = stack.pop() {
        let lm = 0.5 * (a + m);
        let rm = 0.5 * (m + b);
        let flm = f(lm);
        let frm = f(rm);
        let sl = (m - a) / 6.0 * (fa + 4.0 * flm + fm);
        let sr = (b - m) / 6.0 * (fm + 4.0 * frm + fb);
        if depth >= 30 || (sl + sr - s).abs() <= 15.0 * tol {
            total += sl + sr + (sl + sr - s) / 15.0;
        } else {
            stack.push((a, fa, lm, flm, m, fm, sl, depth + 1));
            stack.push((m, fm, rm, frm, b, fb, sr, depth + 1));
        }
    }
    total
}

// ---------- Richardson central difference, O(h^4) ----------

fn derivative(f: impl Fn(f64) -> f64, x: f64) -> f64 {
    let h = 1e-3;
    let d1 = (f(x + h) - f(x - h)) / (2.0 * h);
    let d2 = (f(x + 0.5 * h) - f(x - 0.5 * h)) / h;
    (4.0 * d2 - d1) / 3.0
}

// ---------- Demo / self-check ----------

fn main() {
    use std::f64::consts::{E, PI};

    // f(x) = x sin x ; f'(1) = sin 1 + cos 1
    let f = |x: Dual| x * x.sin();
    let exact1 = 1.0_f64.sin() + 1.0_f64.cos();
    println!(
        "d/dx[x sin x] at 1:  AD={:.12}  Richardson={:.12}  exact={:.12}",
        diff(f, 1.0),
        derivative(|x| x * x.sin(), 1.0),
        exact1
    );

    // int_0^pi sin x dx = 2
    println!(
        "int sin [0,pi]:   GL7x10={:.12}  adaptive={:.12}  exact=2.000000000000",
        gauss_legendre_composite(f64::sin, 0.0, PI, 10),
        adaptive_simpson(f64::sin, 0.0, PI, 1e-12)
    );

    // int_0^2 x e^x dx = e^2 + 1
    let g = |x: f64| x * x.exp();
    println!(
        "int x e^x [0,2]:  adaptive={:.12}  exact={:.12}",
        adaptive_simpson(g, 0.0, 2.0, 1e-12),
        2.0_f64.exp() + 1.0
    );

    // d/dx[e^x sin x] at 1 = e (sin 1 + cos 1)
    let h = |x: Dual| x.exp() * x.sin();
    let exact2 = E * (1.0_f64.sin() + 1.0_f64.cos());
    println!(
        "d/dx[e^x sin x] at 1: AD={:.12}  exact={:.12}",
        diff(h, 1.0),
        exact2
    );
}
