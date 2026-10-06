#!/usr/bin/env python3
"""Tests for the error-resilient Elpi parser (Mastic), on top of recov.exe.

  recov.py show FILE...           compact view of what the parser recovers
  recov.py check [--promote] DIR  hand-written battery: DIR/*.elpi vs DIR/*.expected
  recov.py fuzz [options] FILE... simulate editing: damage valid programs and
                                  check what the parser recovers
"""
import argparse, collections, concurrent.futures, json, os, random, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
def _exe():
    """recov.exe in the dune _build tree above this directory"""
    d, rel = HERE, []
    while not os.path.isdir(os.path.join(d, "_build")):
        d, base = os.path.split(d)
        if not base:
            sys.exit("recov.py: no _build directory found, run dune build first")
        rel.insert(0, base)
    return os.path.join(d, "_build", "default", *rel, "recov.exe")


EXE = os.environ.get("RECOV_EXE") or _exe()
TIMEOUT = 5

LOC = re.compile(r'File "([^"]*)", line -?\d+, column -?\d+, characters (-?\d+)-(-?\d+):;?')
PIECE = re.compile(r"\('((?:[^'\\]|\\.)*)',(\d+),(\d+)\)")
KIND = re.compile(r"^\(Ast\.Decl\.(\w+)")
NAME = re.compile(r"Ast\.Term\.Const ([^ ;)]+)|name = ([^ ;]+);")


def term_error_spans(raw, path):
    """spans of the (Ast.Term.Err ...) nodes: the loc that follows the node"""
    spans, i = [], 0
    while True:
        i = raw.find("(Ast.Term.Err", i)
        if i < 0:
            return spans
        depth, j, instr = 0, i, False
        while j < len(raw):
            c = raw[j]
            if instr:
                if c == "\\":
                    j += 1
                elif c == '"':
                    instr = False
            elif c == '"':
                instr = True
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        m = LOC.search(raw, j)
        if m and m.group(1) == path:
            spans.append((int(m.group(2)), int(m.group(3))))
        i = j


def union_length(spans):
    total, end = 0, None
    for b, e in sorted(spans):
        if end is None or b > end:
            total += e - b
            end = e
        elif e > end:
            total += e - end
            end = e
    return total


class Decl:
    def __init__(self, raw, path):
        self.raw = raw
        m = KIND.match(raw)
        self.kind = m.group(1) if m else "?"
        if self.kind == "Error":
            self.pieces = [(s, int(b), int(e)) for s, b, e in PIECE.findall(raw)]
            spans = [(b, e) for _, b, e in self.pieces]
        else:
            self.pieces = []
            # only positions in this file: an accumulate also holds the other file
            spans = [(int(b), int(e)) for f, b, e in LOC.findall(raw) if f == path]
        self.b = min((b for b, _ in spans), default=None)
        self.e = max((e for _, e in spans), default=None)
        self.term_errors = term_error_spans(raw, path) if self.kind != "Error" else []
        n = NAME.search(raw)
        self.name = (n.group(1) or n.group(2)) if n else ""
        # positions removed: two declarations are equal if they differ only by where they are
        self.norm = re.sub(r"\s+", "", re.sub(r'file_name =\s*"[^"]*"', "", LOC.sub("", raw)))
        if self.kind == "Accumulated":
            # a file accumulated twice is read once: compare the file names only
            self.norm = "Accumulated" + " ".join(
                os.path.basename(f) for f in re.findall(r'file_name =\s*"([^"]*)"', raw))


class Result:
    def __init__(self, status, lines=(), path=None):
        self.status = status  # ok | crash | timeout
        self.errors, self.completions, self.decls, self.exn = [], [], [], None
        for l in lines:
            tag, _, rest = l.partition("\t")
            if tag == "E":
                off, st = rest.split("\t")
                self.errors.append(("parse", int(off), "state " + st))
            elif tag == "L":
                off, msg = rest.split("\t", 1)
                self.errors.append(("lex", int(off), msg))
            elif tag == "C":
                off, txt = rest.split("\t", 1)
                self.completions.append((int(off), txt))
            elif tag == "D":
                self.decls.append(Decl(rest, path))
            elif tag == "X":
                self.exn = rest

    @property
    def error_decls(self):
        return [d for d in self.decls if d.kind == "Error"]


def run(path, include=None):
    cmd = [EXE, path] + ([include] if include else [])
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT, errors="replace")
    except subprocess.TimeoutExpired:
        return Result("timeout", path=path)
    lines = p.stdout.splitlines()
    if p.returncode != 0:
        r = Result("crash", lines, path)
        if r.exn is None:
            r.exn = (p.stderr.strip().splitlines() or ["exit %d" % p.returncode])[-1]
        return r
    return Result("ok", lines, path)


# ---------------------------------------------------------------- show / check

def linecol(text, off):
    line = text.count("\n", 0, off) + 1
    return "%d:%d" % (line, off - (text.rfind("\n", 0, off) + 1))


def show(path, include=None):
    text = open(path, encoding="utf-8", errors="replace").read()
    r = run(path, include)
    out = []
    if r.status != "ok":
        out.append("%s: %s" % (r.status.upper(), r.exn or ""))
    for kind, off, what in r.errors:
        out.append("%s error at %s (%s)" % (kind, linecol(text, off), what))
    for off, txt in r.completions:
        out.append("inserted %r at %s" % (txt, linecol(text, off)))
    for d in r.decls:
        where = "%s-%s" % (linecol(text, d.b), linecol(text, d.e)) if d.b is not None else "?"
        if d.kind == "Error":
            unknown = sum(1 for s, _, _ in d.pieces if s == "TODO")
            src = text[d.b:d.e].replace("\n", "⏎")
            out.append("  %-11s ERROR «%s»  (%d pieces, %d without text)" % (where, src, len(d.pieces), unknown))
        else:
            out.append("  %-11s %s %s" % (where, d.kind, d.name))
    return "\n".join(out) + "\n"


def check(d, promote):
    failed = 0
    for f in sorted(os.listdir(d)):
        if not f.endswith(".elpi"):
            continue
        path = os.path.join(d, f)
        exp = path[:-5] + ".expected"
        got = show(path)
        old = open(exp).read() if os.path.exists(exp) else None
        if got == old:
            print("OK      ", f)
            continue
        if promote:
            open(exp, "w").write(got)
            print("PROMOTED", f)
        else:
            failed += 1
            print("FAIL    ", f)
            print("--- expected\n%s--- got\n%s" % (old or "(missing)\n", got))
    return 1 if failed else 0


# ---------------------------------------------------------------- fuzz

TOKEN = re.compile(r'"(?:[^"\\]|\\.)*"|[A-Za-z_0-9.\'?]+|\S')


def tokens(text):
    """(start, end) of the tokens, roughly, skipping % comments"""
    out = []
    for m in TOKEN.finditer(text):
        ls = text.rfind("\n", 0, m.start()) + 1
        if "%" in text[ls:m.start()]:
            continue
        out.append((m.start(), m.end()))
    return out


def mutations(text, rng, per_kind):
    """yield (kind, damaged_start, damaged_end, new_text); the damage is [a, b) in the original"""
    toks = tokens(text)
    if not toks:
        return
    lines, pos = [], 0
    for l in text.splitlines(keepends=True):
        if l.strip() and not l.lstrip().startswith("%"):
            lines.append((pos, pos + len(l)))
        pos += len(l)

    def pick(xs, n):
        return rng.sample(xs, min(n, len(xs)))

    for a, _ in pick(toks, per_kind):  # typing in progress: the file stops here
        yield "truncate", a, len(text), text[:a]
    for a, b in pick(toks, per_kind):
        yield "del-token", a, b, text[:a] + text[b:]
    for a, b in pick(lines, per_kind):
        yield "del-line", a, b, text[:a] + text[b:]
    for _ in range(per_kind if len(lines) > 2 else 0):
        i = rng.randrange(len(lines))
        j = min(len(lines) - 1, i + rng.randint(1, 5))
        a, b = lines[i][0], lines[j][1]
        yield "del-chunk", a, b, text[:a] + text[b:]
    closers = [(a, b) for a, b in toks if text[a:b] in (")", "]", "}")]
    closers += [(b - 1, b) for a, b in toks if text[a:b].endswith(".") and (b == len(text) or text[b].isspace())]
    for a, b in pick(closers, per_kind):
        yield "del-closer", a, b, text[:a] + text[b:]
    for a, b in pick(toks, per_kind):  # start of a new token being typed
        yield "half-token", a + (b - a) // 2, b, text[:a + (b - a) // 2] + text[b:]


def fuzz_file(args):
    path, seed, per_kind, keep_dir = args
    text = open(path, encoding="utf-8", errors="replace").read()
    orig = run(path)
    if orig.status != "ok" or orig.errors or orig.error_decls or not orig.decls:
        return path, None, []
    decls = orig.decls
    if any(d.b is None for d in decls):
        return path, None, []
    # a declaration owns the text up to the next one (its final '.' included)
    owns = [(d.b if i else 0, decls[i + 1].b if i + 1 < len(decls) else len(text)) for i, d in enumerate(decls)]
    rng = random.Random("%s:%d" % (os.path.basename(path), seed))
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        for n, (kind, a, b, new) in enumerate(mutations(text, rng, per_kind)):
            mpath = os.path.join(tmp, "m%d.elpi" % n)
            open(mpath, "w").write(new)
            r = run(mpath, os.path.dirname(os.path.abspath(path)))
            hit = [i for i, (s, e) in enumerate(owns) if s < max(b, a + 1) and a < e]
            expected = [i for i in range(len(decls)) if i not in hit]
            found = collections.Counter(d.norm for d in r.decls)
            lost = []
            for i in expected:
                if found[decls[i].norm] > 0:
                    found[decls[i].norm] -= 1
                else:
                    lost.append(i)
            near = set()
            for i in hit:
                near |= {i - 1, i + 1}
            row = dict(file=os.path.basename(path), kind=kind, a=a, b=b, status=r.status,
                       exn=r.exn, decls=len(decls), hit=len(hit), expected=len(expected),
                       lost_near=sum(1 for i in lost if i in near),
                       lost_far=sum(1 for i in lost if i not in near),
                       errors=len(r.errors), error_decls=len(r.error_decls),
                       # text inside errors: declaration errors and errors inside terms
                       error_chars=union_length([(d.b, d.e) for d in r.error_decls if d.b is not None]
                                                + [sp for d in r.decls for sp in d.term_errors]),
                       damage=b - a, size=len(new))
            # the part of the file outside errors; nothing when the parser fails
            row["parsed"] = 1 - row["error_chars"] / max(1, len(new)) if r.status == "ok" else 0.0
            if keep_dir and (r.status != "ok" or row["lost_far"]):
                name = "%s.%s.%d.elpi" % (os.path.basename(path)[:-5], kind, n)
                open(os.path.join(keep_dir, name), "w").write(new)
                row["kept"] = name
            rows.append(row)
    return path, len(decls), rows


def fuzz(files, seed, per_kind, jobs, keep_dir, out_json):
    if keep_dir:
        os.makedirs(keep_dir, exist_ok=True)
    rows, skipped = [], []
    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        for path, n, rs in ex.map(fuzz_file, [(f, seed, per_kind, keep_dir) for f in files]):
            if n is None:
                skipped.append(os.path.basename(path))
            rows += rs
    if out_json:
        json.dump(rows, open(out_json, "w"), indent=0)
    print("files: %d used, %d skipped (the original does not parse cleanly)" % (len(files) - len(skipped), len(skipped)))
    hdr = "%-11s %6s %6s %7s %8s %9s %9s %8s %10s %8s" % (
        "edit", "runs", "crash", "timeout", "expected", "lost-near", "lost-far", "far>0", "err-chars", "parsed%")
    print(hdr)
    print("-" * len(hdr))
    kinds = sorted(set(r["kind"] for r in rows), key=lambda k: [r["kind"] for r in rows].index(k))
    for k in kinds + ["TOTAL"]:
        rs = [r for r in rows if k == "TOTAL" or r["kind"] == k]
        ok = [r for r in rs if r["status"] == "ok"]
        print("%-11s %6d %6d %7d %8d %9d %9d %8d %10.1f %8.2f" % (
            k, len(rs), sum(r["status"] == "crash" for r in rs), sum(r["status"] == "timeout" for r in rs),
            sum(r["expected"] for r in ok), sum(r["lost_near"] for r in ok), sum(r["lost_far"] for r in ok),
            sum(r["lost_far"] > 0 for r in ok),
            sum(r["error_chars"] for r in ok) / max(1, len(ok)),
            100 * sum(r["parsed"] for r in rs) / max(1, len(rs))))
    exns = collections.Counter(r["exn"] for r in rows if r["status"] == "crash")
    if exns:
        print("\ncrashes:")
        for e, c in exns.most_common():
            print("  %5d  %s" % (c, e[:150]))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("show"); s.add_argument("files", nargs="+")
    s.add_argument("--include", help="where to find accumulated files")
    c = sub.add_parser("check"); c.add_argument("dir"); c.add_argument("--promote", action="store_true")
    f = sub.add_parser("fuzz"); f.add_argument("files", nargs="+")
    f.add_argument("--seed", type=int, default=0)
    f.add_argument("--per-kind", type=int, default=10, help="mutations of each kind per file")
    f.add_argument("-j", type=int, default=os.cpu_count())
    f.add_argument("--keep", help="directory where to save the failing mutants")
    f.add_argument("--json", help="write every run to this file")
    a = ap.parse_args()
    if a.cmd == "show":
        for p in a.files:
            if len(a.files) > 1:
                print("===", p)
            sys.stdout.write(show(p, a.include))
    elif a.cmd == "check":
        sys.exit(check(a.dir, a.promote))
    else:
        fuzz(a.files, a.seed, a.per_kind, a.j, a.keep, a.json)


if __name__ == "__main__":
    main()
