(* ============================================================
 * 用 OCaml 解释牛顿三大定律
 * 编译运行: ocamlopt -o newton newtons_laws.ml && ./newton
 * ============================================================ *)

(* ---------- 数学基础:二维向量(位置、速度、力都是向量) ---------- *)
type vec = { x : float; y : float }

let vec x y = { x; y }
let add a b = vec (a.x +. b.x) (a.y +. b.y)
let sub a b = vec (a.x -. b.x) (a.y -. b.y)
let scale k a = vec (k *. a.x) (k *. a.y)
let neg a = scale (-1.) a
let to_string a = Printf.sprintf "(%.3f, %.3f)" a.x a.y

(* ---------- 质点:有质量、位置、速度的物体 ---------- *)
type body = { name : string; mass : float; pos : vec; vel : vec }

let show b =
  Printf.printf "    %-8s 位置 %s  速度 %s\n" b.name (to_string b.pos) (to_string b.vel)

(* ============================================================
 * 牛顿第一定律(惯性定律):
 *   合外力为零 ⇒ 速度不变;静止的保持静止,匀速的保持匀速。
 * 代码体现:时间推进时只改位置,速度字段原样保留。
 * ============================================================ *)
let step_inertia dt b = { b with pos = add b.pos (scale dt b.vel) }

let demo_first_law () =
  Printf.printf "\n【第一定律】合外力 = 0 ⇒ 速度不变\n";
  let at_rest = ref { name = "静止的箱子"; mass = 1.; pos = vec 0. 0.; vel = vec 0. 0. } in
  let sliding = ref { name = "匀速的冰壶"; mass = 1.; pos = vec 0. 0.; vel = vec 5. 0. } in
  for i = 1 to 3 do
    at_rest := step_inertia 1. !at_rest;
    sliding := step_inertia 1. !sliding;
    Printf.printf "  第 %d 秒末:\n" i;
    show !at_rest; show !sliding
  done;
  Printf.printf "  结论:速度始终是 (0,0) 和 (5,0)——没有力,就没有速度变化。\n"

(* ============================================================
 * 牛顿第二定律: F = m·a ⇔ a = F/m
 * 代码体现:加速度 = 力 ÷ 质量;同一个力,质量越大加速度越小。
 * ============================================================ *)
let acceleration b f = scale (1. /. b.mass) f

let step_force dt b f =
  let a = acceleration b f in
  { b with vel = add b.vel (scale dt a);
           pos = add b.pos (scale dt b.vel) }

let demo_second_law () =
  Printf.printf "\n【第二定律】F = m·a ⇔ a = F/m\n";
  let f = vec 10. 0. in
  let light = { name = "1 kg 球"; mass = 1.; pos = vec 0. 0.; vel = vec 0. 0. } in
  let heavy = { name = "10 kg 箱"; mass = 10.; pos = vec 0. 0.; vel = vec 0. 0. } in
  Printf.printf "  同样的力 F = %s 作用在初速为 0 的物体上:\n" (to_string f);
  Printf.printf "    %s: a = %s\n" light.name (to_string (acceleration light f));
  Printf.printf "    %s: a = %s\n" heavy.name (to_string (acceleration heavy f));
  let light2 = step_force 2. light f in
  let heavy2 = step_force 2. heavy f in
  Printf.printf "  推 2 秒后的速度: %s → %s,  %s → %s\n"
    light.name (to_string light2.vel) heavy.name (to_string heavy2.vel);
  Printf.printf "  结论:质量在分母上,质量越大越难推动。\n"

(* ============================================================
 * 牛顿第三定律: 作用力与反作用力,大小相等、方向相反。
 *   万有引力 F = G·m1·m2/r² 作为例子(内力天然成对)。
 * 代码体现:算出 a 受到的力,直接把相反数给 b。
 * ============================================================ *)
let gravity g a b =
  (* 返回 b 对 a 的引力(方向从 a 指向 b) *)
  let d = sub b.pos a.pos in
  let r2 = d.x *. d.x +. d.y *. d.y in
  let r = sqrt r2 in
  if r < 1e-6 then vec 0. 0.
  else scale (g *. a.mass *. b.mass /. r2 /. r) d

let step_pair dt g a b =
  let f_on_a = gravity g a b in
  (step_force dt a f_on_a, step_force dt b (neg f_on_a))  (* 第三定律 *)

let momentum b = scale b.mass b.vel

let demo_third_law () =
  Printf.printf "\n【第三定律】作用力 = −反作用力\n";
  let g = 1.0 in
  let sun = ref { name = "太阳"; mass = 100.; pos = vec 0. 0.; vel = vec 0. 0. } in
  let planet = ref { name = "行星"; mass = 1.; pos = vec 10. 0.; vel = vec 0. 1. } in
  let f_on_planet = gravity g !planet !sun in   (* 太阳对行星的引力 *)
  Printf.printf "  太阳对行星的引力 = %s\n" (to_string f_on_planet);
  Printf.printf "  行星对太阳的引力 = %s  (等大反向)\n" (to_string (neg f_on_planet));
  let p0 = add (momentum !sun) (momentum !planet) in
  for _ = 1 to 50 do
    let s', p' = step_pair 0.1 g !sun !planet in
    sun := s'; planet := p'
  done;
  let p1 = add (momentum !sun) (momentum !planet) in
  Printf.printf "  模拟 50 步后:\n";
  show !sun; show !planet;
  Printf.printf "    初始总动量 = %s\n" (to_string p0);
  Printf.printf "    50 步后    = %s\n" (to_string p1);
  Printf.printf "  结论:内力成对抵消,系统总动量守恒。\n"

let () =
  demo_first_law ();
  demo_second_law ();
  demo_third_law ();
  let b = { name = "x"; mass = 2.; pos = vec 1. 2.; vel = vec 3. 4. } in
  Printf.printf "\n【注】第一定律其实是第二定律在 F=0 时的特例: %b\n"
    (step_inertia 0.1 b = step_force 0.1 b (vec 0. 0.))
