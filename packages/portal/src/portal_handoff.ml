open Std
open Std.Collections

(** Seamless-handoff splice: deduplicates a continuation stream against the
    text already delivered to the client.

    When a model dies mid-stream we restart on a fallback account with the
    already-generated text as an assistant prefix. The fallback then either
    re-emits that prefix before continuing, continues directly, or ignores
    the prefix and answers from scratch. This module matches the incoming
    continuation against [sent_so_far], forwards only genuinely new text and
    classifies the handoff (spec §3.1):

    - [Exact] (G1): byte-exact replay or direct continuation — zero overlap
    - [Approximate] (G2): the replay drifted after ≥ 20% of the prefix —
      forwarded from the divergence point
    - [Restart] (G3): the fallback is answering from scratch — the caller
      must announce the restart and forward the continuation as a new answer

    Matching works on whole UTF-8 characters, so forwarded text never starts
    or ends inside a multi-byte sequence; incomplete trailing bytes of a
    chunk are held until the next [step].

    Pure and unit-testable; no I/O here. *)

type level =
  | Exact
  | Approximate
  | Restart

type phase =
  | Matching
  | Undecided of string
  | Forwarding

type t = {
  sent: string;
  match_pos: int;
  phase: phase;
  pending: string;
  diverged_at: int option;
  level: level option;
}

type step =
  | Forward of string
  | Restart_with of string

let head_window = 32

let init = fun ~sent_so_far ->
  {
    sent = sent_so_far;
    match_pos = 0;
    phase = Matching;
    pending = "";
    diverged_at = None;
    level = None;
  }

let sent_so_far = fun t -> t.sent

let matched_bytes = fun t -> t.match_pos

let diverged_at = fun t -> t.diverged_at

let level = fun t -> t.level

let level_to_string = function
  | Exact -> "G1"
  | Approximate -> "G2"
  | Restart -> "G3"

(* ---------- UTF-8 helpers ---------- *)

let byte_at = fun s i -> Char.code (String.get_unchecked s ~at:i)

(** Expected sequence length from a lead byte; stray continuation or invalid
    bytes count as 1 so they never stall the stream. *)
let utf8_len = fun lead ->
  if lead < 0x80 then 1
  else if lead land 0xE0 = 0xC0 then 2
  else if lead land 0xF0 = 0xE0 then 3
  else if lead land 0xF8 = 0xF0 then 4
  else 1

let is_valid_utf8 = fun s ->
  let len = String.length s in
  let is_cont i = if i < len then byte_at s i land 0xC0 = 0x80 else false in
  let rec go i =
    if i >= len then
      true
    else
      let b = byte_at s i in
      if b < 0x80 then
        go (i + 1)
      else if b land 0xE0 = 0xC0 && b >= 0xC2 then
        is_cont (i + 1) && go (i + 2)
      else if b land 0xF0 = 0xE0 then
        is_cont (i + 1) && is_cont (i + 2) && go (i + 3)
      else if b land 0xF8 = 0xF0 && b <= 0xF4 then
        is_cont (i + 1) && is_cont (i + 2) && is_cont (i + 3) && go (i + 4)
      else
        false
  in
  go 0

(** Split [data] into complete characters plus an incomplete tail. *)
let split_chars = fun data ->
  let len = String.length data in
  let rec go i acc =
    if i >= len then
      (List.rev acc, "")
    else
      let n = utf8_len (byte_at data i) in
      if i + n > len then
        (List.rev acc, String.sub data ~offset:i ~len:(len - i))
      else
        go (i + n) (String.sub data ~offset:i ~len:n :: acc)
  in
  go 0 []

let levenshtein = fun a b ->
  let la = String.length a in
  let lb = String.length b in
  let prev = Array.make ~count:(lb + 1) ~value:0 in
  let cur = Array.make ~count:(lb + 1) ~value:0 in
  for j = 0 to lb do
    Array.set_unchecked prev ~at:j ~value:j
  done;
  for i = 1 to la do
    Array.set_unchecked cur ~at:0 ~value:i;
    for j = 1 to lb do
      let cost =
        if Char.equal (String.get_unchecked a ~at:(i - 1)) (String.get_unchecked b ~at:(j - 1)) then 0
        else 1
      in
      let del = Array.get_unchecked prev ~at:j + 1 in
      let ins = Array.get_unchecked cur ~at:(j - 1) + 1 in
      let sub = Array.get_unchecked prev ~at:(j - 1) + cost in
      Array.set_unchecked cur ~at:j ~value:(min del (min ins sub))
    done;
    for j = 0 to lb do
      Array.set_unchecked prev ~at:j ~value:(Array.get_unchecked cur ~at:j)
    done
  done;
  Array.get_unchecked prev ~at:lb

(** A divergence at byte 0 is either a direct continuation (the fallback
    skipped the echo) or a fresh answer. A fresh answer usually opens like
    the original text did, so a small edit distance between the two openings
    means [Restart]. *)
let classify_head = fun ~sent ~head ->
  let n = min head_window (min (String.length sent) (String.length head)) in
  if n = 0 then
    Exact
  else
    let d =
      levenshtein (String.sub head ~offset:0 ~len:n) (String.sub sent ~offset:0 ~len:n)
    in
    if d * 2 > n then Exact else Restart

(* ---------- feeding ---------- *)

let head_needed = fun t -> min head_window (String.length t.sent)

let step = fun t chunk ->
  let (chars, pending) = split_chars (t.pending ^ chunk) in
  let sent_len = String.length t.sent in
  let out = StringBuilder.create ~size:64 in
  let restarted = ref false in
  let decide_head (st : t) buf =
    match classify_head ~sent:st.sent ~head:buf with
    | Restart ->
        restarted := true;
        StringBuilder.add_string out buf;
        { st with phase = Forwarding; level = Some Restart }
    | lvl ->
        StringBuilder.add_string out buf;
        { st with phase = Forwarding; level = Some lvl }
  in
  let feed_char (st : t) c =
    match st.phase with
    | Forwarding ->
        StringBuilder.add_string out c;
        st
    | Undecided buf ->
        let buf = buf ^ c in
        if String.length buf >= head_needed st then decide_head st buf
        else { st with phase = Undecided buf }
    | Matching ->
        let n = String.length c in
        if st.match_pos >= sent_len then (
          StringBuilder.add_string out c;
          { st with phase = Forwarding; diverged_at = Some st.match_pos; level = Some Exact }
        ) else if
          (* Std's [&&] is not short-circuiting: guard the slice explicitly *)
          (if st.match_pos + n <= sent_len then
             String.equal (String.sub st.sent ~offset:st.match_pos ~len:n) c
           else false)
        then
          { st with match_pos = st.match_pos + n }
        else
          let st = { st with diverged_at = Some st.match_pos } in
          if st.match_pos = 0 then
            if String.length c >= head_needed st then decide_head st c
            else { st with phase = Undecided c }
          else if st.match_pos * 5 < sent_len then (
            restarted := true;
            StringBuilder.add_string out (String.sub st.sent ~offset:0 ~len:st.match_pos);
            StringBuilder.add_string out c;
            { st with phase = Forwarding; level = Some Restart }
          ) else (
            StringBuilder.add_string out c;
            { st with phase = Forwarding; level = Some Approximate }
          )
  in
  let t' = List.fold_left chars ~init:{ t with pending } ~fn:feed_char in
  let text = StringBuilder.contents out in
  if !restarted then (Restart_with text, t') else (Forward text, t')

(** Flush at the end of the continuation stream: an undecided head is
    classified with whatever arrived; an incomplete trailing sequence is
    dropped (it can never become valid). *)
let finish = fun t ->
  match t.phase with
  | Undecided buf -> (
      match classify_head ~sent:t.sent ~head:buf with
      | Restart -> (Restart_with buf, { t with phase = Forwarding; pending = ""; level = Some Restart })
      | lvl -> (Forward buf, { t with phase = Forwarding; pending = ""; level = Some lvl })
    )
  | Matching -> (Forward "", { t with pending = ""; level = Some Exact })
  | Forwarding -> (Forward "", { t with pending = "" })

(** Compatibility wrapper: the text to forward, whatever the step kind. *)
let feed = fun t chunk ->
  match step t chunk with
  | (Forward s, t') -> (s, t')
  | (Restart_with s, t') -> (s, t')
