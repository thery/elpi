# elpi-lsp: a language server for Elpi

`elpi-lsp` speaks the [Language Server Protocol](https://microsoft.github.io/language-server-protocol/)
on stdin/stdout. It is meant to try the error-resilient parser of Elpi (built
with [Mastic](https://github.com/LPCIC/mastic)), which reports all the syntax
errors of a file at once.

## What it does

For each open `.elpi` document (full text synchronization), the server checks the text:

1. it parses it with the **error-resilient parser**. If there are syntax
   errors, they are all published as diagnostics (severity *Error*), with the
   tokens inserted by the recovery as *Information* diagnostics ("missing )",
   "missing term"), and the check stops there;
2. otherwise it **compiles the text as a unit** through the API of Elpi
   (`Parse.program_from`, `Compile.scope_ast`, `Compile.unit`), and publishes
   the scoping/type errors (the first one: Elpi stops at the first error) and
   the warnings (e.g. linear variables) as diagnostics. `accumulate`d files are
   resolved relative to the directory of the document, then in `TJPATH`. An
   error located in an accumulated file is shown on the `accumulate` directive;
3. if the text compiles, it keeps the result of `Compile.hover` for:
   - **hover**: the type of the innermost sub-expression under the cursor;
   - **go to definition**: the declaration of the symbol under the cursor
     (possibly in an accumulated file). There is no answer for the predicates of
     the standard library (they are not in a file) nor for variables.

Changes are debounced: messages from the client are handled before checks,
so after a burst of changes only the last version of a document is checked.
A hover or definition request on a document not checked yet checks it first.

Logs go to stderr (in VS Code: the output channel of the extension), never to stdout.

## Design

- `text.ml`: conversions between byte offsets (Elpi locations) and LSP
  positions (0-based lines, columns in UTF-16 code units).
- `checker.ml`: everything Elpi: the instance (`Setup.init`), the error hooks
  turned into exceptions, the resilient parser
  (`Elpi_parser.Parse.Make(..).Internal.program_resilient`), compilation, and
  queries on the hover information.
- `elpi_lsp.ml`: the protocol and the main loop. As in
  [vsrocq](https://github.com/rocq-prover/vsrocq), the loop is driven by
  [Sel](https://github.com/gares/sel): the todo set holds the recurrent event
  reading a message on stdin (`Sel.On.httpcle`, Content-Length framing) and the
  checks of documents (`Sel.now`, with a lower priority than reading). Messages
  are decoded and encoded with the `lsp` library (`Jsonrpc`,
  `Lsp.Client_request`, `Lsp.Client_notification`, `Lsp.Server_notification`).

Capabilities: `textDocumentSync` (open/close, Full), `hoverProvider`,
`definitionProvider`. Requests: `initialize`, `shutdown`, `textDocument/hover`,
`textDocument/definition`; notifications: `initialized`, `exit`,
`textDocument/didOpen`, `didChange`, `didClose`.

## Build

It needs the OCaml libraries `sel` and `lsp` (from ocaml-lsp, with `jsonrpc`) in
addition to those of Elpi. In a dune workspace holding `mastic/` and `elpi/`:

    dune build ./elpi/lsp/elpi_lsp.exe

The executable is `_build/default/elpi/lsp/elpi_lsp.exe`; `dune build @install`
(or `dune install elpi-lsp`) also provides it as `elpi-lsp`
(`_build/install/default/bin/elpi-lsp`). It is a separate opam package,
`elpi-lsp.opam`, so that `elpi` does not depend on `sel` and `lsp`.

Test (drives the server with JSON-RPC messages, compares with `test/test_lsp.expected`):

    dune build @elpi/lsp/runtest

## VS Code

The VS Code client is in `editors/vscode-lsp` (branch `lsp-vscode`). Its setting
`elpi-lsp.path` must point to the server, e.g. the absolute path of
`_build/install/default/bin/elpi-lsp`, unless `elpi-lsp` is in the `PATH`.
Any LSP client can be used: the server takes no argument (it ignores
`--stdio`) and speaks on stdin/stdout.

## Limits

- Only the first scoping or type error is reported (the compiler stops there),
  and only when the text has no syntax error.
- Hover and definition work only on a text that compiles: while the text has
  errors, there is no answer.
- The definition of a symbol is its whole declaration (e.g. the `pred`
  declaration), not just the name. There is no definition for variables nor for
  the standard library.
- Errors in an accumulated file are reported on the `accumulate` directive found
  by a textual search (at the beginning of the document if not found, e.g. for
  nested accumulates).
- Documents that are not files (`untitled:`) are checked, but `accumulate` there
  is resolved relative to a meaningless directory.
- Only full text synchronization; no completion, no document symbols.
