#!/usr/bin/env python3
"""A tiny fake LSP server, only to test lsp_client.py (and the extension)
before elpi-lsp exists.  Standard library only.

- initialize: advertises Full sync, hover, definition;
- didOpen/didChange: publishes an EMPTY diagnostics list;
- hover: markdown with the word under the cursor ("fake: `word`");
- definition: first line, in the opened documents (current one first),
  that starts with the word under the cursor;
- shutdown/exit as in the spec.

--mode lets it misbehave, to check that the client detects it:
  normal | crash-on-hover | silent-definition | garbage-on-hover |
  bad-exit | error-on-hover
"""

import json
import re
import sys

MODE = "normal"
docs = {}  # uri -> text


def log(msg):
    sys.stderr.write("fake_server: %s\n" % msg)
    sys.stderr.flush()


def read_msg(inp):
    headers = {}
    while True:
        line = inp.readline()
        if not line:
            return None
        line = line.decode("ascii").strip()
        if not line:
            break
        k, v = line.split(":", 1)
        headers[k.strip().lower()] = v.strip()
    n = int(headers["content-length"])
    return json.loads(inp.read(n).decode("utf-8"))


def send(out, msg):
    body = json.dumps(msg).encode("utf-8")
    out.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    out.flush()


def word_at(uri, pos):
    lines = docs.get(uri, "").split("\n")
    if pos["line"] >= len(lines):
        return None
    line = lines[pos["line"]]
    for m in re.finditer(r"[A-Za-z_][A-Za-z0-9_\-']*", line):
        if m.start() <= pos["character"] < m.end():
            return m.group(0)
    return None


def find_def(uri, word):
    for u in [uri] + [u for u in docs if u != uri]:
        for i, line in enumerate(docs[u].split("\n")):
            if re.match(re.escape(word) + r"\b", line):
                return {"uri": u, "range": {"start": {"line": i, "character": 0},
                                            "end": {"line": i, "character": len(word)}}}
    return None


def main():
    global MODE
    if len(sys.argv) > 2 and sys.argv[1] == "--mode":
        MODE = sys.argv[2]
    inp, out = sys.stdin.buffer, sys.stdout.buffer
    log("started, mode %s" % MODE)
    shutdown = False
    while True:
        msg = read_msg(inp)
        if msg is None:
            log("stdin closed")
            sys.exit(1)
        m, rid, p = msg.get("method"), msg.get("id"), msg.get("params")
        log("received %s" % m)

        def reply(result):
            send(out, {"jsonrpc": "2.0", "id": rid, "result": result})

        def publish(uri):
            send(out, {"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                       "params": {"uri": uri, "diagnostics": []}})

        if m == "initialize":
            reply({"capabilities": {"textDocumentSync": 1, "hoverProvider": True,
                                    "definitionProvider": True},
                   "serverInfo": {"name": "fake-elpi-lsp", "version": "0"}})
        elif m == "initialized":
            send(out, {"jsonrpc": "2.0", "method": "window/logMessage",
                       "params": {"type": 3, "message": "fake server ready"}})
        elif m == "textDocument/didOpen":
            td = p["textDocument"]
            docs[td["uri"]] = td["text"]
            publish(td["uri"])
        elif m == "textDocument/didChange":
            docs[p["textDocument"]["uri"]] = p["contentChanges"][-1]["text"]
            publish(p["textDocument"]["uri"])
        elif m == "textDocument/didClose":
            docs.pop(p["textDocument"]["uri"], None)
        elif m == "textDocument/hover":
            if MODE == "crash-on-hover":
                log("crashing on purpose")
                sys.exit(2)
            if MODE == "garbage-on-hover":
                out.write(b"Content-Length: 5\r\n\r\n{oops")
                out.flush()
                continue
            if MODE == "error-on-hover":
                send(out, {"jsonrpc": "2.0", "id": rid,
                           "error": {"code": -32603, "message": "internal error on purpose"}})
                continue
            w = word_at(p["textDocument"]["uri"], p["position"])
            reply(None if w is None else
                  {"contents": {"kind": "markdown", "value": "fake: `%s`" % w}})
        elif m == "textDocument/definition":
            if MODE == "silent-definition":
                continue
            w = word_at(p["textDocument"]["uri"], p["position"])
            reply(None if w is None else find_def(p["textDocument"]["uri"], w))
        elif m == "shutdown":
            shutdown = True
            reply(None)
        elif m == "exit":
            sys.exit(3 if MODE == "bad-exit" else (0 if shutdown else 1))
        elif rid is not None:
            send(out, {"jsonrpc": "2.0", "id": rid,
                       "error": {"code": -32601, "message": "method not found: %s" % m}})


if __name__ == "__main__":
    main()
