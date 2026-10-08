(* Drives elpi-lsp with JSON-RPC messages and prints a summary of the answers.
   usage: test_lsp SERVER DIR, where DIR holds the .elpi files of the test *)

open Yojson.Safe.Util

let server, dir =
  match Sys.argv with
  | [| _; s; d |] -> s, d
  | _ -> prerr_endline "usage: test_lsp SERVER DIR"; exit 2

let dir = if Filename.is_relative dir then Filename.concat (Sys.getcwd ()) dir else dir

let to_server_r, to_server_w = Unix.pipe ~cloexec:true ()
let from_server_r, from_server_w = Unix.pipe ~cloexec:true ()

let pid = Unix.create_process server [| server |] to_server_r from_server_w Unix.stderr
let () = Unix.close to_server_r; Unix.close from_server_w
let oc = Unix.out_channel_of_descr to_server_w
let ic = Unix.in_channel_of_descr from_server_r

let send json =
  let s = Yojson.Safe.to_string json in
  Printf.fprintf oc "Content-Length: %d\r\n\r\n%s" (String.length s) s;
  flush oc

let rec receive () =
  let rec headers len =
    match input_line ic with
    | "\r" | "" -> len
    | l ->
        (match String.split_on_char ':' l with
         | [ k; v ] when String.lowercase_ascii k = "content-length" -> headers (int_of_string (String.trim v))
         | _ -> headers len) in
  let len = headers 0 in
  Yojson.Safe.from_string (really_input_string ic len)

let id = ref 0

let request meth params =
  incr id;
  send (`Assoc ([ "jsonrpc", `String "2.0"; "id", `Int !id; "method", `String meth ]
                @ if params = `Null then [] else [ "params", params ]));
  let rec wait () =
    let m = receive () in
    if member "id" m = `Int !id then m else wait () in
  wait ()

let notify meth params =
  send (`Assoc ([ "jsonrpc", `String "2.0"; "method", `String meth ]
                @ if params = `Null then [] else [ "params", params ]))

let uri file = "file://" ^ Filename.concat dir file
(* replaces [d] by [by] in [s] *)
let replace d by s =
  let b = Buffer.create 80 in
  let n = String.length d in
  let i = ref 0 in
  while !i < String.length s do
    if n > 0 && !i + n <= String.length s && String.sub s !i n = d then (Buffer.add_string b by; i := !i + n)
    else (Buffer.add_char b s.[!i]; incr i)
  done;
  Buffer.contents b

(* the directory of the test, also as Elpi names it, without _build/default *)
let anonymize s =
  let clean = Str.global_replace (Str.regexp "/_build/[^/]+") "" dir in
  s |> replace dir "$DIR" |> replace clean "$DIR"

let read_file file =
  let ic = open_in_bin (Filename.concat dir file) in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic; s

let pp_range r =
  let p x = Printf.sprintf "%d:%d" (member "line" x |> to_int) (member "character" x |> to_int) in
  p (member "start" r) ^ "-" ^ p (member "end" r)

let severity = function 1 -> "error" | 2 -> "warning" | 3 -> "info" | _ -> "hint"

let rec wait_diagnostics file =
  let m = receive () in
  if member "method" m = `String "textDocument/publishDiagnostics"
  && member "params" m |> member "uri" = `String (uri file) then begin
    let ds = member "params" m |> member "diagnostics" |> to_list in
    Printf.printf "diagnostics of %s: %d\n" file (List.length ds);
    List.iter (fun d ->
        Printf.printf "  %s %s: %s\n" (pp_range (member "range" d))
          (severity (member "severity" d |> to_int)) (anonymize (member "message" d |> to_string)))
      ds
  end else wait_diagnostics file

let open_file file =
  notify "textDocument/didOpen" (`Assoc [ "textDocument", `Assoc [
      "uri", `String (uri file); "languageId", `String "elpi"; "version", `Int 1;
      "text", `String (read_file file) ] ]);
  wait_diagnostics file

let change_file file version text =
  notify "textDocument/didChange" (`Assoc [
      "textDocument", `Assoc [ "uri", `String (uri file); "version", `Int version ];
      "contentChanges", `List [ `Assoc [ "text", `String text ] ] ]);
  wait_diagnostics file

(* the LSP position of the [k]-th character after the first occurrence of
   [needle] in [file], counting columns in UTF-16 code units *)
let position file needle k =
  let s = read_file file in
  let rec find i = if String.sub s i (String.length needle) = needle then i else find (i + 1) in
  let off = find 0 + k in
  let line = ref 0 and col = ref 0 in
  for i = 0 to off - 1 do
    let c = Char.code s.[i] in
    if s.[i] = '\n' then (incr line; col := 0)
    else if c land 0xC0 <> 0x80 then col := !col + (if c >= 0xF0 then 2 else 1)
  done;
  `Assoc [ "line", `Int !line; "character", `Int !col ]

let at file needle k =
  `Assoc [ "textDocument", `Assoc [ "uri", `String (uri file) ]; "position", position file needle k ]

let hover file needle k =
  let r = request "textDocument/hover" (at file needle k) |> member "result" in
  Printf.printf "hover %S+%d: %s\n" needle k
    (if r = `Null then "none" else
       Printf.sprintf "%s %S" (pp_range (member "range" r)) (member "contents" r |> member "value" |> to_string))

let definition file needle k =
  let r = request "textDocument/definition" (at file needle k) |> member "result" in
  Printf.printf "definition %S+%d: %s\n" needle k
    (match r with
     | `Null | `List [] -> "none"
     | `List (l :: _) | (`Assoc _ as l) ->
         anonymize (member "uri" l |> to_string) ^ " " ^ pp_range (member "range" l)
     | _ -> "?")

let () =
  let init = request "initialize" (`Assoc [ "processId", `Null; "rootUri", `Null; "capabilities", `Assoc [] ]) in
  let caps = init |> member "result" |> member "capabilities" in
  Printf.printf "capabilities: %s\n" (Yojson.Safe.to_string caps);
  notify "initialized" (`Assoc []);
  open_file "syntax.elpi";
  open_file "typeerr.elpi";
  open_file "warn.elpi";
  open_file "accbad.elpi";
  open_file "accmissing.elpi";
  open_file "good.elpi";
  hover "good.elpi" "double 3" 0;
  hover "good.elpi" "double 3 Y" 9;
  hover "good.elpi" "twice Y Z" 0;
  hover "good.elpi" "x\\ y\\ y = x" 6;
  hover "good.elpi" "std.map" 4;
  hover "good.elpi" "\"λ\" L" 5;
  hover "good.elpi" "% a comment" 3;
  definition "good.elpi" "double 3" 2;
  definition "good.elpi" "twice Y Z" 1;
  definition "good.elpi" "double 3 Y" 9;
  definition "good.elpi" "std.map" 4;
  (* an edit breaking the file, then fixing it *)
  let text = read_file "good.elpi" in
  change_file "good.elpi" 2 (text ^ "oops :- .\n");
  hover "good.elpi" "double 3" 0;
  change_file "good.elpi" 3 text;
  hover "good.elpi" "double 3" 0;
  let r = request "shutdown" `Null in
  Printf.printf "shutdown: %s\n" (Yojson.Safe.to_string (member "result" r));
  notify "exit" `Null;
  match Unix.waitpid [] pid with
  | _, Unix.WEXITED n -> Printf.printf "server exited with code %d\n" n
  | _ -> print_endline "server killed"
