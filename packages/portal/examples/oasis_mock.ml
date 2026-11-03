open Std

(** Standalone programmable mock OpenAI upstream for local demos.

    Usage:
      oasis-mock --port 9911 [--sse "a,b,c"] [--cut N] [--body "json"] [--status 429]
    Keep-alive server; streams the given SSE events then [DONE], optionally
    cutting the connection mid-stream after N bytes (quota-death simulation). *)

let main ~args =
  let port = ref 9911 in
  let sse = ref [] in
  let cut = ref 0 in
  let body = ref "{\"id\":\"mock\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"mock-ok\"}}]}" in
  let status = ref 200 in
  let rec parse = function
    | "--port" :: p :: rest ->
        port := Int.from_string_opt p |> Option.unwrap_or ~default:9911;
        parse rest
    | "--sse" :: evs :: rest ->
        sse := String.split ~by:"," evs;
        parse rest
    | "--cut" :: n :: rest ->
        cut := Int.from_string_opt n |> Option.unwrap_or ~default:0;
        parse rest
    | "--body" :: b :: rest ->
        body := b;
        parse rest
    | "--status" :: s :: rest ->
        status := Int.from_string_opt s |> Option.unwrap_or ~default:200;
        parse rest
    | _ :: rest -> parse rest
    | [] -> ()
  in
  parse args;
  (
    match
      Portal.Mock.start ~host:"127.0.0.1" ~port:!port ()
    with
    | Error e ->
        eprintln ("mock start failed: " ^ e);
        Error (Failure e)
    | Ok mock ->
        Portal.Mock.set_scenario
          mock
          {
            (Portal.Mock.default_scenario) with
            sse = !sse;
            cut_after_bytes = !cut;
            body = !body;
            status = !status;
          };
        println
          ("oasis-mock listening on 127.0.0.1:"
          ^ Int.to_string mock.pool.port
          ^ (if List.is_empty !sse then " (non-stream)" else " (SSE stream)"));
        let rec keep_alive () =
          sleep (Time.Duration.from_secs 60);
          keep_alive ()
        in
        keep_alive ()
  )

let () = Runtime.run ~main ~args:Env.args ()
