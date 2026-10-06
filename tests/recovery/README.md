# Error recovery for the Elpi parser

A language server sees programs while they are being typed, so they are
almost never syntactically correct. The branch `error-parser` makes the Elpi
parser *error resilient* with [Mastic](https://github.com/gares/mastic):
instead of stopping at the first syntax error, it always returns the list of
declarations, the broken parts being `Decl.Error` nodes.

This branch adds

- **tests** measuring how good that recovery is: 31 hand-written broken
  programs, and a simulation of editing on the 196 valid programs of
  `tests/sources`;
- a **better recovery**: a new strategy in `src/parser/parse.ml` and a
  lexer that does not raise (`src/parser/lexer.mll.in`). The grammar is
  unchanged, and on the programs of `tests/sources` the output of the parser
  (declarations and errors) is identical.

## What the new recovery improves

On 10 469 simulated edits (described [below](#the-editing-simulation)), with
95 000 declarations that the edit does not touch and that should therefore
be recovered unchanged:

|                                                | `error-parser` | this branch | |
|------------------------------------------------|---------------:|------------:|--|
| parser crashes                                 | 92             | **21**      | −77 % |
| untouched declarations lost next to the edit   | 1 097          | **641**     | −42 % |
| untouched declarations lost further away       | 45             | **30**      | −33 % |
| characters inside errors, per edit             | 33.0           | **29.3**    | −11 % |

Per kind of edit: [`baseline.txt`](baseline.txt) (before) and
[`improved.txt`](improved.txt) (after). The improvements, one by one:

### 1. The rest of a broken clause is no longer read as new clauses

Before, after the error the parser restarted in the middle of the clause, so
its end became one or more bogus clauses. Now, after an error, the tokens up
to the next `.` (or the next restart point, see 2) belong to the error
(*panic mode*), and consecutive errors are merged.

```prolog
p 1.
p X :- q X), r.
p 3.
```
```
before                                   after
  1:0-1:3   Clause p                       1:0-1:3   Clause p
  1:4-2:11  ERROR «p X :- q X)»            1:4-2:15  ERROR «p X :- q X), r.»
  2:11-2:12 ERROR «,»                      3:0-3:3   Clause p
  2:13-2:14 Clause r       ← bogus
  3:0-3:3   Clause p
```

In a long clause, the end of the body `t X, u X.` was a bogus clause `,`
([`cases/29_error_in_long_clause`](cases/29_error_in_long_clause.elpi)).
This is most of the drop of the near losses (`del-token`: 155 → 81,
`half-token`: 168 → 104).

### 2. An unfinished declaration no longer swallows the next ones

While typing, a declaration is often unfinished, without its `.`. Before,
the error went on and swallowed the following declarations. Now a token
that does not fit and that is at the beginning of a line, or is a keyword
that can only begin a declaration (`pred`, `func`, `type`, `kind`,
`namespace`, `typeabbrev`, `accumulate`, `shorten`, `macro`, `constraint`,
`rule`), closes the current declaration as an error, and parsing restarts
there.

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

### 3. A missing closing bracket no longer loses the clause

Before, when a `.` arrived inside an open `(` or `{`, the whole clause
became an error. Now the recovery inserts the missing `)`, `]` or `}` (and,
at the end of the file, the final `.`) when the parser accepts it, so the
clause is kept, and the insertion is reported.

```prolog
p 1.
p X :- q (X, r.
p 3.
```
```
before                                   after
  1:0-1:3   Clause p                       parse error at 2:14
  1:4-2:15  ERROR «p X :- q (X, r.»        inserted ')' at 2:14
  3:0-3:3   Clause p                       1:0-1:3   Clause p
                                           2:0-2:14  Clause p X :- q (X, r)
                                           3:0-3:3   Clause p
```

When a closer is deleted (`del-closer`), errors are half as large: 83.8 →
40.6 characters per edit.

### 4. The end of the file no longer breaks the parser

Before, at the end of the file the strategy turned `EOF` into an error.
Mastic then merges the two items on top of the stack, so it either swallowed
the previous, correct declaration, or crashed on an assertion when there was
only one item (`truncate`: 35 crashes). Now a hole closes the unfinished
declaration as an error, and `EOF` is read normally.

```prolog
p 1.
:
```
```
before                                   after
  2:0-2:1   ERROR «:»                      1:0-1:3   Clause p
            (p 1. is lost)                 2:0-2:1   ERROR «:»
```

`truncate` (the file being typed, stopping anywhere): 35 crashes → 0, and 26
lost declarations → 0.

### 5. Lexical errors no longer stop everything

Before, an unknown character (`$`), an unterminated string, quotation or
comment raised an exception: nothing was recovered (42 crashes, mostly on
`half-token`). Now the lexer returns an `ERROR_TOKEN`; for an unterminated
string, quotation or comment the error is the opening `"`, `{{` or `/*`,
and lexing restarts right after it, so the rest of the file is still
parsed. These errors are reported with the ones of the parser.

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
                                           1:4-2:3   ERROR «p "»
                                           2:3-2:6   Clause abc
                                           3:0-3:3   Clause p
```

## How the recovery works

Mastic drives the Menhir parser token by token. When a token does not fit,
it asks the strategy (`Recovery.handle_unexpected_token` in `parse.ml`) what
to do: reduce, turn the token into an `ERROR_TOKEN`, insert a token, or
insert a hole (an empty `ERROR_TOKEN`). An `ERROR_TOKEN` that does not fit is
merged with the top of the parser stack, until a rule accepts it; in the
grammar only `decl` does, so an error always covers whole declarations.

| the token that does not fit is …                    | `error-parser`  | this branch |
|-----------------------------------------------------|-----------------|-------------|
| inside a term that can be reduced                   | reduce          | reduce |
| `.` or end of file, and `)` `]` `}` `.` can be inserted | turn into error | **insert it** |
| end of file, nothing to insert                      | turn into error | **insert a hole** |
| at the beginning of a line, or a declaration keyword | turn into error | **insert a hole**, restart at this token |
| anything else                                       | turn into error | turn into error, and **skip to the next `.` or restart point** |

On this branch, consecutive `Decl.Error` are also merged into one, and the
lexer turns its errors into `ERROR_TOKEN`s, which it records
(`Lexer.errors`) for the parser to report them, since Mastic does not report
the `ERROR_TOKEN`s it receives.

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
what the new recovery changed).

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
| `err-chars` | characters inside `Error` declarations, per run |

## What remains to do

- **21 crashes**: exceptions raised by the semantic actions of the grammar
  (`NotInProlog` from `mkApp`, `bind '\' operator must follow a name`,
  `Macro name must begin with '@'`, mixfix directives), and `accumulate` of
  a file that does not exist. Either Mastic catches exceptions of semantic
  actions, or the actions build errors instead of raising.
- **Errors lose their content**: inside a `Decl.Error` only the positions
  survive (`('TODO', start, end)`), since `reduce_as_parse_error` only knows
  `decl`. Error nodes in `term` (a grammar change) would keep the content and
  make errors smaller than a whole declaration.
- **Not handled yet**: a missing `]` is not inserted (`p X :- q [X, r.` is
  still one error), and after a lexical error the rest of the clause is
  still read as a clause (`p X :- q X $ r.` gives a clause `r`).
- **Unavoidable losses**: deleting a `.` merges two clauses into a valid one
  (`p 2` then `p 3.` is `p 2 p 3`), most of the remaining near losses;
  deleting the closing `"` of a string makes it run to the next `"`, maybe
  lines later (the far losses of `half-token`, 7 → 15, are such edits, which
  crashed before and are now parsed).
- **Artefacts of the measure**: in `index2.elpi` many clauses are identical,
  and when two of them merge, the loss is counted far away.
- Unrelated, found on the way: some locations have a negative column
  (`column -25` in `findall.elpi`).
- `dune runtest` passes (`test_lexer` now accepts an `ERROR_TOKEN` where it
  expected a lexing error); the main test runner of Elpi was not run, it
  needs `ANSITerminal`.
