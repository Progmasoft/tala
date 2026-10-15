<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# talafmt

talafmt provides the `talafmt` command and validates every input with the canonical Tala lexer and parser before
changing it. It normalizes line endings, trailing horizontal whitespace, the final newline, and brace-based block
indentation. The compiler's lossless source-fragment model distinguishes code from comments, character literals, normal
strings, and raw strings, so structural characters inside protected text never affect indentation.

The formatter accepts what the compiler it is built with accepts. Version 0.2.0 is built with the compiler of
Tala 0.6.0, so a source may use method references (`Type::Method`), names written through their namespace,
conditionals over strings, `match`, enums and console formats; none of them changes how a line is laid out.

```text
talafmt Program.tala Library.tala
talafmt --check Program.tala Library.tala
talafmt --emit=stdout Program.tala
talafmt --help
talafmt --version
```

Without options `talafmt` formats every requested file in place and prints nothing. `--check` changes nothing and returns
a failing exit status when any requested source would change. `--emit=stdout`, `coverage`, `checkstyle` and `json` write
the formatted source or a report to standard output and leave the files alone; `--emit=files` is the default. `-h` and
`-v` are the short forms of `--help` and `--version`. The command line is read by a typed parser written by hand; a line
it cannot read exits with status 2. Project configuration is evaluated once for all requested sources.

The default engine uses four spaces per block level. Its public Haskell options also support tabs, an independent tab width,
explicit LF or CRLF output, disabling reindentation, and preserving a missing final newline. Lines crossed by a multi-line
raw string or long comment retain their payload indentation and trailing whitespace exactly; only their physical line
ending changes when an explicit output ending is requested.

The Kotlin module under `sources/main/kotlin` owns the typed `talafmt.kts` configuration surface, canonical
defaults, validation, immutable snapshots, and real scripting evaluator. `talafmt` invokes the installed `talafmt-config` helper
once, then applies the selected input encoding, output encoding, and BOM policy to every requested source. Encoding is not
a formatter CLI option: both direct `talafmt` use and project-wide `tazel fmt` obey `talafmt.kts`. UTF-16 and UTF-32
output uses deterministic little-endian payloads, with BOM emission controlled independently.
