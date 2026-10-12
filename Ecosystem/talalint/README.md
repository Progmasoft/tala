<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# talalint

talalint provides the `talalint` command. Its semantic diagnostics come directly from the canonical Tala compiler
frontend. The first independent checks cover trailing whitespace, mixed line endings, and a missing final newline.

```text
talalint Program.tala
talalint --fix Program.tala
talalint --help
talalint --version
```

The linter reports what the compiler it is built with reports. Version 0.1.1 is built with the compiler of
Tala 0.5.0: a source may use method references (`Type::Method`), names written through their namespace,
conditionals over strings and console output, and their diagnostics arrive under the `compiler` check, for example
`compiler.TAT0080` for a method reference that does not select one overload and `compiler.TAT0076` for a format the
compiler rejects.

`--fix` applies only safe physical-source fixes and never rewrites compiler or semantic diagnostics. `-h` and `-v` are
the short forms of `--help` and `--version`. The command line is read by a typed parser written by hand; a line it
cannot read exits with status 2.

The Kotlin module under `sources/main/kotlin` owns the typed `talalint.kts` configuration surface. It exposes the
complete rule catalog as typed scope properties and produces immutable snapshots without discovering or evaluating
scripts.
