(* recov FILE [INCLUDE_DIR]: run the error-resilient Elpi parser on FILE and
   print one line per item, tab separated, for recov.py:
     E <offset> <state>   parse error (Menhir state)
     L <offset> <msg>     lexing error
     C <offset> <text>    token inserted by the recovery
     D <decl>             a declaration, as printed by Ast.Decl.show
     X <exn>              the parser raised an exception *)
open Elpi_parser

let one_line s = String.map (function '\n' | '\t' -> ' ' | c -> c) s

let () =
  let file = Sys.argv.(1) in
  let paths = if Array.length Sys.argv > 2 then [ Sys.argv.(2) ] else [ Filename.dirname file ] in
  let module P = Parse.Make (struct
    let versions = Elpi_util.Util.StrMap.empty
    let resolver = Elpi_util.Util.std_resolver ~paths ()
  end) in
  let ic = open_in_bin file in
  let lexbuf = Lexing.from_string (really_input_string ic (in_channel_length ic)) in
  lexbuf.Lexing.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = file };
  match P.Internal.program_resilient lexbuf with
  | errs, comps, ast ->
      List.iter
        (function
          | Mastic.ErrorResilientParser.LexError (p, m) -> Printf.printf "L\t%d\t%s\n" p.Lexing.pos_cnum (one_line m)
          | Mastic.ErrorResilientParser.ParseError (p, st) -> Printf.printf "E\t%d\t%d\n" p.Lexing.pos_cnum st)
        (List.rev errs);
      List.iter (fun (p, s) -> Printf.printf "C\t%d\t%s\n" p.Lexing.pos_cnum s) (List.rev comps);
      List.iter (fun d -> Printf.printf "D\t%s\n" (one_line (Ast.Decl.show d))) ast
  | exception e ->
      Printf.printf "X\t%s\n" (one_line (Printexc.to_string e));
      exit 2
