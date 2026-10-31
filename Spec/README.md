<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

# Tala specification examples

The `.tala` files below this directory are topic-oriented language design examples. Each numbered fragment is independent and
includes context that explains the intended rule, whether the fragment is valid or invalid, and which surrounding declarations
may be omitted for brevity.

These files are not concatenated programs. Repeated declarations, incomplete context, and deliberately rejected examples are
intentional. A file may therefore be useful as a design reference without being directly compilable as one application.

The directory records current language intent; it is not an implementation-completeness claim. The production compiler is
still moving to the Haskell-through-CorePrep and C++20 Xpp/Xmm architecture, so some examples describe behavior that has not
yet reached the production Talac route.

When a language rule is implemented, it should gain a focused compiler test in addition to its explanatory example here.
Compiler behavior must not be inferred from historical fixtures when it conflicts with the current examples.

See [the specification guide](../Documents/SPECIFICATION.md) for the topic map and maintenance rules.

## Catalog

### Language

- [Declarations](Language/Decls.tala) and [attributes](Language/Attributes.tala), including tests: `[Fact]` and `#expect`
- [Evaluation](Language/Evaluation.tala): evaluation by need and effects
- [Operators](Language/Operators.tala), [iteration](Language/Iteration.tala), and [unsafe behavior](Language/Unsafe.tala)
- [String](Language/String.tala), [Optional](Language/Optional.tala), and [exceptions](Language/Exceptions.tala)

### Standard library

- Core: [core system](StandardLibrary/Core/CoreSystem.tala) and [collections](StandardLibrary/Core/Collections.tala)
- I/O: [console](StandardLibrary/IO/ConsoleIO.tala), [files](StandardLibrary/IO/FileIO.tala), and
  [commands](StandardLibrary/IO/Command.tala)
- Text: [JSON](StandardLibrary/Text/Text.Json.tala) and [XML](StandardLibrary/Text/Text.Xml.tala)
- Numerics: [System.Math](StandardLibrary/Numerics/Math.tala)
- Runtime services: [threading](StandardLibrary/Concurrency/Threading.tala), [date](StandardLibrary/Temporal/Date.tala), and
  [time](StandardLibrary/Temporal/Time.tala)
- Query: [BLINQ](StandardLibrary/Query/BLINQ.tala)

### Libraries and interop

- Databases: [MariaDB](Libraries/Databases/MariaDB.tala), [PostgreSQL](Libraries/Databases/PostgreSQL.tala), and
  [SQLite](Libraries/Databases/Sqlite3.tala)
- Native boundaries: [FFI](Interop/FFI.tala) and [inline assembly](Interop/InlineAssembly.tala)
