open Std

(** Incremental HTTP/1.1 chunked transfer-coding decoder (pure, unit-testable). *)

type error = string

type state =
  | Waiting_size
  | Reading_data

type t = {
  pending: string;
  state: state;
  remaining: int;
}

type fed =
  | More of string list * t
  | Done of string list * t

let init = { pending = ""; state = Waiting_size; remaining = 0 }

let find_sub = fun s ~pattern ->
  let n = String.length s in
  let m = String.length pattern in
  if m = 0 then
    Some 0
  else
    let rec loop i =
      if i + m > n then
        None
      else
        let rec eq j =
          if j >= m then
            true
          else if
            Char.equal
              (String.get_unchecked s ~at:(i + j))
              (String.get_unchecked pattern ~at:j)
          then
            eq (j + 1)
          else
            false
        in
        if eq 0 then Some i else loop (i + 1)
    in
    loop 0

let hex_value = fun c ->
  let code = Char.code c in
  if code >= Char.code '0' && code <= Char.code '9' then
    Some (code - Char.code '0')
  else if code >= Char.code 'a' && code <= Char.code 'f' then
    Some (10 + code - Char.code 'a')
  else if code >= Char.code 'A' && code <= Char.code 'F' then
    Some (10 + code - Char.code 'A')
  else
    None

let parse_hex = fun s ->
  if String.is_empty s then
    None
  else
    let rec go i acc =
      if i >= String.length s then
        Some acc
      else
        match hex_value (String.get_unchecked s ~at:i) with
        | None -> None
        | Some v -> go (i + 1) ((acc * 16) + v)
    in
    go 0 0

(** Feed raw bytes. Returns decoded body pieces (possibly several) and the next
    decoder state. [Done] means the terminating 0-size chunk was consumed. *)
let feed = fun t chunk ->
  let pending = ref (t.pending ^ chunk) in
  let state = ref t.state in
  let remaining = ref t.remaining in
  let pieces = ref [] in
  let emit s = pieces := s :: !pieces in
  let rec step () =
    match !state with
    | Waiting_size -> (
        match find_sub !pending ~pattern:"\r\n" with
        | None -> Ok None
        | Some idx ->
            let size_line = String.sub !pending ~offset:0 ~len:idx in
            pending :=
              String.sub
                !pending
                ~offset:(idx + 2)
                ~len:(String.length !pending - idx - 2);
            let size_hex =
              match String.index_of size_line ~char:';' with
              | None -> String.trim size_line
              | Some i -> String.trim (String.sub size_line ~offset:0 ~len:i)
            in
            (
              match parse_hex size_hex with
              | None -> Error ("invalid chunk size line: " ^ size_line)
              | Some 0 -> Ok (Some `End)
              | Some n ->
                  state := Reading_data;
                  remaining := n;
                  step ()
            )
      )
    | Reading_data when !remaining = 0 -> (
        let avail = String.length !pending in
        if avail < 2 then
          Ok None
        else
          let c0 = String.get_unchecked !pending ~at:0 in
          let c1 = String.get_unchecked !pending ~at:1 in
          if Char.equal c0 '\r' && Char.equal c1 '\n' then (
            pending :=
              String.sub !pending ~offset:2 ~len:(String.length !pending - 2);
            state := Waiting_size;
            step ()
          ) else
            Error "malformed chunked encoding: missing CRLF after chunk data"
      )
    | Reading_data -> (
        let avail = String.length !pending in
        if avail = 0 then
          Ok None
        else
          let take = min !remaining avail in
          let piece = String.sub !pending ~offset:0 ~len:take in
          pending :=
            String.sub !pending ~offset:take ~len:(String.length !pending - take);
          remaining := !remaining - take;
          emit piece;
          step ()
      )
  in
  match step () with
  | Error e -> Error e
  | Ok None -> Ok (More (List.rev !pieces, { pending = !pending; state = !state; remaining = !remaining }))
  | Ok (Some `End) -> Ok (Done (List.rev !pieces, { pending = !pending; state = !state; remaining = !remaining }))
