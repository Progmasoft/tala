<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
-->

# Tala comparative programs

Each directory contains the same complete program in five languages:

- Tala, written against the normative `Spec/` language and standard-library contracts;
- C# 13;
- C++20;
- Java 21;
- Rust.

The examples are comparative source material, not a declaration that every forward-looking Tala feature is already
implemented by the current compiler. The "Compiles with talac" column says which Tala programs talac compiles, and
for the others the first construct talac rejects; `verify-examples --talac=<talac>` compiles every program and fails when the column is
wrong in either direction. C#, Java, and Rust are comparison languages only. Rust examples and the comparative
benchmark do not make Rust a Tala compiler implementation language or a mandatory compiler-development prerequisite.
`optional_packages.go` can add `rustc` and `rust-std` components to an existing rustup toolchain; it never installs or
selects a toolchain automatically.

Every program is intentionally self-contained. The C++, C#, Java, and Rust variants use their own standard libraries rather
than imitating Tala APIs mechanically.

| Program | Main Tala surface | Compiles with talac |
| --- | --- | --- |
| `HelloWorld` | namespace, class entry point, `String`, console output | yes |
| `FizzBuzz` | closed ranges, `for (:)`, mandatory `if` parentheses | no: closed ranges (`1 ... 30`) |
| `Fibonacci` | lazy `System.Utils.Enumerable<T>` generator and `yield` | no: `yield` |
| `WordFrequency` | `[T]` dynamic arrays and `[K to V]` dictionaries | no: array literals |
| `BankAccount` | AARC class, constructor labels, fields, mutation | no: fields |
| `ShapeAreas` | data classes, inheritance, type patterns, `match` | no: data classes |
| `FileRoundTrip` | standard file APIs, UTF-8 text, resource cleanup | no: `using` directives |
| `ConcurrentMessages` | MPSC channels, task spawning, message transfer | no: `using` directives |
| `ExceptionRecovery` | declared throws, typed catch, per-item recovery | no: `throws` clauses |
| `GenericStack` | generic classes, dynamic collections, LIFO operations | no: fields |
| `LoopControl` | `while`, `do/while`, classic `for`, `break`, and `continue` | yes |
| `PrimeNumbers` | nested loops, early returns, divisor bounds | yes |
| `CollatzTrace` | loop-carried state, parity, a bounded termination guard | yes |
| `MatrixTranspose` | flattened row-major storage and nested index loops | no: array literals |
| `GCD` | Euclid's algorithm and loop-carried remainder state | yes |

## Comparing loop behavior

`LoopControl`, `PrimeNumbers`, `CollatzTrace`, `MatrixTranspose`, and `GCD` put the loop forms under active compiler
development into small, inspectable programs. In particular, `LoopControl` exercises all three loop statements and both
loop-control transfers in one deterministic result. `MatrixTranspose` deliberately uses a flat buffer rather than
assuming that nested arrays share the same layout across the five languages. `PrimeNumbers` uses trial division so the
example demonstrates control flow instead of hiding it inside a library sieve.
