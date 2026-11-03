open Std

(** Seamless-handoff splice: deduplicates a continuation stream against the
    text already delivered to the client.

    When a model dies mid-stream we restart on a fallback account with the
    already-generated text as an assistant prefix. The fallback then typically
    re-emits that prefix before continuing. This module matches the incoming
    continuation against [sent_so_far] and forwards only the bytes that are
    genuinely new, so the client sees one continuous stream with no duplicate
    tokens.

    Pure and unit-testable; no I/O here. *)

type t = {
  sent: string;
  match_pos: int;
  diverged: bool;
}

let init = fun ~sent_so_far -> { sent = sent_so_far; match_pos = 0; diverged = false }

let sent_so_far = fun t -> t.sent

(** Feed a chunk of continuation text. Returns the substring to forward to the
    client ("" when the chunk is still inside the duplicated prefix) and the
    new state. *)
let feed = fun t chunk ->
  let sent_len = String.length t.sent in
  let forward = ref [] in
  let match_pos = ref t.match_pos in
  let diverged = ref t.diverged in
  let rec loop i =
    if i >= String.length chunk then
      ()
    else
      let c = String.get_unchecked chunk ~at:i in
      if !diverged then (
        forward := String.from_char c :: !forward;
        loop (i + 1)
      ) else if !match_pos < sent_len then (
        if Char.equal (String.get_unchecked t.sent ~at:!match_pos) c then (
          match_pos := !match_pos + 1;
          loop (i + 1)
        ) else (
          diverged := true;
          forward := String.from_char c :: !forward;
          loop (i + 1)
        )
      ) else (
        diverged := true;
        forward := String.from_char c :: !forward;
        loop (i + 1)
      )
  in
  loop 0;
  ( List.rev !forward |> String.concat "",
    { sent = t.sent; match_pos = !match_pos; diverged = !diverged } )
