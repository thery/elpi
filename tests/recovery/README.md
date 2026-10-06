# Tests for the error-resilient parser

Tools to measure how well the Mastic-based parser (branch `error-parser`)
recovers from syntax errors, as a language server would need while the user
is typing.

- `recov.exe FILE` runs the resilient parser (`Parse.Internal.program_resilient`)
  and prints the errors, the inserted tokens and the declarations.
- `recov.py show FILE` prints a compact view of what is recovered.
- `recov.py check cases` runs the hand-written battery: each `cases/*.elpi`
  is compared to its `.expected` (`--promote` to update them).
- `recov.py fuzz FILE...` simulates editing: it damages valid programs and
  checks what the parser recovers. The summaries of a run on `tests/sources`
  are in `baseline.txt` (before) and `improved.txt` (after).

## Running

Mastic is not on opam yet: clone it next to elpi and build both in one dune
workspace, or `opam pin add mastic https://github.com/gares/mastic.git`.

```
git clone https://github.com/gares/mastic.git
git clone -b mastic-recovery-tests https://github.com/thery/elpi.git
echo '(lang dune 3.0)' > dune-workspace
dune build ./elpi/tests/recovery/recov.exe
python3 elpi/tests/recovery/recov.py check elpi/tests/recovery/cases
python3 elpi/tests/recovery/recov.py fuzz --keep /tmp/mutants elpi/tests/sources/*.elpi
```

`MASTIC_DEBUG=1` turns on the trace of Mastic (beware: when running `elpi`,
this traces `builtin.elpi` too).

## The editing simulation

For each program of `tests/sources` that parses without errors, and for each
kind of edit, 10 random edits (fixed seed):

| edit | what it simulates |
|---|---|
| `truncate` | the file stops at a token: the rest is not typed yet |
| `del-token` | one token deleted |
| `del-line` | one line deleted |
| `del-chunk` | 2 to 6 consecutive lines deleted |
| `del-closer` | one `)`, `]`, `}` or final `.` deleted |
| `half-token` | a token cut in the middle: it is being typed |

Each declaration of the original owns its text up to the next declaration.
The edit damages the declarations whose text it touches; every other
declaration is *expected* to be recovered unchanged (positions and spacing
aside). The columns:

- `crash`, `timeout`: the parser did not return;
- `expected`: undamaged declarations, summed over the runs;
- `lost-near`: expected declarations not recovered, next to a damaged one
  (often unavoidable: deleting a `.` merges two clauses);
- `lost-far`: expected declarations not recovered, further away (a real loss);
- `far>0`: runs with at least one far loss;
- `err-chars`: average number of characters inside `Error` declarations.

## Results

`baseline.txt` is the recovery of the `error-parser` branch (8c41fe01, Mastic
69f6b83), `improved.txt` the recovery of this branch, measured the same way
(10 edits of each kind for each of the 196 programs, seed 0):

| | error-parser | this branch |
|---|---|---|
| crashes (out of 10469 runs) | 92 | **21** |
| declarations lost next to the edit | 1097 | **641** |
| declarations lost further away | 45 (in 45 runs) | **30 (in 23 runs)** |
| characters inside `Error` declarations, per run | 33.0 | **29.3** |

On the 198 programs of `tests/sources` themselves (valid ones, and the
ones testing syntax errors), the declarations and errors are identical with
both versions. `dune runtest` passes (`test_lexer` now accepts an
`ERROR_TOKEN` where it expected a lexing error); the main test runner of
Elpi could not be run here, it needs `ANSITerminal`.

### What the recovery of error-parser does

On an unexpected token, it forces a reduction when inside a `term`, otherwise
it turns the token into an `ERROR_TOKEN`; Mastic then pops the stack into
the error until it reaches a state that accepts `ERROR_TOKEN`, and only
`decl` does. So the damaged declaration becomes one `Decl.Error`. Problems:

- crashes: lexer errors are exceptions (unterminated string or comment,
  unknown character such as `$`), and at the end of the file turning `EOF`
  into an error hits an assertion of Mastic (a file containing only `:`);
- after the error, the rest of the clause is parsed as new, bogus clauses
  (`p X :- q X), r.` gives an error and a clause `r`);
- an error swallows the following declarations when the `.` is missing
  (`typeabbrev xx` followed by `namespace foo {` and a `pred`);
- a missing `)`, `]` or `}` turns the whole clause into an error.

### What this branch changes (src/parser/parse.ml, lexer.mll.in)

The grammar is unchanged, only the recovery strategy and the lexer change:

1. **Restart points.** A token at the beginning of a line, or a keyword
   that begins a declaration (`pred`, `func`, `type`, `kind`, `namespace`,
   `typeabbrev`, `accumulate`, `shorten`, `macro`, `constraint`, `rule`),
   that does not fit closes the current declaration as an error
   (`GenerateHole`) and parsing restarts at that token.
2. **Panic mode.** After a token is turned into an error, the following
   tokens are turned into errors too, up to the next `.` or restart point,
   and consecutive `Decl.Error` are merged into one.
3. **Completion.** At a `.` or at the end of the file that does not fit, the
   recovery inserts the missing `)`, `]`, `}` (and `.` at the end of the
   file) when the automaton accepts it (`token_of_terminal` +
   `GenerateToken`): `p X :- q (X, r.` is now the clause `p X :- q (X, r).`
   with an error, instead of an `Error` declaration.
4. **End of file.** When nothing can be inserted, a hole closes the current
   declaration as an error, instead of turning `EOF` into an error (which
   crashed Mastic).
5. **Lexer.** An unknown character is an `ERROR_TOKEN`; an unterminated
   string, quotation or comment is an `ERROR_TOKEN` for its opening `"`, `{{`
   or `/*`, and lexing restarts just after it (the file is read in a string
   for that). These errors are recorded by the lexer (`Lexer.errors`) and
   reported with the ones of the parser, since Mastic does not report the
   `ERROR_TOKEN`s it receives.

### What remains

- 21 crashes: exceptions raised by the semantic actions of the grammar
  (`NotInProlog` from `mkApp`, `bind '\' operator must follow a name`,
  `Macro name must begin with '@'`, mixfix directives) and an `accumulate`
  of a file that does not exist. They need Mastic to catch exceptions of
  semantic actions, or the actions to build errors instead of raising.
- Inside a `Decl.Error` only positions survive (`('TODO', start, end)`):
  `reduce_as_parse_error` only knows `decl`. Error nodes in `term` would keep
  the content and make errors smaller than a declaration.
- Deleting a `.` merges two clauses into a valid one (`p 2` then `p 3.` is
  `p 2 p 3`): nothing to recover, this is most of the remaining near losses.
- Deleting the closing `"` of a string: the string runs up to the next `"`,
  which may be lines later (the 15 far losses of `half-token`).
- Some far losses are an artefact of the measure: in `index2.elpi` many
  clauses are identical, and when two of them are merged the lost one is
  counted far away.
- Unrelated: some locations have a negative column (`column -25` in
  `findall.elpi`).

## The hand-written cases

`cases/` has 31 small programs, one kind of error each, usually between two
valid clauses `p 1.` and `p 3.`; their `.expected` record the current
behaviour (crashes included), so that improvements show up as diffs.
