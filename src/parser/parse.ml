(* elpi: embedded lambda prolog interpreter                                  *)
(* license: GNU Lesser General Public License Version 2.1 or later           *)
(* ------------------------------------------------------------------------- *)

open Elpi_util
open Elpi_lexer_config

exception ParseError = Parser_config.ParseError

module type Parser = sig
  val program : file:string -> Ast.Program.t
  val goal : loc:Util.Loc.t -> text:string -> Ast.Goal.t
  
  val goal_from : loc:Util.Loc.t -> Lexing.lexbuf -> Ast.Goal.t
  val program_from : loc:Util.Loc.t -> Lexing.lexbuf -> Ast.Program.t
end

module type Parser_w_Internals = sig
  include Parser

  module Internal : sig
    val infix_SYMB : (Lexing.lexbuf -> Tokens.token) -> Lexing.lexbuf -> Ast.Func.t
    val prefix_SYMB : (Lexing.lexbuf -> Tokens.token) -> Lexing.lexbuf -> Ast.Func.t
    val postfix_SYMB : (Lexing.lexbuf -> Tokens.token) -> Lexing.lexbuf -> Ast.Func.t
    val program_resilient : Lexing.lexbuf ->
      Mastic.ErrorResilientParser.error list * Mastic.ErrorResilientParser.completion list * Ast.Program.t
  end
end

module type Config = sig
  val versions : (int * int * int) Util.StrMap.t
  val resolver : ?cwd:string -> unit:string -> unit -> string

end

module Make(C : Config) = struct
  
let parse_ref : (?cwd:string -> string -> Ast.Decl.parser_output list) ref =
  ref (fun ?cwd:_ _ -> assert false)
  

module ParseFile = struct
  let parse_file ?cwd file = !parse_ref ?cwd file
  let client_payload : Obj.t option ref = ref None
  let set_current_clent_loc_pyload x = client_payload := Some x
  let get_current_client_loc_payload () = !client_payload

end

module Grammar = Grammar.Make(ParseFile)
  
let message_of_state s = try Error_messages.message s with Not_found -> "syntax error"

let at_line_start (p : Lexing.position) = p.pos_cnum = p.pos_bol

(* a token at the beginning of a line, or a keyword that begins a declaration,
   is a good point to restart parsing *)
let restart_point t (p : Lexing.position) =
  at_line_start p ||
  match t with
  | Tokens.PRED | Tokens.FUNC | Tokens.TYPE | Tokens.KIND | Tokens.NAMESPACE
  | Tokens.TYPEABBREV | Tokens.ACCUMULATE | Tokens.SHORTEN | Tokens.MACRO
  | Tokens.CONSTRAINT | Tokens.RULE -> true
  | _ -> false

module ProgramParser = struct
  type ast = Ast.Program.t
  type 'a checkpoint = 'a Grammar.MenhirInterpreter.checkpoint

  let main = Grammar.Incremental.program

  type token = Grammar.token

  let token = Lexer.token C.versions
end
module GoalParser = struct
  type ast = Ast.Goal.t
  type 'a checkpoint = 'a Grammar.MenhirInterpreter.checkpoint

  let main = Grammar.Incremental.goal

  type token = Grammar.token

  let token = Lexer.token C.versions
end
module Recovery = struct
  type token = Grammar.token
  let show_token _ = ""
  type 'a symbol = 'a Grammar.MenhirInterpreter.symbol
  type xsymbol = Grammar.MenhirInterpreter.xsymbol

  let pp_nonterminal : type a. Format.formatter -> a Grammar.MenhirInterpreter.symbol -> unit =
    fun fmt x ->
    let open Grammar.MenhirInterpreter in
    match x with
    | N N_decl -> Format.fprintf fmt "<decl>"
    | _ -> Format.fprintf fmt "TODO"

  let pp_symbol : type a. a option -> Format.formatter -> a Grammar.MenhirInterpreter.symbol -> unit =
    fun x fmt tx ->
    match x with
    | None -> pp_nonterminal fmt tx
    | Some x ->
        let open Grammar.MenhirInterpreter in
        match tx with
        | N N_decl -> Ast.Decl.pp fmt x
        | _ -> Format.fprintf fmt "TODO"

  type 'a terminal = 'a Grammar.MenhirInterpreter.terminal
  type 'a env = 'a Grammar.MenhirInterpreter.env
  type production = Grammar.MenhirInterpreter.production  
  (* the tokens the recovery may insert: closing brackets, and the final dot *)
  let token_of_terminal : type a. a Grammar.MenhirInterpreter.terminal -> (string * token) option =
    function
    | T_RPAREN -> Some (")", Tokens.RPAREN)
    | T_RBRACKET -> Some ("]", Tokens.RBRACKET)
    | T_RCURLY -> Some ("}", Tokens.RCURLY)
    | T_FULLSTOP -> Some (".", Tokens.FULLSTOP)
    | _ -> None
  (* DECL_ERROR_TOKEN is an error that only a declaration accepts: Mastic
     merges the stack into it up to the declaration, which becomes an error.
     It is marked by a piece Lex "\000", that survives the merges *)
  let decl_marker = "\000"
  let has_decl_marker e =
    List.exists (fun x -> Mastic.Error.unloc x = Mastic.Error.Lex decl_marker) e
  let match_error_token = function Tokens.ERROR_TOKEN x | Tokens.DECL_ERROR_TOKEN x -> Some x | _ -> None
  let build_error_token t = if has_decl_marker t then Tokens.DECL_ERROR_TOKEN t else Tokens.ERROR_TOKEN t
  let is_eof_token = function Tokens.EOF -> true | _ -> false
  let reduce_as_parse_error : type a. a -> a Grammar.MenhirInterpreter.symbol -> Lexing.position -> Lexing.position -> token =
    let open Grammar.MenhirInterpreter in
   fun x tx b e ->
    match tx with
    | N N_decl -> Tokens.ERROR_TOKEN Mastic.Error.(Ast.Decl.build_token (loc x b e))
    | N N_term -> Tokens.ERROR_TOKEN Mastic.Error.(Ast.Term.build_token (loc x b e))
    | N N_term_noconj -> Tokens.ERROR_TOKEN Mastic.Error.(Ast.Term.build_token (loc x b e))
    | N N_closed_term -> Tokens.ERROR_TOKEN Mastic.Error.(Ast.Term.build_token (loc x b e))
    | N N_head_term -> Tokens.ERROR_TOKEN Mastic.Error.(Ast.Term.build_token (loc x b e))
    | N N_open_term -> Tokens.ERROR_TOKEN Mastic.Error.(Ast.Term.build_token (loc x b e))
    | N N_open_term_noconj -> Tokens.ERROR_TOKEN Mastic.Error.(Ast.Term.build_token (loc x b e))
    | N N_binder_term -> Tokens.ERROR_TOKEN Mastic.Error.(Ast.Term.build_token (loc x b e))
    | N N_binder_term_noconj -> Tokens.ERROR_TOKEN Mastic.Error.(Ast.Term.build_token (loc x b e))
    | N N_clause_hd_term -> Tokens.ERROR_TOKEN Mastic.Error.(Ast.Term.build_token (loc x b e))
    | N N_clause_hd_closed_term -> Tokens.ERROR_TOKEN Mastic.Error.(Ast.Term.build_token (loc x b e))
    | N N_clause_hd_open_term -> Tokens.ERROR_TOKEN Mastic.Error.(Ast.Term.build_token (loc x b e))
    | N _ -> Tokens.ERROR_TOKEN Mastic.Error.(mkLexError (loc "TODO" b e))
    | T y -> Tokens.ERROR_TOKEN Mastic.Error.(mkLexError (loc (Format.asprintf "%a" (pp_symbol (Some x)) tx) b e))


  let is_term =
    let open Grammar.MenhirInterpreter in
    function
    | X (N N_term), _,_,_ -> true
    | _ -> false
  let is_decl_start =
    let open Grammar.MenhirInterpreter in
    function
    | X (N N_decl), _,_,0 -> true
    (* after a declaration, the kernel item is program -> decl . program *)
    | X (N N_program), _,_,1 -> true
    | _ -> false

  let handle_unexpected_token ~productions
       ~next_token
       ~acceptable_tokens
      ~reducible_productions
       ~generation_streak =
     let open Mastic.ErrorResilientParser in
     match reducible_productions with
     | p :: _ when List.exists is_term productions -> Reduce p
     | 
     _ ->
        (* finish the current declaration: reduce if possible, otherwise
           insert the final dot or a closing bracket if it fits, otherwise
           try the dot anyway, then a hole for a missing term, then close the
           declaration as an error *)
        let complete () =
          if generation_streak >= 10 then TurnIntoError else
          match reducible_productions with
          | p :: _ -> Reduce p
          | _ ->
          match List.find_opt (fun x -> x.t = Tokens.FULLSTOP) acceptable_tokens, acceptable_tokens with
          | Some x, _ | None, x :: _ -> GenerateToken x
          | None, [] ->
              (* the dot may still fit after empty reductions, that Mastic does
                 not see but Menhir performs: try it, unless the dot that does
                 not fit is one we generated (it has an empty span) *)
              if next_token.t <> Tokens.FULLSTOP then
                GenerateToken { s = "."; t = Tokens.FULLSTOP; b = next_token.b; e = next_token.b }
              (* a term may be missing before the dot *)
              else if generation_streak <= 1 then GenerateHole
              (* nothing finishes the declaration: it becomes an error *)
              else
                let b = next_token.b in
                GenerateToken { s = "(error)"; b; e = b;
                  t = Tokens.DECL_ERROR_TOKEN Mastic.Error.(mkLexError (loc decl_marker b b)) } in
        if List.exists is_decl_start productions then TurnIntoError
        else match next_token.t with
        | Tokens.FULLSTOP | Tokens.EOF -> complete ()
        | t when restart_point t next_token.b ->
            (* likely the beginning of the next declaration: finish the current
               one, and parsing restarts at this token *)
            complete ()
        | _ -> TurnIntoError
end

module ErProgram = Mastic.ErrorResilientParser.Make(Grammar.MenhirInterpreter)(ProgramParser)(Recovery)
module ErGoal = Mastic.ErrorResilientParser.Make(Grammar.MenhirInterpreter)(GoalParser)(Recovery)

(* consecutive errors are merged into one *)
let rec merge_errors = function
  | Ast.Decl.Error x :: Ast.Decl.Error y :: rest -> merge_errors (Ast.Decl.Error (Mastic.Error.merge x y) :: rest)
  | d :: rest -> d :: merge_errors rest
  | [] -> []

(* the errors of the lexer, recorded by Lexer.errors, are added to the ones of
   the parser; errs is in reverse order, as returned by Mastic *)
let with_lex_errors f lexbuf =
  (* an accumulate parses another file in the middle of this one *)
  let saved = !Lexer.errors, !Ast.Term.deferred, !Ast.Term.deferring in
  let restore () =
    let l, d, b = saved in Lexer.errors := l; Ast.Term.deferred := d; Ast.Term.deferring := b in
  Lexer.errors := []; Ast.Term.deferred := []; Ast.Term.deferring := true;
  let errs, comps, ast = try f lexbuf with e -> restore (); raise e in
  let lex = List.map (fun (p,m) -> Mastic.ErrorResilientParser.LexError(p,m)) !Lexer.errors in
  let deferred = List.rev !Ast.Term.deferred in
  restore ();
  (* the errors of the semantic actions are reported as lexical ones *)
  let lexing_pos { Util.Loc.source_name; line; line_starts_at; source_start; _ } =
    { Lexing.pos_fname = source_name; pos_lnum = line; pos_bol = line_starts_at; pos_cnum = source_start } in
  let sem = List.filter_map (function
    | Ast.Term.NotInProlog(loc,m) | Parser_config.ParseError(loc,m) ->
        Some (Mastic.ErrorResilientParser.LexError(lexing_pos loc, m))
    | Failure m -> Some (Mastic.ErrorResilientParser.LexError(lexbuf.Lexing.lex_start_p, m))
    | _ -> None) deferred in
  let pos = function Mastic.ErrorResilientParser.LexError(p,_) | ParseError(p,_) -> p.Lexing.pos_cnum in
  let errs = List.stable_sort (fun x y -> compare (pos y) (pos x)) (sem @ lex @ errs) in
  (* the recovery may meet the same error several times: one per position *)
  let rec dedup = function
    | x :: (y :: _ as rest) when pos x = pos y -> dedup (x :: List.tl rest)
    | x :: rest -> x :: dedup rest
    | [] -> [] in
  let errs = List.rev (dedup (List.rev errs)) in
  errs, comps, ast, deferred

let parse_program lexbuf =
  let errs, comps, ast, deferred = with_lex_errors ErProgram.parse lexbuf in
  errs, comps, merge_errors ast, deferred
let () = Mastic.ErrorResilientParser.debug := Sys.getenv_opt "MASTIC_DEBUG" <> None
let e2e = function
  | Mastic.ErrorResilientParser.LexError(loc,msg) ->
      let loc = {
        Util.Loc.client_payload = None;
        source_name = loc.Lexing.pos_fname;
        line = loc.Lexing.pos_lnum;
        line_starts_at = loc.Lexing.pos_bol;
        source_start = loc.Lexing.pos_cnum;
        source_stop = loc.Lexing.pos_cnum;
      } in
      (loc,msg)
  | Mastic.ErrorResilientParser.ParseError(loc,state_id) ->
      let message = message_of_state state_id in
      let loc = {
        Util.Loc.client_payload = None;
        source_name = loc.Lexing.pos_fname;
        line = loc.Lexing.pos_lnum;
        line_starts_at = loc.Lexing.pos_bol;
        source_start = loc.Lexing.pos_cnum;
        source_stop = loc.Lexing.pos_cnum;
      } in
      (loc,message)

let c2c (loc,msg) =
      let loc = {
        Util.Loc.client_payload = None;
        source_name = loc.Lexing.pos_fname;
        line = loc.Lexing.pos_lnum;
        line_starts_at = loc.Lexing.pos_bol;
        source_start = loc.Lexing.pos_cnum;
        source_stop = loc.Lexing.pos_cnum;
      } in
      (loc,"Completed with token " ^ msg)

let raise_err (errs, compl, ast, deferred) =
  (* an error of a semantic action is raised as is, as without recovery *)
  match deferred with e :: _ -> raise e | [] ->
  match List.map e2e (List.rev errs) @ List.map c2c compl with
  | [] -> ast
  | (loc,msg) :: l ->
      raise (Parser_config.ParseError(loc, String.concat "\n" (msg :: List.map snd l)))

(*
let parse grammar lexbuf =
  let buffer, lexer = MenhirLib.ErrorReports.wrap Lexer.(token C.versions) in
  try
    grammar lexer lexbuf
  with
  | Ast.Term.NotInProlog(loc,message) ->
      raise (Parser_config.ParseError(loc,message^"\n"))
  | Lexer.Error(loc,message) ->
    let loc = {
      Util.Loc.client_payload = None;
      source_name = loc.Lexing.pos_fname;
      line = loc.Lexing.pos_lnum;
      line_starts_at = loc.Lexing.pos_bol;
      source_start = loc.Lexing.pos_cnum;
      source_stop = loc.Lexing.pos_cnum;
    } in
    raise (Parser_config.ParseError(loc,message))
  | Grammar.Error stateid ->
    let message = message_of_state stateid in
    let loc = lexbuf.Lexing.lex_curr_p in
    let loc = {
      Util.Loc.client_payload = None;
      source_name = loc.Lexing.pos_fname;
      line = loc.Lexing.pos_lnum;
      line_starts_at = loc.Lexing.pos_bol;
      source_start = loc.Lexing.pos_cnum;
      source_stop = loc.Lexing.pos_cnum;
    } in
    raise (Parser_config.ParseError(loc,message)) *)

let already_parsed = Hashtbl.create 11

let cleanup_fname filename = Re.Str.replace_first (Re.Str.regexp "/_build/[^/]+") "" filename

let () =
  parse_ref := (fun ?cwd filename ->
  let filename = C.resolver ?cwd ~unit:filename () in
  let digest = Digest.file filename in
  let to_parse =
    if Filename.extension filename = ".mod" then
      let sigf = Filename.chop_extension filename ^ ".sig" in
      if Sys.file_exists sigf then [sigf,Digest.file sigf;filename,digest]
      else [filename,digest]
    else [filename,digest] in
  to_parse |> List.map (fun (filename,digest) ->
    if Hashtbl.mem already_parsed digest then
      { Ast.Decl.file_name = filename; digest; ast = [] }
    else
      let ic = open_in filename in
      (* the whole file is in the buffer, so that the lexer can go back *)
      let lexbuf = Lexing.from_string (really_input_string ic (in_channel_length ic)) in
      let dest = cleanup_fname filename in
      lexbuf.Lexing.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = dest };
      Hashtbl.add already_parsed digest true;
      let ast = raise_err @@ parse_program lexbuf in
      (* let ast = parse Grammar.program lexbuf in *)
      close_in ic;
      { file_name = filename; digest; ast }))

let to_lexing_loc { Util.Loc.source_name; line; line_starts_at; source_start; _ } =
  { Lexing.pos_fname = source_name;
    pos_lnum = line;
    pos_bol = line_starts_at;
    pos_cnum = source_start; }
  
let lexing_set_position lexbuf loc =
  Option.iter ParseFile.set_current_clent_loc_pyload loc.Util.Loc.client_payload;
  let loc = to_lexing_loc loc in
  let open Lexing in
  lexbuf.lex_abs_pos <- loc.pos_cnum;
  lexbuf.lex_start_p <- loc;
  lexbuf.lex_curr_p <- loc
  
let goal_from ~loc lexbuf =
  lexing_set_position lexbuf loc;
  raise_err @@ with_lex_errors ErGoal.parse lexbuf
  (* parse Grammar.goal lexbuf *)
      
let goal ~loc ~text =
  let lexbuf = Lexing.from_string text in
  goal_from ~loc lexbuf

let program_from ~loc lexbuf =
  Hashtbl.clear already_parsed;
  lexing_set_position lexbuf loc;
  raise_err @@ parse_program lexbuf
  (* parse Grammar.program lexbuf *)

let program ~file =
  Hashtbl.clear already_parsed;
  List.(concat (map (fun { Ast.Decl.ast = x } -> x) @@ !parse_ref file))

module Internal = struct
let infix_SYMB = Grammar.infix_SYMB
let prefix_SYMB = Grammar.prefix_SYMB
let postfix_SYMB = Grammar.postfix_SYMB
(* When there are errors, the file is parsed a second time with strings that
   cannot span lines: a string whose closing quote is missing otherwise runs
   to the next string, maybe far away. The result with more declarations that
   are not errors is kept. *)
let program_resilient lexbuf =
  let copy = { lexbuf with Lexing.lex_buffer = Bytes.copy lexbuf.Lexing.lex_buffer } in
  let errs, comps, ast, _ = parse_program lexbuf in
  if errs = [] && comps = [] then errs, comps, ast else
  let good ast = List.length (List.filter (function Ast.Decl.Error _ -> false | _ -> true) ast) in
  Lexer.single_line_strings := true;
  let errs2, comps2, ast2, _ =
    Fun.protect ~finally:(fun () -> Lexer.single_line_strings := false) (fun () -> parse_program copy) in
  if good ast2 > good ast then errs2, comps2, ast2 else errs, comps, ast
end

end