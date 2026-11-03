(* calculus.ml
   Efficient numerical calculus in OCaml:
     - dual numbers (forward-mode automatic differentiation): exact derivatives
     - Gauss-Legendre quadrature (7-point, composite)
     - adaptive Simpson integration with reused function evaluations
     - Richardson-extrapolated central differences, O(h^4)
   Build: ocamlopt -O3 calculus.ml -o calculus && ./calculus
*)

(* ---------- Dual numbers ---------- *)

module Dual = struct
  type t = { v : float; d : float }

  let var x = { v = x; d = 1.0 }
  let const x = { v = x; d = 0.0 }
  let value t = t.v
  let deriv t = t.d

  let ( +: ) a b = { v = a.v +. b.v; d = a.d +. b.d }
  let ( -: ) a b = { v = a.v -. b.v; d = a.d -. b.d }
  let ( *: ) a b = { v = a.v *. b.v; d = a.v *. b.d +. a.d *. b.v }
  let ( /: ) a b =
    let inv = 1.0 /. b.v in
    { v = a.v *. inv; d = (a.d -. a.v *. b.d *. inv) *. inv }

  let sin a = { v = Stdlib.sin a.v; d = a.d *. Stdlib.cos a.v }
  let cos a = { v = Stdlib.cos a.v; d = -.a.d *. Stdlib.sin a.v }
  let exp a = let e = Stdlib.exp a.v in { v = e; d = a.d *. e }
  let log a = { v = Stdlib.log a.v; d = a.d /. a.v }
  let sqrt a = let s = Stdlib.sqrt a.v in { v = s; d = a.d /. (2.0 *. s) }
  let pow a n = { v = a.v ** n; d = a.d *. n *. (a.v ** (n -. 1.0)) }
end

(* derivative of f at x; f must be written in Dual arithmetic *)
let diff f x = Dual.deriv (f (Dual.var x))

(* ---------- Gauss-Legendre quadrature (7-point) ---------- *)

let gl7_nodes =
  [| 0.9491079123427585; 0.7415311855993945; 0.4058451513773972; 0.0;
     -0.4058451513773972; -0.7415311855993945; -0.9491079123427585 |]

let gl7_weights =
  [| 0.1294849661688697; 0.2797053914892766; 0.3818300505051189;
     0.4179591836734694; 0.3818300505051189; 0.2797053914892766;
     0.1294849661688697 |]

(* exact for polynomials up to degree 13 on [a,b]; 7 evaluations *)
let gauss_legendre f a b =
  let mid = 0.5 *. (a +. b) and half = 0.5 *. (b -. a) in
  let s = ref 0.0 in
  for i = 0 to 6 do
    s := !s +. gl7_weights.(i) *. f (mid +. half *. gl7_nodes.(i))
  done;
  half *. !s

(* composite: n panels of the 7-point rule *)
let gauss_legendre_composite f a b n_panels =
  let h = (b -. a) /. float_of_int n_panels in
  let s = ref 0.0 in
  for i = 0 to n_panels - 1 do
    let x0 = a +. float_of_int i *. h in
    s := !s +. gauss_legendre f x0 (x0 +. h)
  done;
  !s

(* ---------- Adaptive Simpson ---------- *)

(* Every panel passes its 3 known values (fa, fm, fb) down, so each
   subdivision costs only 2 new evaluations instead of 5. *)
let adaptive_simpson ?(max_depth = 30) f a b tol =
  let fa = f a and fb = f b in
  let m = 0.5 *. (a +. b) in
  let fm = f m in
  let s = (b -. a) /. 6.0 *. (fa +. 4.0 *. fm +. fb) in
  let rec loop a fa m fm b fb s depth =
    let lm = 0.5 *. (a +. m) and rm = 0.5 *. (m +. b) in
    let flm = f lm and frm = f rm in
    let sl = (m -. a) /. 6.0 *. (fa +. 4.0 *. flm +. fm) in
    let sr = (b -. m) /. 6.0 *. (fm +. 4.0 *. frm +. fb) in
    if depth >= max_depth || abs_float (sl +. sr -. s) <= 15.0 *. tol then
      sl +. sr +. (sl +. sr -. s) /. 15.0
    else
      loop a fa lm flm m fm sl (depth + 1)
      +. loop m fm rm frm b fb sr (depth + 1)
  in
  loop a fa m fm b fb s 0

(* ---------- Richardson central difference, O(h^4) ---------- *)

let derivative f x =
  let h = 1e-3 in
  let d1 = (f (x +. h) -. f (x -. h)) /. (2.0 *. h) in
  let d2 = (f (x +. 0.5 *. h) -. f (x -. 0.5 *. h)) /. h in
  (4.0 *. d2 -. d1) /. 3.0

(* ---------- Demo / self-check ---------- *)

let () =
  let pi = 4.0 *. atan 1.0 in

  (* f(x) = x sin x ; f'(1) = sin 1 + cos 1 *)
  let f x = x *. Stdlib.sin x in
  let f_dual x = Dual.(x *: sin x) in
  let exact1 = Stdlib.sin 1.0 +. Stdlib.cos 1.0 in
  Printf.printf "d/dx[x sin x] at 1:  AD=%.12f  Richardson=%.12f  exact=%.12f\n"
    (diff f_dual 1.0) (derivative f 1.0) exact1;

  (* int_0^pi sin x dx = 2 *)
  Printf.printf "int sin [0,pi]:   GL7x10=%.12f  adaptive=%.12f  exact=2.000000000000\n"
    (gauss_legendre_composite Stdlib.sin 0.0 pi 10)
    (adaptive_simpson Stdlib.sin 0.0 pi 1e-12);

  (* int_0^2 x e^x dx = e^2 + 1 *)
  let g x = x *. Stdlib.exp x in
  Printf.printf "int x e^x [0,2]:  adaptive=%.12f  exact=%.12f\n"
    (adaptive_simpson g 0.0 2.0 1e-12) (Stdlib.exp 2.0 +. 1.0);

  (* d/dx[e^x sin x] at 1 = e (sin 1 + cos 1) *)
  let h_dual x = Dual.(exp x *: sin x) in
  let exact2 = Stdlib.exp 1.0 *. (Stdlib.sin 1.0 +. Stdlib.cos 1.0) in
  Printf.printf "d/dx[e^x sin x] at 1: AD=%.12f  exact=%.12f\n"
    (diff h_dual 1.0) exact2
