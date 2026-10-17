<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Ecosystem tools

tala-analyzer, talafmt, and talalint are separate products with separate versions, build layers, and CI
workflows. The compiler coordinates project source policy, but it does not embed these tools or force them to share the
compiler release number.

## Product map

| Product | Primary implementation | Public executable | Configuration |
| --- | --- | --- | --- |
| tala-analyzer | Haskell LSP plus editor hosts | `tala-analyzer` stdio binary | `tala-analyzer.kts` |
| talafmt | Haskell formatter | `talafmt` | `talafmt.kts` |
| talalint | Haskell semantic/source linter | `talalint` | `talalint.kts` |

Each product also contains a Kotlin Script DSL model. All three configuration hosts require JRE 25 and Kotlin Script Runner;
the runtime is not embedded into the Haskell tool.

The Kotlin projects provide typed scopes, defaults, validation, and immutable configuration snapshots. talafmt
also has a real Kotlin scripting evaluator used by the project-wide CLI bridge; the other tool evaluators remain separate
integration work. A checked-in DSL type alone must not be described as proof of end-to-end script evaluation.

## Shared project source policy

`tazel fmt` and `tazel lint` operate on the project. Tazel evaluates the project file, collects the same sources and
exclusions it hands to the compiler, and starts the tool once per ViPkg with those files. Everything after `--` goes to
the tool unread.

```text
tazel fmt
tazel fmt -- --check
tazel lint
tazel lint -- --fix
```

`format` requires `talafmt`; a project containing `talafmt.kts` also requires the installed `talafmt-config` evaluator.
`lint` requires `talalint`. If the corresponding configuration file is absent from the project root, the installed tool uses
its defaults. When present, configuration is selected for that tool only:

```text
talafmt.kts
talalint.kts
tala-analyzer.kts
```

The compiler project file does not grow formatter or linter rule blocks. Tool versioning and configuration remain owned by
the tool.

## tala-analyzer

tala-analyzer ships the `tala-analyzer` stdio LSP binary. The Haskell `lsp` package handles standard JSON-RPC framing,
process lifecycle, and incremental document synchronization. The analyzer calls the shared compiler frontend and publishes
diagnostics and hierarchical document symbols with UTF-16 positions. Editor-specific hosts launch this server; no Protobuf
dialect is required.

The intended configuration surface includes:

```kotlin
version = "latest"
analysisMode = AnalysisMode.FULL

diagnostics {
  compiler = true
  linter = true
  onChange = true
  onSave = true
}

inlayHints = true
formatting = true

workspace {
  indexDependencies = true
}

performance {
  workerThreads = 0
}
```

`workerThreads = 0` means automatic selection. Compiler and linter diagnostic controls are independent switches: Analyzer
coordinates them but does not merge their version or rule configuration.

The repository can contain IntelliJ Platform and VS Code host code without making either editor the language architecture.
Editor hosts should be thin protocol/UI adapters; Lexer through CorePrep remains in the Haskell language layer.

## talafmt

talafmt provides `talafmt`.

```text
talafmt File.tala
talafmt --check File.tala
talafmt --emit=stdout File.tala
talafmt --help
```

Without options `talafmt` formats each file in place and prints nothing. `--check` reports whether formatting would change
a file without modifying it. `--emit=stdout|coverage|checkstyle|json` writes the formatted source or a report to standard
output and leaves the files alone; `--emit=files` is the default. See the [command-line reference](CLI.md#talafmt).

Formatter configuration includes version selection, column and indentation widths, tab behavior, brace style, parenthesis
and punctuation spacing, line endings, final newline policy, sorting, input/output encoding, and byte-order-mark emission.
The current configuration model defaults to UTF-8 input/output and no BOM. During `tazel fmt`, source discovery examines
paths without decoding source contents. The formatter then decodes each file with `encoding.input` and writes it with
`encoding.output` and `emitByteOrderMark`; compiler builds continue to require strict UTF-8 independently. Project format
is in place by default, while `tazel fmt -- --check` performs byte-accurate checks without writing.

Formatting must be parser-gated and idempotent. The formatter may normalize physical source layout, but it must not invent
language forms, change name identity, turn an invalid source into a different valid program, or apply C-family `switch/case`
rules to a language without those constructs.

The implemented layout engine normalizes block indentation in addition to line endings, trailing horizontal whitespace,
and final-newline policy. It consumes the compiler's lossless source-fragment model: braces in comments and literals do not
alter nesting, and lines crossed by raw strings or long comments retain payload whitespace. The executable engine supports
space or tab indentation with independent indent and tab widths. Remaining configuration keys stay typed configuration
surface until their corresponding layout passes exist; they are not silently treated as implemented behavior.

Install the package globally through ViGet:

```text
tazel install --global Progmasoft.Talafmt
```

## talalint

talalint provides `talalint`. Its standalone control surface includes:

```text
talalint File.tala
talalint --fix File.tala
talalint --help
```

`--fix` applies fixes classified as applicable
by the configured safety policy; a diagnostic suggestion is not automatically a safe rewrite.

The linter configuration begins with global diagnostic behavior:

- product version;
- default severity;
- maximum diagnostic count;
- source/severity/rule ordering;
- rule IDs and explanation links;
- safe and unsafe fix application;
- generated/inactive/dependency/whole-program analysis policy;
- unknown and deprecated rule policy;
- suppression reporting; and
- baseline behavior.

Rules are grouped by language ownership rather than one flat list. Current catalog categories include naming, imports,
visibility, declarations, modifiers, overrides, members, bindings, functions, constructors, destructors, entry points,
expressions, control flow, exceptions, optionals, ownership, closures, generators, iteration, collections, BLINQ, text,
comments, attributes, operators, unsafe operations, FFI, assembly, directives, performance, concurrency, I/O, command
execution, databases, public API, maintenance, and formatting hygiene.

A key in the typed catalog is not automatically an implemented analysis. A linter rule becomes connected when it has a
semantic/source implementation, stable rule identity, severity behavior, focused tests, and—when relevant—safe/unsafe fix
classification.

Install the package globally through ViGet:

```text
tazel install --global Progmasoft.Talalint
```

## Configuration independence

Formatter and Linter configurations are not sections of `BUILD.kts`. Their defaulting rules are:

1. use the tool configuration file in the project root when it exists;
2. otherwise use the installed tool's default configuration; and
3. apply command-line controls of the standalone tool to the current invocation.

Tool configuration versions do not inherit the compiler version. This is necessary because formatting stability, linter
rule evolution, Analyzer protocol features, and compiler language support can ship on different schedules.

## Distribution and registry paths

ViGet is the one hosted package registry. Tala packages and Kotlin DSL plugins occupy distinct catalogs:

```text
https://viget.progmasoft.com/langs/tala/<Publisher>/<Name>/
https://viget.progmasoft.com/dslplugins/tazel/<Publisher>/<Name>/
```

The first path contains Tala-authored `.vipkg` packages, in the catalog of the Tala language. The second contains the
Kotlin DSL plugin JARs of Tazel, in the catalog of its build-system DSL. The language and the build system are part of
the path so that each catalog stays separate from those of other languages and build systems. A DSL plugin is not
a `.vipkg`, and a Tala library is not loaded as JVM build logic.

Publisher identity is the Progmasoft Account name. Account management and dashboards belong under the account service, not
under a fake registry dashboard path:

```text
https://account.progmasoft.com/<Account>/dashboard
```

ViGet coordinates are case-sensitive. Local project declarations use explicit contained paths and do not create another
repository:

```kotlin
plugins {
  localPlugin {
    path = "plugin.jar"
  }
}

dependencies {
  localDependency {
    path = "dependency.vipkg"
  }
}
```

Remote coordinate layout is fixed by ViGet. Project files do not configure a Gradle-like repository list or generate an
alternative DSL-plugin repository coordinate.

## Build and workflow ownership

Each ecosystem root is a small multi-language project:

```text
Ecosystem/tala-analyzer/    Cabal + Gradle + editor-host build metadata
Ecosystem/talafmt/   Cabal + Gradle
Ecosystem/talalint/      Cabal + Gradle
```

Cabal owns Haskell implementation/tests. Gradle owns Kotlin DSL models/tests. Editor host package systems own only their host
integration. GitHub workflows are split into `analyzer.yml`, `formatter.yml`, and `linter.yml` so a tool failure is visible
without coupling all releases to the compiler workflow.

## Boundary rules

- Do not move language parsing or type checking into editor code.
- Do not make `talac` silently format or lint during ordinary compilation.
- Do not make Ecosystem/talafmt/Linter installation a compiler build dependency.
- Do not use filesystem layout as namespace identity.
- Do not call an unevaluated Kotlin model an active configuration evaluator.
- Do not treat `tala-analyzer` as a compiler driver: it is an editor-facing stdio LSP process.
- Do not publish DSL plugin JARs in the `.vipkg` catalog.
- Do not add user-configurable remote repository lists; ViGet is the hosted registry.
- Do not share release numbers merely because components live in one source repository.
