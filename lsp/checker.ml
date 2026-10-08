(* Checking a document with Elpi: error-resilient parsing first, then
   compilation (scoping and type checking) as a unit through the API: of the
   text when it has no syntax error, otherwise of the program where the
   erroneous parts are erased (API.Parse.program_resilient), so that type
   errors, hover and definition are available even when the text has syntax
   errors. The result is a list of diagnostics, as byte offsets in the text,
   and, when the program compiles, the hover information. *)

open Elpi.API

type severity = Error | Warning | Information

type diagnostic = {
  start : int;   (* byte offsets in the document *)
  stop : int;
  severity : severity;
  message : string;
}

(* the hover information: of the clauses (Compile.hover), and of the type
   expressions of the declarations (Compile.hover_types) *)
type hover = {
  terms : Compile.info Compile.IntervalTree.t list;
  types : (Ast.Loc.t * string * Ast.Loc.t option) list;
}

type result = {
  diagnostics : diagnostic list;
  hover : hover option; (* when the text compiles *)
}

let log fmt = Printf.ksprintf (fun s -> prerr_endline ("[elpi-lsp] " ^ s)) fmt

(* --- Elpi instance -------------------------------------------------------- *)

(* The error hooks of Elpi exit by default: we turn errors into exceptions,
   and collect warnings. *)
exception Elpi_error of Ast.Loc.t option * string

let warnings = ref []

let () =
  Setup.set_error (fun ?loc msg -> raise (Elpi_error (loc, msg)));
  Setup.set_type_error (fun ?loc msg -> raise (Elpi_error (loc, msg)));
  Setup.set_anomaly (fun ?loc msg -> raise (Elpi_error (loc, "anomaly: " ^ msg)));
  Setup.set_warn (fun ?loc ~id:_ msg -> warnings := (loc, msg) :: !warnings);
  Setup.set_std_formatter Format.err_formatter

(* accumulated files are resolved relative to the accumulating file (the
   parser passes its directory as ~cwd), then in TJPATH *)
let tjpath =
  match Sys.getenv_opt "TJPATH" with
  | None -> []
  | Some v -> List.filter (fun s -> s <> "") (String.split_on_char ':' v)

let resolver = Parse.std_resolver ~paths:tjpath ()

let elpi = lazy (Setup.init ~builtins:[Elpi.Builtin.std_builtins] ~file_resolver:resolver ())

(* --- diagnostics ------------------------------------------------------------ *)

let one_line s = String.concat " " (List.filter (( <> ) "") (String.split_on_char '\n' s))

(* the span of the accumulate directive of [file] in [text], or the
   beginning of the text: a heuristic, the directive is looked for in text *)
let accumulate_span text file =
  let name = Filename.remove_extension (Filename.basename file) in
  let re = Str.regexp ("^[ \t]*accumulate[^.]*\\b" ^ Str.quote name ^ "\\b[^.]*\\.") in
  match Str.search_forward re text 0 with
  | start -> start, Str.match_end ()
  | exception Not_found -> 0, 0

(* a diagnostic from an Elpi location; an error located in another file
   (an accumulated one) is shown on its accumulate directive *)
let diag_of_loc ~path ~text severity loc message =
  let message = String.trim message in
  match loc with
  | Some { Ast.Loc.source_name; source_start; source_stop; _ } when source_name = path ->
      { start = source_start; stop = source_stop; severity; message }
  | Some { Ast.Loc.source_name; line; source_start; line_starts_at; _ } ->
      let start, stop = accumulate_span text source_name in
      { start; stop; severity;
        message = Printf.sprintf "In %s, line %d, column %d: %s" source_name line
            (source_start - line_starts_at + 1) message }
  | None -> { start = 0; stop = 0; severity; message }

let syntax_diagnostics text (errors : Parse.syntax_error list) =
  let t = Text.make text in
  List.map (fun { Parse.loc; message; inserted } ->
    let start = loc.Ast.Loc.source_start in
    if inserted then { start; stop = start; severity = Information; message }
    else { start; stop = Text.word_end t start; severity = Error; message = one_line message })
    errors

(* --- checking --------------------------------------------------------------- *)

let resilient_parse ~path text =
  let elpi = Lazy.force elpi in
  let lexbuf = Lexing.from_string text in
  Parse.program_resilient ~elpi ~loc:(Ast.Loc.initial path) ~digest:(Digest.string text) lexbuf

let compile_program ast =
  let elpi = Lazy.force elpi in
  let base = Compile.empty_base ~elpi in
  let sps = Compile.scope_ast ~elpi ast in
  let _, terms =
    List.fold_left (fun (base, hover) sp ->
        let u = Compile.unit ~elpi ~base sp in
        Compile.extend ~base u, Compile.hover u :: hover)
      (base, []) sps in
  { terms; types = List.concat_map Compile.hover_types sps }

(* An error of the compiler, as a location and a message *)
let error_of_exn = function
  | Parse.ParseError (loc, msg) -> Some loc, msg
  | Compile.CompileError (loc, msg) -> loc, msg
  | Elpi_error (loc, msg) -> loc, msg
  | Failure msg -> None, msg
  | e ->
      log "internal error: %s\n%s" (Printexc.to_string e) (Printexc.get_backtrace ());
      None, "internal error: " ^ Printexc.to_string e

(* The compiler stops at the first error. To go on, the declaration where the
   error is is removed and the program compiled again (at most [max_errors]
   times), so that all the errors are reported, and the hover information is
   available for the rest. An error in a declaration that contains a syntax
   error (a position of [syntax]) is a consequence of the error recovery: it
   is not reported. Warnings are those of the last compilation. *)
let max_errors = 50

let compile_resilient ~path ~text ~syntax ast =
  let caused_by_syntax spans =
    List.exists (fun (sp : Ast.Loc.t) ->
        List.exists (fun p -> sp.source_start <= p && p <= sp.source_stop) syntax) spans in
  let rec go ast diags n =
    warnings := [];
    match compile_program ast with
    | hover -> List.rev diags, Some hover
    | exception e ->
        let loc, msg = error_of_exn e in
        let diag = diag_of_loc ~path ~text Error loc msg in
        match loc with
        | Some l when n > 0 && l.Ast.Loc.source_name = path -> begin
            match Ast.remove_declarations_at ast l with
            | Some (ast, spans) -> go ast (if caused_by_syntax spans then diags else diag :: diags) (n - 1)
            | None -> List.rev (diag :: diags), None
          end
        | _ -> List.rev (diag :: diags), None in
  go ast [] max_errors

let check ~path text =
  (* the resilient parser may still raise: the normal path then reports the
     first error *)
  let syntax, erased =
    match resilient_parse ~path text with
    | errors, ast -> syntax_diagnostics text errors, Some ast
    | exception e -> log "resilient parser: %s" (Printexc.to_string e); [], None in
  (* without syntax error, the text is parsed as Elpi does; with syntax
     errors, the program where they are erased is used *)
  let program =
    match syntax, erased with
    | _ :: _, Some ast -> Ok ast
    | _ ->
        let elpi = Lazy.force elpi in
        match Parse.program_from ~elpi ~loc:(Ast.Loc.initial path) ~digest:(Digest.string text)
                (Lexing.from_string text) with
        | ast -> Ok ast
        | exception e -> Error (error_of_exn e) in
  let errors, hover =
    match program with
    | Ok ast ->
        compile_resilient ~path ~text ~syntax:(List.map (fun d -> d.start) syntax) ast
    | Error (loc, msg) -> [ diag_of_loc ~path ~text Error loc msg ], None in
  let ws = List.rev_map (fun (loc, msg) -> diag_of_loc ~path ~text Warning loc msg) !warnings in
  warnings := [];
  { diagnostics = syntax @ errors @ ws; hover }

(* --- queries on the hover information ---------------------------------------- *)

(* The entries of the hover information at byte [off] of [path], as
   (location, text, definition); the innermost one with a text (for hover) or
   a definition is chosen: among the intervals containing [off], or else
   ending at [off] (the cursor just after a word). *)
let entries ~path off (hover : hover) =
  let loc = { (Ast.Loc.initial path) with source_start = off; source_stop = off } in
  let terms =
    List.concat_map (Compile.IntervalTree.find loc) hover.terms
    |> List.map (fun (l, { Compile.type_; defined }) ->
        l, Option.map (Format.asprintf "%a" Compile.pp_type_) type_, defined) in
  let types =
    List.filter_map (fun ((l : Ast.Loc.t), text, defined) ->
        if l.source_name = path && l.source_start <= off && off <= l.source_stop
        then Some (l, Some text, defined) else None) hover.types in
  terms @ types

let innermost ~path off p hover =
  let entries = List.filter p (entries ~path off hover) in
  let size ({ Ast.Loc.source_start; source_stop; _ }, _, _) = source_stop - source_start in
  let inside = List.filter (fun ({ Ast.Loc.source_start; source_stop; _ }, _, _) ->
      source_start <= off && off < source_stop) entries in
  let candidates = if inside <> [] then inside else entries in
  match List.stable_sort (fun x y -> compare (size x) (size y)) candidates with
  | x :: _ -> Some x
  | [] -> None

let type_at ~path off hover =
  match innermost ~path off (fun (_, t, _) -> t <> None) hover with
  | Some (loc, Some text, _) -> Some (loc, text)
  | _ -> None

let definition_at ~path off hover =
  match innermost ~path off (fun (_, _, d) -> d <> None) hover with
  | Some (loc, _, Some d) -> Some (loc, d)
  | _ -> None
