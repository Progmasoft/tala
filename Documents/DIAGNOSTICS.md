<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Diagnostics and failure behavior

Diagnostics are a compiler interface. They must identify the stage that owns a failure, preserve source context when one
exists, and prevent invalid or stale artifacts from appearing successful.

## Structured tooling channel

Tools must consume the [TADG structured diagnostic protocol](DIAGNOSTIC-PROTOCOL.md), not parse stderr. The versioned
side channel carries stage, severity, stable code, source range, named message arguments, related locations, and fix
descriptions. It remains private to trusted local compiler integrations and is not a user-selectable emit format.

The Haskell frontend converts its one-based source positions to the protocol's zero-based scalar coordinates. The C++
implementation validates and accumulates native-stage diagnostics using the same record model. Xide owns an independent
bounded Kotlin decoder, so compatibility is tested across all three implementation languages instead of being assumed.

### Accumulation semantics

Native compiler stages use `Progmasoft::Tala::Diagnostic::Collection` when more than one component contributes records.
The collection:

- validates a record before accepting it;
- preserves the first-emission order;
- coalesces only byte-identical records;
- counts errors and warnings without treating information or hints as failures;
- applies a configured record limit;
- merges a document transactionally;
- supports snapshot, transfer, clear, and reuse without retaining stale identities.

Transactional merge matters when one stage returns a batch. If any new record is invalid or would exceed capacity, none
of that batch becomes observable. An exact duplicate is successful but does not consume capacity or increment severity
counts. Messages with different arguments, locations, related context, or fixes remain distinct even when their codes
match.

### Side-channel lifecycle

The frontend writes a complete empty TADG document after a successful check. On failure it writes the structured records
before printing the human-readable diagnostics and exiting. This makes the protocol independent of terminal wording and
ensures that an old failure file cannot survive as the apparent result of a new success.

If `TALA_DIAGNOSTICS_FILE` is absent, no protocol file is written. The variable is an implementation boundary passed by
the native driver or a trusted editor client; it is intentionally absent from public CLI help. A configured empty path,
an invalid diagnostic model, an encoding failure, or an I/O failure makes the frontend fail rather than silently leaving
the requesting tool without a trustworthy result.

Consumers use a fresh temporary path per process and remove it on every outcome. They must treat a missing file after a
normal process exit, malformed protocol bytes, unsupported versions, and oversized documents as integration failures.
Human stderr may be displayed as supplemental detail, but it must never be reparsed into synthetic diagnostic records.

### Document-version ownership

TADG version 1 describes the disk snapshot compiled by `talac`; it does not carry an editor document version. Xide records
the active version when it starts a check and publishes the resulting diagnostics only if that version remains current.
Edits made while the compiler runs therefore invalidate the result. Fixes require the same version guard before their
text edits can be applied.

Protocol columns count Unicode scalar values, whereas Kotlin strings use UTF-16 code units. An editor must map through
its line model and must not add a scalar column directly to a JVM string offset. This distinction is required for correct
highlighting after supplementary characters.

## Output channels

`talac` writes ordinary requested output to standard output and diagnostics to standard error. Help and version are parser
outcomes rendered by the driver; parsing itself does not print. This separation lets tests and embedding clients inspect a
typed parse result without redirecting global streams.

Compilation, project evaluation, tool discovery, malformed artifact, target-machine, and link failures return a nonzero
status. `talac run` returns a build failure without launching anything, and after a successful build it propagates the native
program's exit status.

## Diagnostic ownership

| Failure class | Owning layer |
| --- | --- |
| unknown command or option | C++20 CLI parser |
| missing/duplicate/out-of-scope option | C++20 CLI parser |
| invalid typed option value | C++20 CLI parser |
| project discovery or DSL validation | Kotlin project evaluator |
| source-root containment or UTF-8 decoding | Haskell source loader |
| token spelling, escape, or literal structure | Haskell Lexer |
| grammar and precedence | Haskell Parser |
| duplicate lexical binding | Haskell Renamer |
| unresolved or ambiguous reference | Haskell Name Resolution |
| type, call, return, operator, or entry rule | Haskell Type Checker |
| malformed Core or CorePrep semantics | corresponding Core verifier |
| malformed Xpp or optimization result | Xpp verifier |
| malformed Xmm or optimization result | Xmm verifier |
| missing target layout or invalid LLVM module | LLVM backend |
| object/assembly emission failure | LLVM target machine boundary |
| executable link failure | C++20 LLD driver |
| missing Formatter or Linter installation | C++20 project-tool dispatch |

A later layer should not reinterpret an earlier layer's error. For example, an unresolved name is not reported as a missing
LLVM symbol, and a malformed integer token is not split into a valid prefix plus an unrelated identifier.

## CLI parse diagnostics

The CLI schema owns canonical spelling, command scope, arity, and value domains. Useful parse failures distinguish:

- unknown command;
- unknown option;
- option valid for another command but not this command;
- missing option value;
- duplicate option;
- invalid Boolean or enumerated value;
- unexpected positional argument;
- missing required positional package coordinate;
- invalid `-Build` and `-File` combination; and
- invalid process argument vector.

Option and value spelling is case-sensitive. The diagnostic should repeat the rejected spelling and, where bounded, the
accepted domain. It must not silently accept `--help`, lowercase a target-sensitive identifier, or reinterpret a misspelled
command as a file.

`-Help` is contextual. Global help lists commands and global syntax; `talac build -Help` includes build-only `-Emit`; `talac
check -Help` does not. Help is a successful outcome and does not start project evaluation or compilation.

## Source positions

### Source parser commitments

The Haskell parser records token consumption while it recognizes a construct.
An alternative may run only if the previous branch consumed no tokens. After
`namespace`, `if`, `return`, or `else` has been recognized, errors belong to that
construct. Optional syntax therefore means absent syntax; it does not mean
silently ignoring an incomplete construct.

For example, `namespace Example class Program {}` reports the missing `;` at
`class`. It does not restart at `namespace` and report a missing class declaration.
Similarly, `if (true) {} else return;` reports the missing block at `return`.
The same rule preserves errors inside optional capture modes and closure bodies.

Identifier-led local declarations and expression statements share a prefix.
The implemented scalar-type grammar uses bounded token lookahead to select the
declaration path before parsing its initializer. A missing initializer or `;`
therefore remains a declaration error. Extending the type grammar requires
extending this discriminator alongside the new syntax.

### Token kinds and literal payloads

Grammar punctuation is recognized by both token kind and spelling. The lexer
decodes normal String content before the parser consumes it, so token text alone
cannot distinguish `"}"` from `}` or `"not"` from `not`.

String payloads never close blocks, introduce statements, or become operators.
The contextual capture modifiers `weak` and `unowned` are recognized only in
their capture-list context; their identifier tokens remain usable elsewhere.

### Comparison errors

The equality and relational precedence groups are non-associative, following
the examples in `Spec/Language/Operators.tala`. `a < b < c` and `a == b == c`
produce `TAP0014` at the second operator. Parentheses establish a separate
expression level: `(a < b) == (b < c)` is syntactically valid and is subsequently
checked for type compatibility.

Use `a < b && b < c` for an ordered pair of comparisons. The parser does not
guess whether a chain was intended to mean a conjunction or nested comparison.

Type checking separates the expected result from the operands of comparisons
and logical operators. A `bool` return type does not turn the integers in
`1 == 2` into Boolean literals. Core verification accepts matching Boolean
equality operands, and constant folding compares their actual values. Numeric
equality never falls back to comparing truthiness.

### Conditional and assignment forms

`condition ? first : second` and `left ?: fallback` are the weakest expression
level and group to the right. A `?` that is not followed by a result and `:`
produces `TAP0029`. `left ? : fallback` with a spaced empty middle is the same
omitted-middle form as `?:`.

`??` and `??=` are recognized as tokens so that they are not read as two
conditionals. They need nullable types, which are not implemented; the parser
reports `TAP0030` and `TAP0031` instead of guessing a meaning.

A simple assignment and a compound assignment (`+=`, `-=`, `*=`, `/=`, `//=`,
`%=`, `**=`, `<<=`, `>>=`, `&=`, `^=`, `|=`) have a named target; another
target expression produces `TAP0003`. Both are also expressions that yield the
stored value. Assignment is the weakest expression level and groups to the
right, so `a = b = 10` is `a = (b = 10)` and `a = b += 2` is `a = (b += 2)`.
Elsewhere an assignment operand needs parentheses: `1 + (a = 2)`.

`++target` and `target++` are expressions too. The prefix form yields the new
value and the postfix form the previous one. The operand must be a named
storage location: `++10`, `(a + b)++` and `Next()++` produce `TAP0028`.

The language has no decrement operator. `--` starts a comment wherever it
stands outside a string, also directly after a value, so `value--;` is the
name `value` followed by a comment and `--value;` is only a comment. Neither
is an error: the remaining text is parsed as it stands, and a trailing `value`
before the closing brace of a block is that block's final expression. Write
`value -= 1`.

Because such text can keep compiling with a different meaning, the compiler
reports the warning `TAL0009` at the `--` in two spellings:

- attached: `--` directly follows a name, `)` or `]`, as in `value--;`;
- leading: the whole comment is a name directly after `--` and a `;`, as in
  `--value;`.

A comment separated from the code by a space (`value -- note`), a comment that
starts with a space (`-- value;`), documentation comments (`--|`, `--!`) and
long comments are not reported. The warning does not change what is compiled.
It follows `-Warnings none` and `-Werror true` like every other warning, and
it is listed after the errors when the same source is also rejected.

`_ = value;` is the discard statement, not an assignment to a binding named
`_`, and is not an expression: `(_ = value)` produces `TAP0032`.

The type checker reports:

| Code | Meaning |
| --- | --- |
| `TAT0035` | the operator result of a compound assignment does not have the target type, for example floating `//=` |
| `TAT0036` | a conditional test is neither `bool` nor numeric |
| `TAT0037` | the two results of a conditional have different types |
| `TAT0038` | the two operands of truthy coalescing have different types |
| `TAT0039` | the result of a conditional form is not `bool`, numeric, an enum or, for `? :`, a `String`; other result types are not lowered yet |

A compound assignment otherwise reuses the assignment and operator
diagnostics: `TAT0003` for an immutable target and `TAT0012` for operands the
operator does not accept. An untyped numeric literal operand of a conditional
form takes the type of the other operand in either direction, and both take
the expected type when there is one; a computed operand is never converted.

An assignment or increment used as a value is checked exactly like its
statement form and reports the same codes: `TAT0003` and `TAT0004` for
assignment, `TAT0022` through `TAT0024` for increment. Its type
is the target type. The target type is context for the assigned value, as a
declared type is for a binding initializer, so `wide = 5` types the literal
from `wide`; the context that receives the assignment's value does not reach
the right operand. Parameters are immutable, so they cannot be targets.

### Loop expressions

A `while` or classic `for` loop in operand position is an expression. Its value
is the operand of the `break value;` that leaves it:

```talac
int found = while (true) {
    if (Ready()) {
        break 10;
    }
};
```

Such a loop must not be able to end without a value. The type checker
reports:

| Code | Meaning |
| --- | --- |
| `TAT0025` | `break` outside any loop |
| `TAT0026` | `break value;` in a loop statement; only a loop used as an expression has a value |
| `TAT0040` | a bare `break;` leaves a loop used as an expression |
| `TAT0041` | the condition of a loop used as an expression is not the constant `true` (or, for `for`, absent), so the loop could end without a value |
| `TAT0042` | a loop used as an expression has no `break` that carries a value |
| `TAT0043` | the `break` values of one loop have different types |
| `TAT0044` | the loop value is not `bool`, numeric, an enum or a `String`; other result types are not lowered yet |

A `return` inside a loop used as an expression leaves the method. A loop that
no `break` leaves and that returns never yields a value, which is valid; a
loop that neither breaks nor returns is `TAT0042`.

A `break` always leaves the innermost loop, so a value-carrying `break` inside
a loop statement nested in a loop expression is still `TAT0026`. The value of
a `break` takes its context from the place that receives the loop's value.
`do`/`while` has no expression form, and the enumerable `for (:)` form is not
implemented. `TAD0002` is an internal error: it reports a value-carrying
`break` that reached Core lowering without a loop expression to receive it.

### Match, if expressions and guard

`match` selects the first arm whose patterns and guard accept its subjects:

```talac
int kind = match (code), (strict) {
    (0), (_) -> 10,
    (1), (true) -> 20,
    (int other), (_) if other < 0 -> 0 - other,
    (_), (_) -> { int rest = code - 1; rest + 30 }
};
```

At the start of a statement `match` is the statement form: it needs no
terminator, its arms yield no value, and it does nothing when no arm accepts.
Anywhere else it is an expression. `if` in operand position is an expression
over two value blocks, and `guard (condition) else { ... }` is a statement.

The parser reports:

| Code | Meaning |
| --- | --- |
| `TAP0033` | an `if` used as an expression has no `else` branch |
| `TAP0034` | the `else` branch of an `if` used as an expression is another `if` instead of a block |
| `TAP0035` | the condition of an `if`, `guard` or `while` is a binding such as `auto user = Find()`, which requires optional values |
| `TAP0036` | a match arm does not start with a pattern: a literal, a `-` and a numeric literal, `_`, `null`, `.Case`, or a type followed by a name or `_`; or a `-` in a pattern is not followed by a numeric literal |
| `TAP0037` | `guard (condition)` is not followed by `else` |
| `TAP0038` | the pattern of a match arm was read as part of the expression body of the arm before it |

A bare name is not a pattern, so `value -> ...` is `TAP0036`: a binding always
states its type, as in `int value -> ...`. A numeric literal may be preceded
by `-`, which makes the constant negative; no other expression is a pattern.
The constant is checked against the type of its subject like every literal
(`TAT0016`), so `-128` is a pattern for a `byte` and `-129`, `128` and any
negative constant for an unsigned subject are not.
The comma after an arm is optional. Without it, a parenthesized pattern after
an expression body continues that expression as a call, and the `->` that
follows cannot; `TAP0038` is reported at that arrow. An unterminated
match reports `TAP0002`.

The renamer reports `TAR0008` when a pattern binds a name that is already in
scope, including a name bound by an earlier pattern of the same arm. Two arms
may bind the same name: a binding is in scope only in the guard and the body
of its own arm.

The type checker reports:

| Code | Meaning |
| --- | --- |
| `TAT0046` | a block used as a value can complete normally and does not end with an expression that has no semicolon |
| `TAT0048` | a match arm does not have exactly one pattern for each subject |
| `TAT0049` | a match guard is neither `bool` nor numeric |
| `TAT0050` | the arms of a match used as an expression have different types |
| `TAT0051` | the result of a match is not `bool`, numeric, an enum or a `String`; other result types are not lowered yet |
| `TAT0052` | a match used as an expression may accept no arm |
| `TAT0053` | a match arm can never be selected because an earlier arm accepts everything it accepts |
| `TAT0054` | a literal pattern cannot be compared with its subject |
| `TAT0055` | a `null` pattern; reference subjects are not supported in `match` yet |
| `TAT0056` | an enum case pattern such as `.Ready` for a subject that is not of an enum type |
| `TAT0057` | a type pattern names another type than its subject's; class hierarchies are not implemented |
| `TAT0058` | a match subject is not `bool`, numeric, an enum or a `String`; other subject types are not lowered yet |
| `TAT0060` | a guard condition is neither `bool` nor numeric |
| `TAT0061` | the `else` block of a guard can complete normally instead of leaving the enclosing scope |
| `TAT0062` | the `return` statements of a method or callable whose result type is inferred carry values of different types |
| `TAT0063` | the return type of a method declared with `auto` cannot be inferred: every result is a call that depends on the method itself |
| `TAT0064` | an enum has no member of the given name, in `Enum.Member` or in a case pattern |
| `TAT0065` | an operation on a value of an enum other than `==` or `\=` with a value of the same enum |
| `TAT0066` | the underlying type of an enum is not an integer type |
| `TAT0067` | an enum names a member twice |
| `TAT0068` | the value of an enum member does not fit the underlying type of the enum |
| `TAT0069` | a target-typed `.Member` stands where no enum type is expected: the type of the place is inferred, or is not an enum |
| `TAT0070` | the value written for an enum member is not a constant integer expression, names something that is not an earlier member of the same enum, or has no value, as a division by zero has none |

A block used as a value may leave instead of yielding a value: `return`
leaves the enclosing method and is checked against its return type
(`TAT0005`), also from inside a loop used as an expression, and `break` and
`continue` target the nearest loop around the expression and need one
(`TAT0025`, `TAT0027`). A `break` follows the rules of that loop: it carries
a value to a loop used as an expression (`TAT0040` without one) and none to a
loop statement (`TAT0026`). The condition and the update clause of a loop
belong to the loop: a `break` in a block used as a value there leaves that
loop, a `continue` in the condition evaluates the condition again, and a
`continue` in the update clause of a `for` ends the update. A callable is
not inside the loops around the place that creates it, so a `break` or
`continue` in its body is `TAT0025` or `TAT0027` unless a loop of its own
encloses it. The returns of a callable whose
result type is inferred are collected through expressions as well and must
agree (`TAT0062`); the returns of a nested callable are its own. A method
declared with `auto` is inferred the same way before its callers are
checked, wherever it is declared; calls of methods that are not inferred yet
take no part, so a recursive method is inferred from its base case, and a
method all of whose results depend on itself is `TAT0063`. A block that cannot complete normally
needs no final expression and gives its expression no type; the blocks that
complete do. When no block completes, the expression never yields a value.
That is valid: the place that would have received the value is not held to a
type, because it is never reached, and nothing is stored for it. The
statements after it are still checked.

Whether a block can complete normally, for `TAT0046` and `TAT0061`, is decided
from its control flow. A statement cannot complete when it is a `return`, a
`break` or a `continue`; an `if` with an `else` whose two blocks both cannot;
a nested block that cannot; a loop whose condition is the literal `true`, or
absent in a `for`, and that no `break` leaves, also from a block used as a
value; a statement `match` one arm of which always matches and all arms of
which are blocks that cannot; or any statement an expression of which is
always evaluated and never yields a value. A block cannot complete when any
of its statements cannot. A call is assumed to return: calls whose result is `never`
are not recognized yet.

A match used as an expression is complete, so that `TAT0052` is not reported,
when an arm without a guard has only `_` and type patterns, or when every
subject is a `bool` and the arms without guards accept each combination of
`true` and `false` between them. No other set of literals is recognized as
complete. `TAT0053` compares an arm with every earlier arm that has no guard,
pattern by pattern: the earlier pattern accepts every value or is the same
literal.

An arm made only of untyped numeric literals takes its type from the context
that receives the match, and without one from the first arm that has a type.
A literal pattern is typed as the other operand of a comparison with its
subject. A pattern binding is an ordinary local and may be assigned. An
expression body in a statement match must have an effect, like any expression
statement; a pure one is `TAT0013`.

An `if` used as an expression is the conditional expression with block
operands, so it reports `TAT0036`, `TAT0037` and `TAT0039` for its test and
its results. The `else` block of a guard leaves when its last statement is
`return`, `break` or `continue`, or an `if` whose two branches both leave.
The arms of a statement match are statements of the enclosing body: they may
`return`, and in a loop they may `break` and `continue`; in a loop used as an
expression a `break value;` in an arm supplies the loop's value.

A `{` at the start of a statement opens a nested block. It has no diagnostics
of its own: an unterminated block is `TAP0002`, a name it declares is unknown
after it, and declaring a name that is already in scope is `TAR0003`, as for
any local. Two blocks side by side may declare the same name.

### Nesting limits

The stages after Core recurse once per level of real nesting, so the
frontend bounds how deep a function body may nest and reports the place where
it becomes too deep. The check runs before any analysis of the body. The two
values are resource limits of this implementation, chosen against the
measured cost of a level in every native stage; the specification states no
nesting limit, and they are not language rules. They are the limits this
version of the compiler ships with, together with a compiler stack
reservation of 256 MiB. A program at the expression limit commits about
2.5 MiB of that stack in an ordinary build on Windows, Linux and macOS, and
at most 5.5 MiB in a sanitizer build; the measurements are in
`Benchmarks/2026-10-04-Nesting-And-Chains.md`:

| Code | Meaning |
| --- | --- |
| `TAP0039` | a statement is nested more than 256 levels deep in other statements |
| `TAP0040` | an expression is nested more than 1024 levels deep in other expressions |

`TAP0041` is no longer reported. It refused a value of an enum member that
was not an integer literal; a member value is now any constant integer
expression, and `TAT0070` reports one that is not.

The statements of a function body are at level 1, and an expression that is
not an operand is at level 1. A block, a branch, a loop body, a `guard`
block, a block used as a value and a closure body are each one statement
level below what holds them. The links of an `else if` chain are all at the
level of the first `if`, and so are the `if` statements of `else { if ... }`.
The body of a `match` arm is one level below its match, however many arms
the match has. Expressions inside a statement that is itself inside
an expression keep counting from that expression. Each function reports each
code at most once, at the first node in source order that is one level
beyond the limit, and nothing below that node is examined.

A chain of a binary operator is not nesting either. The left operand of a
binary operator is at the level of the operator, so `a + b + c + ...` and
`a && b && c && ...` are at one level however long they are: every stage
walks such a chain in a loop, and a sum of 50000 operands compiles. A right
operand, a call argument, a conditional result and the operand of a unary
operator are one level below the expression that holds them, so
`a + (b + (c + ...))` nests one level per addition.

### Supplied token streams

Embedding clients may supply a token list through `ParserInput`. An empty list
is an empty module, and a complete token list may omit the final EOF marker.
If a marker is present, it must be the final token. A suffix after EOF produces
`TAP0015`; it cannot be silently discarded as unparsed input.

When physical exhaustion occurs after a token, the parser retains a zero-width
span at that token's end. This preserves the source filename even for truncated
supplied streams. Lexer-produced EOF tokens retain their own source positions.

### Construct ranges

Function spans include access modifiers and the closing body delimiter. Branch
spans include the final closing brace, including empty branches and complete
`else if` chains. Callable spans include explicit capture brackets and their
body delimiter, including empty closures. Return statement spans include `;`.
A `match` runs from its keyword to its closing brace, a `guard` from its
keyword to the closing brace of its block, and a nested block and a block
used as a value include both braces. A match arm starts at its first pattern
and includes the comma after it when there is one; a pattern includes its own
parentheses. An `if` used as an expression runs from its keyword to the
closing brace of its `else` block.

These ranges support downstream diagnostics and editor selection without
reconstructing a construct's extent from its last nonempty child. The public
AST and token constructors remain unchanged by this cursor implementation.

Source diagnostics should retain:

- canonical project-relative file identity;
- one-based line and column for user display;
- a span covering the smallest relevant source form;
- the primary message;
- related declaration locations when ambiguity or duplication involves more than one site; and
- the stage/rule identity needed by Analyzer and Linter clients.

Byte offsets are an implementation detail and must not be presented as Unicode character indexes. Tala source is
decoded as UTF-8, while runtime `String` semantics use Unicode scalar values. Diagnostics must not confuse UTF-8 byte count,
UTF-16 code units, and scalar positions.

When recovery is possible, later messages should be suppressed if they are direct consequences of one missing delimiter or
malformed token. Recovery is for discovering independent errors, not maximizing the message count.

## Severity and warnings

Compiler warning policy is controlled by the resolved CLI/project settings:

```text
-Warnings all|medium|low|none
-Werror true|false
-Wexperimental true|false
-Wshadow true|false
-Wundef true|false
```

`-Werror` changes the build result of an emitted warning; it does not rewrite the diagnostic's semantic identity into an
unrelated error category. Experimental, shadowing, and undefined-name controls are explicit settings and follow the same
CLI-over-project precedence as other compiler settings.

talalint has its own rule severity model. Compiler diagnostics and linter diagnostics can appear in one Analyzer
session, but their configuration and version lines remain independent.

## Artifact diagnostics

Public Core decoding is hostile-input parsing. Reader failures should state the violated contract without dumping arbitrary
document bytes. Relevant categories include:

- wrong magic or wire version;
- truncated field;
- document, text, collection, type-depth, or expression-depth limit exceeded;
- invalid UTF-32 scalar in a string value;
- duplicate or missing symbol;
- mismatched function/call signature;
- invalid branch target or missing terminator;
- unsupported payload in the current wire revision; and
- private CorePrep bytes supplied as public Core.

Xpp and Xmm have bounded public readers. Malformed artifacts report framing, version, tag, scalar, or resource-limit failures
at decode. Structurally valid but semantically invalid artifacts report the owning Xpp or Xmm verifier failure before
optimization or lowering.

A callable that remembers its result is checked by every stage that carries it. Each stage reports under its own code
that the operand is not a callable without parameters whose result is `bool` or numeric, or that the result does not
have the operand's type:

| Code | Stage |
| --- | --- |
| `TAC1073` | Core, in the Haskell and the native verifier |
| `TAC0025` | CorePrep, in the Haskell verifier |
| `TAC1074` | CorePrep, in the native verifier |
| `TAP1047` | Xpp |
| `TAL1053` | Xmm |

None of them can be reached from source: the frontend produces the operation only in a form that passes. They report a
malformed artifact or a defect of a stage.

A call of a runtime function is checked the same way, by every stage, against the runtime catalog: that its first operand
is a literal that names a function, that it has that function's number of arguments, that each argument has a type the
function takes, and that the call has the type the function returns.

| Code | Stage |
| --- | --- |
| `TAC1075` | Core, in the Haskell and the native verifier |
| `TAC0026` | CorePrep, in the Haskell verifier |
| `TAC1076` | CorePrep, in the native verifier |
| `TAP1048` | Xpp |
| `TAL1054` | Xmm |

These cannot be reached from source either. What a program can get wrong about the console and about strings is reported
by the type checker, with `TAT0071` to `TAT0079`; [Console output and strings](CONSOLE-IO.md) lists them.

A method reference `Type::Method` reports `TAT0080` when the method has several overloads and the place does not expect
the type of exactly one of them, and `TAT0081` when its receiver is a value and not a type;
[Static member resolution](STATIC-MEMBER-RESOLUTION.md) lists the forms.

## Safe output behavior

Failure must not make an old file look newly built.

- `check` writes no output artifact.
- A build replaces its selected output only after the producing stage succeeds.
- `run` records the exact artifact from the current invocation and never executes a pre-existing `.vxse` after failure.
- Binary emission removes temporary objects after success and failure.
- Project-wide object and assembly requests are rejected before writing while Core lacks source ownership. Once that route is
  connected, flattened source-stem collisions must be rejected before either input overwrites the other.
- Project evaluation aborted by `panic` emits no partial plan and does not begin compilation.
- TADC refuses to overwrite the binary lock database with a text dump.

When atomic replacement is available, writers should create a sibling temporary file, flush/close it, and replace the
destination only after validation. A failure message should mention both the requested destination and the underlying error,
without exposing credentials or unrelated environment contents.

## Tool discovery failures

Project `format` and `lint` commands require separately installed `talafmt` and `talalint`. If the executable is unavailable, the
message names the missing binary and the ViGet package used to install it. The compiler does not fall back to an embedded
formatter/linter or silently skip the command.

The private Haskell frontend is different: it is part of the compiler distribution and is resolved from the running
compiler's layout. A missing frontend is an installation/build-layout failure, not a suggestion to install a random
executable from `PATH`.

LLVM discovery failures belong to Bazel analysis or build configuration. Repository diagnostics should instruct the user to
set `LLVM_ROOT` or expose `llvm-config`; they must not recommend committing an absolute machine path.

## Analyzer and machine-readable use

The compiler pipeline keeps semantic rule decisions separate from final message construction. That lets tala-analyzer and
talalint reuse symbol, type, range, and control-flow facts without parsing human prose.

A stable machine-facing diagnostic needs:

- an owning subsystem;
- a stable diagnostic or rule identifier;
- severity;
- source range or artifact context;
- message arguments separate from the rendered sentence; and
- optional related locations and safe fixes.

The current CLI is text-oriented. A future structured protocol must be versioned rather than inferred from terminal output.
Until then, external tools should use the compiler libraries/frontends they own instead of scraping `talac` wording.

## Security and privacy

Diagnostics may include source paths, package coordinates, target triples, and compiler tool paths needed to fix the error.
They must not print environment-variable values, OAuth secrets, registry tokens, mail passwords, signing keys, or complete
service responses containing credentials.

Malformed source and artifacts can contain control characters. Terminal rendering should escape or delimit untrusted
spellings so a diagnostic cannot forge another line or terminal control sequence.

## Diagnostic review checklist

Before merging a new failure path, verify:

1. the earliest owning stage reports it;
2. the message names the rejected thing and the expected contract;
3. a source span or artifact path is attached when meaningful;
4. error recovery does not generate a misleading cascade;
5. the command returns nonzero unless this is help/version or a warning allowed by policy;
6. no output or temporary artifact survives incorrectly;
7. tests assert the diagnostic category and essential context; and
8. secrets and arbitrary unescaped bytes are not printed.
