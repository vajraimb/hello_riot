open Std

(** M0 spike: HTTPS probe against a real provider. Expects to reach
    https://api.deepseek.com/models and print the HTTP status line (401 without
    a key proves the TLS + HTTP/1.1 client path works in the wild). *)

let main ~args:_ =
  let host = "api.deepseek.com" in
  let addr =
    Net.Addr.from_host_and_port ~host ~port:443
    |> Result.unwrap
  in
  match Portal.Client.connect_tls ~hostname:host addr with
  | Error e ->
      eprintln (Portal.Client.error_to_string e);
      Error (Failure (Portal.Client.error_to_string e))
  | Ok conn ->
      let req =
        Portal.Client.make_request
          ~method_:"GET"
          ~path:"/models"
          ~headers:[ ("Host", host); ("Connection", "close") ]
          ()
      in
      (
        match Portal.Client.request_string conn req with
        | Error e ->
            Portal.Client.close conn;
            eprintln (Portal.Client.error_to_string e);
            Error (Failure (Portal.Client.error_to_string e))
        | Ok (resp, body) ->
            Portal.Client.close conn;
            println
              ("[HTTPS probe] " ^ host ^ " -> HTTP/1.1 " ^ Int.to_string resp.Portal.Client.status
              ^ " " ^ resp.Portal.Client.reason);
            let preview =
              String.sub body ~offset:0 ~len:(min 200 (String.length body))
            in
            println ("[HTTPS probe] body preview: " ^ preview);
            Ok ()
      )

let () = Runtime.run ~main ~args:Env.args ()
