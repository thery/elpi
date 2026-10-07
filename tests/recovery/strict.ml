(* strict FILE: the normal parsing path of Elpi (Parse.program), for checking
   that it is unchanged: prints the declarations, or the error raised *)
open Elpi_util
open Elpi_parser

let () =
  let file = Sys.argv.(1) in
  let module P = Parse.Make (struct
    let versions = Util.StrMap.empty
    let resolver = Util.std_resolver ~paths:[ Filename.dirname file ] ()
  end) in
  match P.program ~file with
  | { ast; _ } -> List.iter (fun d -> print_endline (Ast.Program.show_decl d)) ast
  | exception e -> print_endline ("RAISED " ^ Printexc.to_string e)
