<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
-->

# Changelog

## Unreleased

### Verification and tooling

- Every command of `helpers/` defines its command line with Cobra.
  `verify-benchmarks` and `verify-examples` take the checkout as `--root`;
  their earlier `-Root` and `-Help` are rejected. `prebuild` and
  `optional-packages` take `check` or `install` as a command, in lower case,
  and print their help when no command is given. `verify-docs` rejects
  arguments it used to ignore. An invocation a command does not understand
  fails before it reads, probes or installs anything.
- `develop fuzz`, `fuzz-stress` and `fuzz-thread` take `--seconds`, `--jobs`,
  `--corpus` and `--target`, each beside the environment variable of the same
  meaning; `VXS_FUZZ_TARGETS` is new. `develop fuzz-targets` lists the targets
  and their limits. A selection that names an unknown target is refused before
  a build.
- `develop sanitizers` lists what each sanitizer kind is on the host, and
  `develop sanitize all` runs every checker the host has and reports each.
- `develop benchmark` takes `--output`, `--filter`, `--repetitions`,
  `--native-only` and `--haskell-only`. `develop benchmark-report` prints a
  result set as a table, and `develop benchmark-compare` sets one against
  another and fails when a benchmark became slower than a threshold.
- `optional-packages` supports the hosts `prebuild` supports: it now installs
  on Ubuntu 26.04 LTS with apt and on Fedora 43 with dnf as well.

## 0.5.1 - 2026-10-10

### Language

- `match`, `if` used as a value and a loop used as a value yield strings:
  `String kind = match (code) { 0 -> "none", _ -> "some" };`. Only the
  selected result is evaluated, as for the conditional expression. A
  callable result is still not lowered and reports `VXT0051` or `VXT0044`.
- A string is a subject of `match`:
  `match (name) { "none" -> 0, "some" -> 1, _ -> 2 }`. A string pattern
  accepts a subject that holds the same characters, as `==` does. String
  patterns never cover every string, so such a match needs an arm that
  accepts the rest, and a pattern written twice is reported as one that can
  never be selected. A number is not a pattern of a string subject, nor a
  string of a numeric one (`VXT0054`).

### Fixed

- `value is "text"` compared the two string objects in native code and not
  their characters, so it was false for every string made at run time, also
  under `not`, `or` and `and` and written as `is == "text"`. The reference
  evaluator of the test suite compared characters and hid it. The pattern
  now lowers to the comparison `==` uses, and the evaluator refuses the
  equality primitive on two strings so that a lowering to it fails a test.

### Release

- Advanced compiler-owned Haskell packages, the CLI, Bazel module, Kotlin
  project model, and compiler project version to 0.5.1.

## 0.5.0 - 2026-10-10

### Why 0.5.0 and not 0.4.2

The third component of the version is for a release that a program and its
build artifacts written for the one before still work with. This release is
not one:

- The language changed what existing programs mean. Evaluation is by need,
  so a value nothing reads is no longer computed, and `==` on two strings
  compares their characters where it compared the objects.
- `match`, `guard` and `enum` became reserved words.
- Every serialized stage changed incompatibly: Core went from version 8 to
  10, CorePrep to 8, Xpp and Xmm to 7. No artifact of 0.4.1 is read.
- A native executable is now linked with a runtime library that ships
  beside the compiler, so an installation of 0.4.1 cannot be updated by
  replacing the compiler alone.
- The Haskell packages of the formatter, linter and analyzer bound the
  compiler below 0.5 on purpose, and their bounds move with this release.

The language also grew by more than a patch carries: evaluation by need,
`match`, enums, constant expressions and console output. 0.4.2 was never
published; the number is skipped, not withdrawn.

### Language

- A method reference `Type::Method` is the static method as a callable
  value: `auto f = Counter::Next;`, `Apply(Counter::Next)`. Where the method
  has overloads, the type the place expects selects one, and `VXT0080`
  reports a place that selects none. A reference through a value,
  `counter::Next`, reports `VXT0081` until values have members. A selector
  with a dot and no call, `Counter.Next`, stays rejected with `VXT0034`.
- A declaration may be named through the namespace it is declared in:
  inside `namespace Demo;`, `Demo.Program.Run()` is `Program.Run()`,
  `Demo.Color.Red` is `Color.Red` and `Demo.Program::Run` is
  `Program::Run`. A namespace of several parts is written whole. A name of
  the program spelled like the first part hides the namespace. Other
  namespaces, and a qualified name in a type position, are not connected.
- The conditional expression selects strings:
  `String kind = count > 0 ? "some" : "none";`. Only the selected operand
  is evaluated. `?:` is unchanged, because its left operand is also its
  test and a string is not one.
- Visual X# is a lazy language with call-by-need evaluation, and the
  specification now says so in `Spec/Language/Evaluation.vxs`: a value is
  computed when it is first needed and at most once, a value that is never
  needed is never computed, effects happen where they are written, and
  neither thunks nor effects have any notation in the source. The compiler
  implements the first part of it: a local binding of `bool`, numeric or
  enum type whose initializer has no effect is computed by its first read
  and not at all when nothing reads it, so `int x = left / right; return 5;`
  no longer divides. That holds in the body of a callable as in the body of
  a method. An expression written as a statement, and a value assigned to
  the discard, are evaluated. Results, other types and assigned
  or captured variables are still computed where they are written;
  `Documents/EVALUATION.md` lists what is pending.
- Arguments are passed by need. An argument of `bool`, numeric or enum type
  that has no effect is computed when the method first needs it, at most
  once however often the method reads it and however many methods it is
  handed through, and not at all when no method needs it:
  `Choose(true, 1, left / right)` no longer divides when `Choose` returns
  its second parameter. A value the caller needs as well is computed once
  for both. An argument of a call through a callable, an argument a closure
  of the method captures, and arguments of other types are still computed
  at the call.
- Programs write to the console. `Console.Print` and `Console.Println` write
  a value, `Console.Printf` and `Console.Printfn` a format with its
  conversions applied, `Console.Error`, `Errorln`, `Errorf` and `Errorfn` do
  the same to standard error, and `Console.Format` returns the string and
  writes nothing. `System` is imported implicitly, so `Console` needs no
  qualification; `System.Console` is accepted. The example
  `Examples/HelloWorld/HelloWorld.vxs` compiles to a native executable and
  runs.
- A format is a string literal and is checked when the program is compiled.
  The conversions are `%d`, `%u`, `%x`, `%f`, `%s`, `%c` and `%b`, with `%n`
  for the line terminator of the platform and `%%` for a percent sign; the
  flags are `-`, `0`, `+`, space, `#` and `'`; a width or a precision may be
  written as `*` and is then an `int` argument before the value. A
  conversion that does not exist, a flag a conversion does not take, a
  missing or a surplus argument and an argument of the wrong type are
  errors, `VXT0071` to `VXT0079`. Examples 69 to 85 of
  `Spec/StandardLibrary/IO/ConsoleIO.vxs` state what the specification left
  open: which flags each conversion takes, that `%b` writes a `bool`, that
  `%f` rounds the exact value with a tie to the even digit, and that a line
  ends with the terminator of the platform.
- `+` joins two strings, and writes a value that is not a string as text
  first when the other side is one: an integer in decimal, a `bool` as
  `true` or `false`, a `char` as itself. `+=` appends to a string variable.
  `==` and `\=` on two strings compare the characters they hold; before,
  they compared where the strings were kept. Examples 86 to 89 of
  `Spec/Language/Operators.vxs`.
- Output is an effect, and effects are not lazy: an expression that writes,
  itself or through a method it calls, is evaluated where it is written and
  in the order it is written, whether or not its value is ever needed. A
  value that only computes is still computed by need in the same program.
  Examples 15 and 16 of `Spec/Language/Evaluation.vxs`.
- An integer quotient or remainder by zero and a shift by an amount that is
  negative or not less than the width of the shifted value have no value,
  and a program that needs one stops. Example 14 of
  `Spec/Language/Evaluation.vxs` states the rule. Before, generated code gave
  these operations no meaning and an optimized program could run on past
  them with a result that was never computed.
- When one statement needs several values that cannot be computed, which
  failure the program meets is not determined, and a value that runs without
  end counts as one that cannot be computed. Whether the program fails is
  determined, and so is the order of statements and of effects. Example 13
  of `Spec/Language/Evaluation.vxs` states the rule.
- Added `match`. The statement `match (subject) { pattern -> body, ... }` runs
  the first arm whose patterns and guard accept the subject, and does nothing
  when no arm accepts. In operand position `match` is an expression: every
  arm yields a value of one type, and some arm must accept whatever the
  subject is. Several subjects are written `match (a), (b)` with one pattern
  for each in every arm. The subjects are evaluated once, left to right.
- A pattern is a literal, `_`, or a type followed by a name or `_`. A type
  pattern binds the value of the subject for the guard and the body of its
  arm, as an ordinary local that may be assigned. An arm may have a guard, `pattern if condition ->`,
  which is evaluated only when the patterns of that arm accept.
- An arm that can never be selected is an error: a second arm for the same
  literals, or any arm after one that accepts every value without a guard.
- Added `if` as an expression: `int larger = if (a > b) { a } else { b };`.
  Both blocks are required and each ends with an expression that has no
  semicolon. Only the selected block runs. As the last item of a block that
  is used as a value, an `if` with two such blocks and a `match` are the
  value of that block.
- The comma after a match arm is optional, as in the grammar. A
  parenthesized pattern that follows an expression body without a comma is
  read as a call of that body; `VXP0038` is reported at the arrow after it.
- Added `guard (condition) else { ... }`. The block runs when the condition is
  false and must leave the enclosing scope with `return`, `break` or
  `continue`.
- Added the block statement: a `{ ... }` at the start of a statement is a
  nested block. The names it declares end with it, so two blocks side by side
  may declare the same name.
- `match` and `guard` are now reserved words and can no longer name a local,
  a parameter, a method or a class.
- Subjects and results of `match` and results of `if` expressions are limited
  to `bool` and numeric types for now. The `null` pattern, enum case patterns
  such as `.Ready`, type patterns that name another type than their
  subject's, and a binding in the condition of `if`, `guard` or `while` are
  recognized and rejected with dedicated diagnostics until reference
  subjects, enums, class hierarchies and optional values exist.
- A numeric constant pattern may be negative: `-1 -> ...`. The minus sign
  belongs to the numeric literal; no other expression is a pattern. The
  constant is checked against the type of its subject, so the most negative
  value of a signed type is a pattern and a negative constant for an
  unsigned subject is rejected.
- A block used as a value may leave instead of yielding a value. `return`
  leaves the enclosing method and `break` and `continue` target the loop
  around the expression, under the rules they have anywhere else. A block
  that leaves has no value; the expression has the type of the blocks that
  complete. An expression none of whose blocks completes is valid: it never
  yields a value, what would have received the value is not lowered, and no
  result slot or placeholder is created for it.
- Such a block may stand in a loop header and in a loop used as an
  expression. The condition and the update clause belong to their loop: a
  `break` in either leaves that loop; a `continue` in the condition
  evaluates the condition again without running the body or the update; a
  `continue` in the update clause of a `for` ends the update, and the
  condition is tested next; a `break` may carry a value to the loop
  expression around the block. A callable is not inside the loops around
  the place that creates it. `Spec/Language/Iteration.vxs` gains examples
  79 to 83 for these rules, and `VXT0059` is retired.
- Added classic enums: `enum Name { A, B = 2, C }`, with an optional
  underlying integer type written `enum Name = byte { ... }`. Members are
  numbered from zero, a member without a value follows the one before it,
  and two members may share a value. `Name.Member` is a value of the enum.
  Values are compared with `==` and `\=` with values of the same enum and
  take part in no other operation; there is no conversion between an enum
  and an integer in either direction. `match` over an enum uses `.Member`
  patterns and needs no catch-all arm when every value is named; a second
  arm for the same value is unreachable. `Spec/Language/Decls.vxs` gains
  examples 311 to 315 for the operations, the absence of conversions and
  the target-typed `.Member` spelling. `enum` is now a reserved word.
  The value of a member is a constant integer expression over integer
  literals and earlier members of the same enum, as in `WRITE = READ << 1`
  and `ALL = READ | WRITE`: inside its own declaration the name of a member
  stands for its number, and nowhere else. The expression is computed in
  the underlying type by the constant evaluator of the language; examples
  316 and 317 specify it, and `VXT0070` reports a value that is not such an
  expression. `VXP0041`, which allowed only an integer literal, is retired.
  `.Member` is accepted in an expression wherever an enum type is expected:
  a declared type, a parameter, a return type, the right operand of a
  comparison, the variable assigned to; elsewhere it is `VXT0069`. A
  conditional, an `if` expression, a `match` and a loop expression may
  yield an enum.
- A method declared with `auto` can be called. Return types are inferred
  before any caller is checked, across classes and against declaration
  order, through chains and mutual recursion; a method with no result
  independent of itself is `VXT0063`, and one whose returns disagree is
  `VXT0062`. Such calls used to pass the frontend and fail in the Core
  verifier with `VXC1018`.
- A callable may be created inside a callable. The outer one captures what
  the inner one reads from further out, and nothing that belongs to the
  inner one; it used to capture the inner parameters and fail in the Core
  verifier with `VXC1020`.
- `return` is accepted inside a loop used as an expression, and a loop
  expression that returns and never breaks is valid. `VXT0045` and `VXT0047`
  are retired.
- The return type of a callable is inferred from the returns inside its
  expressions as well, up to nested callables. Returns of different types
  are `VXT0062`.
- The `else` block of a `guard` is checked by its control flow instead of by
  its last statement: a loop that cannot end and a statement `match` that
  always selects an arm and all of whose arms leave are accepted, and a
  block that leaves before its last statement is as well.
- A type pattern over a scalar applies no numeric conversion: `long n` does
  not match an `int`.
- `Spec/Language/Decls.vxs` gains examples 295 to 310 for these rules, for
  exhaustiveness and for the statement `match` that selects no arm, and the
  grammar allows `-` before a numeric literal in a match pattern.

### Compiler pipeline

- The Desugarer lowers `match` to a chain of Core `if` statements over
  subjects bound once, a value block to its statements followed by its final
  expression, `guard` to an `if` with an empty first branch, and a block
  statement to its statements in the enclosing sequence. Core, its wire
  format, the optimizer, CorePrep and the native pipeline are unchanged.
- The arms of a match are lowered to one chain, each arm in the false branch
  of the one before it, which is the shape of an `else if` chain and is
  walked in a loop by every stage. The names the arms bind are bound before
  the chain, and a guard is the last operand of the test of its arm. Matches
  of 200 and of 2000 arms compile.
- Fixed a stack overflow that ended the compiler without a diagnostic on an
  `else if` chain of about 150 links. Such a chain reaches Core as one level
  of nesting per link, and the native Core wire reader and writer, the Core
  verifier and the Core-to-CorePrep adapter recursed once per link. They now
  walk a chain in a loop. The bytes, the checks and the CorePrep blocks are
  unchanged; chains of 1200 links compile.
- The parsed, renamed, resolved and typed trees have four new nodes: the
  match expression, the block expression, the guard statement and the block
  statement. Closure
  analysis, template discovery, instantiation, freshening, member
  reachability and the specialization verifier handle them.
- Ownership placement. The compiler created AARC objects and never released
  them: no stage wrote a retain or a release. A new Xpp pass gives every AARC
  value an owner and writes the operations: parameters are borrowed, results
  are owned, a local is released after its last use on each path, including
  on the edge of a branch on which it dies, a copy retains or takes over the
  reference, and a closure owns its captures. The ownership verifiers of Xpp
  and Xmm check its output.
- A method used as a value is a closure without captures. Before, the value
  was the address of the method's code, and calling it read an invoke
  pointer out of that code.

- Core has a new primitive, `Memoize`: a callable without parameters whose
  result is `bool` or numeric becomes a callable of the same type that calls
  it at most once and remembers the result. It is how a value by need
  reaches another function. CorePrep, Xpp and Xmm carry it under their own
  names, each verifier checks its rule, and LLVM lowers it to an AARC object
  with an invoke thunk and a destructor of its own. The wire versions are
  now Core 9, CorePrep 7, Xpp 6 and Xmm 6; artifacts of earlier versions are
  rejected at the version field and have to be produced again.
- Core has a second new primitive, the runtime call: a call of a function of
  the Visual X# runtime, named by a literal first operand that is the
  function's identity in a catalog of thirteen. CorePrep, Xpp and Xmm carry
  it, every verifier checks a call against the catalog (`VXC1075`,
  `VXC0026`, `VXC1076`, `VXP1048`, `VXL1054`), and LLVM lowers it to a call
  of the function's symbol, widening an integer or a floating-point argument
  to 64 bits. The wire versions are now Core 10, CorePrep 8, Xpp 7 and
  Xmm 7.
- The type checker rewrites a console call and the string operators into
  runtime calls, so no stage after it knows what a format is. The frontend
  infers which methods may write, from all methods of a program together,
  and evaluates an expression that calls one where it stands.
- A native executable is linked with `vxs-runtime.lib`, the ownership
  runtime and the new text and console runtime as one object that needs no
  C runtime. It replaces the ownership functions the compiler generated into
  each executable, and with them their limits: memory comes from the heap of
  the process, and weak and unowned references, strings and type tests link.
  The library stands beside the compiler, where the development helper and
  the release bundle put it. It imports seven functions of kernel32, for
  which the linker makes the import library from a list of names.
- Fixed a leak: a string literal passed directly as an argument was never
  released. Ownership placement now gives such a literal a symbol of its
  own.
- A method with a parameter that is passed by need has a second function
  that takes suspended computations in place of those parameters. The
  method's own function is unchanged, and a call that has nothing worth
  suspending still uses it.
- Fixed native executables that stopped instead of ending. A method without
  a result whose body ended without a `return` was closed with an
  unreachable marker by both Core-to-CorePrep adapters, so a `Main` written
  without a final `return;` executed an invalid instruction. Reaching the
  end of such a body now returns.
- Fixed native executables that did not link. An executable is linked
  without any library, and code that creates a closure calls the ownership
  runtime. The module that holds the entry now defines allocation, retain
  and release itself, over a 64 MiB arena whose released blocks are reused.
  Weak and unowned handles, strings and type tests still need the runtime
  library and do not link in an executable.
- Fixed `vxs run -File Name.vxs` with a relative path: the executable it had
  just built was looked for on `PATH` and not found.
- Integer division, remainder and shifts are preceded by a check that stops
  the program when the operation has no value. The least value of a signed
  type divided by minus one is carried out so that it wraps like a sum that
  does not fit, where the processor's instruction would stop the program.

### Verification and tooling

- `EffectTests.hs` holds the inference of which calls write from both
  sides: programs whose writes lie one and two calls down, in mutual
  recursion, in callables and in methods used as values must write in the
  order they say, and programs that only compute must keep their deferred
  bindings and suspended arguments. `FormatSweepTests.hs` writes every
  combination of flags, width and precision for every conversion, 5184
  formats, and compares the reader with the rules stated a second time.
  `TextRuntimeTests.cpp` compares `%d`, `%u` and `%x` with the C library of
  the host over 44 400 fields of deterministic pseudo-random values, and
  `%f` over 3000 numbers drawn from every exponent and 80 020 that lie on
  or beside a rounding tie.
- Visual Formatter and Visual Linter are 0.1.1. Neither has a new rule:
  both are rebuilt with this compiler, so they accept the forms above, and
  their tests now hold them. The formatter keeps `::`, qualified names,
  string conditionals and console formats as written while it indents; the
  linter reports the new diagnostics under its `compiler` check.
- `QualifiedNameTests.hs` runs programs that name declarations through
  their namespace and methods through `::`, before and after optimization,
  and holds the forms that must be rejected. The leak-checked smoke program
  and the tests that run a linked executable select strings in a loop of a
  million passes and call methods through references.
- `ConsoleTests.hs` runs some 180 programs that write in the reference Core
  evaluator, before and after optimization, against text written by hand,
  and holds about a hundred programs that must be rejected. The evaluator's
  text functions are a second implementation, in `RuntimeText.hs`.
  `RuntimeCallTests.hs` pins the runtime catalog and the reading of formats.
- `text_runtime_tests` calls the runtime library as generated code does and
  compares the digits of `%f` with those of the host's C library.
  `RuntimeCallPipelineTests.cpp` and `RuntimeCallVerifierTests.cpp` break a
  runtime call in each way it can be broken at each native stage.
- `source_console_smoke` compiles 83 programs that write through LLVM and
  the JIT in both pipeline modes, reads their output through a sink, and
  requires each to leave no object of the runtime behind.
  `executable_run_tests` now runs executables with their standard streams
  sent to files and compares the bytes.
- The expression and leaving tables run in a program of their own,
  `source_expression_smoke`. With arguments passed by need the programs of
  the three execution tables together ran past the 240 second watchdog under
  the sanitizers. The watchdog is unchanged and no case was removed.
- `executable_run_tests` builds programs into native executables and runs
  them as processes, which no test did before: every other execution test
  runs generated code inside the compiler's process. It covers a `Main`
  that ends without a return, arguments by need, closures, a quotient by
  zero that is needed and one that is not, and two million objects created
  and released in a loop. The linker is the Windows one, so these cases run
  on Windows.
- `MemoizeTests.hs`, `MemoizePipelineTests.cpp`, `FallThroughTests.hs`,
  `FallThroughTests.cpp` and `ComputabilityExecutionTests.cpp` cover the
  remembering callable at every stage, the end of a body without a result
  in both adapters, and the checks before division and shifts.
  `source_feature_smoke` runs 23 programs that pass arguments by need
  through LLVM in both pipeline modes and requires each to leave no object
  of the runtime behind.
- `OwnershipPlacementTests.cpp` runs every placed function on an independent
  reference-count model along all of its paths. `source_feature_smoke`
  runs 26 closure programs through LLVM and the AARC runtime, one at a time,
  and fails a program that leaves an allocation behind; the runtime counts
  its live allocations for that purpose.
- `ConditionalChainTests.cpp` pins the native handling of `else if` chains:
  wire round trips and a constant byte step per link, rejection of every
  truncated prefix, the verifier's checks in late links, the return analysis,
  and the block numbering of the adapter, at lengths up to 600 links.
  `source_fuzz_smoke` runs a chain of 300 links and a match of 200 arms
  through both pipeline modes.
- `NestingLimitTests.hs` nests every construct that holds statements or
  operands to the limit and one level beyond, checks the position of the
  diagnostic, and runs the accepted programs. `NestingLimitTests.cpp` pins
  the wire statement depth limit and walks 1500 levels and a chain of 3000
  links through the native Core stages on the compiler stack.
  `source_fuzz_smoke` runs 255 nested `if` statements
  and a sum of 1024 operands through both pipeline modes, and the source
  corpus has permanent seeds at and beyond both limits.
- `source_fuzz_smoke` compiles each distinct body of its execution tables
  once, up to eight small bodies in a program, and checks all runs of a body
  in that program, instead of compiling a program for every run. No run was
  removed. Under sanitizers the program takes 160 seconds where it took 291
  on the same machine.
- The execution tables are a smoke program of their own,
  `source_execution_smoke`, beside `source_fuzz_smoke`, each under the
  unchanged process watchdog of 240 seconds. In the fuzzing configuration
  the single program had grown to 221 seconds; apart, each takes 77 to 110
  seconds on the same machine. The new program also compiles and verifies
  programs that own closures while control leaves through a value block.
- The tables written by hand for single features, which are inferred return
  types, evaluation by need, enums and closures, are a third smoke program,
  `source_feature_smoke`. With them `source_execution_smoke` ran past the
  unchanged watchdog in the fuzzing configuration; no case was removed.
- An expression that is certain to read a value by need more than once
  computes it once ahead of itself. Each read carried the whole computation,
  so the Core of a chain of bindings that each read the one before twice
  doubled with every link; it now grows with the length of the chain.
- The branching and leaving tables of both harnesses are generated from the
  case files under `Compiler/Fuzzing/Cases` by the new Go helper
  `execution-cases`, whose `check` command and tests fail on a stale table.
  The reference Core evaluator of the frontend tests runs closures, and
  `source_feature_smoke` links the AARC runtime and runs closures through
  LLVM: created, called, nested, returned and alive across loop transfers.
- `BranchingTests.hs` pins the grammar, every typing rule, the lowered shapes
  and the values of 83 program runs on the unoptimized and the optimized
  Core. `BranchingOracleTests.hs` generates 36 families of arm lists, writes
  each as a match and as the `if` chain it stands for, and requires both to
  return the same values over a domain of arguments.
- `BranchingDiagnosticTests.hs` pins where each new diagnostic points, feeds
  the frontend every prefix of a program that uses the new forms and that
  program with each token removed or repeated, and pins the behavior of the
  forms in a template body. `ParserContractTests.hs` pins the source ranges
  of the new nodes, their arms and their patterns.
- `source_fuzz_smoke` runs the same 83 cases through CorePrep, Xpp, Xmm,
  LLVM and the ORC JIT in both pipeline modes, and the differential generator
  has a fourteenth program shape that combines `match`, `guard` and an `if`
  expression with an independent host model. The differential seed corpus is
  renumbered for the new shape count, and source, parser and differential
  seeds for the new forms are added.
- Dependabot no longer proposes major updates of `@types/node` for the VS Code
  extension. The type definitions must match the Node.js runtime the
  extension runs on, so that update is made by hand.

### Nesting limits

- Deep nesting no longer ends the compiler with a stack overflow. Before
  this change a sum of 100 operands, 100 nested parentheses, an `if` nested
  100 levels deep and an `else if` chain of about 1500 links each overflowed
  the one-megabyte stack a process starts with on Windows, with no
  diagnostic.
- `vxs` and `vxsi` now run the compiler on a thread whose stack they choose
  themselves, 256 MiB of reserved address space, so that how deep a program
  may nest is the same on every platform and does not depend on the stack
  the operating system gives the process. Pages are committed as they are
  used. The fuzz targets and the smoke program use the same stack. Starting
  that thread costs a few milliseconds per run: `vxs check` on small
  programs measured 3 to 8 ms slower than before on Windows, and a program
  of 300 statements measured the same.
- The frontend rejects a function body that nests statements more than 256
  levels deep (`VXP0039`) or expressions more than 1024 levels deep
  (`VXP0040`), at the first node that is too deep. An `else if` chain is not
  nesting, and the body of a `match` arm is one level below its match
  however many arms the match has. A chain of a binary operator is not
  nesting either: the left operand of a binary operator is at the level of
  the operator, so `a + b + c + ...` is one level however long it is, and a
  sum of 50000 operands compiles. The Core wire formats count the first
  operand of a primitive at the level of the primitive for the same reason.
- Releasing a Core module no longer recurses along a chain of operators or
  an `else if` chain: the destructors of the native Core expression and
  statement release their operands and nested statements from a list. The
  native wire writer walks operator chains in a loop like the reader.
- The native stages use far less stack per level of nesting. The Core wire
  reader, the Core verifier and the Core-to-CorePrep adapter no longer hold
  statements, instructions or diagnostic texts in the frames of the
  functions that recurse, and they walk chains of operators, of conditional
  expressions and of let bindings in a loop. Measured with the new
  `stack_probe` program, the whole native pipeline went from 14.9 KiB to
  0.67 KiB of stack per statement level and from 7.1 KiB to 1.9 KiB per
  level of nested operands; a sanitizer build uses 1.67 KiB and 3.4 KiB.
  Chains of operators and `else if` chains use none per link. Whole
  compilations at the frontend's limits commit at most 0.8 MiB of stack for
  nested statements and 2.5 MiB for nested expressions, and 1.3 MiB and
  4.6 MiB in a sanitizer build, measured as committed stack, which is an
  upper bound to the page and not an exact count of bytes in use, with the
  new `source_stack_probe` program. The reservation of 256 MiB costs address space only: the commit
  of a compilation is the same with and without it. The measurements,
  including what the lowering adds to a nest and what was not measured, are
  in `Benchmarks/2026-10-04-Nesting-And-Chains.md`.
- The native Core wire reader and writer bound the nesting of statement
  bodies at 4096 levels, as they already bounded expression depth. A `.core`
  file nested deeper is rejected as exceeding a limit instead of being
  walked.
- The Core-to-CorePrep adapter no longer copies every function before
  preparing it. Copying nested statements recurses once per level, which is
  what overflowed the stack on long `else if` chains; chains of 5000 links
  now compile.

### Compile time

- The native Core verifier no longer copies every visible definition when it
  enters a branch, a loop body, a let or a closure. It did, so its time grew
  with the square of a function's size: a function of 400 calls that each
  pass four suspended arguments took 2.05 seconds to verify and takes 0.04.
- Nested loops no longer multiply the time of the integer analysis. It
  repeated the fixed point of an inner loop on every pass over the loop
  around it, so 14 nested loops took a second and 50 did not finish. It now
  iterates only loops that hold at most one further level of loops and
  treats what a deeper loop assigns as unknown; 255 nested loops compile in
  under four seconds.
- The Haskell Core wire encoder, the Haskell CorePrep lowering and the
  CorePrep verifier no longer copy what they have produced once per level
  of nesting or per block. On an `else if` chain of 2048 links, encoding
  went from 4.9 seconds to 60 milliseconds, lowering from 2.2 seconds to 20
  milliseconds and verification from 0.75 seconds to 15 milliseconds.
- `Compiler/Haskell/Core/Benches` has benchmarks for nested loops, `else if`
  chains and sequences of `if` statements.
- Long chains of operators no longer take quadratic time or worse. Constant
  propagation asked the integer facts about every node of an expression,
  which re-evaluated the operands at each level, and the CorePrep lowering
  collected symbol identities by appending lists. A sum of 20000 operands
  went from 30 seconds to 4.6, and one of 50000 from 198 seconds to 9.4.
  The truth of a condition is now looked up in the facts only while the
  condition has at most 256 nodes; a chain of 200 comparisons joined by `&&`
  went from 47 seconds to 1.1, on `main` as well as on this branch.

- A class with many methods no longer compiles in time with the square of
  their number. 1000 small methods took 4.3 seconds, 2000 took 16 and 4000
  took 73; they now take 1.4, 2.9 and 4.8 seconds, and 8000 take 10. The
  native CorePrep verifier built a table of every function of the module,
  with the function type of each, once for every function, and searched the
  module for capturing closures as often; it collects both once. The
  renamer kept the names in scope as a list of pairs and now keeps a map.
  The type checker compared a method with every earlier member to find a
  duplicate overload and now compares it with the methods of its name. The
  Haskell Core verifier searched a list of source owners for every
  function, and the CorePrep lowering re-wrapped the list of waiting
  functions once for every function. What each stage accepts and reports is
  unchanged. `Benchmarks/2026-10-07-Many-Methods.md` has the measurements,
  `CorePrepVerifierTests.cpp` pins what a function sees of its module, and
  the CorePrep benchmarks have a case by number of functions.

### Known limitations

- An argument passed by need costs two objects of the runtime and two
  functions of generated code where it is suspended. A program whose calls
  pass many arguments that are themselves calls compiles to several times
  the code it did before and takes correspondingly longer to compile.
- A program that stops because it needs a value that cannot be computed
  ends with the status of a process that executed an invalid instruction.
  It reports nothing about which value or where.
- Console input, the stream objects `Console.Stdout()` and its siblings,
  `%A` and `%O`, a text form of a floating-point number outside `%f`, and
  128-bit numbers as text are specified and not implemented; each reports
  `VXT0079`. `Documents/CONSOLE-IO.md` lists them.
- A string has `+`, `+=`, `==` and `\=` and nothing else yet: no length, no
  indexing and no ordering.
- Native executables are linked on Windows only.
- Compile time still grows faster than the program on very long functions:
  from 2000 to 4000 `else if` links the time of `vxs check` grows from 3.3
  to 10.4 seconds, and from 2000 to 4000 sequential `if` statements from 2.8
  to 7.1 seconds. Nothing bounds the number of statements of a function.
- Copying a native Core module recurses once per level of nesting; the
  pipeline copies only closure bodies.
- Parts of the specified language are recognized and rejected as not
  implemented. They are pending work, listed with their diagnostics under
  "Pending branching and loop forms" in `Documents/IMPLEMENTATION.md`: a
  binding in the condition of `if`, `guard` or `while`, which needs optional
  values, a call that does not return as a way of leaving, enums declared
  inside a class, and `enum class`.
- The nesting limits of 256 and 1024 and the compiler stack reservation of
  256 MiB are the limits this version ships with. `CommittedStackBytes`
  reports on Linux and macOS as well, from the resident pages of the stack
  mapping, and `source_execution_smoke` prints the figure after compiling a
  program of 1023 nested calls. Measured in CI: about 2.5 MiB in an ordinary
  build on Windows, Linux and macOS, and at most 5.5 MiB under a sanitizer.
- The statements after a statement that never completes are checked but no
  longer lowered to Core.

### Upgrading from 0.4.1

- A method that writes and is used as a value, `auto f = Log;` or
  `Run(Log)`, writes where its call stands, like a callable expression that
  writes. No release behaved otherwise; it is listed because the rule in
  `Documents/CONSOLE-IO.md` names it.
- A program that relied on an unused value being computed, for its failure
  or for the time it takes, no longer gets either: a value nothing reads is
  not computed. That now includes an argument the method does not read.
- Core, CorePrep, Xpp and Xmm artifacts written by an earlier compiler are
  rejected. Build them again from source.
- `==` on two strings now compares their characters. A program that relied
  on two equal strings comparing unequal because they were two objects
  compares them equal.
- A program named a class `Console` or `System` keeps its own: the names the
  language declares stand outside the program's.
- Rename anything called `match`, `guard` or `enum`.
- `if (auto name = value)` and the same form in `while` now report `VXP0035`
  instead of a generic syntax error. They were not accepted before either.

### Release

- Advanced compiler-owned Haskell packages, the CLI, Bazel module, Kotlin
  project model, and compiler project version to 0.5.0, and the bounds of
  the formatter, linter and analyzer packages on the compiler to
  `>=0.5.0 && <0.6`.

## 0.4.1 - 2026-10-03

### Language

- Added the conditional expression `condition ? first : second` and truthy
  coalescing `left ?: fallback`. Exactly one result is evaluated, and the left
  operand of `?:` is evaluated once. Results are limited to `bool` and numeric
  types for now.
- Added the compound assignment statements `+=`, `-=`, `*=`, `/=`, `//=`, `%=`,
  `**=`, `<<=`, `>>=`, `&=`, `^=`, and `|=`, including in `for` update lists,
  and the discard statement `_ = value;`.
- `??` and `??=` are now recognized and rejected with dedicated diagnostics
  until nullable types exist.
- Assignment and compound assignment are now also expressions that yield the
  stored value, right-associative at the weakest expression level:
  `a = b = 10`, `int total = (value += 5)`. `++target` and `target++` are
  expressions that yield the new or the previous value. Targets are named
  locals. Operands are evaluated left to right.
- Removed the decrement operator. `--` now starts a comment wherever it stands
  outside a string, including directly after a value, so `value--;` no longer
  decrements. Use `value -= 1`. The spellings `value--;` and `--value;` are
  still accepted as comments and now produce the warning `VXL0009`.
- A `while` or classic `for` loop is an expression when `break value;`
  supplies its value. The loop must not be able to end without one: its
  condition is the constant `true`, or absent in a `for`. Loop values are
  limited to `bool` and numeric types for now.
- A simple assignment now types an untyped numeric literal from its target, as
  a binding initializer does, so `wide = 5` is accepted for a `long` target.

### Compiler pipeline

- Added the lazy `CoreConditional` expression to the Haskell and native Core
  models, verifiers, and wire codecs. The Core wire format is now v8; CorePrep,
  Xpp, and Xmm are unchanged because the expression is lowered to control flow
  before CorePrep.
- Taught effect inference, integer facts, constant folding, liveness, and
  inlining to treat the two arms as alternative paths.
- The native Core-to-CorePrep adapter now binds a `let` value with its own
  operation, matching the Haskell adapter.
- Expressions that store into a local are lowered to statements by the
  Desugarer, so Core, its wire format, the optimizer, CorePrep and the native
  pipeline are unchanged and no Core expression writes a local.
- The frontend ABI is now version 2. A successful request may deliver its
  warnings as output kind `VXS_FRONTEND_WARNING_TEXT` before the result; the
  compiler prints them, hides them under `-Warnings none`, and fails under
  `-Werror true`. A compiler and a frontend library of different ABI versions
  refuse to load together.
- The Haskell CorePrep lowering now compares a floating value with a floating
  zero when it becomes a Boolean, as the native adapter already did. Only the
  native lowering reaches code generation, so compiled programs are unchanged;
  the two lowerings are now compared on floating conditions as well.
- The native Core-to-CorePrep adapter now writes fixed-width integer constants
  in the canonical integer form the CorePrep reader produces, so a lowered
  module is equal to its own wire round trip.

### Verification and tooling

- Added execution tests that run compiled loops with early returns and
  integer division and check the results against hand-written expectations,
  and corrected the documentation of rounded division to match.
- Added a Clang-Tidy gate for the native sources to CI.
- Rewrote the Go Git helper around the topic-branch workflow: `start`,
  `update`, `sync`, `push`, `status` and `clean`. It never rewrites remote
  history and refuses to commit on the default branch.

### Upgrading from 0.4.0

- `value--;` and `--value;` no longer decrement and still compile, now as
  comments. Build once with the default warning level and replace every place
  that reports `VXL0009` with `value -= 1`.
- The compiler and its frontend library must come from the same release: the
  frontend ABI moved to version 2, and a mixed pair refuses to load.
- Core wire files written by 0.4.0 are version 6 and are not read by this
  release, which reads version 8 only; rebuild `.core` artifacts from source.

### Release

- Advanced compiler-owned Haskell packages, the CLI, Bazel module, Kotlin
  project model, and compiler project version to 0.4.1.

## 0.4.0 - 2026-09-27

### Compiler pipeline

- Carried deterministic project-source provenance from the Haskell Core model
  through CorePrep, Xpp, and Xmm, with independently verified ownership at
  every artifact boundary. Core and CorePrep wire formats are now v6; Xpp and
  Xmm are v5.
- Added project `OBJECT` and `ASSEMBLY` emission as one artifact per source
  file. Each LLVM partition emits only its owning function bodies and retains
  cross-source declarations; all outputs are lowered and validated before a
  rollback-capable batch replacement begins.
- Added portable path, UTF-8 filename, device-name, collision, symlink,
  replacement, and recovery handling, plus focused native tests and a Google
  Benchmark suite for planning and batch output.
- Made the parsed `-Header` option explicitly reserved until the VXCI export
  and ABI contract is defined instead of silently accepting an ignored flag.

### Release

- Advanced compiler-owned Haskell packages, the CLI, Bazel module, Kotlin
  project model, and compiler project version to 0.4.0.

## 0.3.9.5 - 2026-09-26

### Compiler and verification

- Added bounded mutation and coverage-guided libFuzzer campaigns for the Core, CorePrep, Xpp, and Xmm binary decoders.
  Native CI runs 4,096 deterministic cases plus a 30-second instrumented campaign on Windows and macOS. Crashing inputs
  are preserved as CI artifacts and can be promoted to component-owned regression tests.
- Moved native tests to the Progmasoft Catch3 submodule and added an invariant-focused property check.

### Contributor experience

- Added a detailed external contributor guide, repository-specific issue templates across the ecosystem, and an explicit
  fuzzing guide that distinguishes current checks from planned campaigns.
- Advanced compiler-owned Haskell packages, native CLI, Bazel module, Kotlin project evaluator, and default compiler
  model to 0.3.9.5. The project's own example version remains independent of the compiler version.

## 0.3.9 - 2026-09-24

### Compiler

- Added exact-ratio, target-width floating constant folding for binary16, binary32, binary64, and binary128 without using
  the compiler host's floating-point types. The Core optimizer now folds basic arithmetic, remainder, comparisons,
  truth conversion, and floating rounded division while preserving ties-to-even, signed zero, subnormals, infinities,
  and NaN behavior.
- Aligned floating `//` result typing across the Haskell frontend, Core/CorePrep verifiers, Xpp, Xmm, and LLVM. Floating
  operands produce `int`; integer operands retain their integer width. Fixed discarded CorePrep operations to validate
  operands without requiring a value type they no longer carry.
- Added optimizer, frontend, native pipeline, and malformed-result regression tests plus a Criterion floating-fold
  workload and its first Windows measurement.
- Changed `githelper.go update` to regular fast-forward-only push; it no longer uses `--force-with-lease`.
- Centralized Core integer widths, signedness, and ranges; Core folding now bounds power by squaring, validates shifts
  before host-width conversion, masks unsigned bitwise complement to the operand width, and leaves out-of-range results
  explicit.
- Bounded exact frontend constant and template-value evaluation to magnitudes strictly inside `2^65536`. Multiplication
  and power preflight intermediate growth; shift evaluation avoids distance-sized allocation, with context-specific
  diagnostics instead of wrapping or silently treating an oversized expression as nonconstant.
- Added deterministic arithmetic-oracle, integer-boundary, evaluator-parity, and source-diagnostic matrices. Extended
  Criterion's Core integer-fold workload through 2,048 operation groups and recorded Windows measurements separately.

### Release

- Advanced compiler-owned Haskell packages, the native CLI, Bazel module, Kotlin project evaluator, and default compiler
  model to 0.3.9.

## 0.3.8 - 2026-09-20

### Compiler

- Added first-class `is` patterns with wildcard, null, literal, exact nominal
  type, relational, negated, conjunctive, and disjunctive forms across parsing,
  resolution, type checking, Core, CorePrep, Xpp, Xmm, and LLVM lowering.
- Added explicit Core `let`, null, and type-identity operations so pattern
  subjects are evaluated once and short-circuit behavior remains visible to
  verifiers and optimizers.
- Advanced the Core and CorePrep wire contracts to version 5 and synchronized
  their Haskell and C++ readers, writers, fixtures, and verifier coverage.
- Replaced C-style CLI enums and function names with scoped C++20 APIs using
  the repository's `kPascalCase` enum-member convention and camel-case fields.
- Added typed ViPkg creation, VXCI package-shape options, multi-name executable,
  library, and ViPkg target selection, and exact `--` forwarding for `vxs run`.

### Project system

- Removed project-level `emit`; emitted artifacts are selected by the `vxs`
  invocation rather than persisted as project identity.
- Replaced `sources.main` with repeatable executable and library targets,
  including library namespace and ViPkg shape declarations, nullable exclusion
  policies, named test suites, and a version 6 native source registry.
- Replaced `sources.viget.publish` with `sources.viget.push`, moved authors and
  default features into the project block, and aligned warning option names with
  the compiler CLI.

### Release

- Advanced compiler-owned Haskell packages, the Bazel module, native CLI,
  Kotlin project evaluator, and default project model to 0.3.8.

## 0.3.7 - 2026-09-12

### Compiler

- Added a shared control-flow ownership analysis for explicit strong, weak, and
  unowned AARC handles. The analysis preserves all states at joins, converges
  across loops, ignores unreachable code, and remains independent of block
  presentation order.
- Connected ownership verification to both Xpp and Xmm. The compiler now rejects
  use after release, double release, wrong handle representations, and values
  whose ownership state differs across incoming control-flow paths before LLVM
  can lower an unsafe load or runtime call.
- Added stable Xpp and Xmm ownership diagnostics with function, block, and
  instruction locations, plus focused coverage for conversions, releases,
  returns, diamonds, loops, entry backedges, direct calls, scalar values, and
  malformed analysis graphs.

### Release

- Advanced compiler-owned Haskell packages, the native CLI, Bazel module, Kotlin
  project runtime, default compiler model, and release validation to 0.3.7.

## 0.3.6 - 2026-09-08

### Compiler

- Added a target-independent control-flow analysis that validates block identity,
  entry and successor integrity while producing deterministic predecessor,
  preorder, reverse-postorder, reachability, and per-block successor facts.
- Made Xpp and Xmm optimization bypass empty jump trampolines, collapse branches
  with identical destinations, prune unreachable blocks, and emit reachable blocks
  in deterministic reverse-postorder without changing branch semantics.
- Made Xmm virtual-register assignment independent of block presentation order:
  parameters retain ABI order and local destinations follow stable `SymbolId` order.
- Added permutation, diamond, loop, malformed-graph, deep-graph, idempotence,
  trampoline, reachability, and lowering-determinism regression coverage.

### Release

- Advanced the Visual X# compiler, native CLI, Haskell frontend packages, Bazel
  module, and default project model to 0.3.6. Tooling components retain their
  independent version lines.

## 0.3.5 - 2026-09-06

### Compiler

- Added first-class template specialization across the Haskell frontend, typed
  Core, CorePrep, and the native C++20 pipeline, including type, value, and
  template-template parameters.
- Added deterministic specialization discovery, binding, substitution,
  identity, mangling, member reachability, planning, verification, and
  monomorphization contracts with bounded expansion diagnostics.
- Advanced Core and CorePrep wire formats to version 4 for template values,
  fixed arrays, specialization metadata, and stricter artifact validation.
- Added matching Haskell and native regression suites for declarations,
  defaults, packs, nested applications, specialization graphs, wire symmetry,
  malformed inputs, and deterministic emission.

### Release

- Advanced compiler-owned package and project defaults to 0.3.5 while keeping
  the Analyzer, Formatter, Linter, and project runtime on their independent
  release lines.

## 0.3.4 - 2026-08-31

### Compiler

- Connected the complete fixed-width Visual X# scalar catalog across Core,
  CorePrep, Xpp, Xmm, and the C++ LLVM backend without host-width narrowing.
- Added canonical sign-and-magnitude integer literals and preserved decimal
  floating spellings, including 128-bit integer and fp128 paths.
- Advanced the Core and CorePrep internal wire contracts to version 3 with
  explicit scalar tags, bounded numeric payloads, and strict validation.
- Extended Haskell and native verifiers to reject payload/type mismatches,
  out-of-range values, malformed floating spellings, and corrupted numeric
  transports before native lowering.
- Added signed, unsigned, and floating LLVM arithmetic selection, including
  floor-division behavior appropriate to each scalar family.

### CLI and repository

- Kept `vxs version` as the single compiler-version command and rejected the
  removed GNU-style `vxs --version` spelling.
- Distributed tests and fixtures into their owning compiler components instead
  of retaining a repository-wide test bucket.
- Centralized current public headers below
  `Compiler/Headers/Visual/XSharp` and isolated retained C23/LIL headers below
  `Compiler/Legacy/Headers/Visual/XSharp/Legacy`.
- Removed the unused Rust proc-macro package, standalone codegen-unit model,
  and Rust-only formatting/error convenience APIs while retaining reference
  HIR, MIR, and XLIL algorithms that still require deliberate migration.
- Expanded public documentation for scalar lowering, bounded artifact wires,
  and component-local test ownership.

This file summarizes user-visible and developer-visible changes in the visual-xsharp repository.

The 0.0.x development period is the pre-1.0 visual-xsharp compiler infrastructure line. It does not imply a complete X#
source-to-native executable pipeline.

## 0.3.3 - 2026-08-30

- Implemented callable literal syntax across the Haskell lexer, parser, renamer, name resolver, and type checker,
  including typed, inferred, and zero-parameter forms; expression and block bodies; explicit and implicit capture mode;
  strong, weak, and unowned captures; ordered aliases; private capture identities; and positional invocation checking.
- Added a layout-neutral closure analysis catalog for tooling and later optimization. It records lexical nesting,
  parameters, ordered captures, ownership, alias/read/write facts, nested capture use, calls, and returns.
- Added typed closure expressions and capture slots to Core, free-binding discovery for implicit captures, recursive Core
  verification and optimization, and Core wire version 2 serialization.
- Added fixed-point CorePrep closure conversion. Closure bodies are lifted into synthetic functions, ordered capture
  values are atomized at creation, hidden environment parameters precede source parameters, and nested closures are
  processed through the same module queue.
- Added `MakeClosure`, capture ownership, and lifted-target support to the C++20 CorePrep model and wire version 2, then
  preserved that metadata through Xpp and Xmm with independent structural and cross-function verification.
- Kept LLVM closure allocation behind an explicit AARC ABI boundary. LLVM emission rejects closure construction until
  object layout, strong/weak/unowned slots, indirect invocation, destruction, and identity are defined; it does not
  guess a plain function-pointer representation.
- Added extensive Haskell and native C++ closure regression suites covering parsing, resolution, typing, lowering,
  nested conversion, malformed IR, ownership restrictions, codec symmetry, and Xpp/Xmm metadata preservation.
- Documented the closure pipeline and added Concurrent Bacon–Rajan cycle collection to the post-compiler roadmap as an
  opt-in `-Cycle-Collector true` feature. The planned default is `false`, and demand-driven collection will not run when
  no candidate cycle remains.
- Advanced the compiler release line to 0.3.3. Visual Analyzer, Visual Formatter, Visual Linter, and project DSL runtime
  retain their independent versions.

## 0.3.2 - 2026-08-21

- Connected the renewed Haskell-to-C++20 pipeline to LLVM target-machine object and assembly emission, a typed Windows LLD
  driver, native `.vxse` builds, and `vxs run`. Binary builds remove their temporary object after linking, while explicit
  object output uses the canonical `.o` extension on Windows.
- Added backend and CLI regression coverage for COFF object identity, assembly output, executable entry validation, direct
  Core native artifacts, single-file execution, project binary builds, and native process exit propagation.
- Added the first compiler-backed Visual Analyzer, Visual Formatter, and Visual Linter Haskell packages. They share the
  compiler's syntax and semantic analysis boundaries instead of maintaining parallel language implementations.
- Added `vfmt` with standard-output, `-In-Place`, `-Dry-Run`, and `-Help` modes, plus `vlint` with compiler diagnostics,
  source-hygiene checks, safe `-Fix`, `-List-Checks`, and `-Help` modes.
- Added project-wide `vxs format` and `vxs lint` dispatch. The compiler-owned source-set loader applies Kotlin project
  roots and exclusions before the installed Visual Formatter or Visual Linter is invoked for each source.
- Advanced the native compiler, Haskell compiler frontend, and Kotlin project runtime to 0.3.2. Visual Formatter and
  Visual Linter retain independent 0.1.0 release lines.
- Removed the retired `xlil-java` binding project; the maintained Rust intermediate-language implementation remains in
  place and is unaffected.
- Added typed Kotlin DSL models for `Visual.Analyzer.kts`, `Visual.Formatter.kts`, and `Visual.Linter.kts`, including
  canonical defaults, validation, immutable snapshots, and the complete linter rule catalog without coupling any DSL to
  a script evaluator.
- Split Visual Analyzer, Visual Formatter, and Visual Linter into independently owned CI workflows; the shared language
  workflow now covers only the project DSL runtime, compiler layers, and Rust core.
- Migrated the renewed C++20 LLVM backend from LLVM-C handles to native LLVM IRBuilder, module, verifier, bitcode, support,
  and new-pass-manager APIs while retaining LLVM-C only for the isolated legacy C backend.
- Replaced the CLI's exceptional GNU-style `--help` spelling with the case-sensitive canonical `-Help` control used by
  the Visual X# command surface; global and command-specific help now reject the retired spelling.
- Unified synchronous vxs help, version, diagnostic, and Core-pipeline output on the existing type-safe `fmt` dependency
  instead of retaining parallel `printf`, `fprintf`, `fputs`, and `putchar` formatting paths.
- Split the post-CorePrep compiler monolith into independently owned Xpp and Xmm lowering units. Added a dedicated Xpp
  structural/storage verifier, moved Xmm validation out of the LLVM backend into its own stage, and made the RAM pipeline
  stop with location-preserving diagnostics before a malformed intermediate representation reaches the next owner.
- Exposed the existing fmt package through a project-owned CMake interface target so compiler and sibling CLI parser tests
  share one dependency without relying on directory-scoped imported targets.

## 0.3.1 - 2026-08-13

- Retired the obsolete Rust `xs-analyzer`, `xsfmt`, and `xstidy` prototypes without carrying them into replacement
  directories. The canonical Visual Analyzer, Visual Formatter, and Visual Linter designs now have independent Haskell,
  Kotlin, and editor-integration ownership outside the native CMake project selector.
- Split the monolithic GitHub Actions workflow into independently cancellable native, language-layer, and Haskell coverage
  workflows.
- Made semicolons mandatory for bindings, assignments, expression statements, and explicit value returns in the Haskell
  parser. A semicolon-free expression is accepted only as the direct final result of a value-returning function body.
- Strengthened the C++20 CLI parser around one declarative command/option schema: command dispatch, artifact kinds,
  warnings, booleans, LLVM choices, and ViGet actions become typed values at the argv boundary; command-specific help is
  generated from the same domains and parse failures identify the rejected option and expected values.
- Connected Kotlin project source roots to a compiler-owned Haskell source-set loader with strict UTF-8 decoding,
  deterministic recursive discovery, project-relative glob exclusions, overlapping-root de-duplication, and root/link
  escape diagnostics.
- Added namespace-based multi-file compilation: physical units are parsed independently, declarations in the same
  namespace are merged before renaming, every namespace crosses the complete verified CorePrep pipeline, and the configured
  namespace/class entry selects the Core module consumed by C++20.
- Connected project `check` and `build -Emit core|llvmll|llvmbc` to the Haskell frontend and native Core-to-LLVM pipeline.
- Replaced the anonymous Kotlin DSL test root with case-sensitive named test suites that preserve independent source roots,
  frameworks, and nullable exclusion policies through project plan v4 and the native source registry v3.
- Rewrote the project driver from manual C allocation to a C++20 RAII model with `fmt` diagnostics, and removed the
  standalone `vxs-project-runtime` launcher. `vxs` now starts the bundled Kotlin evaluator class directly; VXDC remains a
  separate command.
- Added `eprint(Any?)` and `eprintln(Any?)` project-script helpers for standard-error output.
- Replaced the C lexer/parser and compatibility semantic route with the Haskell frontend as the sole `.vxs` source owner.
- Rewrote the public driver around a typed C++20 command schema and removed DIMCLI.
- Connected `.vxs` checking and explicit Core/LLVM emission through the bounded Core boundary and C++20 backend pipeline.
- Removed unreachable C AST, macro, HIR/MIR, compiler-core bridge code and the obsolete Rust direct-IR FFI session wrapper;
  retained Rust IR models, algorithms, and tests.

- Simplified Kotlin dependency features: optional features now remain disabled by default and are activated only with
  `feature(name)` or `enable(name)`; the redundant `disable(name)` DSL operation was removed.

- Migrated monomorphization and codegen-unit planning from manual C allocation tables to GNU++26 ownership while
  preserving their existing C ABI, and added move-only C++ planning views plus Catch2 coverage.
- Added the Kotlin project setting `XS_LLVM_COMPILER = "AOT" | "ORC"`; it defaults to `AOT` and is omitted from plans
  targeting non-LLVM backends.
- Added resolved user-defined enum-data patterns to typed HIR and XHIR, including exact overloaded payload selection,
  inherited owner/tag identity, duplicate detection, scoped bindings, and exhaustive coverage validation.
- Lowered enum-data match statements and expressions through MIR and XLIL with tag extraction, `i32` comparison,
  conditional branches, selected payload-slot extraction, and exhaustive-final-arm fallthrough.
- Split conditional lowering from the growing MIR control-flow module and added verifier plus canonical-text regression
  coverage for payload-bearing, payload-free, overloaded, and inherited enum-data matches.

## 0.3.0 - 2026-08-12

- Added a versioned, bounded CorePrep binary contract shared by the Haskell frontend and C++20 native pipeline.
- Preserved recursive type information, symbol spellings, qualified names, and UTF-32 string values across the compiler boundary.
- Connected verified CorePrep input to the in-memory Xpp and Xmm lowering route.
- Added explicit `.core` artifact I/O without introducing intermediate files into normal compilation.
- Added cross-language golden bytes, malformed-input rejection, semantic verification, and ClangCL sanitizer coverage.
- Enabled `vxs build -Build core -File PATH.core` and `vxs check -Build core -File PATH.core`.

## 0.2.8 - 2026-08-02

- Accepted canonical fixed-width hexadecimal `i64` bit patterns while preserving the legacy decimal `const.i64` form,
  restoring writer/parser round trips for enum-data aggregates with inactive `Int` payload slots.
- Aligned enum-data regression tests with XLIL v1 numeric type-registry identifiers, explicit borrowed `Str` payloads,
  and the rule that a payload-free declaration is a regular `enum` rather than `enum data`.

## 0.2.7 - 2026-08-02

- Added a target-independent enum-data registry that validates same-category inheritance, deduplicates shared ancestors,
  assigns deterministic flattened tags, and resolves typed variant overloads by exact nominal or primitive payload type.
- Lowered typed and payload-free enum-data constructors into explicit HIR values carrying the selected declaration owner,
  flattened tag, and exact payload type; XHIR now round-trips and validates those records.
- Lowered enum-data constructors through MIR and XLIL as deterministic tagged aggregates, including overloaded payload
  slots, inherited variants, canonical inactive values, first-class parameters and returns, and LLVM native calls.
- Added a source-native enum-data overload fixture that produces and runs a `.vxse`, plus direct XHIR and middle-end
  regression coverage for payload selection, hierarchy validation, registry layout, and text round trips.
- Migrated the direct XHIR and XMIR compiler-core adapters to GNU++26 translation units while retaining their stable C
  entry points, beginning the incremental frontend-to-modern-C++ transition without rewriting working C23 subsystems.

## 0.2.6 - 2026-08-02

- Expanded the Rust XLIL producer attribute with immutable local bindings, scoped value blocks, floating-point operations,
  unary operations, value conditionals, and short-circuit boolean control flow.
- Added configurable module and companion names plus a canonical-text companion for attributed XLIL producers.
- Split procedural-macro inference from body lowering and added a dedicated public Rust XLIL API guide.
- Added the optional `xslang` `proc-macros` feature and the `#[xslang::xlil_create]` attribute. It preserves a supported
  Rust function and generates a verified XLIL module producer beside it.
- Added explicit Rust-side `I8` through `I128` and `F16` through `F128` XLIL type selectors plus a `Utf32Builder` that
  emits numeric UTF-32 code points without retaining source text.
- Added `xslang::xlil::typed`, a checked producer facade with typed signatures, registers, slots, constants, arithmetic,
  comparisons, calls, branches, and returns while retaining the canonical raw builder and verifier as the only XLIL
  model implementation.

## 0.2.5 - 2026-08-02

- Strengthened the public Rust XLIL surface with checked signature-derived calls, verified-module proof wrappers,
  combined parse/verification errors, stream-oriented read/write helpers, and read-only model inspection methods.
- Added optional `xslang::rust::XSResult<T>` and `XSError` aliases for thread-safe application error boundaries without
  replacing XLIL's structured build, parse, verification, and I/O errors.
- Added the root-exported `xslang::printf!` Rust convenience macro with checked C-style format conversions and a safe
  standard-output implementation under `xslang::rust`.
- Added feature-gated Kotlin project dependencies through `addOptionalModule`, deterministic feature selection, and the
  version-1 SQLite lock schema. Required, optional, enabled, and disabled dependency records now round-trip without a
  readable lock-file surrogate.
- Added reusable MIR CFG, dominator/frontier, natural-loop, and local-liveness analyses backed by the compiler core's
  graph/dataflow dependencies.
- Added a verified optimization pipeline with levels, fixpoint iteration, dead pure-definition elimination, unused-local
  pruning, identical-target branch simplification, and canonical reverse-postorder block layout.

- Migrated the `xs` executable entry and command schema to GNU++26. DIMCLI 7.6.0 now provides subcommand parsing,
  validation, and generated help while the existing C23 compiler driver and public C ABI remain intact.
- Added command-specific `--help`, pinned DIMCLI source, and the corresponding third-party notice.
- Made CI initialize pinned submodules, install the required system fmt package, and use pinned Catch2 3 when the runner
  does not provide a compatible system test framework.

## 0.2.4 - 2026-08-02

- Began the compiler's incremental Clang GNU++26 transition while retaining the existing strict C23 frontend and stable
  C ABI. Added an owning C++ XLIL API under `<xs/lil/*.hpp>` with RAII modules and builders, typed handles, parsing,
  verification, canonical text emission, calls, and control flow.
- Made every `<xs/lil-c/*.h>` entry point safe to consume from C++ through explicit C linkage and moved the reserved C
  AOT header to `<xs/lil-c/aot.h>`.
- Added the first Rust/GNU++26 compiler-core bridge through the `cxx` crate and a Clang-built native bridge library.
- Added system `fmt` and Catch2 integration without vendoring or package-manager-specific build logic.

- Added structured typed-HIR `Result<T, E>` values, contextual `Ok`/`Error` constructor checking, and exact error-channel
  validation for postfix `@`.
- Lowered Result propagation through explicit MIR discriminant branches, active-payload extraction, early error return,
  canonical aggregate reconstruction, XLIL, LLVM IR, object emission, and native `.vxse` execution.
- Added exhaustive `Ok(binding)`/`Error(binding)` match arms with lexical payload scope. Result matches reject duplicate
  variants, non-Result selectors, and payload-type disagreement, and lower without introducing Result-specific XLIL or
  LLVM instructions.
- Added native source and Kotlin-project coverage for successful propagation, failure propagation, nested
  `Result<Optional<T>, E>`, Result payload matching, malformed constructors, mismatched errors, and invalid match arms.
- Advanced the canonical XHIR, XMIR, and XLIL text format header to version `1`. Readers continue to accept version `0`
  artifacts for compatibility, while writers now emit version `1`.
- Lowered `Optional<T>` coalescing through target-independent MIR aggregate extraction, conditional control flow,
  merge storage, XLIL, LLVM IR, object emission, and native `.vxse` execution. Both `Some` and `nil` source paths are
  covered in direct source and Kotlin project builds.
- Completed mutable-local Optional coalescing assignment and postfix forced unwrapping through typed HIR, canonical
  XHIR/XMIR, MIR verification, XLIL, LLVM trap lowering, and native `.vxse` tests. `??=` evaluates its replacement only
  on the `None` edge, while postfix `!` makes the failed-unwrapping path explicit as a panic terminator.
- Added safe `?.` access for fields of optional `data` values. The lowering maps `Optional<Data>` to
  `Optional<FieldType>` with target-independent aggregate/control-flow records and recursively builds deterministic
  zero payloads for absent non-recursive aggregates.
- Made aggregate-registry discovery traverse complete HIR expression trees, including nested calls, blocks, Optional
  operations, tuples, maps, and control flow, so expression-only aggregate result types are registered before MIR.
- Extended the public C23 XLIL parser to consume canonical hexadecimal two's-complement bit patterns emitted by the Rust
  XLIL writer for signed `i32` and `i64` constants.

## 0.2.3 - 2026-07-29

- Moved the experimental managed-heap implementation out of `xslang` into the independent X Platform project, where it
  continues as XPG. Removed the former XGC project switch and CLI override from the X# compiler.
- Added LLVM-only Kotlin project controls for LTO and optimization level. PGO remains mandatory and ORC JIT remains
  outside the LLVM backend contract.
- Established the separate X Platform `0.0.1` foundation with language-neutral XPI v0, the `xpic` verifier and
  canonicalizer, and a directly interoperable Swift/GNU++ XPG heap core.
- Completed the public C23 XLIL v0 producer surface behind `<xs/lil.h>`. Third-party frontends can construct every
  implemented type, function, block, instruction, and terminator record; verify it; emit owned canonical text; parse it
  back; and inspect typed payloads without exchanging a C `FILE *` across their FFI boundary.
- Added the official Rust `xslang::xlil` producer/reader surface. Its insertion-point `Builder`, public read-only model,
  parser, verifier, and canonical writer provide the same target-independent XLIL v0 boundary without exposing LLVM.
- Added the `XsLilBuilder` convenience layer, stable opaque function handles, packed C API version negotiation, public
  symbol visibility annotations, and an installed shared `xs_lil` library as the foundation for official FFI bindings.
- Added the official Java 25 FFM binding with XLIL writer and reader packages plus the reusable
  `org.xsslang.ffi.c.CString` helper. The binding delegates parsing, verification, construction, and canonical text
  emission to the stable `lil-c` ABI.
- Published `org.xsslang:xlil:2026.1` through the independent Maven-compatible repository at
  `java.xsharp-lang.xyz`.
- Connected canonical `new Type(...)` data-constructor expressions to typed HIR, MIR aggregate values, XLIL, and LLVM.
  Constructor results can now be returned, projected, and passed directly through the scalarized native data-call ABI;
  the former constructor-shaped `Type(...)` call is rejected.
- Integer literals now retain the default inferred `Int` type while accepting an explicit `Bool` context. Contextual
  values are normalized with zero as false and every nonzero integer as true; the native Bool representation remains u8.

## 0.2.2 - 2026-07-26

- Defined XGC as three physically separate managed heaps: Young and Old share the Main Heap, while LOH and POH have
  independent region directories and allocation paths.
- Added concurrent collection plans for Young copying, Old relocation/evacuation, fragmentation-oriented LOH
  compaction, and non-moving POH mark-sweep with coalescing free lists.
- Added XGC read/load forwarding barriers, SATB and card-table write barriers, cross-region remembered edges, and
  selection policy for fragmented LOH regions.
- Added the ordered XGC failure path: ordinary concurrent collection, one emergency concurrent retry, and bounded
  stop-the-world recovery.
- Added runtime allocation-class selection, separate heap routing, POH allocation/reuse, and expanded XGC telemetry.

- Added the buildable `xsrt` runtime with ABI version 0 and explicit boxed ownership for immutable UTF-16
  `Optional<Str>` values.
- Added the public C23 `.xspkg.tar.zst` writer/verifier boundary with deterministic tar metadata, path and resource
  validation, and SHA-256 artifact identity.
- Added `xs resolve`; it reevaluates KTS dependency coordinates and atomically refreshes a real binary
  `xs.lock.sqlite3` without compiling sources.
- Unified compiler and Kotlin project resolution in the `xs` package. `/usr/bin/xs` is the only user command; the
  mandatory JRE 25 project runtime is bundled under `libexec` and still delegates script execution to `kotlin`.
- Documented the planned C23, JavaScript, and WebAssembly backend contracts while keeping LLVM as the only implemented
  backend.
- Removed the discontinued legacy manifest subsystem and its compiler flag.
- Added the first bounded `xsfmt` pass for newline and trailing-whitespace normalization, plus `--check` mode.
- Added the first `xstidy` diagnostic rule for legacy constructor syntax with human and JSON output.
- Added the initial `xs-analyzer` LSP lifecycle and full-document UTF-16 synchronization capability.
- MIR optimization now removes terminal boolean negations by reversing branch targets and collapses branches whose
  successors are identical.
- Added `xs test` for modern Kotlin projects and `xs test -file` for one source. The resolver transfers its disjoint test
  registry to the native compiler; each valid top-level `#[Test] fn name()` receives an isolated native harness and is
  compiled through HIR, MIR, XLIL, LLVM, object emission, linking, and `.vxse` execution. `Ignore` and `ShouldPanic` are
  honored, and unexpected native failure makes the command fail.
- `panic!` statement calls now survive expanded-AST materialization and lower to the existing MIR/XLIL panic terminator
  and LLVM trap path.

- Added KTS build mode, output-directory, and package-artifact settings. `BUILD_MODE` defaults to `Release`, while
  omitted `XSPKG_TYPE` is inferred from optional `lib.<extension>` and `main.<extension>` source files. Structured
  `BINARY` and `LIBRARY` records support named artifacts whose entry files use non-canonical names. Projects that omit
  `source.include` now use the recursive `Sources` root by default, while an existing `Modules` directory supplies the
  optional default module root. Existing `<source-root>/Test` directories supply default test roots.
- Source, module, and test editor/package exclusion metadata now defaults to `*/**`. It remains independent from
  compiler include registries; explicit lists replace the metadata default and empty `exclude()` clears it.
- Compiler registries are disjoint by construction: test selections override module membership, and module membership
  overrides broad source roots.
- Added source, module, and test `filter(listOf(...))` metadata with cross-registry defaults resolved after project
  include defaults are known.

### Added

- `xs run` and `xs run -file` now execute the native `.vxse` produced by the supported compiler
  pipeline and propagate the program exit code. Compiler installation now has an explicit component that installs the
  `xs` command, both public C23 header trees under one `include/xs` hierarchy, and project license notices.
- Tuple destructuring declarations now cross the structural AST into typed HIR as explicit tuple storage and projection
  bindings. Inferred and explicitly typed nested patterns, `else` discard fields, MIR/XLIL aggregate extraction, LLVM
  lowering, and native `.vxse` execution share the existing target-independent tuple registry.

### Changed

- Constructor calls use `new Type(...)`; constructor-shaped `Type::new(...)` expressions are rejected while `::` remains
  available for ordinary associated and static members.

## 0.2.1 - 2026-07-21

### Added

- Kotlin project dependencies now use structured `addModule(name, stability, version)` coordinates and successful KTS
  evaluation writes them to a deterministic, versioned `xs.lock.sqlite3` SQLite lock file. The reserved boolean
  `PUBLISH` project setting defaults to `false` and records future publication intent without uploading packages.
- Payload-free normal enums now retain nominal declarations and ordered variant tags through XHIR, lower to a
  target-independent single-tag aggregate in MIR/XMIR/XLIL, and support construction, direct calls, local storage,
  equality, statement `match`, LLVM lowering, and native `.vxse` execution.
- Explicit concrete turbofish calls to top-level generic functions now create deterministic Rust compiler-core
  monomorphizations and continue through typed HIR, MIR, XLIL, LLVM, object emission, and native `.vxse` execution.
- Reachable generic specializations are discovered transitively, including same-instance recursion. Expanding
  polymorphic recursion is rejected before it can exhaust memory, and interface constraints are checked against direct
  and inherited implementations.
- XHIR v0 declaration records now preserve interface declarations in addition to class and data declarations.
- `xslang/build.rs` now exposes crate and supported XHIR/XMIR/XLIL format versions to the Rust compiler core at build time.

### Changed

- The repository's original source code is now licensed under MPL-2.0. Generated Gradle wrapper launchers retain their
  upstream Apache-2.0 notices.
- Rust static analysis now has a warning-free `clippy::all` baseline with explicit legacy public-module documentation
  boundaries, and the C artifact-path helper is clean under the configured Clang-Tidy correctness checks.
- Project-file documentation now includes the concrete version-0 `xs.lock.sqlite3` schema and example query results.
- CMake ownership now follows monorepo component boundaries: shared policy is in the root `CMakeLists.txt` and compiler
  modules are under `xs/cmake`.
- Semantic compiler-core lowering failures now cross the C23/Rust boundary as session diagnostics; malformed FFI packets
  remain a distinct ABI error.

## 0.2.0 - 2026-07-18

### Added

- XLIL v0 now has runtime-sized `.array %aN : T` registry entries and `%rN:i64 = len.array %rA`. Rust and public C23
  model/parser/writer/verifier APIs preserve the same readable registry contract.
- Runtime-sized `[T]` values now cross function signatures, checked indexing and mutation, `count`, `for` iteration,
  LLVM lowering, object emission, and native `.vxse` execution.
- The `xslang` Rust compiler-core crate is now packaged as a documented public crate.

### Changed

- An unconstrained square-bracket array literal remains runtime-sized `[T]`; only an explicit `[T; N]` context selects a
  fixed layout. That implementation stage retained a fixed element count after construction; the current collection model
  names the count-changing reference collection `System.Array<T>` and exposes it through `[T]`.

## 0.1.9 - 2026-07-18

### Added

- Public `<xs/c23_features.h>` and selective `<xs/c23/trait.h>` / `<xs/c23/impl.h>` headers provide the first strict-C23
  trait-object, implementation binding, and dynamic-call helpers. A standalone public-header test exercises real dispatch.
- Chained `data` field projection from arbitrary values, including aggregate-returning calls, now has a typed XHIR `member`
  record and lowers through MIR/XLIL aggregate extraction to LLVM `extractvalue` and native `.vxse` execution.
- Collection spelling is consistent across the current specification: resizable reference sequences use
  `System.Array<T>` / `[T]`, maps use `System.Dictionary<K, V>` / `[K to V]`, and sets use `System.Set<T>`. These system
  collections are distinct from the built-in fixed-size CoW array `[]T`.
- Ordered, transitive, and multiple `data` base lists now cross the C23 structural AST into Rust HIR and canonical XHIR.
  Inherited fields are laid out base-first in source base-list order, participate in object initialization, member access,
  mutation, scalar call ABI lowering, XMIR aggregate registries, LLVM IR, and native `.vxse` execution. Unknown/cyclic/
  cross-category bases and ambiguous inherited field names are rejected before backend lowering.
- XHIR v0 now preserves nominal `data` declarations, field order, field types, and field mutability before function
  records. Direct XHIR rebuilds the same aggregate registry used by source and XMIR, allowing nested nominal data values
  to survive source → XHIR → native `.vxse` round-trips.
- XMIR v0 program documents now preserve aggregate and fixed-array registry entries in a structured `types` section.
  Direct XHIR rebuilds the same deterministic registry from its higher-level tuple/array types. Tuple-valued calls and
  fixed-array operations now survive both source → XHIR → native and source → XMIR → native `.vxse` round-trips.

### Changed

- XLIL v0 writes signed 64-bit constants with the explicit `%rN:i64 = const.i64 N` opcode. The old untyped
  `const N` spelling is rejected, keeping scalar constant records uniformly width-explicit without introducing
  target-dependent pointers or ABI details into XLIL.
- Direct `xs build --hir -file <program.xhir>` and `xs build --mir -file <program.xmir>` now parse complete version-0
  program documents in the Rust compiler core, validate their typed/control-flow models, lower through verified XLIL, and
  reuse the LLVM object/link path to produce `.ll`, `.o`, and native `.vxse` artifacts. Canonical XHIR program output now
  records leading function parameters separately from ordinary locals, preserving call ABI across source → XHIR → native
  round-trips.
- `xs build --output hir|mir|xlil -file <source.vxs>` and the `--hir`/`--mir`/`--xlil` short forms now write real
  compiler-core output beside the source as `.xhir`, `.xmir`, or `.xlil`. Kotlin project builds use the merged program
  session and write beside the selected entry source. Multi-function XHIR/XMIR files have one versioned `program` record,
  explicit `.function end` boundaries, and a final `.program end`; their Rust readers round-trip the complete document.
- Fixed-size built-in arrays now support source-level `for (value in values)` iteration through typed XHIR, MIR control
  flow, checked array indexing, LLVM IR, and native `.vxse` execution. The iterable is evaluated once, the element
  binding is lexical and immutable, and `break`/`continue` target the generated loop exit/update blocks.
- Positional and named tuple values now cross the Rust compiler core as structural typed-HIR tuples, use target-independent
  MIR/XLIL aggregate construction and extraction, lower to LLVM structure values, and execute in native `.vxse` fixtures.
  XHIR v0 preserves tuple types, field names, literals, element projections, and element assignments in its human-readable
  text form. Tuple values can cross same-module function signatures, nest inside other tuples, and appear as fixed-array
  elements. Chained positional projection such as `value.0.1` remains source syntax; arrays continue to use `value[index]`.
- Fixed-array `for` iteration accepts recursively nested tuple patterns, optional tuple type annotations, and `else` discard
  elements. Compiler-core desugars each pattern to one hidden typed element binding plus explicit tuple projections before
  MIR CFG construction, so the target-independent aggregate and checked iteration paths remain shared.

## 0.1.8 - 2026-07-16

### Added

- The first XGC foundation in `xslang` defines logical heap addresses, fixed 2 MiB regions, mark bitmaps, card tables,
  adaptive remembered sets, thread-local SATB buffers, precise roots and stack maps, collection-set scoring, and
  saturating telemetry. Kotlin `set("XGC_ENABLED", true)` and the `--xgc-enabled` override reach JVM-free compiler
  policy. Allocation, collector threads, barriers, and runtime integration remain deliberately inactive.
- The public XGC Rust API is available exclusively through `xslang::xgc::*`. Executable use requires an explicit X#
  runtime binding for object layout, reference tracing, and root rewriting; no legacy `xslang::gc` alias is provided.
- Data constructor overloads now lower through typed HIR, MIR, XLIL, LLVM IR, and native `.vxse` emission. Constructor
  selection uses exact parameter types, hidden constructor symbols preserve overload identity, and definite field
  initialization rejects paths that leave primitive storage uninitialized.
- Top-level function overloads and instance/static `data` methods now use exact parameter-type selection. Instance
  receivers desugar to explicit target-independent HIR arguments, and deterministic hidden symbols remain distinct through
  direct XHIR/XMIR round-trips and native `.vxse` emission.
- `<xs/lil.h>` is now the umbrella for the selective public C23 XLIL producer headers under `<xs/lil-c/*.h>`.
  Rust producers use `xslang::xlil::*`; both surfaces can build and verify human-readable XLIL v0 modules.
- Canonical `[T; N]` fixed arrays and `[T]` declarations initialized by square-bracket literals now preserve their element
  count through typed HIR, MIR, XLIL, LLVM, and native `.vxse` emission.
- Fixed-array literals now fill omitted numeric elements with zero and discard elements beyond the declared layout, as
  required by the collection specification. Literal index assignment reconstructs the target-independent MIR aggregate
  and can mutate array contents without reassigning a `val` binding.
- Brace-delimited homogeneous literals now have a dedicated built-in set structural-AST and typed-HIR representation.
  The public source type remains `[T]`; there is no nominal `HashSet<T>` spelling.
- Fixed arrays expose canonical `count`, `capacity`, `is_empty`, `start_index`, `end_index`, `first`, and `last` value
  members. Compiler-core resolves them before nominal field lookup and lowers them through the existing typed HIR and
  native array path.
- Kotlin projects may define importable source membership in `xs.module.kts`. Direct members and optional `submodule`
  blocks accept concrete paths or globs and cross the vxs-project/xs-compiler boundary in a module-aware v3 registry.
- Project source, test, and module includes are recursive directory roots rather than globs. Exclude patterns retain glob
  support, `--module` supplies an omitted module root, and `XS_EXTENSION` replaces the default `.vxs` discovery suffix.
- Positional and named tuple types/literals now have explicit structural-AST tuple field records, including positional
  `.0` member syntax.
- Source files now support one optional source-scoped namespace and any number of nested block-scoped namespaces.
- `#[MacroExport]` is retained on macro declarations and is restricted to module or namespace scope. Importing the
  exporting module makes the macro callable by its unqualified name without placing it in the prelude.

### Changed

- `[T] = [...]` denotes an array and `[T] = {...}` denotes a built-in set. A `[T]` declaration without an initializer is
  an array. The literal delimiter supplies the distinction when an initializer is present.
- Fixed arrays now support calculated `Int` indices for reads and writes through checked MIR/XLIL array access records,
  the public C23 XLIL model, and bounds-checked LLVM lowering. Native `.vxse` fixtures cover both operations.
- Prefix operators now consume a postfix-complete operand, so `!value.member` is parsed as `!(value.member)`.
- The source keyword is now singular `import`; legacy `imports` is no longer tokenized as a keyword. Source-level
  `module` declarations have been removed in favor of project metadata, and control-flow parentheses are optional.
- Module names are case-sensitive. Omitted declaration visibility is `internal` and is enforced against the exact logical
  module; cross-module use requires `public` plus the correctly cased import.
- `using namespace` no longer acts as a module import for exported macros; `import stdio;` is required before calling
  Stdio exports such as `println!`.

## 0.1.7 - 2026-07-15

### Added

- The structural parser now accepts canonical built-in collection type forms: `[T]`, fixed-size `[T; N]`, and map
  `[K: V]`. Square-bracket array literals and `[key: value]` map literals now have distinct structural AST records. These
  forms are compiler-known and do not require a standard-library import; `String` inside them still canonicalizes to the
  existing `Optional<Str>` sugar. Array and map declarations retain dedicated compiler-core type records rather than
  desugaring to nominal collection names. Typed HIR now preserves array/map literals, performs homogeneous inference and
  contextual element checks, and round-trips those records through XHIR.
- First-class fixed arrays now lower through typed HIR, MIR, XLIL `%aN` registry records, the public C23 XLIL API, LLVM
  array values, object emission, and native `.vxse` linking. XLIL construction and constant indexing use `array` and
  `extract.array` records; dynamic arrays and maps remain deferred beyond typed HIR.
- Nominal `data` return values now use first-class aggregate values across typed HIR, MIR, XMIR, XLIL, LLVM, and native
  `.vxse` emission. Aggregate-returning calls can initialize local `data` places, including nested layouts, and their fields
  are extracted back into the existing place model without exposing LLVM types to HIR or MIR.
- XLIL v0 now has sequential nominal aggregate type registry records, first-class aggregate construction and field
  extraction instructions, matching Rust and public C23 parse/write/verify APIs, and LLVM named-structure lowering.
  Direct XLIL builds exercise the complete path through object emission and a native `.vxse` executable.
- HIR now resolves automatic `Optional`, `Result`, `Error`, and `Task` types together with import-gated standard-library
  types and functions through one standard-library registry. Associated enum-data variants, static user functions,
  `Task<Result<...>>` propagation contexts, and destructuring/for-each pattern bindings participate in name checking.
- Every complete program under `Spec/Programs` now has an individual semantic `xs check` regression test in addition to
  the recursive structural-syntax suite.
- `xsfmt` gained a small, isolated TOML configuration model for width, indentation, tabs, and newline policy. Formatting
  X# source remains a later milestone.
- The structural frontend now retains generic type-qualified associated expressions, typed object literals, typed
  patterns and tuple-pattern bindings, async function expressions, and unconditional `loop` statements. `loop` also
  crosses the compiler-core, MIR, XLIL, LLVM, and native `.vxse` path for the supported body subset.
- `Str` `==` and `!=` now lower through typed HIR, XMIR `eq.str`/`ne.str`, XLIL, the public C23 model, and hosted LLVM
  native emission. Equality compares UTF-16 code-unit length and content rather than backing-pointer identity.
- Floating-point `!=` now crosses XHIR, XMIR, XLIL `ne.f32`/`ne.f64`, the public C23 XLIL model, and LLVM ordered
  not-equal comparison lowering. Contextual unary `+` and expression-inferred call locals also use the compiler-core
  path.
- Boolean `&&` and `||` now lower as real short-circuit control flow through typed HIR, MIR branches, XLIL `br_if`, LLVM,
  and native `.vxse` builds. Inferred `:=` locals now derive their type from supported expressions rather than literals
  alone, so chained logical results retain `Bool` without an explicit annotation.
- Same-module direct calls now support self recursion and mutual recursion across KTS-selected source files through typed
  HIR, MIR, XLIL, LLVM, and native `.vxse` emission. Unit-returning call statements lower without a result register, while
  semicolon-terminated value calls retain evaluation and explicitly discard their result.
- Prefix and postfix integer updates now preserve their different expression results through typed HIR, MIR local
  storage, XLIL, LLVM, and native `.vxse` output. The remaining arithmetic/bitwise compound assignments also use the Rust
  compiler-core route instead of the temporary C source bridge.
- Primitive fields of locally initialized `data` values now cross the structural AST, typed HIR, MIR storage, XLIL, and
  LLVM pipeline. Object literals, field reads, and field assignments are covered by native `.vxse` regression tests.
- Nested `data` values now scalarize recursively for local storage, whole-value copies, nested-field replacement, and
  same-module calls. Non-recursive `data` parameters use declaration-order primitive leaf parameters in the current native
  ABI; direct object literals and initialized local places can both supply those calls.

### Changed

- LLVM/Clang/LLD tool selection and validation now lives in the root `CMakeLists.txt`. The formerly monolithic CTest
  manifest is split into direct XLIL, source value/control/call, Kotlin, and library test modules.
- Source-native body compilation now has one authoritative implementation: structural AST enters the Rust compiler core,
  then returns verified XLIL through the public C23 boundary for LLVM emission. The obsolete C source-body fallback was
  removed after the complete source-native fixture matrix passed with it disabled.
- Native project tests now evaluate real `vxs.project.kts` files with the external Kotlin 2.4.0 runner and JRE 25, including
  multi-file and fixed-width integer projects.
- Rust compiler-core sessions can merge multiple expanded structural-AST source trees into one program-wide declaration,
  typed HIR, MIR, XLIL, and LLVM module. Same-module helper calls across project files now produce native `.vxse` output.
- Compiler-core sessions retain type-check, MIR-lowering, borrow-check, and optimization diagnostics instead of silently
  dropping failed function bodies. The C23 driver exposes those messages when native emission cannot proceed.
- Recursive by-value `data` parameters are rejected with an explicit indirect-ABI diagnostic instead of recursing during
  compiler lowering. Non-recursive `data` returns now use the shared aggregate registry rather than the scalar parameter
  ABI.
- Kotlin `sources` includes now expand `*`, `**`, and `?` globs, apply excludes, require exactly one resolved `main.vxs`,
  and emit a deterministic main-first source registry.
- `--warning all|medium|low|none`, `--werror true|false`, and `--verbose true|false` provide one-shot compiler-policy
  overrides for KTS and direct source invocations. The KTS resolver now transfers its evaluated
  `compiler {}` policy with the source registry. Defaults are medium warnings, warnings-as-errors disabled, and verbose
  progress enabled.
- The Kotlin project DSL exposes strict `get(name)` and lossless `getAll(name)` lookup. `set(name, value, ...)` supports
  multi-value settings, replacing the former `targets { target(...) }` section; the complete example prints project,
  compiler, backend, and `TARGET` values through ordinary Kotlin `println` calls.
- The Kotlin/JVM 25 `vxs-project` resolver evaluates combined `vxs.project.kts` files or split `vxs.settings.kts` and
  `vxs.build.kts` files through the required external `kotlin` script runner. Explicit source registries require one
  case-sensitive `main.vxs` entry and are compiled by the JVM-free `/usr/bin/xs` process.

### Changed

- The Kotlin project resolver now accepts JRE 25 and newer releases; 25 is the minimum runtime version rather than an
  exact-version requirement.
- Kotlin project host matching treats BSD systems as members of both the BSD and UNIX families.
- The compiler flag is spelled `--werror`; the former misspelling is rejected. ReactOS is a distinct internal host OS,
  has no public OS constant, and satisfies `FAMILY == WINDOWS` without satisfying `OS == WINDOWS`.
- Split Kotlin project files have no section ownership rule. `vxs.settings.kts` is evaluated first and `vxs.build.kts`
  extends its complete state; either file may call any DSL function.

## 0.1.6 - 2026-07-13

### Added

- Arithmetic, division/remainder, bitwise operations, shifts, equality, and ordering now preserve every fixed integer
  width through XHIR, verified XMIR, optimized XLIL, signed/unsigned LLVM lowering, object emission, and native `.vxse`
  builds. The public C23 XLIL API exposes the same typed operation model to third-party producers.
- The complete fixed-width integer literal family now lowers through typed HIR, decimal XMIR constants, fixed-width XLIL
  hexadecimal bit patterns, LLVM IR, object emission, and native `.vxse` builds. Range checking includes signed minimum
  values and full u128 values. Public C23 `XsUInt128`/`XsInt128` types use two 64-bit words; no `__int128` extension is used.
- `Char` literals now cross the structural AST into typed HIR as one UTF-16 code unit, lower through XMIR `const.u16`,
  XLIL `%rN:u16 = const.u16 0xXXXX`, LLVM `i16`, object emission, and native `.vxse` builds. Parameters, locals, direct
  calls, and returns preserve the 16-bit value; the public C23 XLIL API can construct and inspect the record.
- Project-local VS Code settings exclude generated build, Cargo target, dependency, and output directories from file
  watching and workspace search to avoid indexing multi-gigabyte artifact trees.
- Borrowed-static `Str` literals now lower through XHIR, endian-neutral `utf16 [...]` MIR/XMIR, explicit
  `const.str utf16le|utf16be [...]` XLIL v0 records, LLVM static data, PIC object emission, and native `.vxse` linking.
  The public C23 XLIL API exposes the selected encoding and individual UTF-16 code units.
- HIR now documents its coordinated THIR and XHIR sides explicitly: THIR carries typed/source-oriented facts, XHIR carries
  normalized operations for MIR lowering, and `.xhir` represents XHIR rather than THIR.
- Explicit `String` annotations are source sugar for boxed `Optional<Str>`. String literal inference still produces the
  borrowed-static `Str` type; C23 semantic checks and the Rust compiler core preserve this distinction through canonical
  XHIR text.
- `SFloat`/`Float` addition, subtraction, multiplication, division, remainder, equality, and ordered comparisons now
  lower through typed HIR, MIR/XMIR, XLIL v0, LLVM IR, object emission, and native `.vxse` builds. XLIL spells these as
  width-explicit records such as `add.f32` and `lt.f64`; Linux native linking supplies the math runtime needed when LLVM
  legalizes floating remainder to `fmod`/`fmodf`.
- `SFloat` and `Float` literals now cross the C23 structural AST into Rust typed HIR, verified MIR/XMIR, XLIL v0, LLVM
  IR, object emission, and native `.vxse` builds. XMIR and XLIL store exact IEEE-754 f32/f64 bit patterns in fixed-width
  hexadecimal `const.f32` and `const.f64` records.
- Same-module `Int` functions now lower as real i64 functions through typed HIR, MIR/XMIR, XLIL, LLVM IR, object
  emission, and native `.vxse` builds. Division, remainder, bitwise operations, signed shifts, and ordered comparisons use
  the complete i64 instruction family without changing the required `Long`/i32 process entry ABI.
- Unary `+`/`-` on explicitly typed `Long` values and logical `!` on `Bool` values now remain in the Rust typed-HIR,
  XHIR, verified MIR/XMIR, optimized XLIL, LLVM, and native `.vxse` route. `Long` is lowered as i32; `Int` remains i64.
- `Long` division, remainder, bitwise AND/OR/XOR, and left/arithmetic-right shifts now cross the C23 structural AST into
  Rust typed HIR, XHIR, verified MIR/XMIR, XLIL, and the existing LLVM native `.vxse` backend. Context-free integer
  literals remain `Int`; an explicit `Long` return, binding, or parameter supplies the i32 lowering context.
- `format_args_nl!` is now a source-callable compiler-special built-in and shares format-string validation with
  `format_args!`; neither formatting-argument intrinsic can be declared or shadowed through `macro_rules!`.
- Value-producing `match` expressions with `Long`/`Bool` selectors, literal arms, and a final `else` now cross the C23
  structural AST into typed HIR, versioned XHIR, MIR control flow and storage, XLIL, LLVM IR, and native `.vxse` output.
- Value-producing `if` expressions now lower in general value contexts, including local initializers and function-call
  arguments, through target-independent MIR merge storage and the existing XLIL/LLVM native pipeline.

### Changed

- `Optional<T>` and `Result<T, E>` are compiler-provided `enum data` families with explicit `Some`/`None` and
  `Ok`/`Error` variants. User `enum data` declarations may inherit those unspecialized standard families and remain
  usable as their nominal bases.
- `Result<T, E>` accepts both payload types without an error-class bound. The only one-argument form is `Result<()>`,
  which defaults its error payload to the standard `Error` class; incomplete forms such as `Result<Int>` are rejected.
- Runtime and standard-library failures use the single standard `Error` class by default. Applications may derive custom
  error classes from it; former official domain-specific error and exception types are no longer part of the Spec.
- The canonical `format!(...)` expansion is `std::fmt::format(format_args!(...))` with no synthetic source-level block.
- `format!` and the `std::fmt::*` API are both provided by the non-prelude `Stdio` module; importing Stdio makes that
  standard formatting surface available.

### Removed

- Legacy exception declarations and control-flow syntax were removed. Recoverable failures use `Result<T, E>` and postfix
  `@`; panic remains a separate explicit termination mechanism.
- The cancelled XS Backend project was removed. LLVM is the compiler's native backend.

### Fixed

- Nested binary literals now retain an explicit `Long` target context recursively instead of reverting to the default
  `Int` type inside the expression tree.
- Fresh checkouts no longer require the intentionally untracked `xslang/Cargo.lock` as a Ninja input; the pinned Rust
  toolchain can generate the local lock file during the compiler-core build.
- Formatting syntax and the `print!`, `println!`, `eprint!`, `eprintln!`, and `format!` expansion structures now follow
  the exact Rust 1.57 contract. Empty line forms delegate to `print!("\n")`/`eprint!("\n")`; formatted line forms use
  the compiler-internal newline-format argument intrinsic.

## 0.1.5 - 2026-07-13

### Added

- Classic `for` statements now cross the C23 structural-AST boundary into checked HIR, target-independent MIR control
  flow, XLIL, LLVM IR, and native `.vxse` emission for the supported source subset.
- XHIR v0 can read and write explicit `for` records with optional initializer, condition, and update sections.

### Changed

- `write!` and `writeln!` are built-in writer macros and no longer require `import stdio;`. Stdio continues to export
  `print!`, `println!`, `eprint!`, `eprintln!`, and `format!`.
- Result is no longer implied by ordinary output examples. Functions using postfix `@`, `Ok(...)`, or `Error(...)` must
  declare a Result return type; ordinary functions remain free to return unit or another declared type.

## 0.1.4 - 2026-07-13

### Added

- Rust compiler-core HIR now import statement `match` with typed `Long`/`Bool` selectors, literal arms, and a required
  final `else`; HIR verification rejects mismatched, duplicate, and incomplete arm sets.
- HIR `match` lowers into explicit MIR test/body/merge blocks and continues through XLIL `eq.i32`/`br_if`, LLVM IR,
  object emission, and native `.vxse` linking.
- Rust MIR now carries `store.local` and `load.local` statements. XMIR parser/writer, MIR verifier and borrow checker,
  MIR-to-XLIL lowering, XLIL stack slots, and regression tests cover the new storage path.
- Source syntax now accepts `do { ... } while (condition);`. The frontend marks it as post-test loop sugar and lowers it
  through the existing loop, conditional-break, MIR CFG, XLIL, and native backend path.
- Prefix `++value`/`--value` and postfix `value++`/`value--` are distinct value expressions: prefix produces the updated
  value, postfix produces the previous value, and both lower mutation through the existing local storage path.

### Changed

- HIR local initializers and assignments now compute into temporary MIR values and store into stable local storage. Reads
  load fresh values, preserving mutation across branches, loops, and match merges.
- Existing native match and mutable-loop fixtures now use the Rust compiler-core pipeline without losing local updates.

## 0.1.3 - 2026-07-13

### Added

- Rust compiler-core HIR now import `while`, `break`, and `continue`, verifies loop conditions and jump placement, and
  lowers loops through target-independent MIR and XLIL control-flow graphs.
- Class declarations now retain multiple base specifiers with per-base access and virtual-inheritance metadata. HIR
  validates duplicate bases, cycles, sealed bases, and compatible `virtual`/`override`/`sealed` method slots.
- Interface, data, and `enum data` declarations now accept unlimited same-category inheritance; cross-category inheritance
  and payload-free enum base lists are rejected.

### Changed

- Omitted declaration, member, and base visibility is consistently `internal`, including declarations nested in public
  namespaces and external blocks.
- XHIR statement writing is split into a dedicated module and v0 text round-trips structured loop records with explicit
  `.end` block markers.

## 0.1.2 - 2026-07-13

### Added

- Compiler-core sessions now lower supported integer/boolean return expressions and arithmetic/comparison trees into the
  existing Rust HIR type checker and HIR-to-MIR pipeline. Unsupported function bodies remain deferred without invalidating
  the imported declaration module.
- Explicitly typed local declarations and simple assignments now import into Rust HIR, while leading function parameters
  lower as real MIR parameters instead of uninitialized locals.
- Same-module direct calls with resolved parameter and return types now cross the compiler-core import boundary and lower
  through typed Rust HIR, MIR, and XLIL call records.
- Statement `if`/`else` and value-producing `if` expressions now import into typed Rust HIR blocks. Returned conditional
  values lower to verified multi-block MIR and XLIL `branch_if` control flow.
- Supported single-unit source builds now consume compiler-core XLIL through the public C23 XLIL parser and continue through
  LLVM IR, object emission, LLD linking, and native `.vxse` generation. Unsupported source forms retain the existing C23
  source-native fallback while the Rust compiler core grows.
- Same-module compiler-core functions may carry `Long` and `Bool` parameters through MIR, XLIL, LLVM calls, and native
  execution.

### Changed

- Rust `hir.rs`, `mir.rs`, and `xlil.rs` are now small module/re-export surfaces. MIR and XLIL data models live in dedicated
  `model.rs` modules, while the canonical checked-HIR model is re-exported from `hir.rs`.
- HIR value lowering and XHIR block writing were split into focused modules as conditional control-flow support grew.

## 0.1.1 - 2026-07-13

### Added

- The C23 driver now flattens every macro-materialized structural AST into the versioned compiler-core ABI v0 packet:
  fixed node records, a child-index table, and a text-byte arena. Rust `xslang` validates that packet and retains an owned,
  target-independent syntax tree in a compilation-unit session for typed-HIR lowering.
- Compiler-core sessions now lower top-level module and function signatures, including parameter and return types, into the
  first Rust HIR declaration model. Primitive names are resolved during this import while other nominal types retain their
  source names.

## 0.1.0 - 2026-07-13

### Added

- Source-native `Long` and `Bool` local declarations now lower to MIR places, XLIL stack slots, and LLVM
  `alloca`/`store`/`load`; simple assignments update mutable locals through the same target-independent memory path.
- MIR borrow validation now distinguishes the first initialization store of an immutable local from a rejected
  reassignment.
- Source-native builds now lower a statement-level `if` with one simple assignment per branch and a post-branch local
  read through MIR branch/merge blocks. Immutable initialization uses CFG-aware path state, so assignments on mutually
  exclusive branches do not spuriously conflict.
- The source-native `Long` slice now supports `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, and `^=` compound assignments,
  including multiple assignments in a supported `if` branch.
- Source-native conditional assignment lowering now supports nested `if` statements. The driver was split into expression/
  statement lowering and program/native-module construction units to keep the C23 implementation modular.
- Source-native `while` now lowers a supported Bool condition, assignment-only body, and loop exit through MIR CFG,
  XLIL branches, and LLVM IR.
- Source-native `break` and `continue` now target the nearest supported `while` exit and header, including from nested
  conditional blocks.
- MIR local-place validation now rejects a `load` unless the local is initialized on every reachable path; immutable-store
  validation retains its conservative reassignment protection across control-flow joins.
- Supported source-native `if` and `while` bodies may now declare `Long`/`Bool` locals with lexical block lifetime;
  their MIR places still lower through XLIL stack slots and LLVM allocas.
- Supported source-native nested `return <expression>;` statements now lower directly to MIR return terminators, including
  from a `while` body or conditional branch.
- Source-native `else if` chains now lower as ordered MIR conditional blocks with one shared merge target.
- Source-native classic `for (initializer; condition; update)` loops now lower through MIR header/body/update/exit blocks;
  `continue` targets the update block and `break` targets the exit block.
- Source-native lexical scopes now allow an inner block to shadow an enclosing local while still rejecting duplicate names
  in the same scope; leaving the block restores the enclosing binding.
- Postfix `++` and `--` are now represented by the structural AST and lower for supported mutable `Long` locals, including
  canonical `for (...; i++)` updates.
- Function expressions now use the inferred `fn(a, b) { a + b }` form; written lambda parameter and return types are
  rejected while function type annotations remain typed.
- Class construction now requires `new Type(...)`. The untyped `new()` spelling is restricted to the dedicated `else:`
  discard form.
- Specification declarations and examples now consistently use snake_case for modules, namespaces, functions, methods,
  fields, and local bindings while preserving PascalCase for types and enum variants.
- Source-native statement `match` now lowers `Long` and `Bool` selectors with literal arms and a required final `else`
  through MIR branches, XLIL, LLVM IR, ELF object emission, and native `.vxse` linking.

## 0.0.8 - 2026-07-13

### Added

- C MIR and XLIL now carry an explicit `panic` terminator through verification and text round-tripping; LLVM lowers it to
  `llvm.trap` followed by `unreachable`.
- XLIL v0 now has typed stack slots (`.slot %sN:type`) plus register-to-slot `store` and slot-to-register `load`
  instructions in both the public C23 model and Rust `xslang`.
- C MIR root-local places now lower to XLIL stack slots, and LLVM emits corresponding `alloca`, `store`, and `load`
  instructions. Direct XLIL native builds exercise the complete path through `.vxse` linking.

### Changed

- `Str` is documented as the X# UTF-16 counterpart of Rust `&'static str`, with compiler/runtime-selected UTF-16LE or
  UTF-16BE endianness. `Optional<Str>` is documented as the owned optional string case corresponding to Rust
  `Option<String>`.
- `macro_rules!` definitions now use `->` between a matcher and its expansion block, matching the current X# macro syntax
  direction.
- Class properties now use canonical X# name-first declarations such as `public Name: Str { getter; setter; }`.
- X# source syntax now distinguishes discarded and tail values: `expression;` discards to unit, while a final block
  expression without `;` remains value-producing and feeds implicit-return desugaring.
- Class property declarations now use `getter` and `setter` accessors. Plain `get` and `set` remain available as ordinary
  identifiers.
- Source examples now use `()` as the written unit type instead of source-level `void`; XLIL `void` and
  `std::cffi::Void` remain backend/FFI markers.

### Deprecated

- Legacy exception syntax remains parseable for now but is scheduled for removal in X# 2.0.0.

## 0.0.7 - 2026-07-13

### Added

- Source-native builds now lower same-module `Long -> Long` helper calls through C MIR, XLIL, LLVM IR, object emission, and
  native `.vxse` linking.
- Source-native builds now also lower same-module `Long -> Bool` helper calls for supported `if` conditions and explicit
  `Bool` local initializers.
- C MIR now has a call instruction and MIR-to-XLIL call lowering for the supported source-native direct-call slice.
### Changed

- `Optional<T>` and `Result<T>`/`Result<T, E>` implicit namespace behavior is documented: Optional still behaves as if
  `import optional; using namespace std::optional;` existed, while Result treats `import result;` as optional and brings
  `std::result` names such as `Result`, `Ok`, and `Error` into scope.
- The C23 HIR type resolver now accepts canonical `std::result::Result<T>`, `std::result::Result<T, E>`, shorthand
  `Result<T>`, and short `Error` names without a user-defined project symbol.
- Pattern defaults and placeholder spellings use `else`; `_` is no longer produced as a wildcard pattern or inferred
  lifetime/type placeholder.

- HIR CFFI validation now checks the first standard CFFI attribute shapes and scopes for extern blocks, extern functions,
  and extern static declarations.
- `import Module;` now records module usability without placing module symbols in local scope. `Result` and `Panic` are
  implicit standard import; `Panic` assertion/panic macros no longer require an explicit import. `Stdio` remains explicit
  and is not prelude.

## 0.0.6 - 2026-07-13

### Added

- The C23 lexer/parser now accepts `#[...]`/`#![...]` attribute syntax and top-level
  `extern "ABI" { fn ...; static ...; }` blocks.
- HIR symbol collection now descends into extern blocks, collecting foreign functions and foreign static globals with
  inherited block visibility.
- HIR type resolution now recognizes the initial standard CFFI type family and validates its generic arity.
- HIR semantic validation now accepts only explicitly represented C ABI extern blocks, requiring `#[repr(C)] extern "C"`.
- `Spec/Attrs.vxs` and `Spec/CFFI.vxs` document the standard attribute registry and the explicit opt-in CFFI surface.

### Changed

- `format_args!` is now validated as a built-in macro instead of a Stdio export.
- Formatting macro validation now accepts `write!` and `writeln!` forms plus common debug and alignment specs such
  as `{:?}`, `{:#?}`, `{:08x}`, and `{:_>8}` while still checking placeholder counts.
- `Optional<T>` now resolves as an implicit compiler-provided `Optional` import alias for `std::optional::Optional<T>`, with
  value constructors available in source as `None` and `Some(...)`.

### Deprecated

- Legacy exception syntax is now deprecated. `throws`, `throw`, and `try` remain parseable but produce warnings; new code
  should use `Result<T, E>` and postfix `@` propagation.

### Fixed

- The C23 HIR expression checker now accepts postfix `@` inside functions returning `Result<T, E>` or
  `Result<T, E>` and rejects it outside Result-returning functions. Direct same-file function call operands are now also
  checked to return a Result type.
- `Spec/` examples now use Result-style error handling for active examples. Legacy `throws`/`throw`/`try`/`catch` syntax is
  kept only in deprecated legacy notes.

## 0.0.5 - 2026-07-12

### Added

- Imported `Stdio` macros now include `print!`, `println!`, `eprint!`, `eprintln!`, and `format!`, with
  newline-only `println!()`/`eprintln!()` forms.
- `Spec/Stdio.vxs` now documents `std::stdin()` line input examples, and `Spec/Result.vxs` documents the explicit `Result`
  model, postfix `@` propagation, `expect`, and `unwrap`.
- The C23 lexer/parser now accepts postfix `@` as a structural Result propagation expression; semantic checking and lowering
  are intentionally left for later Result work, and HIR expression checking reports that gap explicitly instead of silently
  accepting it.
- Rust `xslang` XHIR now models and round-trips Result propagation with a `propagate` expression record.
- Rust `xslang` type checking and inference now implement the first Result propagation rule: `Result<T>@` and
  `Result<T, E>@` yield `T`, and the enclosing function must return a Result type with a compatible error channel.
  HIR-to-MIR lowering still intentionally rejects propagation until control-flow lowering for error returns exists.
- Rust `xslang` now includes an explicit Result propagation desugar pass. Surface `value@` is translated into a
  Result-match/early-return intent model before MIR lowering work begins, so backend stages do not need to treat `@` as a
  primitive operation.
- Rust `xslang` MIR lowering now exposes a `DesugaredFunction` entry point. Desugared functions without ResultMatch lower
  through the existing HIR path, while explicit ResultMatch nodes are rejected until MIR Result control-flow lowering exists.
- Rust `xslang` XHIR text writing can now emit desugared functions, including explicit `result_match` records for `@`
  desugar output.
- Rust `xslang` treats single-argument `Result<T>` as using the standard `Error` error type for propagation type checking
  and desugaring.
- The C23 HIR type resolver now recognizes the standard wrapper type names `Optional<T>`, `Result<T>`,
  `Result<T, E>`, shorthand `Result<T>`, and `Error` without requiring a user-defined project symbol.
- C MIR, XLIL, MIR optimization, and LLVM lowering now support signed i64 bitwise operations, shifts, inequality, and
  signed ordering comparisons.
- Plain source native builds now accept explicit `Long` and inferred i32-compatible local bindings before the final
  `return`, and those locals can be returned or used by the current i32 expression/condition lowering slice.
- Plain source native builds now accept explicit and inferred `Bool` local bindings for the current `if` condition lowering
  slice.
- C MIR, XLIL, LLVM lowering, and the source-native slice now support materialized boolean negation through `not.bool`, so
  `Bool` local initializers can use unary `!` in the current native path.
- The lexer/parser and source-native `Long` expression slice now support bitwise `^`, lowering to the existing `xor.i32`
  MIR/XLIL/LLVM path.
- C MIR constant folding now covers the i32 arithmetic, bitwise, shift, equality, and signed comparison family used by the
  current source-native `Long` slice.
- C MIR constant folding now turns `branch_if` with a known `const.bool` condition into a direct `goto`, allowing CFG cleanup
  to remove the dead branch.
- Source-native `if` expressions with a syntactically constant boolean condition now lower only the selected branch in the
  current narrow native slice.
- Source-native `if` expressions with constant i32 literal/arithmetic comparisons now also lower only the selected branch.

### Changed

- Source-native builds now run MIR constant folding and CFG cleanup before MIR is lowered to XLIL.

### Known gaps

## 0.0.4 - 2026-07-12

### Added

- Native executable artifacts now use the `.vxse` extension; the first implemented container target is Linux ELF, with PE
  planned after ELF support.
- `xs build -file <Main.vxs>` can now produce `.ll`, `.o`, and `.vxse` artifacts for the
  first supported source-native entry slice: top-level `main` returning `Long` with i32-range literals, `+`, `-`, `*`, and
  one top-level `if` expression over i32 comparisons.
- XLIL, MIR, LLVM lowering, and source-native `if` conditions now support signed `ne.i32` inequality.
- XLIL, MIR, LLVM lowering, and source-native `Long` return expressions now support bitwise `and.i32` and `or.i32`.
- XLIL, MIR, LLVM lowering, and source-native `Long` return expressions now support signed i32 `shl.i32` and arithmetic
  `shr.i32` shifts.
- C MIR, XLIL, MIR optimization, and LLVM lowering now support signed `div.i64` and `rem.i64`, completing the current
  direct i64 arithmetic family.
- C MIR to XLIL lowering now supports `const.bool`, and source-native `if` conditions accept `true`/`false`.
- XLIL, MIR, LLVM lowering, and the source-native slice now support signed `div.i32`.
- XLIL, MIR, LLVM lowering, and the source-native slice now support signed `rem.i32`.
- Source-native `Long` return expressions now support unary `-`.
- Source-native `if` conditions now support unary `!` by swapping branch targets.
- Source-native `Long` return expressions now support unary `+`, matching the documented narrow arithmetic slice.
- XLIL v0 and direct LLVM lowering now support signed `i32` comparison instructions: `lt.i32`, `le.i32`, `gt.i32`,
  and `ge.i32`.
- C MIR to XLIL body lowering now creates all destination blocks before lowering terminators, so `br` and `br_if` can target
  later blocks.

### Changed

### Known gaps

## 0.0.3 - 2026-07-10

### Added

- Direct XLIL native builds now run the LLVM verification and optimization pipeline before writing LLVM IR and object
  artifacts.
- XLIL v0 and the LLVM backend now support `add.i32`, `sub.i32`, `mul.i32`, and `eq.i32` instructions.

### Changed

### Known gaps

## 0.0.2 - 2026-07-10

### Added

- XLIL v0 now has explicit `.param %rN:type` body records and registry-verified direct `call` records.
- The public C23 XLIL API verifies direct call signatures, and the LLVM backend lowers XLIL parameters and calls.
- The C23 XLIL model and LLVM backend now support `add.i64`, `sub.i64`, `mul.i64`, and `eq.i64` instructions.
- Direct `xs build --xlil -file` now emits LLVM IR, an object file, and a local native executable for a defined
  `.func main : () -> i32` XLIL entry point.
- XLIL v0 now supports `%rN:i32 = const.i32 N` for direct native process exit values.
- Rust `xslang` now carries `const.i32` through XMIR text, MIR verification, MIR → XLIL lowering, and XLIL v0 text.
- GitHub Actions now verifies C23 debug and sanitizer builds, Rust formatting/tests, and patch hygiene.
- X# source comments are line-only; `include!` now enters the driver after the initial structural AST parse.

### Changed

### Known gaps

## 0.0.1 - 2026-07-09

### Added

- LLVM-project-style monorepo layout.
- `xs` compiler project and public C23 compiler APIs.
- X# lexer, structural AST parser, and base diagnostic system.
- Macro validation, token expansion, statement/declaration reparsing, and expanded-view infrastructure.
- Initial HIR symbol table, import resolution, name resolution, and type resolution infrastructure.
- Generic arity, duplicate generic parameter, and generic interface constraint checks.
- Primitive type metadata for `bool`, `byte`, `sbyte`, `char`, integer types, supported float types, and `str`.
- MIR model API, MIR writer, borrow-check skeleton, and initial optimizer passes.
- XLIL model, assembly-like text writer/parser/verifier, and limited MIR-to-XLIL body lowering.
- LLVM backend infrastructure for context/module/target/data layout management, signature lowering, LLVM IR text emission,
  object emission, and linker abstraction.
- CLI recognition for direct file forms: `xs build --output hir|mir|xlil -file ...` and
  `xs build --hir|--mir|--xlil -file ...`.
- Direct `.xlil` inputs with supported version/module headers and top-level `.extern`/`.func` signatures can produce LLVM IR
  declarations.
- Public XLIL C23 API can parse v0 text registry files and expose read-only function signature metadata.
- LLVM backend can lower the first XLIL body subset: parameters, `const i64`, `const.bool`, direct calls, `br`, `br_if`,
  `ret`, and `ret %rN` functions.
- Documentation clarifies that `.xhir`, `.xmir`, and `.xlil` are human-readable text formats, not binary or opaque
  serialized compiler state.
- XHIR and XMIR documentation now separates their structured text design from XLIL's assembly-like registry format.
- Rust `xslang` gained initial structured XHIR/XMIR text writers plus parser subsets.
- XHIR parsing now covers the checked-function subset emitted by the Rust writer.
- XMIR tests now cover goto, local return values, unreachable terminators, and the current local statement records.
- XLIL text now starts with `.xlil version 0` before module records.
- MIR/XMIR can now carry explicit function parameter/return types, optional XLIL local value types, and `const.i64`
  statements; Rust MIR → XLIL lowering can emit signatures, `const`, and `ret %rN` for typed i64 local returns.
- Rust `xslang` XLIL gained typed `call` instructions plus writer/parser/verifier coverage; MIR/XMIR can carry typed call
  statements that lower when their arguments already have XLIL values.
- Rust `xslang` gained a MIR structural verifier for duplicate ids, missing terminators, and unknown local/block references.
- Rust `xslang` optimizer gained a verified entry point that checks MIR before and after optimization.
- XMIR text support gained optimizer analysis writer/parser coverage for optimization pass reports.
- XMIR text support gained structural verifier analysis writer/parser coverage.
- XHIR text support gained type-check analysis writer/parser coverage.
- Root README and strengthened documentation set under `Documents/`.
- `xs --version` reports the current compiler version.
- XLIL text uses register-style value names such as `%r0`.

### Changed

- Module selected-import syntax corrected its former plural misspelling to singular `from`.
- `byte` resolves to `u8` at HIR level, and `sbyte` resolves to `i8`.
- `char` is documented as a 16-bit UTF-16 code unit.
- `str` is treated as UTF-16 and unbounded up to runtime allocator and target environment limits.
- HIR and MIR are documented as independent from LLVM and tied to the XLIL vocabulary instead.
- XLIL text moved away from C-like function records toward assembly-like `.xlil`, `.extern`, `.func`, label, typed SSA
  value, `br`, and `ret` records.
- Structural parser can consume a `>>` token as two closing `>` tokens when ending generic type/parameter lists.
- `match` examples and tests use the parenthesized subject form, such as `match (value) { ... }`.
- X# no longer exposes `float16` or `double` as language primitive type names.

### Known gaps

- Full AST macro replacement does not yet perform in-place parent-child rewrites.
- General expression type inference, overload resolution, and nominal interface membership checks are incomplete.
- MIR statement/expression lowering and async state machine generation are incomplete.
- Borrow checker is not yet a full region/loan/move/drop model.
- End-to-end `xs build`/`xs run` object/link/native executable flow is incomplete.
- Direct XLIL build mode currently lowers only the supported initial body subset.
