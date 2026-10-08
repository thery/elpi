# Elpi LSP (experimental) — VS Code client

A minimal VS Code extension that starts the `elpi-lsp` language server for
`.elpi` files and shows:

- **diagnostics**: all syntax errors at once (the parser is error-resilient;
  the tokens it inserts to recover, e.g. "missing )", are shown as
  *Information* diagnostics), otherwise compile/type errors and warnings;
- **hover**: the type of the expression under the cursor;
- **go to definition** (F12 / Ctrl+click): the declaration of a predicate or
  constant, possibly in another (accumulated) file. Nothing is returned for
  variables or symbols of the standard library.

The extension is plain JavaScript (`extension.js`), there is no build step
besides `npm install`.

## Compatibility with the "Elpi lang" extension

The syntax highlighting extension from the marketplace
([LPCIC/elpi-lang](https://github.com/LPCIC/elpi-lang), `gares.elpi-lang`)
declares the language id `elpi` for `*.elpi` files. This extension uses
the **same id `elpi`**, so both can be installed together: elpi-lang gives
the highlighting and the tracer, this one the language server. Settings
(`elpi-lsp.*` vs `elpi.*`) and commands (`elpi-lsp.*` vs `elpi.*`) do not
clash. Both provide a language configuration (comments `%` and `/* */`,
brackets); they are equivalent, VS Code uses one of them.

## 1. Build the server

The server lives on branch `lsp` of Elpi, built in the dune workspace
`~/claudeExp/mastic-work` (which contains `elpi/` and `mastic/`):

```sh
cd ~/claudeExp/mastic-work
dune build ./elpi/lsp/elpi_lsp.exe @elpi/install
```

The executable is `_build/default/elpi/lsp/elpi_lsp.exe`; the install step
also creates `_build/install/default/bin/elpi-lsp`, a symlink to it, which is
the path to give to the extension:

```
/home/thery/claudeExp/mastic-work/_build/install/default/bin/elpi-lsp
```

The server needs no argument (extra ones, like the `--stdio` added by the
VS Code client library, are ignored), speaks LSP on stdin/stdout and logs
on stderr.

## 2. Build the extension (.vsix)

```sh
cd editors/vscode-lsp
npm install                    # vscode-languageclient + @vscode/vsce, locally
npx @vscode/vsce package       # produces elpi-lsp-0.0.1.vsix
node test/check_extension.js   # optional smoke test outside VS Code
```

## 3. Install it

```sh
code --install-extension editors/vscode-lsp/elpi-lsp-0.0.1.vsix
```

Then tell it where the server is (unless `elpi-lsp` is in your `PATH`):
*File > Preferences > Settings*, search for `elpi-lsp`, or in
`settings.json`:

```json
"elpi-lsp.path": "/home/thery/claudeExp/mastic-work/_build/install/default/bin/elpi-lsp"
```

Settings:

| setting                 | default    | meaning                                                   |
|-------------------------|------------|-----------------------------------------------------------|
| `elpi-lsp.path`         | `elpi-lsp` | server executable (looked up in `PATH`; `~/` is expanded) |
| `elpi-lsp.args`         | `[]`       | extra arguments for the server                            |
| `elpi-lsp.trace.server` | `off`      | `off` / `messages` / `verbose`: trace the LSP traffic     |

After changing `path` or `args`, run **Elpi LSP: Restart server** from the
command palette (Ctrl+Shift+P); the extension also offers to do it.

## 4. Try it

Open a folder containing `.elpi` files, e.g. `editors/vscode-lsp/test/`:

- `syntax_errors.elpi`: several red squiggles at once, plus blue
  (Information) markers where the parser inserted a missing token; see them
  all in the *Problems* panel (Ctrl+Shift+M);
- `type_error.elpi`: a type error on `"two"` (line 12);
- `good.elpi`: no diagnostics; hover over `add` on line 13 shows its type
  in an elpi code block; put the cursor on `double` on line 16 and press
  **F12** to jump to its declaration;
- `accumulated.elpi` (`accumulate good.`): F12 on `double` jumps into
  `good.elpi`.

Edit a file: diagnostics are updated on every change (full text sync).

## 5. Logs and trace

- *View > Output*, channel **Elpi LSP**: client messages and the server's
  stderr (also: command **Elpi LSP: Show output**). If the server cannot
  be started (wrong `elpi-lsp.path`), an error notification says so.
- Set `"elpi-lsp.trace.server": "verbose"` and look at the output channel
  **Elpi LSP Trace** for every JSON-RPC message exchanged.
- **Elpi LSP: Restart server** restarts the server (e.g. after rebuilding
  it with dune).

## 6. Uninstall

```sh
code --uninstall-extension lpcic.elpi-lsp
```

(and remove the `elpi-lsp.*` entries from your settings if you added some).

## 7. Test the server without VS Code

`test/lsp_client.py` is a black-box LSP client (python3, standard library
only). It starts the server, does initialize/initialized, opens files,
waits for `publishDiagnostics`, sends hover/definition requests, then
shutdown/exit, and prints a readable transcript.

```sh
cd editors/vscode-lsp
S=~/claudeExp/mastic-work/_build/install/default/bin/elpi-lsp

# one file, positions are LINE:COL, 1-based as in the VS Code status bar
python3 test/lsp_client.py --server $S test/good.elpi --hover 13:16 --definition 16:9

# the scripted scenario on test/*.elpi
python3 test/lsp_client.py --server $S --all
```

Useful options: `-v` (print every raw JSON-RPC message), `--hide-stderr`,
`--timeout SEC` (per answer, default 10), `--settle SEC` (how long to keep
listening for newer diagnostics, default 0.5), `--zero-based` (raw LSP
positions), `--server-arg ARG`. The server command can also be given in
`$ELPI_LSP`.

Exit status: 0 ok; 1 protocol error (no answer before the timeout,
malformed message, error response, server crash, non-zero exit after
shutdown/exit); 2 usage error; 3 with `--strict` when the protocol is fine
but a content check of the scenario failed (e.g. no error reported for
`syntax_errors.elpi`, hover on `add` not mentioning `nat`, definition of
`double` not in `good.elpi`).

`test/fake_server.py` is a tiny fake server (empty diagnostics, hover =
word under the cursor) used to test the client itself; `--mode
crash-on-hover|silent-definition|garbage-on-hover|error-on-hover|bad-exit`
makes it misbehave, and the client must then exit with status 1:

```sh
python3 test/lsp_client.py --server "python3 test/fake_server.py" --all
python3 test/lsp_client.py --server "python3 test/fake_server.py --mode crash-on-hover" test/good.elpi --hover 13:16
```
