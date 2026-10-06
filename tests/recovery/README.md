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
  checks what the parser recovers. The summary of a run on `tests/sources`
  is in `baseline.txt`.

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

## Baseline (error-parser at 8c41fe01, Mastic at 69f6b83)

```
edit          runs  crash timeout expected lost-near  lost-far    far>0  err-chars
----------------------------------------------------------------------------------
truncate      1927     35       0    10272        26         0        0       40.8
del-token     1927      9       0    18010       156         9        9       27.8
del-line      1382      7       0    16233        52         3        3        9.0
del-chunk     1820     12       0    14879        39         0        0       14.0
del-closer    1486      6       0    17150       658        28       28       83.8
half-token    1927     42       0    17825       169         8        8       26.1
TOTAL        10469    111       0    94369      1100        48       48       33.0
```

What the current recovery does: on an unexpected token, it forces a
reduction when inside a `term`, otherwise it turns the token into an
`ERROR_TOKEN`; Mastic then pops the stack into the error until it reaches a
state that accepts `ERROR_TOKEN`, and only `decl` does. So the unit of
recovery is the declaration: the damaged declaration becomes one
`Decl.Error` and parsing restarts after its `.`. When there is no error the
undamaged declarations are kept almost always (1100 + 48 losses out of 94369).

Problems found:

1. **Crashes (111 runs, 1%)**, the parser raises instead of recovering:
   - Mastic assertion `errorResilientParser.ml:271` (26), at end of file when
     fewer than two stack items can be merged; smallest case: a file
     containing only `:`.
   - lexer errors are exceptions, not `ERROR_TOKEN`s: unterminated string (24),
     unterminated comment and unknown characters such as `$`
     (`Failure "lexing: empty token"`, 17).
   - errors raised by semantic actions are not recovered: `NotInProlog`
     (e.g. `main :- (x\ x)  (x\ X).`), `bind '\' operator must
     follow a name`, `Macro name must begin with '@'`, mixfix directives.
   - `Invalid_argument "String.sub"` (20), not investigated yet.
   - `accumulate` of a file that does not exist (being typed) is a failure.
2. **Content of errors is lost**: inside a `Decl.Error` only the positions
   survive, each piece is `('TODO', start, end)` because
   `reduce_as_parse_error` only knows `decl`. Each error also starts with an
   empty piece at the end of the previous declaration.
3. **Declaration-sized errors**: one error in a long clause loses the whole
   clause (`cases/29_error_in_long_clause`); deleting a closing bracket
   (`del-closer`) gives errors of 84 characters on average.
4. **Bad restarts**: after an error the tail of the clause can be parsed as a
   new, bogus clause (`cases/04_close_paren`, `06_bad_list_tail`, `29`), and
   an error can swallow the following declarations
   (`typeabbrev xx` with `bool.` deleted also loses the `namespace` and the
   `pred` after it; `pred` with its name deleted turns `:name "name1" c1.`
   into a clause `name "name1" c1`).
5. **No error at all** for a missing `.` between two clauses (`p 2` followed
   by `p 3.` is the clause `p 2 p 3`), which is valid Elpi but where an
   editor would like a warning.
6. Unrelated: some locations have a negative column (`column -25` in
   `findall.elpi`).

## The hand-written cases

`cases/` has 31 small programs, one kind of error each, usually between two
valid clauses `p 1.` and `p 3.`; their `.expected` record the current
behaviour (crashes included), so that improvements show up as diffs.
