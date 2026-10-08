# elpi-lsp: a language server for Elpi

`elpi-lsp` speaks the [Language Server Protocol](https://microsoft.github.io/language-server-protocol/)
on stdin/stdout. It is meant to try the error-resilient parser of Elpi (built
with [Mastic](https://github.com/gares/mastic)), which reports all the syntax
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

## Quick start

Everything is on the branch `lsp` of https://github.com/thery/elpi. Mastic is
not on opam yet: it is built together with Elpi, in one dune workspace.

1. Get the sources, side by side:

       mkdir elpi-lsp && cd elpi-lsp
       git clone https://github.com/gares/mastic.git
       git clone -b lsp https://github.com/thery/elpi.git
       echo '(lang dune 3.0)' > dune-workspace
       echo '(dirs mastic elpi)' > dune

2. Install the OCaml dependencies (OCaml >= 4.14, an opam switch): those of
   Elpi and Mastic, plus `sel` and `lsp` (from ocaml-lsp) for the server:

       opam install dune menhir menhirLib ppx_deriving ppxlib ppx_optcomp re \
         stdlib-shims atdgen atdts sel lsp jsonrpc yojson

3. Build the server:

       dune build ./elpi/lsp/elpi_lsp.exe @elpi/install

   The server is `_build/install/default/bin/elpi-lsp` (a link to
   `_build/default/elpi/lsp/elpi_lsp.exe`). Test it with
   `dune build @elpi/lsp/runtest`.

4. Install the VS Code extension, which is in the repository:

       code --install-extension elpi/editors/vscode-lsp/elpi-lsp-0.0.1.vsix

5. In the settings of VS Code, set `elpi-lsp.path` to the absolute path of
   `_build/install/default/bin/elpi-lsp` (not needed if `elpi-lsp` is in the
   `PATH`).

6. Open a `.elpi` file: syntax errors are underlined (all of them at once),
   then type errors; on a file that compiles, hovering shows types and F12
   (Go to Definition) jumps to the declaration of a predicate.

The extension can be installed together with the syntax highlighting extension
of Elpi (`gares.elpi-lang`): both use the language id `elpi`. More about the
extension, its settings and its test client in
[`editors/vscode-lsp/README.md`](../editors/vscode-lsp/README.md).

## Build

The server is a separate opam package, `elpi-lsp.opam`, so that `elpi` does not
depend on `sel` and `lsp`. In the workspace above:

    dune build ./elpi/lsp/elpi_lsp.exe         # the server
    dune build @elpi/lsp/runtest               # its test: JSON-RPC messages, compared with test/test_lsp.expected

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
