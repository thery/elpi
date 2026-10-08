#!/usr/bin/env python3
"""Black-box LSP test client for elpi-lsp (python3, standard library only).

Starts a server command, talks LSP to it over stdio (JSON-RPC with
Content-Length framing) and prints a readable transcript.

Single-file mode:
    python3 test/lsp_client.py --server PATH test/good.elpi \
        --hover 13:15 --definition 16:9

  Positions are LINE:COL, 1-based (as shown in the VS Code status bar);
  use --zero-based to give raw LSP positions.  --hover/--definition may be
  repeated; they apply to the first FILE given.  Several FILEs may be
  opened (all are opened before the requests are sent).

Scripted mode:
    python3 test/lsp_client.py --server PATH --all [--strict]

  Runs a scenario on the test/*.elpi inputs (open, diagnostics, edit,
  hover, definition, cross-file definition, shutdown/exit).

Exit status: 0 = ok; 1 = protocol error (no answer before the timeout,
malformed message, error response, server crash or bad exit); 2 = usage
error; 3 = (only with --strict) protocol ok but some content checks failed
(e.g. no diagnostics for a file with syntax errors).
"""

import argparse
import json
import os
import queue
import shlex
import subprocess
import sys
import threading
import time
from urllib.parse import quote, unquote, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))

SEVERITY = {1: "Error", 2: "Warning", 3: "Information", 4: "Hint"}


class ProtocolError(Exception):
    pass


def path_to_uri(path):
    return "file://" + quote(os.path.abspath(path))


def uri_to_path(uri):
    p = urlparse(uri)
    if p.scheme != "file":
        return uri
    return unquote(p.path)


def short(uri):
    path = uri_to_path(uri)
    try:
        rel = os.path.relpath(path)
        return rel if not rel.startswith("../../..") else path
    except ValueError:
        return path


class Transcript:
    def __init__(self, verbose):
        self.verbose = verbose
        self.t0 = time.monotonic()

    def log(self, msg):
        print("[%6.2fs] %s" % (time.monotonic() - self.t0, msg), flush=True)

    def raw(self, direction, msg):
        if self.verbose:
            text = json.dumps(msg, indent=None)
            if len(text) > 2000:
                text = text[:2000] + "...(truncated)"
            self.log("%s %s" % (direction, text))


class Server:
    """A running server process plus a reader thread for its stdout."""

    def __init__(self, cmd, transcript, timeout, show_stderr):
        self.tr = transcript
        self.timeout = timeout
        self.next_id = 1
        self.messages = queue.Queue()  # parsed messages, or ("EOF", reason)
        self.stderr_lines = []
        self.show_stderr = show_stderr
        self.notifications = []  # all notifications received, in order
        self.protocol_errors = []
        self.tr.log("starting server: %s" % " ".join(shlex.quote(c) for c in cmd))
        try:
            self.proc = subprocess.Popen(
                cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE)
        except OSError as e:
            raise ProtocolError("cannot start server %r: %s" % (cmd[0], e))
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    # ---- low level -------------------------------------------------------

    def _read_stdout(self):
        out = self.proc.stdout
        try:
            while True:
                headers = {}
                while True:
                    line = out.readline()
                    if not line:
                        self.messages.put(("EOF", "server closed its stdout"))
                        return
                    line = line.decode("ascii", errors="replace")
                    if line in ("\r\n", "\n"):
                        if headers:
                            break
                        continue  # tolerate stray blank lines
                    if not line.endswith("\r\n"):
                        self.messages.put(("MALFORMED", "header line not terminated by CRLF: %r" % line))
                    if ":" not in line:
                        self.messages.put(("MALFORMED", "bad header line %r" % line))
                        continue
                    k, v = line.split(":", 1)
                    headers[k.strip().lower()] = v.strip()
                if "content-length" not in headers:
                    self.messages.put(("MALFORMED", "no Content-Length header in %r" % headers))
                    continue
                try:
                    n = int(headers["content-length"])
                except ValueError:
                    self.messages.put(("MALFORMED", "bad Content-Length %r" % headers["content-length"]))
                    continue
                body = out.read(n)
                if len(body) < n:
                    self.messages.put(("EOF", "server closed stdout in the middle of a message"))
                    return
                try:
                    msg = json.loads(body.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    self.messages.put(("MALFORMED", "invalid JSON body (%s): %r" % (e, body[:200])))
                    continue
                self.messages.put(msg)
        except Exception as e:  # pragma: no cover
            self.messages.put(("EOF", "reader error: %s" % e))

    def _read_stderr(self):
        for line in self.proc.stderr:
            line = line.decode("utf-8", errors="replace").rstrip("\n")
            self.stderr_lines.append(line)
            if self.show_stderr:
                self.tr.log("  stderr| " + line)

    def _write(self, msg):
        self.tr.raw("-->", msg)
        body = json.dumps(msg).encode("utf-8")
        data = b"Content-Length: %d\r\n\r\n" % len(body) + body
        try:
            self.proc.stdin.write(data)
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError) as e:
            raise ProtocolError("cannot write to server (crashed?): %s" % e)

    def _check(self, msg):
        if not isinstance(msg, dict):
            raise ProtocolError("message is not a JSON object: %r" % (msg,))
        if msg.get("jsonrpc") != "2.0":
            raise ProtocolError("message without jsonrpc \"2.0\": %r" % (msg,))

    def _next(self, deadline, what, quiet_timeout=False):
        """Next message from the server, handling server->client requests.
        On timeout: raise, or return None if quiet_timeout."""
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                if quiet_timeout:
                    return None
                raise ProtocolError("timeout (%.1fs) waiting for %s" % (self.timeout, what))
            try:
                msg = self.messages.get(timeout=remaining)
            except queue.Empty:
                continue
            if isinstance(msg, tuple):
                kind, reason = msg
                if kind == "EOF":
                    self.messages.put(msg)  # keep it for later waits
                    rc = self.proc.poll()
                    raise ProtocolError("%s while waiting for %s (exit code %s)" % (reason, what, rc))
                raise ProtocolError("malformed message: %s" % reason)
            self.tr.raw("<--", msg)
            self._check(msg)
            if "method" in msg and "id" in msg:
                self._answer_server_request(msg)
                continue
            if "method" in msg:
                self.notifications.append(msg)
                self._on_notification(msg)
            return msg

    def _answer_server_request(self, msg):
        method = msg["method"]
        self.tr.log("server request %s (id %r): answering" % (method, msg["id"]))
        if method == "workspace/configuration":
            result = [None for _ in msg.get("params", {}).get("items", [])]
        elif method == "window/showMessageRequest":
            result = None
        else:  # client/registerCapability, window/workDoneProgress/create, ...
            result = None
        self._write({"jsonrpc": "2.0", "id": msg["id"], "result": result})

    def _on_notification(self, msg):
        m = msg["method"]
        p = msg.get("params", {}) or {}
        if m in ("window/logMessage", "window/showMessage"):
            kind = {1: "error", 2: "warning", 3: "info", 4: "log"}.get(p.get("type"), "?")
            self.tr.log("%s [%s]: %s" % (m, kind, p.get("message")))

    # ---- high level ------------------------------------------------------

    def notify(self, method, params):
        self._write({"jsonrpc": "2.0", "method": method, "params": params})

    def request(self, method, params, allow_error=False):
        rid = self.next_id
        self.next_id += 1
        self._write({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        deadline = time.monotonic() + self.timeout
        while True:
            msg = self._next(deadline, "the answer to %s (id %d)" % (method, rid))
            if "method" in msg:
                continue  # notification, already recorded
            if "id" not in msg:
                raise ProtocolError("message with neither method nor id: %r" % msg)
            if msg["id"] != rid:
                raise ProtocolError("answer with unexpected id %r (waiting for %d)" % (msg["id"], rid))
            has_r, has_e = "result" in msg, "error" in msg
            if has_r == has_e:
                raise ProtocolError("response must have exactly one of result/error: %r" % msg)
            if has_e:
                err = msg["error"]
                if allow_error:
                    return None, err
                raise ProtocolError("%s returned an error: %r" % (method, err))
            return msg["result"], None

    def wait_diagnostics(self, uri, settle):
        """Wait for a publishDiagnostics for uri; then keep collecting during
        `settle` seconds and return the last one."""
        def match(n):
            return (n["method"] == "textDocument/publishDiagnostics"
                    and (n.get("params") or {}).get("uri") == uri)
        start = len(self.notifications)
        deadline = time.monotonic() + self.timeout
        found = None
        while found is None:
            for n in self.notifications[start:]:
                if match(n):
                    found = n
            if found is None:
                msg = self._next(deadline, "publishDiagnostics for %s" % short(uri))
                if "method" not in msg:
                    raise ProtocolError("unexpected response %r" % msg)
        end = time.monotonic() + settle
        while True:
            msg = self._next(end, "message", quiet_timeout=True)
            if msg is None:
                break
            if "method" not in msg:
                raise ProtocolError("unexpected response %r" % msg)
            if match(msg):
                found = msg
        params = found.get("params") or {}
        diags = params.get("diagnostics")
        if not isinstance(diags, list):
            raise ProtocolError("publishDiagnostics without a diagnostics list: %r" % found)
        return diags

    def shutdown(self):
        self.tr.log("shutdown")
        result, _ = self.request("shutdown", None)
        if result is not None:
            self.tr.log("  note: shutdown result should be null, got %r" % (result,))
        self.notify("exit", None)
        try:
            rc = self.proc.wait(timeout=self.timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            raise ProtocolError("server did not exit after the exit notification")
        self.tr.log("server exited with code %d" % rc)
        if rc != 0:
            raise ProtocolError("server exit code %d after shutdown/exit (expected 0)" % rc)

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()


# ---- pretty printing --------------------------------------------------------

def fmt_range(r):
    s, e = r["start"], r["end"]
    return "%d:%d-%d:%d" % (s["line"] + 1, s["character"] + 1, e["line"] + 1, e["character"] + 1)


def print_diagnostics(tr, uri, diags, text):
    tr.log("diagnostics for %s: %d" % (short(uri), len(diags)))
    lines = text.split("\n") if text is not None else []
    for d in diags:
        try:
            sev = SEVERITY.get(d.get("severity"), "?")
            src = (" (%s)" % d["source"]) if d.get("source") else ""
            tr.log("  %s %s%s: %s" % (fmt_range(d["range"]), sev, src,
                                       d.get("message", "").replace("\n", "\n" + " " * 14)))
            ln = d["range"]["start"]["line"]
            if 0 <= ln < len(lines):
                c = d["range"]["start"]["character"]
                tr.log("      | " + lines[ln])
                tr.log("      | " + " " * c + "^")
        except (KeyError, TypeError) as e:
            raise ProtocolError("malformed diagnostic %r (%s)" % (d, e))


def hover_text(result):
    if result is None:
        return None
    if not isinstance(result, dict) or "contents" not in result:
        raise ProtocolError("malformed hover result %r" % (result,))
    c = result["contents"]

    def one(x):
        if isinstance(x, str):
            return x
        if isinstance(x, dict) and "value" in x:
            if "language" in x:
                return "```%s\n%s\n```" % (x["language"], x["value"])
            return x["value"]
        raise ProtocolError("malformed hover contents %r" % (x,))
    if isinstance(c, list):
        return "\n".join(one(x) for x in c)
    return one(c)


def locations(result):
    """Normalize a definition result to a list of (uri, range)."""
    if result is None:
        return []
    if isinstance(result, dict):
        result = [result]
    if not isinstance(result, list):
        raise ProtocolError("malformed definition result %r" % (result,))
    out = []
    for l in result:
        if not isinstance(l, dict):
            raise ProtocolError("malformed location %r" % (l,))
        if "targetUri" in l:  # LocationLink
            out.append((l["targetUri"], l.get("targetSelectionRange") or l["targetRange"]))
        elif "uri" in l and "range" in l:
            out.append((l["uri"], l["range"]))
        else:
            raise ProtocolError("malformed location %r" % (l,))
    return out


def line_of(path, line0):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().split("\n")[line0]
    except (OSError, IndexError):
        return None


# ---- session -----------------------------------------------------------------

class Session:
    def __init__(self, args):
        self.args = args
        self.tr = Transcript(args.verbose)
        self.server = None
        self.docs = {}  # uri -> (version, text)
        self.check_failures = []

    def check(self, cond, what):
        if cond:
            self.tr.log("  check ok: " + what)
        else:
            self.tr.log("  CHECK FAILED: " + what)
            self.check_failures.append(what)

    def start(self):
        cmd = shlex.split(self.args.server) + list(self.args.server_arg or [])
        self.server = Server(cmd, self.tr, self.args.timeout, not self.args.hide_stderr)
        root = os.path.abspath(self.args.root or os.getcwd())
        self.tr.log("initialize (rootUri %s)" % path_to_uri(root))
        result, _ = self.server.request("initialize", {
            "processId": os.getpid(),
            "clientInfo": {"name": "elpi-lsp test client", "version": "0.1"},
            "rootUri": path_to_uri(root),
            "workspaceFolders": [{"uri": path_to_uri(root), "name": os.path.basename(root)}],
            "capabilities": {
                "textDocument": {
                    "synchronization": {"dynamicRegistration": False, "didSave": False},
                    "publishDiagnostics": {"relatedInformation": True, "versionSupport": True},
                    "hover": {"contentFormat": ["markdown", "plaintext"]},
                    "definition": {"linkSupport": False},
                },
                "window": {"workDoneProgress": False},
                "general": {"positionEncodings": ["utf-16"]},
            },
            "trace": "off",
        })
        if not isinstance(result, dict) or "capabilities" not in result:
            raise ProtocolError("initialize result without capabilities: %r" % (result,))
        caps = result["capabilities"]
        info = result.get("serverInfo") or {}
        self.tr.log("server: %s %s" % (info.get("name", "?"), info.get("version", "")))
        self.tr.log("capabilities: %s" % json.dumps(caps, sort_keys=True))
        self.caps = caps
        sync = caps.get("textDocumentSync")
        kind = sync.get("change") if isinstance(sync, dict) else sync
        self.check(kind == 1, "textDocumentSync is Full (1), got %r" % (kind,))
        self.check(bool(caps.get("hoverProvider")), "hoverProvider")
        self.check(bool(caps.get("definitionProvider")), "definitionProvider")
        self.server.notify("initialized", {})

    def open(self, path):
        uri = path_to_uri(path)
        with open(path, encoding="utf-8") as f:
            text = f.read()
        self.docs[uri] = (1, text)
        self.tr.log("didOpen %s" % short(uri))
        self.server.notify("textDocument/didOpen", {"textDocument": {
            "uri": uri, "languageId": "elpi", "version": 1, "text": text}})
        diags = self.server.wait_diagnostics(uri, self.args.settle)
        print_diagnostics(self.tr, uri, diags, text)
        return uri, diags

    def change(self, uri, text):
        version = self.docs[uri][0] + 1
        self.docs[uri] = (version, text)
        self.tr.log("didChange %s (version %d)" % (short(uri), version))
        self.server.notify("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": version},
            "contentChanges": [{"text": text}]})
        diags = self.server.wait_diagnostics(uri, self.args.settle)
        print_diagnostics(self.tr, uri, diags, text)
        return diags

    def close(self, uri):
        self.tr.log("didClose %s" % short(uri))
        self.server.notify("textDocument/didClose", {"textDocument": {"uri": uri}})

    def show_pos(self, uri, line0, col0):
        lines = self.docs[uri][1].split("\n")
        if 0 <= line0 < len(lines):
            self.tr.log("      | " + lines[line0])
            self.tr.log("      | " + " " * col0 + "^")

    def hover(self, uri, line0, col0):
        self.tr.log("hover %s at %d:%d (0-based %d:%d)" % (short(uri), line0 + 1, col0 + 1, line0, col0))
        self.show_pos(uri, line0, col0)
        result, _ = self.server.request("textDocument/hover", {
            "textDocument": {"uri": uri}, "position": {"line": line0, "character": col0}})
        text = hover_text(result)
        if text is None:
            self.tr.log("  hover: null")
        else:
            rng = (" [range %s]" % fmt_range(result["range"])) if result.get("range") else ""
            self.tr.log("  hover%s:" % rng)
            for l in text.split("\n"):
                self.tr.log("    " + l)
        return text

    def definition(self, uri, line0, col0):
        self.tr.log("definition %s at %d:%d (0-based %d:%d)" % (short(uri), line0 + 1, col0 + 1, line0, col0))
        self.show_pos(uri, line0, col0)
        result, _ = self.server.request("textDocument/definition", {
            "textDocument": {"uri": uri}, "position": {"line": line0, "character": col0}})
        locs = locations(result)
        if not locs:
            self.tr.log("  definition: none")
        for (u, r) in locs:
            self.tr.log("  definition: %s %s" % (short(u), fmt_range(r)))
            l = line_of(uri_to_path(u), r["start"]["line"])
            if l is not None:
                self.tr.log("      | " + l)
        return locs


def parse_pos(s, zero_based):
    try:
        l, c = s.split(":")
        l, c = int(l), int(c)
    except ValueError:
        raise argparse.ArgumentTypeError("position must be LINE:COL, got %r" % s)
    if not zero_based:
        l, c = l - 1, c - 1
    if l < 0 or c < 0:
        raise argparse.ArgumentTypeError("bad position %r" % s)
    return l, c


def find(text, line_marker, word, occurrence=1):
    """0-based position of the `occurrence`-th `word` in the first line
    containing `line_marker`."""
    for i, line in enumerate(text.split("\n")):
        if line_marker in line:
            c = -1
            for _ in range(occurrence):
                c = line.index(word, c + 1)
            return i, c
    raise KeyError(line_marker)


def scenario(s):
    """The --all scripted scenario."""
    d = s.args.test_dir
    good = os.path.join(d, "good.elpi")
    s.start()

    # 1. good file: no errors expected
    uri_good, diags = s.open(good)
    s.check(not [x for x in diags if x.get("severity") == 1], "good.elpi has no error diagnostics")
    text = s.docs[uri_good][1]

    # hover/definition on `add` used in `double`, on `double` used in `main`
    l, c = find(text, "double N M :- add", "add")
    h = s.hover(uri_good, l, c + 1)
    s.check(h is not None and "nat" in h, "hover on `add` mentions nat")
    locs = s.definition(uri_good, l, c + 1)
    s.check(any(u == uri_good and 7 <= r["start"]["line"] <= 9 for u, r in locs),
            "definition of `add` is in good.elpi lines 8-10")
    l, c = find(text, "main :- double", "double")
    locs = s.definition(uri_good, l, c)
    s.check(any(u == uri_good and 11 <= r["start"]["line"] <= 12 for u, r in locs),
            "definition of `double` is in good.elpi lines 12-13")
    # hover on a variable and on a constant
    l, c = find(text, "main :- double", "X")
    h = s.hover(uri_good, l, c)
    s.check(h is not None and "nat" in h, "hover on variable X mentions nat")
    l, c = find(text, "main :- double", "z")
    s.hover(uri_good, l, c)
    # hover in a comment / blank space: any answer (null is fine), but an answer
    s.hover(uri_good, 0, 2)

    # 2. edit good.elpi: introduce a syntax error, then revert
    broken = text.replace("add N N M.", "add N N M :- .", 1)
    diags = s.change(uri_good, broken)
    s.check(any(x.get("severity") == 1 for x in diags), "after edit: an error is reported")
    diags = s.change(uri_good, text)
    s.check(not [x for x in diags if x.get("severity") == 1], "after revert: no error")

    # 3. syntax errors: several reported at once
    uri, diags = s.open(os.path.join(d, "syntax_errors.elpi"))
    errs = [x for x in diags if x.get("severity") in (1, None)]
    s.check(len(errs) >= 2, "syntax_errors.elpi: several errors reported at once (%d)" % len(errs))
    s.close(uri)

    # 4. type error
    uri, diags = s.open(os.path.join(d, "type_error.elpi"))
    s.check(any(x.get("severity") == 1 and x["range"]["start"]["line"] == 11 for x in diags),
            "type_error.elpi: an error on line 12")
    s.close(uri)

    # 5. accumulate: definition in another file
    uri, diags = s.open(os.path.join(d, "accumulated.elpi"))
    s.check(not [x for x in diags if x.get("severity") == 1], "accumulated.elpi has no error")
    atext = s.docs[uri][1]
    l, c = find(atext, "quadruple N M :- double", "double")
    s.hover(uri, l, c)
    locs = s.definition(uri, l, c)
    s.check(any(u == uri_good for u, _ in locs), "definition of `double` is in good.elpi")
    l, c = find(atext, "accumulate good", "good")
    s.definition(uri, l, c)  # optional: may jump to good.elpi
    s.close(uri)
    s.close(uri_good)

    s.server.shutdown()


def main():
    ap = argparse.ArgumentParser(
        description="Black-box LSP test client for elpi-lsp.",
        epilog="Positions are LINE:COL, 1-based unless --zero-based.")
    ap.add_argument("--server", default=os.environ.get("ELPI_LSP", "elpi-lsp"),
                    help="server command (split like a shell command line); "
                         "default $ELPI_LSP or elpi-lsp")
    ap.add_argument("--server-arg", action="append", help="extra argument for the server (repeatable)")
    ap.add_argument("files", nargs="*", help=".elpi files to open")
    ap.add_argument("--hover", action="append", default=[], metavar="LINE:COL")
    ap.add_argument("--definition", action="append", default=[], metavar="LINE:COL")
    ap.add_argument("--zero-based", action="store_true", help="positions are 0-based LSP positions")
    ap.add_argument("--all", action="store_true", help="run the scripted scenario on the test inputs")
    ap.add_argument("--test-dir", default=HERE, help="directory of the test inputs for --all")
    ap.add_argument("--root", help="workspace root sent in initialize (default: cwd)")
    ap.add_argument("--timeout", type=float, default=10.0, help="seconds to wait for each answer (default 10)")
    ap.add_argument("--settle", type=float, default=0.5,
                    help="after a publishDiagnostics, keep listening this long for newer ones (default 0.5)")
    ap.add_argument("--strict", action="store_true", help="exit 3 if a content check fails")
    ap.add_argument("--hide-stderr", action="store_true", help="do not show the server stderr")
    ap.add_argument("-v", "--verbose", action="store_true", help="print every raw JSON-RPC message")
    args = ap.parse_args()

    if not args.all and not args.files:
        ap.error("give FILEs or --all")
    try:
        hovers = [parse_pos(p, args.zero_based) for p in args.hover]
        defs = [parse_pos(p, args.zero_based) for p in args.definition]
    except argparse.ArgumentTypeError as e:
        ap.error(str(e))
    for f in args.files:
        if not os.path.isfile(f):
            ap.error("no such file: %s" % f)

    s = Session(args)
    try:
        if args.all:
            scenario(s)
        else:
            s.start()
            uris = [s.open(f)[0] for f in args.files]
            for (l, c) in hovers:
                s.hover(uris[0], l, c)
            for (l, c) in defs:
                s.definition(uris[0], l, c)
            s.server.shutdown()
    except ProtocolError as e:
        s.tr.log("PROTOCOL ERROR: %s" % e)
        if s.server is not None:
            s.server.kill()
            if s.server.stderr_lines and args.hide_stderr:
                s.tr.log("last server stderr lines:")
                for l in s.server.stderr_lines[-20:]:
                    s.tr.log("  stderr| " + l)
        return 1
    except KeyboardInterrupt:
        if s.server is not None:
            s.server.kill()
        return 1
    if s.check_failures:
        s.tr.log("protocol OK; %d content check(s) failed:" % len(s.check_failures))
        for f in s.check_failures:
            s.tr.log("  - " + f)
        return 3 if args.strict else 0
    s.tr.log("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
