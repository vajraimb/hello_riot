open Std

module Atacama = Atacama
module Trail = Trail
module Nomad = Nomad
module Aegis_otp = Aegis_otp

(** Return the starter greeting for hello_riot. *)
let hello = fun () -> "Hello from hello_riot"

(** Return the nth Fibonacci number (0-indexed, tail-recursive).
    Raises [Invalid_argument] for negative [n]. *)
let fib n =
  if n < 0 then Std.panic "fib: n must be >= 0";
  let rec go a b = function
    | 0 -> a
    | k -> go b (a + b) (k - 1)
  in
  go 0 1 n

(** Return the first [n] Fibonacci numbers (0-indexed, tail-recursive).
    Raises [Invalid_argument] for negative [n]. *)
let fib_list n =
  if n < 0 then Std.panic "fib_list: n must be >= 0";
  let rec go acc a b = function
    | 0 -> List.rev acc
    | k -> go (a :: acc) b (a + b) (k - 1)
  in
  go [] 0 1 n
