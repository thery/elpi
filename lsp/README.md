# elpi-lsp: a language server for Elpi

`elpi-lsp` speaks the [Language Server Protocol](https://microsoft.github.io/language-server-protocol/)
on stdin/stdout. It is meant to try the error-resilient parser of Elpi (built
with [Mastic](https://github.com/gares/mastic)), which reports all the syntax
errors of a file at once.

## What it does

For each open `.elpi` document (full text synchronization), the server checks the text:

1. it parses it with the **error-resilient parser**
   (`Parse.program_resilient` of the API). All the syntax errors are published
   as diagnostics (severity *Error*), with the tokens inserted by the recovery
   as *Information* diagnostics ("missing )", "missing term");
2. it **compiles the program as a unit** through the API of Elpi
   (`Compile.scope_ast`, `Compile.unit`): the text itself when it has no
   syntax error, otherwise the program returned by the resilient parser, where
   the **erroneous parts are erased** (an erroneous term becomes a fresh
   variable, which fits any type; a declaration that cannot stand without its
   erroneous part is dropped). So the **type checker works on a text with
   syntax errors** too;
3. the compiler stops at the first error: the declaration where it is is then
   **removed and the program compiled again** (`Ast.remove_declarations_at`
   of the API, at most 50 times), so that **all the type errors** are reported.
   An error in a declaration that contains a syntax error is a consequence of
   the recovery, and is not reported. The warnings (e.g. linear variables) are
   published too. `accumulate`d files are resolved relative to the directory
   of the document, then in `TJPATH`. An error located in an accumulated file
   is shown on the `accumulate` directive;
4. the result of `Compile.hover` of the program that finally compiles (all of
   it, but the removed declarations) is kept for:
   - **hover**: the type of the innermost sub-expression under the cursor; in
     the declarations (`pred`, `type`, type abbreviations), the kind of a
     type constructor (`list : type -> type`), type variables, and the whole
     type of a predicate (`pred i:(list A), o:(list A)`), from
     `Compile.hover_types`;
   - **go to definition**: the declaration of the symbol under the cursor
     (possibly in an accumulated file). There is no answer for the predicates of
     the standard library (they are not in a file) nor for variables.

**Colors** (semantic tokens, `textDocument/semanticTokens/full`): the text
is lexed by Elpi's lexer (in recovering mode, so also on broken text), and
each name is classified by what the compiler knows (`Compile.hover`,
`Compile.hover_types`): a predicate (`function`), a variable, a parameter
bound by `\`, a type, a type variable (`typeParameter`), a constant
(`enumMember`); keywords, operators, strings, numbers and comments by their
token. Without that information (e.g. in a declaration with a syntax error),
the context is used (the name after `pred` is a predicate, …). The VS Code
extension maps these kinds to the scopes of the TextMate grammar of
`gares.elpi-lang` (`semanticTokenScopes`), so that the colors look as before,
but the tokens are recognized by the parser instead of regular expressions.
See `lsp/highlight.ml`.

To see the difference, open `editors/vscode-lsp/test/colors.elpi`: with
regular expressions only, every lowercase name has the color of a function;
with the server, the constants `z` and `s` have no color, and the variable `x`
bound by `\` has the color of a binder. Semantic tokens are used only if
`"editor.semanticHighlighting.enabled": true` is set in the settings of VS
Code (its default, `configuredByTheme`, leaves it to the color theme, and many
themes leave it off); switching it between `true` and `false` shows the two
colorings.

Accumulated files are read from the disk: when a file is saved, the other
open documents are checked again (they may accumulate it), so that their
diagnostics follow; the compiled units that did not change come from the
cache.

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

       code --install-extension elpi/editors/vscode-lsp/elpi-lsp-0.0.2.vsix

5. In the settings of VS Code, set `elpi-lsp.path` to the absolute path of
   `_build/install/default/bin/elpi-lsp` (not needed if `elpi-lsp` is in the
   `PATH`).

6. Open a `.elpi` file: syntax errors and type errors are underlined, all of
   them at once, even when the text has syntax errors; hovering shows types
   and F12 (Go to Definition) jumps to the declaration of a predicate, in the
   parts of the text without error.

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

## Performance

- **Compiled units are cached**: a program is a list of units (the accumulated
  files, then the document), each compiled on top of the previous ones; a unit
  is identified by its digest and those of the units before it, and an
  unchanged accumulated file is not compiled again. Editing a file that
  accumulates a 48,000-line file is checked in 0.1 to 2 seconds instead of 20.
  The first check of such a file still compiles everything.
- The text is **parsed once**: the program of the resilient parser is compiled
  (without syntax error it is the program of the normal parser).
- The error recovery of the compiler (removing a declaration and compiling
  again) stops after **3 seconds**, with a message saying that there may be
  more errors.
- The **colors are linear** in the size of the text: on a 13.7 MB file (1.65
  million tokens) they take about 5 seconds.
- `ELPI_LSP_PROFILE=1` in the environment of the server logs the time of each
  phase (scoping, each unit, colors).

## Limits

- After an error, the whole declaration where it is is removed before compiling
  again: a second error in the same clause is not reported, and there is no
  hover in that clause.
- A type error that the erasure of a syntax error causes is hidden only if it is
  in the declaration of the syntax error; in rare cases an erased term (a
  fresh variable) may still cause a confusing error elsewhere.
- Warnings without a location (e.g. "Undeclared globals") are shown at the
  beginning of the document.
- The definition of a symbol is its whole declaration (e.g. the `pred`
  declaration), not just the name. There is no definition for variables nor for
  the standard library.
- Errors in an accumulated file are reported on the `accumulate` directive found
  by a textual search (at the beginning of the document if not found, e.g. for
  nested accumulates).
- Documents that are not files (`untitled:`) are checked, but `accumulate` there
  is resolved relative to a meaningless directory.
- Only full text synchronization; no completion, no document symbols.
