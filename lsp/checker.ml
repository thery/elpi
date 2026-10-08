(* Checking a document with Elpi: error-resilient parsing first, then, if
   the text has no syntax error, compilation (scoping and type checking) as a
   unit through the API. The result is a list of diagnostics, as byte offsets
   in the text, and, when the text compiles, the hover information. *)

open Elpi.API

type severity = Error | Warning | Information

type diagnostic = {
  start : int;   (* byte offsets in the document *)
  stop : int;
  severity : severity;
  message : string;
}

type hover = Compile.info Compile.IntervalTree.t list

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

(* the error-resilient parser *)
module Resilient = Elpi_parser.Parse.Make (struct
  let versions = Elpi_util.Util.StrMap.empty
  let resolver = resolver
end)

let message_of_state s =
  match Elpi_parser.Error_messages.message s with
  | m -> String.trim m
  | exception Not_found -> "syntax error"

(* --- diagnostics ------------------------------------------------------------ *)

let one_line s = String.concat " " (List.filter (( <> ) "") (String.split_on_char '\n' s))

(* a diagnostic from an Elpi location; an error located in another file
   (an accumulated one) is shown at the beginning of the document *)
let diag_of_loc ~path severity loc message =
  match loc with
  | Some { Ast.Loc.source_name; source_start; source_stop; line; _ } when source_name = path ->
      { start = source_start; stop = source_stop; severity; message }
  | Some { Ast.Loc.source_name; line; source_start; line_starts_at; _ } ->
      { start = 0; stop = 0; severity;
        message = Printf.sprintf "In %s, line %d, column %d: %s" source_name line
            (source_start - line_starts_at + 1) message }
  | None -> { start = 0; stop = 0; severity; message }

let syntax_diagnostics text errors completions =
  let t = Text.make text in
  let error = function
    | Mastic.ErrorResilientParser.LexError (p, msg) ->
        let start = p.Lexing.pos_cnum in
        { start; stop = Text.word_end t start; severity = Error; message = one_line msg }
    | Mastic.ErrorResilientParser.ParseError (p, state) ->
        let start = p.Lexing.pos_cnum in
        { start; stop = Text.word_end t start; severity = Error; message = message_of_state state } in
  let completion (p, s) =
    let start = p.Lexing.pos_cnum in
    { start; stop = start; severity = Information;
      message = if s = "_" then "missing term" else Printf.sprintf "missing %s" s } in
  List.rev_map error errors @ List.rev_map completion completions

(* --- checking --------------------------------------------------------------- *)

let resilient_parse ~path text =
  let lexbuf = Lexing.from_string text in
  lexbuf.Lexing.lex_curr_p <- { lexbuf.Lexing.lex_curr_p with pos_fname = path };
  let errors, completions, _ast = Resilient.Internal.program_resilient lexbuf in
  syntax_diagnostics text errors completions

let compile ~path text =
  let elpi = Lazy.force elpi in
  let ast =
    Parse.program_from ~elpi ~loc:(Ast.Loc.initial path) ~digest:(Digest.string text)
      (Lexing.from_string text) in
  let base = Compile.empty_base ~elpi in
  let _, hover =
    List.fold_left (fun (base, hover) sp ->
        let u = Compile.unit ~elpi ~base sp in
        Compile.extend ~base u, Compile.hover u :: hover)
      (base, []) (Compile.scope_ast ~elpi ast) in
  hover

let check ~path text =
  let error loc msg = { diagnostics = [ diag_of_loc ~path Error loc msg ]; hover = None } in
  match resilient_parse ~path text with
  | _ :: _ as diagnostics -> { diagnostics; hover = None }
  | exception e -> error None ("parser: " ^ Printexc.to_string e)
  | [] ->
      warnings := [];
      let result =
        match compile ~path text with
        | hover -> { diagnostics = []; hover = Some hover }
        | exception Parse.ParseError (loc, msg) -> error (Some loc) msg
        | exception Compile.CompileError (loc, msg) -> error loc msg
        | exception Elpi_error (loc, msg) -> error loc msg
        | exception (Failure msg) -> error None msg
        | exception e ->
            log "internal error: %s\n%s" (Printexc.to_string e) (Printexc.get_backtrace ());
            error None ("internal error: " ^ Printexc.to_string e) in
      let ws = List.rev_map (fun (loc, msg) -> diag_of_loc ~path Warning loc msg) !warnings in
      warnings := [];
      { result with diagnostics = result.diagnostics @ ws }

(* --- queries on the hover information ---------------------------------------- *)

(* the innermost entry at byte [off] of [path] satisfying [p]: the intervals
   containing [off], or else ending at [off] (the cursor just after a word) *)
let find ~path off p (hover : hover) =
  let loc = { (Ast.Loc.initial path) with source_start = off; source_stop = off } in
  let entries = List.concat_map (Compile.IntervalTree.find loc) hover in
  let entries = List.filter (fun (_, i) -> p i) entries in
  let size ({ Ast.Loc.source_start; source_stop; _ }, _) = source_stop - source_start in
  let inside = List.filter (fun ({ Ast.Loc.source_start; source_stop; _ }, _) ->
      source_start <= off && off < source_stop) entries in
  let candidates = if inside <> [] then inside else entries in
  match List.stable_sort (fun x y -> compare (size x) (size y)) candidates with
  | x :: _ -> Some x
  | [] -> None

let type_at ~path off hover =
  match find ~path off (fun i -> i.Compile.type_ <> None) hover with
  | Some (loc, { Compile.type_ = Some ty; _ }) -> Some (loc, Format.asprintf "%a" Compile.pp_type_ ty)
  | _ -> None

let definition_at ~path off hover =
  match find ~path off (fun i -> i.Compile.defined <> None) hover with
  | Some (loc, { Compile.defined = Some d; _ }) -> Some (loc, d)
  | _ -> None
