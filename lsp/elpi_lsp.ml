(* elpi-lsp: a language server for Elpi, speaking LSP on stdin/stdout.

   As in vsrocq, the main loop is driven by Sel: the todo set holds the
   (recurrent) event reading an LSP message on stdin, and the checks of the
   documents. Reading stdin has a higher priority than checking, so the
   messages already received (e.g. a burst of didChange) are all handled
   before a document is checked, and only its last version is checked. *)

open Lsp.Types

let log = Checker.log

(* --- output ------------------------------------------------------------------ *)

(* Elpi may print on stdout: the LSP messages go to a copy of the original
   stdout, and stdout itself is redirected to stderr. *)
let out = Unix.dup Unix.stdout
let () = Unix.dup2 Unix.stderr Unix.stdout

let output_json json =
  let msg = Yojson.Safe.to_string json in
  let s = Printf.sprintf "Content-Length: %d\r\n\r\n%s" (String.length msg) msg in
  let rec write off =
    if off < String.length s then
      write (off + Unix.write_substring out s off (String.length s - off)) in
  write 0

let send_notification n =
  output_json (Jsonrpc.Notification.yojson_of_t (Lsp.Server_notification.to_jsonrpc n))

(* --- documents --------------------------------------------------------------- *)

type document = {
  path : string;
  mutable text : Text.t;
  mutable version : int;            (* bumped at each change *)
  mutable checked : int;            (* the version last checked *)
  mutable hover : Checker.hover option; (* if the last checked version compiles *)
}

let documents : (DocumentUri.t, document) Hashtbl.t = Hashtbl.create 7

type event =
  | Read of Jsonrpc.Packet.t option (* a message from the client *)
  | Check of DocumentUri.t * int    (* check this version of the document *)

let read_message : event Sel.Event.t =
  Sel.On.httpcle ~priority:0 ~name:"lsp" Unix.stdin (function
    | Ok buf ->
        (try Read (Some (Jsonrpc.Packet.t_of_yojson (Yojson.Safe.from_string (Bytes.to_string buf))))
         with e -> log "cannot decode message: %s" (Printexc.to_string e); Read None)
    | Error e -> log "cannot read stdin (%s), exiting" (Printexc.to_string e); exit 1)

let check_later uri version = Sel.now ~priority:10 ~name:"check" (Check (uri, version))

let severity : Checker.severity -> DiagnosticSeverity.t = function
  | Error -> Error
  | Warning -> Warning
  | Information -> Information

let check uri doc =
  let t0 = Unix.gettimeofday () in
  let { Checker.diagnostics; hover } = Checker.check ~path:doc.path doc.text.Text.text in
  log "checked %s (version %d) in %.3fs: %d diagnostics%s" doc.path doc.version
    (Unix.gettimeofday () -. t0) (List.length diagnostics) (if hover <> None then ", compiles" else "");
  doc.checked <- doc.version;
  doc.hover <- hover;
  let diagnostics = List.map (fun { Checker.start; stop; severity = s; message } ->
      Diagnostic.create ~range:(Text.range doc.text start stop) ~severity:(severity s)
        ~source:"elpi" ~message:(`String message) ()) diagnostics in
  send_notification (PublishDiagnostics (PublishDiagnosticsParams.create ~uri ~diagnostics ()))

(* the hover information of a document, checking it first if needed *)
let hover_of uri =
  match Hashtbl.find_opt documents uri with
  | None -> None
  | Some doc ->
      if doc.checked <> doc.version then check uri doc;
      Option.map (fun h -> doc, h) doc.hover

(* --- requests ------------------------------------------------------------------ *)

let initialize _params =
  let textDocumentSync =
    `TextDocumentSyncOptions (TextDocumentSyncOptions.create ~openClose:true
                                ~change:TextDocumentSyncKind.Full ()) in
  let semanticTokensProvider =
    `SemanticTokensOptions (SemanticTokensOptions.create ~full:(`Bool true)
      ~legend:(SemanticTokensLegend.create ~tokenTypes:Highlight.legend ~tokenModifiers:[]) ()) in
  let capabilities = ServerCapabilities.create ~textDocumentSync
      ~hoverProvider:(`Bool true) ~definitionProvider:(`Bool true) ~semanticTokensProvider () in
  InitializeResult.create ~capabilities
    ~serverInfo:(InitializeResult.create_serverInfo ~name:"elpi-lsp" ~version:"0.1" ()) ()

let hover ({ textDocument = { uri }; position; _ } : HoverParams.t) =
  match hover_of uri with
  | None -> None
  | Some (doc, h) ->
      let off = Text.offset_of_position doc.text position in
      match Checker.type_at ~path:doc.path off h with
      | None -> None
      | Some ({ source_start; source_stop; _ }, ty) ->
          let contents = `MarkupContent (MarkupContent.create ~kind:Markdown
                                           ~value:(Printf.sprintf "```elpi\n%s\n```" ty)) in
          Some (Hover.create ~contents ~range:(Text.range doc.text source_start source_stop) ())

(* the text of a file, to convert the location of a definition *)
let text_of_file doc file =
  if file = doc.path then Some doc.text
  else if Sys.file_exists file then
    try
      let ic = open_in_bin file in
      let s = Fun.protect ~finally:(fun () -> close_in ic)
          (fun () -> really_input_string ic (in_channel_length ic)) in
      Some (Text.make s)
    with Sys_error _ -> None
  else None

let definition ({ textDocument = { uri }; position; _ } : DefinitionParams.t) : Locations.t option =
  match hover_of uri with
  | None -> None
  | Some (doc, h) ->
      let off = Text.offset_of_position doc.text position in
      match Checker.definition_at ~path:doc.path off h with
      | None -> None
      | Some (_, { source_name; source_start; source_stop; _ }) ->
          (* builtins are defined in files that do not exist *)
          let file =
            if Filename.is_relative source_name
            then Filename.concat (Filename.dirname doc.path) source_name else source_name in
          match text_of_file doc file with
          | None -> None
          | Some t ->
              let uri = if file = doc.path then uri else DocumentUri.of_path file in
              Some (`Location [ Location.create ~uri ~range:(Text.range t source_start source_stop) ])

(* the colors of a document: semantic tokens, from the lexer and the hover
   information (see highlight.ml) *)
let semantic_tokens ({ textDocument = { uri }; _ } : SemanticTokensParams.t) =
  match Hashtbl.find_opt documents uri with
  | None -> None
  | Some doc ->
      if doc.checked <> doc.version then check uri doc;
      let text = doc.text.Text.text in
      let tokens = Checker.timed "colors: tokens" (fun () -> Highlight.tokens ~path:doc.path ~hover:doc.hover text) in
      let data = Checker.timed "colors: encode" (fun () -> Highlight.encode text tokens) in
      Some (SemanticTokens.create ~data ())

let shutdown_received = ref false

let handle_request : type a. a Lsp.Client_request.t -> (a, string) result = function
  | _ when !shutdown_received -> Error "shutdown received"
  | Initialize params -> Ok (initialize params)
  | Shutdown -> shutdown_received := true; Ok ()
  | TextDocumentHover params -> Ok (hover params)
  | SemanticTokensFull params -> Ok (semantic_tokens params)
  | TextDocumentDefinition params -> Ok (definition params)
  | _ -> Error "unsupported request"

(* --- notifications --------------------------------------------------------------- *)

let set_text uri text =
  match Hashtbl.find_opt documents uri with
  | None ->
      let doc = { path = DocumentUri.to_path uri; text = Text.make text; version = 0;
                  checked = -1; hover = None } in
      Hashtbl.replace documents uri doc;
      [ check_later uri doc.version ]
  | Some doc ->
      doc.text <- Text.make text;
      doc.version <- doc.version + 1;
      doc.hover <- None;
      [ check_later uri doc.version ]

let handle_notification : Lsp.Client_notification.t -> event Sel.Event.t list = function
  | TextDocumentDidOpen { textDocument = { uri; text; _ } } -> set_text uri text
  | TextDocumentDidChange { textDocument = { uri; _ }; contentChanges } ->
      (* full synchronization: the last change is the whole text *)
      (match List.rev contentChanges with
       | { text; range = None; _ } :: _ -> set_text uri text
       | _ -> log "ignoring an incremental change"; [])
  | TextDocumentDidClose { textDocument = { uri } } ->
      Hashtbl.remove documents uri;
      send_notification (PublishDiagnostics (PublishDiagnosticsParams.create ~uri ~diagnostics:[] ()));
      []
  | Initialized -> []
  | Exit -> exit (if !shutdown_received then 0 else 1)
  | _ -> []

(* --- main loop -------------------------------------------------------------------- *)

let handle_packet : Jsonrpc.Packet.t -> event Sel.Event.t list = function
  | Request req ->
      let response =
        match Lsp.Client_request.of_jsonrpc req with
        | Error e -> Jsonrpc.Response.(error req.id (Error.make ~code:InvalidRequest ~message:e ()))
        | Ok (E r) ->
            match handle_request r with
            | Ok x -> Jsonrpc.Response.ok req.id (Lsp.Client_request.yojson_of_result r x)
            | Error message -> Jsonrpc.Response.(error req.id (Error.make ~code:RequestFailed ~message ()))
            | exception e ->
                let message = Printexc.to_string e in
                log "request %s failed: %s" req.method_ message;
                Jsonrpc.Response.(error req.id (Error.make ~code:InternalError ~message ())) in
      output_json (Jsonrpc.Response.yojson_of_t response);
      []
  | Notification n ->
      (match Lsp.Client_notification.of_jsonrpc n with
       | Ok n -> handle_notification n
       | Error e -> log "ignoring notification %s: %s" n.method_ e; [])
  | _ -> log "ignoring a message"; []

let handle_event = function
  | Read None -> [ read_message ]
  | Read (Some packet) -> read_message :: handle_packet packet
  | Check (uri, version) ->
      (match Hashtbl.find_opt documents uri with
       | Some doc when doc.version = version && doc.checked <> version ->
           (try check uri doc with e -> log "check failed: %s" (Printexc.to_string e))
       | _ -> () (* closed, changed since, or already checked *));
      []

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  log "started";
  let rec loop todo =
    let ready, todo = Sel.pop todo in
    loop (Sel.Todo.add todo (handle_event ready)) in
  loop (Sel.Todo.add Sel.Todo.empty [ read_message ])
