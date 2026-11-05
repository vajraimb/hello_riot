open Std

(** Server-Sent Events (SSE) incremental parser. Feeds raw bytes, emits complete
    events. Tolerates "\n" and "\r\n" line endings. *)

type event = {
  event_type: string;
  data: string;
  id: string option;
  done_sentinel: bool;
}

type t = {
  line_buf: string;
  cur_type: string;
  cur_id: string option;
  cur_data: string list;
  has_data: bool;
}

let init = { line_buf = ""; cur_type = "message"; cur_id = None; cur_data = []; has_data = false }

let strip_cr = fun line ->
  let len = String.length line in
  if len = 0 then
    line
  else if Char.equal (String.get_unchecked line ~at:(len - 1)) '\r' then
    String.sub line ~offset:0 ~len:(len - 1)
  else
    line

let strip_leading_space = fun s ->
  if String.is_empty s then
    s
  else if Char.equal (String.get_unchecked s ~at:0) ' ' then
    String.sub s ~offset:1 ~len:(String.length s - 1)
  else
    s

let feed = fun t chunk ->
  let events = ref [] in
  let cur_type = ref t.cur_type in
  let cur_id = ref t.cur_id in
  let cur_data = ref t.cur_data in
  let has_data = ref t.has_data in
  let dispatch () =
    if !has_data then (
      let data = List.rev !cur_data |> String.concat "\n" in
      let ev =
        {
          event_type = !cur_type;
          data;
          id = !cur_id;
          done_sentinel = String.equal (String.trim data) "[DONE]";
        }
      in
      events := ev :: !events;
      cur_data := [];
      has_data := false;
      cur_id := None;
      cur_type := "message"
    )
  in
  let handle_line line =
    let line = strip_cr line in
    if String.is_empty line then
      dispatch ()
    else if String.starts_with ~prefix:":" line then
      ()
    else if String.starts_with ~prefix:"data:" line then (
      let v =
        String.sub line ~offset:5 ~len:(String.length line - 5)
        |> strip_leading_space
      in
      cur_data := v :: !cur_data;
      has_data := true
    ) else if String.starts_with ~prefix:"event:" line then
      cur_type :=
        String.sub line ~offset:6 ~len:(String.length line - 6)
        |> String.trim
    else if String.starts_with ~prefix:"id:" line then
      cur_id :=
        Some
          (String.sub line ~offset:3 ~len:(String.length line - 3)
          |> String.trim)
  in
  let combined = t.line_buf ^ chunk in
  let rec split_lines s =
    match String.index_of s ~char:'\n' with
    | None -> s
    | Some i ->
        let line = String.sub s ~offset:0 ~len:i in
        let rest =
          String.sub s ~offset:(i + 1) ~len:(String.length s - i - 1)
        in
        handle_line line;
        split_lines rest
  in
  let line_buf = split_lines combined in
  ( List.rev !events,
    {
      line_buf;
      cur_type = !cur_type;
      cur_id = !cur_id;
      cur_data = !cur_data;
      has_data = !has_data;
    } )
