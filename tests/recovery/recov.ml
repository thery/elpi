(* recov FILE         runs the error-resilient parser on FILE and prints, as the
                      test driver of Mastic: the source with the errors
                      underlined, the tokens inserted by the recovery, and the
                      recovered AST (terms as s-expressions, errors as Err«text»)
   recov --raw FILE   the same for recov.py, one item per line, tab separated:
                        E <offset> <state>   parse error (Menhir state)
                        L <offset> <msg>     lexing error
                        C <offset> <text>    token inserted by the recovery
                        S <kind> <start> <end> an error node (decl, term, …)
                        D <decl>             a declaration, as printed by show
                        X <exn>              the parser raised an exception
   recov --strict FILE the normal path of Elpi: number of declarations, or the
                      error raised *)
open Elpi_util
open Elpi_parser
open Ast

let one_line s = String.map (function '\n' | '\t' -> ' ' | c -> c) s

(* the source text of an error node, from its span *)
let text = ref ""

let slice b e =
  let b = max 0 b and e = min (String.length !text) e in
  if e <= b then "" else String.sub !text b (e - b)

let error_span (e : Mastic.Error.t) =
  let b, e = Mastic.Error.span e in
  (b.Lexing.pos_cnum, e.Lexing.pos_cnum)

let pp_err e =
  let b, e = error_span e in
  Printf.sprintf "Err«%s»" (one_line (slice b e))

(* the error nodes of a declaration, as spans *)
let spans = ref []
let add_error kind e = let b, e = error_span e in spans := (kind, b, e) :: !spans

let rec pp_term (t : Term.t) =
  match t.it with
  | Term.Const f -> Func.show f
  | Term.App (hd, args) -> "(" ^ String.concat " " (List.map pp_term (hd :: args)) ^ ")"
  | Term.Lam (x, _, None, t) -> Func.show x ^ "\\ " ^ pp_term t
  | Term.Lam (x, _, Some ty, t) -> Func.show x ^ ":" ^ pp_type ty ^ "\\ " ^ pp_term t
  | Term.CData c -> Format.asprintf "%a" Util.CData.pp c
  | Term.Quoted { data; _ } -> "{{" ^ data ^ "}}"
  | Term.Cast (t, ty) -> "(" ^ pp_term t ^ " : " ^ pp_type ty ^ ")"
  | Term.Parens t -> pp_term t

and pp_type : 'a. 'a TypeExpression.t -> string = fun ty ->
  match ty.tit with
  | TypeExpression.TConst c -> Func.show c
  | TypeExpression.TApp (c, t, ts) -> "(" ^ String.concat " " (Func.show c :: List.map pp_type (t :: ts)) ^ ")"
  | TypeExpression.TPred (_, args, _) ->
      "(pred " ^ String.concat ", " (List.map (fun (m, t) ->
        (match m with Util.Mode.Input -> "i:" | Util.Mode.Output -> "o:") ^ pp_type t) args) ^ ")"
  | TypeExpression.TArr (a, b) -> "(" ^ pp_type a ^ " -> " ^ pp_type b ^ ")"

let pp_attributes = function
  | [] -> ""
  | l -> String.concat " " (List.map (fun a -> ":" ^ one_line (show_raw_attribute a)) l) ^ " "

let pp_decl (d : Program.decl) =
  match d with
  | Program.Clause { attributes; body; _ } -> "clause " ^ pp_attributes attributes ^ pp_term body
  | Program.Chr { to_match; to_remove; guard; new_goal; _ } ->
      let seq { Chr.conclusion; _ } = pp_term conclusion in
      "rule " ^ String.concat " " (List.map seq to_match)
      ^ (if to_remove = [] then "" else " \\ " ^ String.concat " " (List.map seq to_remove))
      ^ (match guard with None -> "" | Some g -> " | " ^ pp_term g)
      ^ (match new_goal with None -> "" | Some g -> " <=> " ^ seq g)
  | Program.Pred { name; attributes; ty; _ } -> "pred " ^ pp_attributes attributes ^ Func.show name ^ " " ^ pp_type ty
  | Program.Type l -> "type " ^ String.concat ", " (List.map (fun { Type.name; _ } -> Func.show name) l)
      ^ (match l with { ty; _ } :: _ -> " " ^ pp_type ty | [] -> "")
  | Program.Kind l -> "kind " ^ String.concat ", " (List.map (fun { Type.name; _ } -> Func.show name) l)
  | Program.Macro { name; body; _ } -> "macro " ^ Func.show name ^ " " ^ pp_term body
  | Program.TypeAbbreviation { name; _ } -> "typeabbrev " ^ Func.show name
  | Program.Namespace (_, f) -> "namespace " ^ Func.show f ^ " {"
  | Program.Constraint _ -> "constraint {"
  | Program.Begin _ -> "{"
  | Program.End _ -> "}"
  | Program.Shorten _ -> "shorten"
  | Program.Accumulated (_, l) -> "accumulate " ^ String.concat ", " (List.map (fun o -> Filename.basename o.file_name) l)
  | Program.Ignored _ -> "ignored"
  | Program.Error e -> add_error "decl" e; "ERROR " ^ pp_err e

(* the source, each line followed by the underlined error spans *)
let underline_source spans =
  let lines = String.split_on_char '\n' !text in
  let _ = List.fold_left (fun start line ->
    let stop = start + String.length line in
    Printf.printf "  %s\n" line;
    let marks = Bytes.make (String.length line) ' ' in
    List.iter (fun (_, b, e) ->
      for i = max b start to min e stop - 1 do Bytes.set marks (i - start) '^' done;
      (* an empty error (a hole) is shown where it is *)
      if b = e && start <= b && b <= stop then
        Bytes.set marks (min (b - start) (max 0 (String.length line - 1))) '^') spans;
    if Bytes.exists (fun c -> c = '^') marks then Printf.printf "  %s\n" (Bytes.to_string marks);
    stop + 1) 0 lines in
  ()

let () =
  let raw = Array.mem "--raw" Sys.argv and strict = Array.mem "--strict" Sys.argv in
  let args = List.filter (fun a -> a <> "--raw" && a <> "--strict") (List.tl (Array.to_list Sys.argv)) in
  let file, paths = match args with f :: d :: _ -> f, [d] | [f] -> f, [Filename.dirname f] | [] -> prerr_endline "usage: recov [--raw|--strict] FILE [INCLUDE_DIR]"; exit 1 in
  let module P = Parse.Make (struct
    let versions = Util.StrMap.empty
    let resolver = Util.std_resolver ~paths ()
  end) in
  if strict then begin
    (match P.program ~file with
     | { ast; _ } -> Printf.printf "OK %d declarations\n" (List.length ast)
     | exception e -> Printf.printf "RAISED %s\n" (one_line (Printexc.to_string e)));
    exit 0
  end;
  let ic = open_in_bin file in
  text := really_input_string ic (in_channel_length ic);
  let lexbuf = Lexing.from_string !text in
  lexbuf.Lexing.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = file };
  let pos p = Printf.sprintf "%d:%d" p.Lexing.pos_lnum (p.Lexing.pos_cnum - p.Lexing.pos_bol) in
  match P.Internal.program_resilient lexbuf with
  | errs, comps, ast ->
      let printed = List.map pp_decl ast in
      if raw then begin
        List.iter (function
          | Mastic.ErrorResilientParser.LexError (p, m) -> Printf.printf "L\t%d\t%s\n" p.Lexing.pos_cnum (one_line m)
          | Mastic.ErrorResilientParser.ParseError (p, st) -> Printf.printf "E\t%d\t%d\n" p.Lexing.pos_cnum st)
          (List.rev errs);
        List.iter (fun (p, s) -> Printf.printf "C\t%d\t%s\n" p.Lexing.pos_cnum s) (List.rev comps);
        List.iter (fun (k, b, e) -> Printf.printf "S\t%s\t%d\t%d\n" k b e) (List.rev !spans);
        List.iter (fun d -> Printf.printf "D\t%s\n" (one_line (Program.show_decl d))) ast
      end else begin
        underline_source !spans;
        List.iter (function
          | Mastic.ErrorResilientParser.LexError (p, m) -> Printf.printf "lexical error at %s: %s\n" (pos p) m
          | Mastic.ErrorResilientParser.ParseError (p, _) -> Printf.printf "syntax error at %s\n" (pos p))
          (List.rev errs);
        List.iter (fun (p, s) -> Printf.printf "inserted %s at %s\n" s (pos p)) (List.rev comps);
        List.iter (fun s -> Printf.printf "%s\n" s) printed
      end
  | exception e ->
      Printf.printf "X\t%s\n" (one_line (Printexc.to_string e));
      exit 2
