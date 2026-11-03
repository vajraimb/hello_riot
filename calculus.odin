// calculus.odin
// Efficient numerical calculus in Odin:
//   - dual numbers (forward-mode automatic differentiation): exact derivatives
//   - Gauss-Legendre quadrature (7-point, composite)
//   - adaptive Simpson integration with reused function evaluations
//   - Richardson-extrapolated central differences, O(h^4)
// Run: odin run calculus.odin -file -o:speed

package main

import "core:fmt"
import "core:math"

// ---------- Dual numbers ----------

Dual :: struct {
	v: f64,
	d: f64,
}

dual_var   :: #force_inline proc(x: f64) -> Dual { return Dual{x, 1} }
dual_const :: #force_inline proc(x: f64) -> Dual { return Dual{x, 0} }
dual_add   :: #force_inline proc(a, b: Dual) -> Dual { return Dual{a.v + b.v, a.d + b.d} }
dual_sub   :: #force_inline proc(a, b: Dual) -> Dual { return Dual{a.v - b.v, a.d - b.d} }
dual_mul   :: #force_inline proc(a, b: Dual) -> Dual { return Dual{a.v*b.v, a.v*b.d + a.d*b.v} }
dual_div   :: #force_inline proc(a, b: Dual) -> Dual {
	inv := 1.0 / b.v
	return Dual{a.v*inv, (a.d - a.v*b.d*inv)*inv}
}
dual_sin   :: #force_inline proc(a: Dual) -> Dual { return Dual{math.sin(a.v), a.d*math.cos(a.v)} }
dual_cos   :: #force_inline proc(a: Dual) -> Dual { return Dual{math.cos(a.v), -a.d*math.sin(a.v)} }
dual_exp   :: #force_inline proc(a: Dual) -> Dual { e := math.exp(a.v); return Dual{e, a.d*e} }
dual_log   :: #force_inline proc(a: Dual) -> Dual { return Dual{math.log(a.v), a.d/a.v} }
dual_sqrt  :: #force_inline proc(a: Dual) -> Dual { s := math.sqrt(a.v); return Dual{s, a.d/(2*s)} }
dual_pow   :: #force_inline proc(a: Dual, n: f64) -> Dual { return Dual{math.pow(a.v, n), a.d*n*math.pow(a.v, n-1)} }

diff :: proc(f: proc(Dual) -> Dual, x: f64) -> f64 {
	return f(dual_var(x)).d
}

// ---------- Gauss-Legendre quadrature (7-point) ----------

GL7_X := [7]f64{0.9491079123427585, 0.7415311855993945, 0.4058451513773972, 0.0, -0.4058451513773972, -0.7415311855993945, -0.9491079123427585}
GL7_W := [7]f64{0.1294849661688697, 0.2797053914892766, 0.3818300505051189, 0.4179591836734694, 0.3818300505051189, 0.2797053914892766, 0.1294849661688697}

// exact for polynomials up to degree 13 on [a,b]; 7 evaluations
gauss_legendre :: proc(f: proc(f64) -> f64, a, b: f64) -> f64 {
	mid := 0.5 * (a + b)
	half := 0.5 * (b - a)
	s := 0.0
	for i in 0..<7 {
		s += GL7_W[i] * f(mid + half*GL7_X[i])
	}
	return half * s
}

gauss_legendre_composite :: proc(f: proc(f64) -> f64, a, b: f64, n: int) -> f64 {
	h := (b - a) / f64(n)
	s := 0.0
	for i in 0..<n {
		x0 := a + f64(i)*h
		s += gauss_legendre(f, x0, x0 + h)
	}
	return s
}

// ---------- Adaptive Simpson ----------

Panel :: struct {
	a, fa, m, fm, b, fb, s: f64,
	depth: int,
}

// Each panel carries its 3 known values (fa, fm, fb), so a subdivision
// costs 2 new evaluations instead of 5.
adaptive_simpson :: proc(f: proc(f64) -> f64, a, b, tol: f64) -> f64 {
	fa := f(a)
	fb := f(b)
	m := 0.5 * (a + b)
	fm := f(m)
	s := (b - a) / 6.0 * (fa + 4.0*fm + fb)

	stack: [dynamic]Panel
	defer delete(stack)
	append(&stack, Panel{a, fa, m, fm, b, fb, s, 0})

	total := 0.0
	for len(stack) > 0 {
		p := pop(&stack)
		lm := 0.5 * (p.a + p.m)
		rm := 0.5 * (p.m + p.b)
		flm := f(lm)
		frm := f(rm)
		sl := (p.m - p.a) / 6.0 * (p.fa + 4.0*flm + p.fm)
		sr := (p.b - p.m) / 6.0 * (p.fm + 4.0*frm + p.fb)
		if p.depth >= 30 || math.abs(sl + sr - p.s) <= 15.0*tol {
			total += sl + sr + (sl + sr - p.s) / 15.0
		} else {
			append(&stack, Panel{p.a, p.fa, lm, flm, p.m, p.fm, sl, p.depth + 1})
			append(&stack, Panel{p.m, p.fm, rm, frm, p.b, p.fb, sr, p.depth + 1})
		}
	}
	return total
}

// ---------- Richardson central difference, O(h^4) ----------

derivative :: proc(f: proc(f64) -> f64, x: f64) -> f64 {
	h := 1e-3
	d1 := (f(x + h) - f(x - h)) / (2.0 * h)
	d2 := (f(x + h/2) - f(x - h/2)) / h
	return (4.0*d2 - d1) / 3.0
}

// ---------- Demo / self-check ----------

main :: proc() {
	pi := math.PI

	// f(x) = x sin x ; f'(1) = sin 1 + cos 1
	f := proc(x: Dual) -> Dual { return dual_mul(x, dual_sin(x)) }
	g1 := proc(x: f64) -> f64 { return x * math.sin(x) }
	exact1 := math.sin(1.0) + math.cos(1.0)
	fmt.printf("d/dx[x sin x] at 1:  AD=%.12f  Richardson=%.12f  exact=%.12f\n",
		diff(f, 1.0), derivative(g1, 1.0), exact1)

	// int_0^pi sin x dx = 2
	fmt.printf("int sin [0,pi]:   GL7x10=%.12f  adaptive=%.12f  exact=2.000000000000\n",
		gauss_legendre_composite(math.sin, 0.0, pi, 10),
		adaptive_simpson(math.sin, 0.0, pi, 1e-12))

	// int_0^2 x e^x dx = e^2 + 1
	g2 := proc(x: f64) -> f64 { return x * math.exp(x) }
	fmt.printf("int x e^x [0,2]:  adaptive=%.12f  exact=%.12f\n",
		adaptive_simpson(g2, 0.0, 2.0, 1e-12), math.exp(2.0) + 1.0)

	// d/dx[e^x sin x] at 1 = e (sin 1 + cos 1)
	h := proc(x: Dual) -> Dual { return dual_mul(dual_exp(x), dual_sin(x)) }
	exact2 := math.E * (math.sin(1.0) + math.cos(1.0))
	fmt.printf("d/dx[e^x sin x] at 1: AD=%.12f  exact=%.12f\n", diff(h, 1.0), exact2)
}
