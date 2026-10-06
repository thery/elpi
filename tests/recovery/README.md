# Error recovery for the Elpi parser

A language server sees programs while they are being typed, so they are
almost never syntactically correct. The branch `error-parser` makes the Elpi
parser *error resilient* with [Mastic](https://github.com/gares/mastic):
instead of stopping at the first syntax error, it always returns the list of
declarations, the broken parts being error nodes.

This branch adds

- **tests** measuring how good that recovery is: 31 hand-written broken
  programs, and a simulation of editing on the 196 valid programs of
  `tests/sources`;
- a **better recovery**, evaluated with these tests: a new strategy
  (`src/parser/parse.ml`), error nodes inside terms (`Term.Err`), a lexer
  that does not raise, and semantic actions that do not raise while
  recovering.

Nothing changes for Elpi itself: on the 198 programs of `tests/sources`,
the normal parsing path (the one that raises the first error) gives exactly
the same declarations and the same errors as on `error-parser`.

## What the new recovery improves

On 10 469 simulated edits (described [below](#the-editing-simulation)),
with 95 000 declarations that the edit does not touch and that should be
recovered unchanged:

|                                               | `error-parser` | this branch |
|-----------------------------------------------|---------------:|------------:|
| **part of the file parsed** (outside errors)  | 83.8 %         | **95.8 %**  |
| parser crashes                                | 92             | **0**       |
| untouched declarations lost next to the edit  | 1 097          | **643**     |
| untouched declarations lost further away      | 45             | **30**      |
| characters inside errors, per edit            | 33.0           | **6.8**     |

The part of the file that is parsed, per kind of edit:

| edit | `error-parser` | this branch |
|---|---:|---:|
| `truncate` (the file is being typed) | 66.0 % | **91.0 %** |
| `del-token` | 86.3 % | **94.2 %** |
| `del-line` | 96.9 % | **99.7 %** |
| `del-chunk` | 93.0 % | **99.6 %** |
| `del-closer` (a `)` `]` `}` `.` deleted) | 76.9 % | **96.4 %** |
| `half-token` (a token being typed) | 86.2 % | **95.3 %** |

Full numbers: [`baseline.txt`](baseline.txt) (before),
[`improved.txt`](improved.txt) (after). The improvements, one by one:

### 1. An error no longer throws away its clause

On `error-parser` only a whole declaration can be an error, so one bad
token loses the whole clause. Now a term can be an error too (`closed_term:
| ERROR_TOKEN`, AST node `Term.Err`): the bad token becomes an erroneous
argument, and the clause around it is kept.

```prolog
p 1.
p X :-
  q X,
  r X,
  s X X ),
  t X,
  u X.
p 3.
```
```
before                                       after
  1:0-1:3   Clause p                           parse error at 5:8
  1:4-5:9   ERROR «p X :- q X, r X, s X X )»   1:0-1:3   Clause p
  5:9-5:10  ERROR «,»                          2:0-7:5   Clause p X :- …   (the ')' is an error inside)
  6:2-7:5   Clause ,       ← bogus             8:0-8:3   Clause p
  8:0-8:3   Clause p
```

An error also keeps its content: inside `Term.Err` are the parsed subterms
(`reduce_as_parse_error` now builds term errors), where `error-parser` only
kept positions (`('TODO', start, end)`).

### 2. A missing token is inserted

When the declaration cannot be finished, the recovery inserts what is
missing and reports it: a closing `)`, `]` or `}`, the final `.`, or a hole
`_` for a missing term.

```prolog
p 1.
p X :- q (X, r.            p X :- X is 2 + .           p X :- q X,      (end of file)
p 3.
```
```
inserted ')' at 2:14       inserted '_' at 2:16        inserted '.' and '_' at 2:11
  2:0-2:14  Clause …         2:0-2:16  Clause …          2:0-2:11  Clause p X :- q X, _
```

On `error-parser` these three clauses were thrown away.

### 3. An unfinished declaration no longer swallows the next ones

While typing, a declaration is often unfinished. A token that does not fit
and that is at the beginning of a line, or that is a keyword beginning a
declaration (`pred`, `func`, `type`, `kind`, `namespace`, `typeabbrev`,
`accumulate`, `shorten`, `macro`, `constraint`, `rule`), finishes the
current declaration, and parsing restarts there. When nothing can finish it,
the declaration becomes an error (with a second error token,
`DECL_ERROR_TOKEN`, that only `decl` accepts).

```prolog
typeabbrev xx

namespace foo {
pred f i:xx.
f _.
}
```
```
before                                   after
  1:0-3:9   ERROR «typeabbrev xx           1:0-3:0   ERROR «typeabbrev xx»
              namespace»                   3:0-3:15  Namespace foo
  3:9-4:4   ERROR «foo { pred»             3:15-4:11 Pred f
  4:4-4:9   ERROR «f i:»                   5:0-5:3   Clause f
  4:9-4:11  Clause xx      ← bogus         6:0-6:1   End
  5:0-5:3   Clause f
  6:0-6:1   End
```

### 4. No more crashes

`error-parser` crashed in 92 of the edits; now in none:

- **lexical errors** (unknown character, unterminated string, quotation or
  comment) were exceptions. Now they are `ERROR_TOKEN`s; for an unterminated
  string, quotation or comment the error is the opening `"`, `{{` or `/*`,
  and lexing restarts right after it. The lexer records these errors so that
  they are reported (Mastic does not report the `ERROR_TOKEN`s it receives);
- **the end of the file**: the strategy turned `EOF` into an error, which
  made Mastic either swallow the previous, correct declaration, or fail on an
  assertion. Now the unfinished declaration is finished or becomes an error,
  and `EOF` is read normally;
- **errors of the semantic actions** (`NotInProlog` in `mkApp`, `bind '\'
  operator must follow a name`, ill-formed macros, mixfix directives,
  `accumulate` of a missing file) raised exceptions through Mastic. While
  recovering they are now *deferred* (`Ast.Term.defer`): the action returns
  an error term and the parsing goes on. The normal path of Elpi raises the
  first deferred exception, unchanged, so error messages are the same.

```prolog
p 1.
p "abc.
p 3.
```
```
before                                   after
  CRASH: Lexer.Error "missing            lex error at 2:2 (missing terminator
  terminator for string starting here"     for string starting here)
                                           1:0-1:3   Clause p
                                           2:0-2:6   Clause p
                                           3:0-3:3   Clause p
```

## How the recovery works

Mastic drives the Menhir parser token by token. When a token does not fit,
it asks the strategy (`Recovery.handle_unexpected_token` in `parse.ml`) what
to do: reduce, turn the token into an `ERROR_TOKEN`, insert a token, or
insert a hole (an empty `ERROR_TOKEN`). An `ERROR_TOKEN` that does not fit
is merged with the top of the parser stack until a rule accepts it: now a
term or a declaration.

| the token that does not fit is … | `error-parser` | this branch |
|---|---|---|
| inside a term that can be reduced | reduce | reduce |
| `.`, end of file, or a restart point (line start, declaration keyword) | turn into an error | **finish the declaration**: reduce; else insert `.` or `)` `]` `}` if the parser accepts it; else try `.` anyway (Menhir may accept it after empty reductions, that Mastic does not list); else insert a hole; else close the declaration with a `DECL_ERROR_TOKEN` |
| at the start of a declaration | turn into an error | turn into an error |
| anything else | turn into an error (the declaration is lost) | turn into an error (it becomes a term) |

Consecutive declaration errors are merged, and the errors are reported once
per position.

### How the strategy was chosen

Each rule was kept only if the simulation showed a gain. Some ideas did not
pass:

- *panic mode* (after an error, skip to the next `.`): it removed the bogus
  clauses but put their text in the error; switched off, the parsed part went
  from 84.2 % to 86.0 % with the same losses;
- a hole when nothing else fits: a hole is a valid argument, so `f _`
  followed by `}` became `f _ _ _ …` and swallowed the next declarations;
  reducing first, trying `.`, and the declaration error token fixed it.

## Running the tests

Mastic is not on opam yet: put it next to elpi in one dune workspace (or
`opam pin add mastic https://github.com/gares/mastic.git`).

```sh
git clone https://github.com/gares/mastic.git
git clone -b mastic-recovery-tests https://github.com/thery/elpi.git
echo '(lang dune 3.0)' > dune-workspace
dune build ./elpi/tests/recovery/recov.exe

# the hand-written cases
python3 elpi/tests/recovery/recov.py check elpi/tests/recovery/cases

# the editing simulation, keeping the failing edited programs
python3 elpi/tests/recovery/recov.py fuzz --keep /tmp/mutants elpi/tests/sources/*.elpi

# what is recovered from one file
python3 elpi/tests/recovery/recov.py show myfile.elpi
```

| command | what it does |
|---|---|
| `recov.exe FILE` | runs the resilient parser (`Parse.Internal.program_resilient`) and prints errors, inserted tokens and declarations, one per line |
| `recov.exe FILE --strict` | the normal path of Elpi: prints the number of declarations, or the error raised |
| `recov.py show FILE…` | compact view of what is recovered (`--include DIR` to find accumulated files) |
| `recov.py check [--promote] DIR` | compares each `DIR/*.elpi` to its `.expected`; `--promote` records the current output |
| `recov.py fuzz FILE…` | the editing simulation; `--per-kind N` (default 10), `--seed S`, `--keep DIR`, `--json FILE` (every run) |

`MASTIC_DEBUG=1` prints the trace of Mastic (when running `elpi`, it traces
`builtin.elpi` too).

## The hand-written cases

[`cases/`](cases) has 31 small programs with one kind of error each, most
of them between two valid clauses `p 1.` and `p 3.`: operators without
operand, unbalanced brackets, missing or double `.`, empty bodies, unknown
characters, unterminated strings and comments, broken `pred`, `type`,
`kind`, `namespace` and attributes, end of file in the middle of a clause,
two errors in one file. The `.expected` files record what is recovered, so
any change of the recovery shows up as a diff (`git log -p cases/` shows
how each version changed them).

## The editing simulation

For each program of `tests/sources` that parses without errors, 10 random
edits of each kind (fixed seed, so runs are reproducible):

| edit | simulates |
|---|---|
| `truncate` | the file stops at some token: the rest is not typed yet |
| `del-token` | a token deleted |
| `del-line` | a line deleted |
| `del-chunk` | 2 to 6 consecutive lines deleted |
| `del-closer` | a `)`, `]`, `}` or final `.` deleted |
| `half-token` | a token cut in the middle: it is being typed |

Each declaration of the original program owns its text up to the next
declaration. An edit damages the declarations whose text it touches; all
the others are **expected** to be recovered unchanged (positions aside).
For each kind of edit the summary gives:

| column | meaning |
|---|---|
| `crash`, `timeout` | the parser did not return |
| `expected` | untouched declarations, over all runs |
| `lost-near` | untouched declarations not recovered, next to a damaged one (often unavoidable: deleting a `.` merges two clauses) |
| `lost-far` | untouched declarations not recovered, further away: a real loss |
| `far>0` | runs with at least one far loss |
| `err-chars` | characters inside error nodes (`Decl.Error` and `Term.Err`), per run |
| `parsed%` | part of the file outside error nodes, averaged over the runs (a crash counts as 0 %) |

## What remains to do

- **Unavoidable losses**: deleting a `.` merges two clauses into a valid one
  (`p 2` then `p 3.` is `p 2 p 3`), most of the remaining near losses;
  deleting the closing `"` of a string makes it run to the next `"`, maybe
  lines later (most far losses of `half-token`).
- **Artefacts of the measure**: in `index2.elpi` many clauses are identical,
  and when two of them merge, the loss is counted far away.
- The compiler rejects `Term.Err` with "syntax error"; it is only reached
  through the resilient path, the normal path raises before.
- Unrelated, found on the way: some locations have a negative column
  (`column -25` in `findall.elpi`).
- `dune runtest` passes (`test_lexer` knows the new tokens and accepts an
  `ERROR_TOKEN` where it expected a lexing error); the main test runner of
  Elpi was not run, it needs `ANSITerminal`.
