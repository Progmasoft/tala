<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Console output and strings

A Visual X# program writes to the console with `System.Console`, and
`System` is imported implicitly, so `Console.Println("Hello")` is a complete
statement. The console is specified in
`Spec/StandardLibrary/IO/ConsoleIO.vxs`, and the two operations on strings
that this document covers, `+` and `==`, in `Spec/Language/Operators.vxs`.

This document says how much of that the compiler implements and how. It is an
implementation reference, not the definition of the language.

## What is implemented

| Form | Meaning |
| --- | --- |
| `Console.Print(value)` | writes the value to standard output |
| `Console.Println(value)` | the same, and then ends the line |
| `Console.Printf(format, ...)` | writes the format with its conversions applied |
| `Console.Printfn(format, ...)` | the same, and then ends the line |
| `Console.Error`, `Errorln`, `Errorf`, `Errorfn` | the same four, to standard error |
| `Console.Format(format, ...)` | applies a format and returns the `String`; writes nothing |
| `left + right` with a `String` on either side | the two as text, joined |
| `text += value` | appends to a `String` variable |
| `left == right`, `left \= right` on two `String`s | whether they hold the same characters |

`System.Console` may be written in place of `Console`. A class of the program
named `Console` is found first and is the program's own.

A value that is not a `String` is written as text by `Print` and by `+`: an
integer of at most 64 bits in decimal, a `bool` as `true` or `false`, a `char`
as the character.

## The output format grammar

A format is a string literal. It is read when the program is compiled, and
everything about it is checked then: a format that is wrong is an error of
the program, never of a run.

A conversion is `%`, flags, a width, a precision after a point, and a letter.

| Conversion | Argument | Flags | Precision |
| --- | --- | --- | --- |
| `%d` | signed integer | `-` `0` `+` space `'` | no |
| `%u` | unsigned integer | `-` `0` `'` | no |
| `%x` | signed or unsigned integer | `-` `0` `#` | no |
| `%f` | `sfloat`, `lfloat` or `float` | `-` `0` `+` space `'` | digits after the point, six by default |
| `%s` | `String` | `-` | the most characters written |
| `%c` | `char` | `-` | no |
| `%b` | `bool` | `-` | no |
| `%n` | none | none | no |
| `%%` | none | none | no |

- `-` and `0` exclude each other, and so do `+` and the space.
- A width or a precision written as `*` is an `int` argument that stands
  before the value.
- `%x` writes a negative number as a minus sign and its magnitude, and `#`
  puts `0x` between the sign and the digits.
- `'` groups the digits before the point in threes with apostrophes.
- `%f` writes the digits of the exact binary value, correctly rounded, a tie
  to the even digit. `nan`, `inf` and `-inf` are written as those words.
- `%n`, like `Println`, writes the line terminator of the platform: a carriage
  return and a line feed on Windows, and a line feed elsewhere.
- An argument is never converted to fit a conversion: `%d` of a `uint` and
  `%f` of an `int` are errors.

## Diagnostics

| Code | Reported when |
| --- | --- |
| `VXT0071` | `Console` has no method of that name |
| `VXT0072` | `Print` or one of its siblings is given no value or several, or a format method is given no format |
| `VXT0073` | a value of a type that has no text form is written or joined |
| `VXT0074` | the format is not a string literal |
| `VXT0075` | the format has a `%` that begins no conversion, or ends inside one |
| `VXT0076` | a conversion has a flag or a precision it does not take, or flags that exclude each other |
| `VXT0077` | the number of arguments is not the number the format takes |
| `VXT0078` | an argument does not have the type its conversion takes |
| `VXT0079` | the form is specified and not implemented yet; see below |

## How a console call is compiled

`Console` is not declared in any source file. The renamer declares `System`
and `Console` for every program, outside the program's own names, and the
type checker recognizes a call on one of them.

The type checker rewrites the call. It reads the format, checks each argument
against its conversion, and leaves in the typed tree the conversions as calls
of the runtime, joined, and one write. `Console.Printfn("%s: %d", name, n)`
becomes, in effect:

```text
write(concat(concat(name, ": "), format_signed(flags, width, precision, n)), output line)
```

No stage after the type checker knows what a format is.

Each of those calls is a *runtime call*: one operation of Core, CorePrep, Xpp
and Xmm whose first operand is a literal that names a function of the runtime
catalog and whose remaining operands are the arguments. The catalog is one
table, written in `Visual/XSharp/Core/RuntimeCall.hpp` for the native stages
and in `Visual.XSharp.RuntimeCall` for the frontend, and every stage verifies
a call against it. `CORE-IR.md` has the operation and `ARTIFACT-WIRE.md` its
encoding.

A conversion takes its flags, its width and its precision before the value.
That is the order of a format's arguments, and the operands of a call are
evaluated in order, so a width written as `*` is evaluated before the value
it applies to.

LLVM lowers a runtime call to a call of the function's symbol. An integer
argument is widened to 64 bits, sign-extended or zero-extended by its type,
and a floating-point argument to a `double`; neither changes a value.

## Output is an effect

Evaluation is by need, and an effect is not: it happens where it is written.
Writing to the console is the first effect of the language that the
expression that has it does not show: `int x = Log(1);` writes only because of
what `Log` does.

The frontend therefore finds the methods a call of which may write, from the
bodies of all methods of the program together, the specializations of
templates included. An expression that contains such a call is evaluated
where it stands: its binding is not deferred, and as an argument it is
computed at the call and not suspended. A value that only computes is by need
as before, in the same program.

The answer errs on the side of an effect. A method that creates a callable
that writes is taken for writing, and a call through a callable value is taken
to write when the body of any callable of the program writes or calls a
method that does, or when a method that writes is used as a value. A program
in which no callable writes keeps its calls through callables by need, and a
program without console output is unaffected altogether.

The Core optimizer treats a console write like a call of a function it knows
nothing about: it is kept, kept once, and kept where it stands. The other
runtime calls compute a string and nothing else; removing one that nothing
uses changes nothing a program can observe.

## The runtime

`Compiler/Runtime/Text` implements the functions: joining, the conversions
and the write. It is written without a standard container and without a
C runtime function, because it is compiled twice.

A process that hosts generated code, such as the interactive shell and the
test programs, links it as a library and exports its entry points to the JIT.
Such a host may install a sink that receives what a program writes in place
of the standard streams; that is how the tests read output.

A native executable is linked with `vxs-runtime.lib`, which stands beside the
compiler. It is one object, built from the same sources as the libraries of
a host together with the ownership runtime, and it needs no C runtime: memory
comes from the process heap and output goes to the standard handles, through
seven functions of kernel32. The linker makes the import library for those
seven from a list of names, so linking a program needs neither a C runtime
nor a Windows SDK. `AARC-ABI.md` describes the ownership side.

On Linux and macOS the library is `libvxs-runtime.a`. An executable there is
linked with the C library of the system: memory comes from `malloc` and
output goes to the standard descriptors through `write`. A line ends with a
line feed alone there, and with a carriage return and a line feed on Windows.

The runtime keeps no buffer. Every write reaches the stream before the call
returns, so output appears in the order it was written and nothing is lost
when a program stops. To a Windows console a string is written as UTF-16; to
a file or a pipe, as UTF-8.

## What is pending

| Pending | Today |
| --- | --- |
| `%A` and `%O`, and the `IDebug` and `IDisplay` contracts | `VXT0079`; they need the object model |
| a text form of a floating-point number for `Print` and `+` | `VXT0079`; `%f` writes one with a precision |
| `longint`, `ulongint` and `double` as text | `VXT0079`; the runtime functions take 64 bits |
| `Console.Stdout()`, `Stderr()`, `Stdin()` and everything on them: `Flush`, `Read`, `Readln`, `Readf`, `Prompt` | `VXT0079`; they need stream objects |
| a format given by a compile-time directive, `#define FORMAT "%d"` | the format must be a literal |
| formatted string interpolation, `"%d$count"` | not parsed as interpolation |
| `-Type-Safe-Format false` | the option is accepted and has no effect: formats are always checked strictly |
| other operations on strings: length, indexing, slicing, ordering | not implemented |
| native executables on Linux and macOS | the native linker is the Windows one |

## Verification

`ConsoleTests.hs` runs some 180 programs in the reference Core evaluator, on
the Core the frontend lowered and on the Core the optimizer left, and compares
what each wrote with text written by hand; it holds about a hundred programs
that must be rejected, each with its code. The text functions of that
evaluator are written a second time, in `RuntimeText.hs`, with unbounded
integers and exact rationals, and share nothing with the runtime library.

`TextRuntimeTests.cpp` calls the runtime library the way generated code does.
The digits of `%f` are compared with those the C library of the host writes,
which is a third implementation, over values chosen for their rounding and
over a sweep of binary exponents.

`RuntimeCallPipelineTests.cpp` pins the catalog row by row and breaks a
runtime call in each way it can be broken at each native stage.

`source_console_smoke` compiles programs from source through LLVM and the JIT
in both pipeline modes, reads what they write through a sink, and requires
each to leave no object of the runtime behind. `executable_run_tests` builds
programs into native executables, runs them as processes and reads their
standard output and standard error.
