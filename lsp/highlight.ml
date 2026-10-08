(* Semantic tokens: the colors of a document, from Elpi's lexer and from what
   the parser and the compiler know, instead of regular expressions.

   The text is lexed by Elpi's lexer in recovering mode (it never fails, also
   on broken text); comments are found in the gaps between tokens. A token is
   classified by its kind (keywords, operators, strings, numbers), and a name
   by the hover information of the compiled program (Checker.hover):
   - in a type expression of a declaration: a type, or a type parameter for a
     type variable;
   - a symbol whose type is pred or func: a function (a predicate);
   - a symbol without definition (bound by a lambda): a parameter;
   - another symbol: a constant (enumMember);
   and, without that information (e.g. the text does not compile), by its
   context: the name after pred/func is a function, after type a constant,
   after kind/typeabbrev a type, an uppercase name a variable. *)

open Elpi_lexer_config

type kind =
  | Keyword | Function | Variable | Parameter | Type | TypeParameter
  | String | Number | Comment | Operator | Constant

(* the legend sent at initialization: the index of a kind in it is its code *)
let legend =
  [ "keyword"; "function"; "variable"; "parameter"; "type"; "typeParameter";
    "string"; "number"; "comment"; "operator"; "enumMember" ]

let code = function
  | Keyword -> 0 | Function -> 1 | Variable -> 2 | Parameter -> 3 | Type -> 4
  | TypeParameter -> 5 | String -> 6 | Number -> 7 | Comment -> 8
  | Operator -> 9 | Constant -> 10

(* --- lexing ----------------------------------------------------------------- *)

(* the tokens of the text, as (start, stop, token), byte offsets *)
let lex text =
  let module L = Elpi_parser.Lexer in
  let saved = !L.recovering, !L.errors in
  L.recovering := true;
  Fun.protect ~finally:(fun () -> let r, e = saved in L.recovering := r; L.errors := e)
    (fun () ->
      let lexbuf = Lexing.from_string text in
      let rec go acc =
        match L.token Elpi_util.Util.StrMap.empty lexbuf with
        | Tokens.EOF -> List.rev acc
        | t -> go ((lexbuf.Lexing.lex_start_p.pos_cnum, lexbuf.Lexing.lex_curr_p.pos_cnum, t) :: acc)
        | exception _ -> List.rev acc in
      go [])

(* the kind of a token; names are classified later *)
let token_kind : Tokens.token -> [ `Name of string | `Kind of kind | `Skip ] = function
  | CONSTANT s -> `Name s
  | STRING _ | QUOTED _ -> `Kind String
  | INTEGER _ | FLOAT _ -> `Kind Number
  | NIL -> `Kind Constant
  | VDASH | QDASH | ARROW | DARROW | DDARROW | DDARROWBANG | DIV | MOD | IS
  | MINUS | MINUSr | MINUSi | MINUSs | CONS | CONJ2 | OR | EQ | EQ2 | IFF | SLASH | RTRI
  | FAMILY_PLUS _ | FAMILY_TIMES _ | FAMILY_MINUS _ | FAMILY_EXP _ | FAMILY_LT _
  | FAMILY_GT _ | FAMILY_EQ _ | FAMILY_QMARK _ | FAMILY_BTICK _ | FAMILY_TICK _
  | FAMILY_SHARP _ | FAMILY_TILDE _ | FAMILY_AND _ | FAMILY_OR _ -> `Kind Operator
  | FULLSTOP | COLON | BIND | LPAREN | RPAREN | LBRACKET | RBRACKET | LCURLY | RCURLY
  | PIPE | CONJ | DOTS | FRESHUV | ERROR_TOKEN _ | DECL_ERROR_TOKEN _ | EOF -> `Skip
  | _ -> `Kind Keyword (* pred, type, kind, namespace, pi, sigma, mode i:/o:, attributes, … *)

(* --- names -------------------------------------------------------------------- *)

let is_variable s = s <> "" && (s.[0] = '_' || (s.[0] >= 'A' && s.[0] <= 'Z'))

let starts_with p s = String.length s >= String.length p && String.sub s 0 (String.length p) = p

(* the kind of the name [s] at [b, e), from the hover information and the
   previous token *)
let classify_name ~path ~hover ~prev b e s =
  let here =
    match hover with
    | None -> []
    | Some h -> List.filter (fun ((l : Elpi.API.Ast.Loc.t), _, _) -> l.source_start = b) (Checker.entries ~path b h) in
  (* the entries of the name itself; a type constructor applied to arguments
     has an entry for the whole application, starting at the name *)
  let exact = List.filter (fun ((l : Elpi.API.Ast.Loc.t), _, _) -> l.source_stop = e) here in
  let text_is l p = List.exists (fun (_, t, _) -> match t with Some t -> p t | None -> false) l in
  (* a type whose result is pred or func *)
  let pred_type t =
    let t = String.trim t in
    let ends_with p = String.length t >= String.length p &&
                      String.sub t (String.length t - String.length p) (String.length p) = p in
    let t' = if starts_with "(" t then String.sub t 1 (String.length t - 1) else t in
    starts_with "pred" t' || starts_with "func" t' || ends_with "(pred)" || ends_with "(func)"
    || ends_with "-> pred" || ends_with "-> func" in
  if text_is here (fun t -> starts_with (s ^ " : type (a type variable)") t) then TypeParameter
  else if text_is here (fun t -> starts_with (s ^ " : type") t) then Type
  else if is_variable s then Variable
  else if text_is exact pred_type then Function
  else
    match exact with
    | (_, _, None) :: _ -> if is_variable s then Variable else Parameter
    | (_, _, Some _) :: _ -> if is_variable s then Variable else Constant
    | [] ->
        match prev with
        | Some (Tokens.PRED | Tokens.FUNC) -> Function
        | Some (Tokens.TYPE | Tokens.SYMBOL) -> Constant
        | Some (Tokens.KIND | Tokens.TYPEABBREV) -> Type
        (* the head of a clause (a name starting a declaration) and the
           first goal of its body are predicates *)
        | None | Some (Tokens.FULLSTOP | Tokens.VDASH) -> if is_variable s then Variable else Function
        | _ -> if is_variable s then Variable else Constant

(* --- comments ----------------------------------------------------------------- *)

(* the comments in [text] between [b] and [e] (a gap between two tokens) *)
let comments text b e =
  let acc = ref [] in
  let i = ref b in
  while !i < e do
    if text.[!i] = '%' then begin
      let j = ref !i in
      while !j < e && text.[!j] <> '\n' do incr j done;
      acc := (!i, !j, Comment) :: !acc; i := !j
    end else if !i + 1 < e && text.[!i] = '/' && text.[!i + 1] = '*' then begin
      let j = ref (!i + 2) and depth = ref 1 in
      while !j < e && !depth > 0 do
        if !j + 1 < e && text.[!j] = '*' && text.[!j + 1] = '/' then (decr depth; j := !j + 2)
        else if !j + 1 < e && text.[!j] = '/' && text.[!j + 1] = '*' then (incr depth; j := !j + 2)
        else incr j
      done;
      acc := (!i, !j, Comment) :: !acc; i := !j
    end else incr i
  done;
  List.rev !acc

(* --- the tokens --------------------------------------------------------------- *)

(* the colored tokens of [text], as (start, stop, kind), in order *)
let tokens ~path ~hover text =
  let toks = Checker.timed "colors: lex" (fun () -> lex text) in
  let rec go prev last acc = function
    | [] -> List.rev_append acc (comments text last (String.length text))
    | (b, e, t) :: rest ->
        let acc = List.rev_append (comments text last b) acc in
        let acc =
          match token_kind t with
          | `Skip -> acc
          | `Kind k -> (b, e, k) :: acc
          | `Name s -> (b, e, classify_name ~path ~hover ~prev b e s) :: acc in
        go (Some t) (max last e) acc rest in
  (* the tokens and the comments of the gaps are produced in order *)
  go None 0 [] toks

(* the LSP encoding: for each token, 5 integers (line and start relative to
   the previous token, length, kind, modifiers), in UTF-16 units; a token
   spanning several lines is cut at the ends of lines. The text is walked
   once, from token to token (positions are not computed from the beginning
   of their line, which is quadratic on long lines). *)
let encode text tokens =
  let pieces = List.concat_map (fun (b, e, k) ->
      (* the next newline in [b, e): only the token is scanned *)
      let rec newline i = if i >= e then None else if text.[i] = '\n' then Some i else newline (i + 1) in
      let rec cut b acc =
        if b >= e then List.rev acc
        else
          match newline b with
          | Some n -> cut (n + 1) (if n > b then (b, n, k) :: acc else acc)
          | None -> List.rev ((b, e, k) :: acc) in
      cut b []) tokens in
  let n = String.length text in
  (* the current position: byte offset, line, UTF-16 column *)
  let off = ref 0 and line = ref 0 and col = ref 0 in
  let advance target =
    let target = min target n in
    while !off < target do
      let c = text.[!off] in
      if c = '\n' then (incr line; col := 0) else col := !col + Text.utf16_units c;
      incr off
    done in
  (* the integers are written directly in an array (millions of them on a
     large file) *)
  let data = Array.make (5 * List.length pieces) 0 and i = ref 0 in
  let pline = ref 0 and pchar = ref 0 in
  List.iter (fun (b, e, k) ->
      if b >= !off then begin
        advance b;
        let l = !line and c = !col in
        advance e;
        let dline = l - !pline in
        data.(!i) <- dline;
        data.(!i + 1) <- (if dline = 0 then c - !pchar else c);
        data.(!i + 2) <- !col - c;
        data.(!i + 3) <- code k;
        i := !i + 5;
        pline := l; pchar := c
      end) pieces;
  Array.sub data 0 !i
