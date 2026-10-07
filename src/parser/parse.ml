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
  val program_from : loc:Util.Loc.t -> digest:Digest.t -> Lexing.lexbuf -> Ast.Program.t
end

module type Parser_w_Internals = sig
  include Parser

  module Internal : sig
    val infix_SYMB : (Lexing.lexbuf -> Tokens.token) -> Lexing.lexbuf -> Ast.Func.t
    val prefix_SYMB : (Lexing.lexbuf -> Tokens.token) -> Lexing.lexbuf -> Ast.Func.t
    val postfix_SYMB : (Lexing.lexbuf -> Tokens.token) -> Lexing.lexbuf -> Ast.Func.t

    (* error-resilient parsing, with Mastic: never fails, the errors are
       returned with the tokens inserted by the recovery *)
    val program_resilient : Lexing.lexbuf ->
      Mastic.ErrorResilientParser.error list * Mastic.ErrorResilientParser.completion list * Ast.Program.decl list
  end
end

module type Config = sig
  val versions : (int * int * int) Util.StrMap.t
  val resolver : ?cwd:string -> unit:string -> unit -> string

end

module Make(C : Config) = struct
  
let parse_ref : (?cwd:string -> string -> Ast.Program.t) ref =
  ref (fun ?cwd:_ _ -> assert false)
  

module ParseFile = struct
  let parse_file ?cwd file = !parse_ref ?cwd file
  let client_payload : Obj.t option ref = ref None
  let set_current_clent_loc_pyload x = client_payload := Some x
  let get_current_client_loc_payload () = !client_payload

end

module Grammar = Grammar.Make(ParseFile)
  
let message_of_state s = try Error_messages.message s with Not_found -> "syntax error"

let raise_parse_error lexbuf stateid =
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
  raise (Parser_config.ParseError(loc,message))

let parse grammar lexbuf =
  let buffer, lexer = MenhirLib.ErrorReports.wrap Lexer.(token C.versions) in
  try
    Grammar.MenhirInterpreter.loop_handle
     (fun x -> x)
     (function (HandlingError e) -> raise_parse_error lexbuf Grammar.MenhirInterpreter.(current_state_number e) | _ -> assert false)
     (Grammar.MenhirInterpreter.lexer_lexbuf_to_supplier lexer lexbuf)
     (grammar lexbuf.lex_curr_p)
    (* grammar lexer lexbuf *)
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
  (* | Grammar.Error stateid -> raise_parse_error lexbuf stateid *)

(* Error-resilient parsing, with Mastic ---------------------------------- *)

module ProgramParser = struct
  type ast = Ast.Program.decl list
  type 'a checkpoint = 'a Grammar.MenhirInterpreter.checkpoint
  let main = Grammar.Incremental.program
  type token = Tokens.token
  let token = Lexer.token C.versions
end

module Recovery = struct
  type token = Tokens.token
  let show_token _ = ""
  type 'a symbol = 'a Grammar.MenhirInterpreter.symbol
  type xsymbol = Grammar.MenhirInterpreter.xsymbol
  type 'a terminal = 'a Grammar.MenhirInterpreter.terminal
  type 'a env = 'a Grammar.MenhirInterpreter.env
  type production = Grammar.MenhirInterpreter.production

  let pp_symbol : type a. a option -> Format.formatter -> a symbol -> unit =
    fun x fmt s ->
    let open Grammar.MenhirInterpreter in
    match x, s with
    | Some x, N N_decl -> Ast.Program.pp_decl fmt x
    | _ -> Format.fprintf fmt "_"

  (* DECL_ERROR_TOKEN is an error that only a declaration accepts: Mastic
     merges the stack into it up to the declaration, which becomes an error.
     It is marked by a piece Lex "\000", that survives the merges *)
  let decl_marker = "\000"
  let has_decl_marker e =
    List.exists (fun x -> Mastic.Error.unloc x = Mastic.Error.Lex decl_marker) e
  let match_error_token = function Tokens.ERROR_TOKEN x | Tokens.DECL_ERROR_TOKEN x -> Some x | _ -> None
  let build_error_token t = if has_decl_marker t then Tokens.DECL_ERROR_TOKEN t else Tokens.ERROR_TOKEN t
  let is_eof_token = function Tokens.EOF -> true | _ -> false

  (* the tokens the recovery may insert: closing brackets, and the final dot *)
  let token_of_terminal : type a. a terminal -> (string * token) option = function
    | T_RPAREN -> Some (")", Tokens.RPAREN)
    | T_RBRACKET -> Some ("]", Tokens.RBRACKET)
    | T_RCURLY -> Some ("}", Tokens.RCURLY)
    | T_FULLSTOP -> Some (".", Tokens.FULLSTOP)
    | _ -> None

  (* a token at the beginning of a line, or a keyword that begins a
     declaration, is a good point to restart parsing *)
  let restart_point t (p : Lexing.position) =
    p.pos_cnum = p.pos_bol ||
    match t with
    | Tokens.PRED | Tokens.FUNC | Tokens.TYPE | Tokens.KIND | Tokens.NAMESPACE
    | Tokens.TYPEABBREV | Tokens.ACCUMULATE | Tokens.SHORTEN | Tokens.MACRO
    | Tokens.CONSTRAINT | Tokens.RULE -> true
    | _ -> false

  (* An item of the stack folded into an error keeps its content: terms,
     types, attributes and declarations become the error nodes of their
     type, the elements of lists are kept one by one, names and strings
     are kept as text *)
  let pos_of_loc { Util.Loc.source_name; line; line_starts_at; source_start; source_stop; _ } =
    let p n = { Lexing.pos_fname = source_name; pos_lnum = line; pos_bol = line_starts_at; pos_cnum = n } in
    p source_start, p source_stop
  let term (t : Ast.Term.t) = let b, e = pos_of_loc t.loc in Ast.Term.build_token (Mastic.Error.loc t b e)
  let ty (t : Ast.raw_attribute list Ast.TypeExpression.t) =
    let b, e = pos_of_loc t.tloc in Ast.TypeExpression.build_token (Mastic.Error.loc t b e)
  let text s b e = Mastic.Error.(mkLexError (loc s b e))
  let all f l b e = match List.map f l with [] -> text "" b e | x :: xs -> List.fold_left Mastic.Error.merge x xs

  let reduce_as_parse_error : type a. a -> a symbol -> Lexing.position -> Lexing.position -> token =
    let open Grammar.MenhirInterpreter in
    fun x s b e ->
    Tokens.ERROR_TOKEN (match s with
    | N N_decl -> Ast.Program.build_token (Mastic.Error.loc x b e)
    | N N_ignored -> Ast.Program.build_token (Mastic.Error.loc x b e)
    | N N_term ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_term_noconj ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_closed_term ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_head_term ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_open_term ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_open_term_noconj ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_binder_term ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_binder_term_noconj ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_goal ->
        Ast.Term.build_token (Mastic.Error.loc x b e)
    | N N_clause_hd_term ->
        Ast.Term.build_token (Mastic.Error.loc (snd x) b e)
    | N N_clause_hd_closed_term ->
        Ast.Term.build_token (Mastic.Error.loc (snd x) b e)
    | N N_clause_hd_open_term ->
        Ast.Term.build_token (Mastic.Error.loc (snd x) b e)
    | N N_binder_body -> let _, _, t = x in term t
    | N N_binder_body_no_ty -> let _, _, t = x in term t
    | N N_list_closed_term_ ->
        all term x b e
    | N N_nonempty_list_closed_term_ ->
        all term x b e
    | N N_list_items ->
        all term x b e
    | N N_list_items_tail ->
        all term x b e
    | N N_type_term ->
        Ast.TypeExpression.build_token (Mastic.Error.loc x b e)
    | N N_atype_term ->
        Ast.TypeExpression.build_token (Mastic.Error.loc x b e)
    | N N_fotype_term ->
        Ast.TypeExpression.build_token (Mastic.Error.loc x b e)
    | N N_kind_term ->
        Ast.TypeExpression.build_token (Mastic.Error.loc x b e)
    | N N_anonymous_pred ->
        Ast.TypeExpression.build_token (Mastic.Error.loc x b e)
    | N N_nonempty_list_atype_term_ -> all ty x b e
    | N N_separated_nonempty_list_CONJ_fotype_term_ -> all ty x b e
    | N N_loption_separated_nonempty_list_CONJ_fotype_term__ -> all ty x b e
    | N N_option_type_term_ -> (match x with Some t -> ty t | None -> text "" b e)
    | N N_pred_item -> ty (snd x)
    | N N_attribute -> Ast.attribute_build_token (Mastic.Error.loc x b e)
    | N N_attributes ->
        all (fun a -> Ast.attribute_build_token (Mastic.Error.loc a b e)) x b e
    | N N_separated_nonempty_list_COLON_attribute_ ->
        all (fun a -> Ast.attribute_build_token (Mastic.Error.loc a b e)) x b e
    | N N_pred_or_func ->
        all (fun a -> Ast.attribute_build_token (Mastic.Error.loc a b e)) x b e
    | N N_constant ->
        text (Ast.Func.show x) b e
    | N N_infix_SYMB ->
        text (Ast.Func.show x) b e
    | N N_prefix_SYMB ->
        text (Ast.Func.show x) b e
    | N N_postfix_SYMB ->
        text (Ast.Func.show x) b e
    | N N_mixfix_SYMB ->
        text (Ast.Func.show x) b e
    | N N_constant_w_loc -> text (Ast.Func.show (fst x)) b e
    | N N_list_constant_ ->
        text (String.concat ", " (List.map Ast.Func.show x)) b e
    | N N_separated_nonempty_list_CONJ_constant_ ->
        text (String.concat ", " (List.map Ast.Func.show x)) b e
    | N N_filename -> text x b e
    | N N_accumulate -> text x b e
    | N N_external_ref -> text x b e
    | N N_separated_nonempty_list_CONJ_filename_ -> text (String.concat ", " x) b e
    | _ -> text "" b e)

  let is_term =
    let open Grammar.MenhirInterpreter in
    function X (N N_term), _,_,_ -> true | _ -> false

  (* the state waits for a term or a type: an item expects one next, and no
     item is complete *)
  let expects_term_or_type productions =
    let open Grammar.MenhirInterpreter in
    let next (_, rhs, _, pos) = List.nth_opt rhs pos in
    List.for_all (fun i -> next i <> None) productions &&
    List.exists (fun i -> match next i with
      | Some (X (N (N_term | N_term_noconj | N_closed_term | N_head_term
                   | N_type_term | N_atype_term | N_fotype_term | N_kind_term))) -> true
      | _ -> false) productions

  let is_decl_start =
    let open Grammar.MenhirInterpreter in
    function
    | X (N N_decl), _,_,0 -> true
    (* after a declaration, the kernel item is program -> decl . program *)
    | X (N N_program), _,_,1 -> true
    | _ -> false

  let handle_unexpected_token ~productions ~next_token ~acceptable_tokens
      ~reducible_productions ~generation_streak =
    let open Mastic.ErrorResilientParser in
    (* finish the current declaration: reduce if possible, otherwise insert
       the final dot or a closing bracket if it fits, otherwise try the dot
       anyway (Menhir may accept it after empty reductions, that Mastic does
       not list), then a hole for a missing term, and finally make the
       declaration an error *)
    let finish () =
      match reducible_productions with
      | p :: _ -> Reduce p
      | [] ->
      match List.find_opt (fun x -> x.t = Tokens.FULLSTOP) acceptable_tokens, acceptable_tokens with
      | Some x, _ | None, x :: _ -> GenerateToken x
      | None, [] ->
          if next_token.t <> Tokens.FULLSTOP then
            GenerateToken { s = "."; t = Tokens.FULLSTOP; b = next_token.b; e = next_token.b }
          else if generation_streak <= 1 then GenerateHole
          else
            let b = next_token.b in
            GenerateToken { s = "(error)"; b; e = b;
              t = Tokens.DECL_ERROR_TOKEN Mastic.Error.(mkLexError (loc decl_marker b b)) } in
    if generation_streak >= 10 || List.exists is_decl_start productions then TurnIntoError
    else if reducible_productions = [] && generation_streak = 0 && expects_term_or_type productions then
      (* a term (or a type) is missing: an error node takes its place, as
         in X is + 2, read X is Err + 2 *)
      GenerateHole
    else match next_token.t with
    | Tokens.FULLSTOP | Tokens.EOF -> finish ()
    | t when restart_point t next_token.b -> finish ()
    | _ ->
    match reducible_productions with
    | p :: _ when List.exists is_term productions -> Reduce p
    | _ -> TurnIntoError
end

module ErProgram = Mastic.ErrorResilientParser.Make(Grammar.MenhirInterpreter)(ProgramParser)(Recovery)

let () = Mastic.ErrorResilientParser.debug := Sys.getenv_opt "MASTIC_DEBUG" <> None

(* consecutive declaration errors are merged into one *)
let rec merge_errors = function
  | Ast.Program.Error x :: Ast.Program.Error y :: rest -> merge_errors (Ast.Program.Error (Mastic.Error.merge x y) :: rest)
  | d :: rest -> d :: merge_errors rest
  | [] -> []

(* One resilient parse: the lexer returns error tokens and the semantic
   actions defer their errors; these errors are added to the ones of Mastic,
   one per position. An accumulate parses (normally) another file in the
   middle of this one, hence the saving of the flags. *)
let resilient_parse lexbuf =
  let saved = !Lexer.recovering, !Lexer.errors, !Ast.Term.deferring, !Ast.Term.deferred in
  let restore () =
    let r, l, d, dl = saved in
    Lexer.recovering := r; Lexer.errors := l; Ast.Term.deferring := d; Ast.Term.deferred := dl in
  Lexer.recovering := true; Lexer.errors := []; Ast.Term.deferring := true; Ast.Term.deferred := [];
  let errs, comps, ast = Fun.protect ~finally:restore (fun () ->
    let errs, comps, ast = ErProgram.parse lexbuf in
    let lexing_pos { Util.Loc.source_name; line; line_starts_at; source_start; _ } =
      { Lexing.pos_fname = source_name; pos_lnum = line; pos_bol = line_starts_at; pos_cnum = source_start } in
    let sem = List.filter_map (function
      | Ast.Term.NotInProlog(loc,m) | Parser_config.ParseError(loc,m) ->
          Some (Mastic.ErrorResilientParser.LexError(lexing_pos loc, m))
      | Failure m -> Some (Mastic.ErrorResilientParser.LexError(lexbuf.Lexing.lex_start_p, m))
      | _ -> None) !Ast.Term.deferred in
    let lex = List.map (fun (p,m) -> Mastic.ErrorResilientParser.LexError(p,m)) !Lexer.errors in
    sem @ lex @ errs, comps, ast) in
  (* errs is in reverse order, as returned by Mastic *)
  let pos = function Mastic.ErrorResilientParser.LexError(p,_) | ParseError(p,_) -> p.Lexing.pos_cnum in
  let errs = List.stable_sort (fun x y -> compare (pos y) (pos x)) errs in
  let rec dedup = function
    | x :: (y :: _ as rest) when pos x = pos y -> dedup (x :: List.tl rest)
    | x :: rest -> x :: dedup rest
    | [] -> [] in
  List.rev (dedup (List.rev errs)), comps, merge_errors ast

(* When there are errors, the text is parsed a second time with strings that
   cannot span lines: a string whose closing quote is missing otherwise runs
   to the next string, maybe far away. The result with more declarations that
   are not errors is kept. The lexbuf must hold the whole text. *)
let program_resilient lexbuf =
  let copy = { lexbuf with Lexing.lex_buffer = Bytes.copy lexbuf.Lexing.lex_buffer } in
  let errs, comps, ast = resilient_parse lexbuf in
  if errs = [] && comps = [] then errs, comps, ast else
  let good ast = List.length (List.filter (function Ast.Program.Error _ -> false | _ -> true) ast) in
  Lexer.single_line_strings := true;
  let errs2, comps2, ast2 =
    Fun.protect ~finally:(fun () -> Lexer.single_line_strings := false) (fun () -> resilient_parse copy) in
  if good ast2 > good ast then errs2, comps2, ast2 else errs, comps, ast

(* ------------------------------------------------------------------------- *)

let already_parsed = Hashtbl.create 11

let cleanup_fname filename = Re.Str.replace_first (Re.Str.regexp "/_build/[^/]+") "" filename

let parse_one_file digest filename =
  if Hashtbl.mem already_parsed digest then
    Hashtbl.find already_parsed digest
  else 
    let ic = open_in filename in
    let lexbuf = Lexing.from_channel ic in
    let dest = cleanup_fname filename in
    lexbuf.Lexing.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = dest };
    let ast = parse Grammar.Incremental.program lexbuf in
    let output = { Ast.file_name = filename; deps = []; digest; ast } in
    Hashtbl.add already_parsed digest output;
    close_in ic;
    output

let () =
  parse_ref := (fun ?cwd filename ->
  let filename = C.resolver ?cwd ~unit:filename () in
  let digest = Digest.file filename in
  if Filename.extension filename = ".mod" then
    (* Teyjus compatibility *)
    let sig_filename = Filename.chop_extension filename ^ ".sig" in
    if Sys.file_exists sig_filename then
      let ds = Digest.file sig_filename in
      let s = parse_one_file ds sig_filename in
      let m = parse_one_file digest filename in
      { Ast.file_name = filename; digest = Digest.string (ds^digest); deps = []; ast = s.ast @ m.ast  }
    else parse_one_file digest filename
  else parse_one_file digest filename)

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
  parse Grammar.Incremental.goal lexbuf
      
let goal ~loc ~text =
  let lexbuf = Lexing.from_string text in
  goal_from ~loc lexbuf

let program_from ~loc ~digest lexbuf =
  Hashtbl.clear already_parsed;
  lexing_set_position lexbuf loc;
  let ast = parse Grammar.Incremental.program lexbuf in
  let filename = let open Util.Loc in
    Printf.sprintf "%s:%d:%d" loc.source_name loc.source_stop lexbuf.Lexing.lex_curr_pos in
  { Ast.file_name = filename; deps = []; digest; ast }


let program ~file =
  Hashtbl.clear already_parsed;
  !parse_ref file

module Internal = struct
let infix_SYMB = Grammar.infix_SYMB
let prefix_SYMB = Grammar.prefix_SYMB
let postfix_SYMB = Grammar.postfix_SYMB
let program_resilient = program_resilient
end

end