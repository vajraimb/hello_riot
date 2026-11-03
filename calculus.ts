// calculus.ts
// Efficient numerical calculus in TypeScript:
//   - dual numbers (forward-mode automatic differentiation): exact derivatives
//   - Gauss-Legendre quadrature (7-point, composite)
//   - adaptive Simpson integration with reused function evaluations
//   - Richardson-extrapolated central differences, O(h^4)
// Run: deno run calculus.ts | bun calculus.ts | node calculus.ts (Node >= 23, or --experimental-strip-types on 22.6+)

// ---------- Dual numbers ----------

type Dual = { v: number; d: number };

const var_ = (x: number): Dual => ({ v: x, d: 1 });
const c = (x: number): Dual => ({ v: x, d: 0 });

const add = (a: Dual, b: Dual): Dual => ({ v: a.v + b.v, d: a.d + b.d });
const sub = (a: Dual, b: Dual): Dual => ({ v: a.v - b.v, d: a.d - b.d });
const mul = (a: Dual, b: Dual): Dual => ({ v: a.v * b.v, d: a.v * b.d + a.d * b.v });
const div = (a: Dual, b: Dual): Dual => {
  const inv = 1 / b.v;
  return { v: a.v * inv, d: (a.d - a.v * b.d * inv) * inv };
};

const dsin = (a: Dual): Dual => ({ v: Math.sin(a.v), d: a.d * Math.cos(a.v) });
const dcos = (a: Dual): Dual => ({ v: Math.cos(a.v), d: -a.d * Math.sin(a.v) });
const dexp = (a: Dual): Dual => { const e = Math.exp(a.v); return { v: e, d: a.d * e }; };
const dlog = (a: Dual): Dual => ({ v: Math.log(a.v), d: a.d / a.v });
const dsqrt = (a: Dual): Dual => { const s = Math.sqrt(a.v); return { v: s, d: a.d / (2 * s) }; };
const dpow = (a: Dual, n: number): Dual => ({ v: a.v ** n, d: a.d * n * a.v ** (n - 1) });

const diff = (f: (x: Dual) => Dual, x: number): number => f(var_(x)).d;

// ---------- Gauss-Legendre quadrature (7-point) ----------

const GL7_X = [0.9491079123427585, 0.7415311855993945, 0.4058451513773972, 0, -0.4058451513773972, -0.7415311855993945, -0.9491079123427585];
const GL7_W = [0.1294849661688697, 0.2797053914892766, 0.3818300505051189, 0.4179591836734694, 0.3818300505051189, 0.2797053914892766, 0.1294849661688697];

// exact for polynomials up to degree 13 on [a,b]; 7 evaluations
function gaussLegendre(f: (x: number) => number, a: number, b: number): number {
  const mid = 0.5 * (a + b), half = 0.5 * (b - a);
  let s = 0;
  for (let i = 0; i < 7; i++) s += GL7_W[i] * f(mid + half * GL7_X[i]);
  return half * s;
}

function gaussLegendreComposite(f: (x: number) => number, a: number, b: number, n: number): number {
  const h = (b - a) / n;
  let s = 0;
  for (let i = 0; i < n; i++) {
    const x0 = a + i * h;
    s += gaussLegendre(f, x0, x0 + h);
  }
  return s;
}

// ---------- Adaptive Simpson ----------

// Each panel carries its 3 known values (fa, fm, fb), so a subdivision
// costs 2 new evaluations instead of 5.
type Panel = [a: number, fa: number, m: number, fm: number, b: number, fb: number, s: number, depth: number];

function adaptiveSimpson(f: (x: number) => number, a: number, b: number, tol: number): number {
  const fa = f(a), fb = f(b);
  const m = 0.5 * (a + b), fm = f(m);
  const s = ((b - a) / 6) * (fa + 4 * fm + fb);
  const stack: Panel[] = [[a, fa, m, fm, b, fb, s, 0]];
  let total = 0;
  while (stack.length > 0) {
    const [a2, fa2, m2, fm2, b2, fb2, s2, depth] = stack.pop()!;
    const lm = 0.5 * (a2 + m2), rm = 0.5 * (m2 + b2);
    const flm = f(lm), frm = f(rm);
    const sl = ((m2 - a2) / 6) * (fa2 + 4 * flm + fm2);
    const sr = ((b2 - m2) / 6) * (fm2 + 4 * frm + fb2);
    if (depth >= 30 || Math.abs(sl + sr - s2) <= 15 * tol) {
      total += sl + sr + (sl + sr - s2) / 15;
    } else {
      stack.push([a2, fa2, lm, flm, m2, fm2, sl, depth + 1]);
      stack.push([m2, fm2, rm, frm, b2, fb2, sr, depth + 1]);
    }
  }
  return total;
}

// ---------- Richardson central difference, O(h^4) ----------

function derivative(f: (x: number) => number, x: number): number {
  const h = 1e-3;
  const d1 = (f(x + h) - f(x - h)) / (2 * h);
  const d2 = (f(x + h / 2) - f(x - h / 2)) / h;
  return (4 * d2 - d1) / 3;
}

// ---------- Demo / self-check ----------

const pi = Math.PI;

// f(x) = x sin x ; f'(1) = sin 1 + cos 1
const f = (x: Dual) => mul(x, dsin(x));
const exact1 = Math.sin(1) + Math.cos(1);
console.log(`d/dx[x sin x] at 1:  AD=${diff(f, 1).toFixed(12)}  Richardson=${derivative((x) => x * Math.sin(x), 1).toFixed(12)}  exact=${exact1.toFixed(12)}`);

// int_0^pi sin x dx = 2
console.log(`int sin [0,pi]:   GL7x10=${gaussLegendreComposite(Math.sin, 0, pi, 10).toFixed(12)}  adaptive=${adaptiveSimpson(Math.sin, 0, pi, 1e-12).toFixed(12)}  exact=2.000000000000`);

// int_0^2 x e^x dx = e^2 + 1
const g = (x: number) => x * Math.exp(x);
console.log(`int x e^x [0,2]:  adaptive=${adaptiveSimpson(g, 0, 2, 1e-12).toFixed(12)}  exact=${(Math.exp(2) + 1).toFixed(12)}`);

// d/dx[e^x sin x] at 1 = e (sin 1 + cos 1)
const h2 = (x: Dual) => mul(dexp(x), dsin(x));
const exact2 = Math.E * (Math.sin(1) + Math.cos(1));
console.log(`d/dx[e^x sin x] at 1: AD=${diff(h2, 1).toFixed(12)}  exact=${exact2.toFixed(12)}`);
