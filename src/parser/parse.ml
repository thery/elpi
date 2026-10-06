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

(* Panic mode: after an error, the tokens up to the next full stop, or up to
   the next token at the beginning of a line, are turned into errors, so that
   the rest of a broken clause is not parsed as a new clause *)
let skipping = ref false

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

let error_token lexbuf =
  Tokens.ERROR_TOKEN Mastic.Error.(mkLexError
    (loc (Lexing.lexeme lexbuf) lexbuf.Lexing.lex_start_p lexbuf.Lexing.lex_curr_p))

module ProgramParser = struct
  type ast = Ast.Program.t
  type 'a checkpoint = 'a Grammar.MenhirInterpreter.checkpoint

  let main = Grammar.Incremental.program

  type token = Grammar.token

  let token lexbuf =
    let t = Lexer.token C.versions lexbuf in
    if not !skipping then t
    else match t with
      | Tokens.EOF -> skipping := false; t
      | Tokens.FULLSTOP -> skipping := false; error_token lexbuf
      | _ when restart_point t lexbuf.Lexing.lex_start_p -> skipping := false; t
      | _ -> error_token lexbuf
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
  let match_error_token = function Tokens.ERROR_TOKEN x -> Some x | _ -> None
  let build_error_token t = Tokens.ERROR_TOKEN t
  let is_eof_token = function Tokens.EOF -> true | _ -> false
  let reduce_as_parse_error : type a. a -> a Grammar.MenhirInterpreter.symbol -> Lexing.position -> Lexing.position -> token =
    let open Grammar.MenhirInterpreter in
   fun x tx b e ->
    match tx with
    | N N_decl -> Tokens.ERROR_TOKEN Mastic.Error.(Ast.Decl.build_token (loc x b e))
    | N _ -> Tokens.ERROR_TOKEN Mastic.Error.(mkLexError (loc "TODO" b e))
    | T y -> Tokens.ERROR_TOKEN Mastic.Error.(mkLexError (loc (Format.asprintf "%a" (pp_symbol (Some x)) tx) b e))


  let complete () = Mastic.ErrorResilientParser.TurnIntoError

  let is_term =
    let open Grammar.MenhirInterpreter in
    function
    | X (N N_term), _,_,_ -> true
    | _ -> false
  let is_decl_start =
    let open Grammar.MenhirInterpreter in
    function
    | X (N N_decl), _,_,0 -> true
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
        match next_token.t with
        | Tokens.FULLSTOP | Tokens.EOF when acceptable_tokens <> [] && generation_streak < 10 ->
            (* complete the declaration: close the open brackets (and add the
               final dot at the end of the file) *)
            GenerateToken (List.hd acceptable_tokens)
        | Tokens.EOF when generation_streak < 10 ->
            (* the current declaration becomes an error, then EOF fits *)
            GenerateHole
        | Tokens.FULLSTOP | Tokens.EOF -> complete ()
        | t when restart_point t next_token.b && generation_streak < 3
                 && not (List.exists is_decl_start productions) ->
            (* likely the beginning of the next declaration: the current one
               becomes an error, and parsing restarts at this token *)
            GenerateHole
        | _ -> skipping := true; TurnIntoError
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
  Lexer.errors := [];
  let errs, comps, ast = f lexbuf in
  let lex = List.map (fun (p,m) -> Mastic.ErrorResilientParser.LexError(p,m)) !Lexer.errors in
  Lexer.errors := [];
  let pos = function Mastic.ErrorResilientParser.LexError(p,_) | ParseError(p,_) -> p.Lexing.pos_cnum in
  let errs = List.stable_sort (fun x y -> compare (pos y) (pos x)) (lex @ errs) in
  errs, comps, ast

let parse_program lexbuf =
  skipping := false;
  let errs, comps, ast = with_lex_errors ErProgram.parse lexbuf in
  errs, comps, merge_errors ast
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

let raise_err (errs, compl, ast) =
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
let program_resilient lexbuf = parse_program lexbuf
end

end