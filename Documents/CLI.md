<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# `talac` command-line interface

## Commands

The parser recognizes:

```text
check
build
format
lint
run
test
resolve
update
install
viget
version
interactive
```

The general invocation shape is:

```text
talac <command> [command options] [command positional values]
talac -Help
talac <command> -Help
```

Command, option, and enumerated-value spelling is case-sensitive. Compiler options use one leading hyphen and Pascal-style
segments. Version reporting is available only through the explicit `talac version` command.

| Command | Purpose | Current connection |
| --- | --- | --- |
| `check` | validate source or a supported explicit artifact | connected for project/source/Core |
| `build` | emit the selected artifact | connected for project/source/Core within documented output limits |
| `run` | build a fresh binary and execute it | connected for the implemented source subset |
| `test` | execute a named project test suite | registered; framework runner not linked |
| `format` | format the complete project source set | connected dispatch; requires installed `talafmt` |
| `lint` | lint the complete project source set | connected dispatch; requires installed `talalint` |
| `resolve` | evaluate the project and refresh the lockfile | connected project operation |
| `update` | reevaluate dependencies and refresh the lockfile | connected project operation |
| `install` | install a ViGet package | registered; ViGet client not linked |
| `viget` | perform registry publication/update action | registered; ViGet client not linked |
| `version` | report compiler version through command form | recognized version outcome |
| `interactive` | launch the Tala Interactive REPL | connected process dispatch; requires `tali` on `PATH` |

Registered commands fail explicitly. They never print success while skipping the requested package or test operation.

`talac interactive` looks up the `tali` companion in the process `PATH` and forwards every subsequent argument unchanged.
This keeps the public entry point singular while allowing the REPL binary to be installed or staged independently:

```text
talac interactive
talac interactive --eval "5 + 5"
talac interactive -Help
```

The no-argument form opens the persistent REPL. One-shot `--eval` runs a Tala expression and exits; `-Help` is handled
by `tali`, not consumed by the outer compiler parser. The native bundle places `tali` beside `talac`, so add that install
directory to `PATH` before invoking the command. Direct `tali` invocation remains available for development and IDEs.

`check`, `build`, `run`, and `test` accept either a discovered `BUILD.kts` project or a `.tala` file selected with
`-File`.

`format` and `lint` are project-only commands. They evaluate the project source policy, apply its roots and exclusions,
and invoke the separately installed ecosystem tool for every discovered `.tala` source:

```text
talac format           # formats in place; requires Progmasoft.Talafmt
talac format -Dry-Run  # checks every source without writing
talac lint    # requires Progmasoft.Talalint
```

talafmt evaluates `talafmt.kts` from the project root when present and otherwise uses its defaults.
`talac format` does not expose `-In-Place`: project formatting is in-place by definition, and `-Dry-Run` is its only format
mode flag. The formatter, rather than the compiler source loader, decodes and re-encodes source bytes according to the
configured `encoding.input`, `encoding.output`, and `emitByteOrderMark` values. talalint applies the equivalent
configuration-file ownership rule for `talalint.kts`.

Package commands use typed positional forms:

```text
talac install [-Global] Publisher.Name
talac viget push|update
```

Hosted coordinates contain exactly two case-sensitive ASCII identifier segments. Each segment starts with an ASCII letter
and continues only with ASCII letters, digits, or `_`; paths, query strings, whitespace, Unicode spellings, and additional
dot-separated segments are rejected before registry dispatch.

## Canonical options

```text
-File PATH
-Standard 26|latest
-Compiler-Version VERSION|latest
-Target TARGET-TRIPLE
-Warnings all|medium|low|none
-Werror true|false
-Wexperimental true|false
-Wshadow true|false
-Wundef true|false
-Type-Safe-Format true|false
-Backend llvm
-Llvm-OptLevel 1|2|3|g
-Llvm-Compiler aot|orc
-Llvm-Lto fat|thin|none
-Xpp-Optimization-Passes true|false
-Xmm-Optimization-Passes true|false
```

Tool commands add only their own scoped controls: `format` accepts `-Dry-Run`, while project formatting without it writes
in place. `-In-Place` belongs to standalone `talafmt` and is intentionally rejected by `talac format`.

`build` additionally parses `-Emit`. `build` and `check` parse `-Build` for an explicit input artifact:

```text
-Emit binary|object|core|xpp|xmm|assembly|llvmll|llvmbc
-Build object|talac|core|xpp|xmm|llvmll|llvmbc
```

Canonical compiler settings use one leading hyphen and the displayed capitalization. `-Help` is the canonical help
control. Legacy GNU-style controls, including `--help` and `--version`, are rejected.

`-Type-Safe-Format true` is the strict and default mode. Calls to formatted Console APIs must use a format grammar whose
conversions agree with the corresponding argument types; a mismatch is a compile-time error. Setting the option to
`false` requests the intentionally looser C-compatible format-checking policy. It does not disable parsing the format
string or make malformed conversions valid. The distinction matters most for `Console.Printf`, `Console.Printfn`,
`Console.Errorf`, `Console.Errorfn`, `Console.Format`, and formatted Console input.

## Parser model

The parser converts raw process arguments into typed command, input, output, warning, Boolean, LLVM, and ViGet-action
values before dispatch. Its owning C++20 result separates ready, help, version, and error outcomes; parsing itself does not
write process output. The driver renders the selected outcome. Later compiler stages do not compare command strings or
reinterpret option values.

One declarative schema owns canonical spelling, value domain, arity, command scope, defaults, and help descriptions.
Consequently, `talac check -Help` shows `check` options but not build-only `-Emit`, while `talac build -Help` includes it.
Option and value spelling is case-sensitive.

## Configuration precedence

For every scalar compiler setting, the driver resolves values in this order, from strongest to weakest:

1. an option explicitly supplied in the current `talac` command;
2. the value produced by the project's `BUILD.kts` evaluation;
3. the Kotlin DSL's built-in default for that value;
4. the CLI fallback used when no project is being evaluated.

The evaluator deliberately materializes both user-written values and Kotlin DSL defaults. The native driver therefore
uses the evaluated project as one authoritative layer and never lets an omitted CLI option overwrite it. This applies to
warning policy, optimization settings, compiler/standard selection, and other transported compiler settings. Artifact
selection is CLI-owned: the project DSL does not persist an `emit` value.

`-Target` accepts a case-sensitive LLVM target triple such as `x86_64-pc-windows-msvc`. In project mode, an explicitly
selected target must occur in the DSL's `targets { target(...) }` catalog when that catalog is non-empty. Without an
explicit target, LLVM selects its host-dependent default; the first catalog entry is not chosen implicitly.

An explicit non-source `-Build` always requires `-File`. For example, `talac check -Build core` is rejected rather than
silently discovering a project; use `talac check -Build core -File Module.core`.

## Defaults

```text
standard: latest
compiler version: latest
warnings: medium
warnings as errors: false
experimental warnings: false
shadow warnings: false
undefined warnings: true
type-safe format checking: true
backend: llvm
LLVM optimization: 2
LLVM compiler: aot
LLVM LTO: none
target: host-dependent
Xpp optimization passes: true
Xmm optimization passes: true
```

### Option scope

| Option | `check` | `build` | `run` | `test` |
| --- | :---: | :---: | :---: | :---: |
| `-File` | yes | yes | yes | yes |
| `-Standard` | yes | yes | yes | yes |
| `-Compiler-Version` | yes | yes | yes | yes |
| `-Target` | yes | yes | yes | yes |
| warning and backend settings | yes | yes | yes | yes |
| LLVM and Xpp/Xmm settings | yes | yes | yes | yes |
| `-Build` | yes | yes | no | no |
| `-Emit` | no | yes | no | no |

The declarative schema is the authority for scope. A value accepted for one command is not ignored on another command; it is
reported as out of scope.

### Help behavior

```powershell
talac -Help
talac check -Help
talac build -Help
```

Help is resolved before project evaluation and compilation. `build` help includes `-Emit`; `check` help does not. Unknown
options still fail even if their spelling resembles a common convention such as `--help`.

## Current reliable operation

Single-file validation:

```powershell
talac check -File .\Sources\Main.tala
```

The Haskell frontend can emit verified Core, LLVM forms, target-machine output, or a native executable:

```powershell
talac build -File .\Sources\Main.tala -Emit core
talac build -File .\Sources\Main.tala -Emit xpp
talac build -File .\Sources\Main.tala -Emit xmm
talac build -File .\Sources\Main.tala -Emit llvmll
talac build -File .\Sources\Main.tala -Emit llvmbc
talac build -File .\Sources\Main.tala -Emit object
talac build -File .\Sources\Main.tala -Emit assembly
talac build -File .\Sources\Main.tala
talac run -File .\Sources\Main.tala
```

The accepted source subset is the subset implemented by the Haskell frontend. Native binary, object, assembly, and `run`
routes use the renewed C++20 backend and never fall back to the removed compatibility frontend. Named test-suite execution
remains pending.

For an explicit `-File` source or artifact, the emitted file is a sibling with the selected extension. Project binary builds
use the Kotlin DSL output directory (`build/debug` or `build/release` by default) and produce one `.vxse`. Project-wide
object and assembly requests produce one `.o` or `.asm` for every source owned by the selected entry namespace. Output paths
flatten to stems (for example, `Sources/MyApp/Main.tala` to `build/debug/Main.o`); duplicate stems are rejected before output
replacement. The driver lowers the whole batch first, stages all bytes beside the destination files, and restores prior
outputs if a later rename fails. It preserves unrelated and stale sibling files; pruning is a separate explicit clean
operation. See [Project native artifacts](PROJECT-ARTIFACTS.md) for the exact boundary and recovery limits.

## Core input status

The CLI reserves the real Core artifact commands:

```powershell
talac check -Build core -File module.core
talac build -Build core -Emit llvmll -File module.core
talac build -Build core -Emit llvmbc -File module.core
```

The native C++20 route reads the Haskell `TACR` v10 contract with byte, collection, text, type-depth, and expression-depth
limits. It verifies Core semantics before adapting nested expressions and source control flow to CorePrep, then runs the
existing verified CorePrep → Xpp → Xmm → LLVM pipeline entirely in memory. `check` writes nothing. The two `build` examples
write a sibling `.ll` or `.bc` file. A Core build can also write a sibling `.o` or `.asm`, or link a `.vxse`; binary is the
default emit kind. The older `TACP` transport remains internal and is rejected when supplied as `.core`.

### Xpp and Xmm artifact routes

```powershell
talac check -Build xpp -File module.xpp
talac build -Build xpp -File module.xpp -Emit xmm
talac check -Build xmm -File module.xmm
talac build -Build xmm -File module.xmm -Emit llvmll
```

`TAPP` and `TAMM` are bounded, versioned binary contracts. Both readers reject
invalid magic/version/flags, malformed tags, invalid Unicode, non-canonical
numeric payloads, excessive counts, truncated fields, and trailing bytes.
Decoded models pass their stage verifier before optimization or lowering.

Conversions move forward through the pipeline. Xmm cannot be converted back
to Xpp or Core, and Xpp cannot be converted back to Core. Rewriting the same
stage is permitted and replaces the artifact after successful verification.

## Registered but not connected

The CLI reserves the renewed artifact vocabulary before all routes are implemented:

- `install` and `viget` report that the ViGet client is not linked into the compiler build.
- `-Header` is recognized as a reserved build option but fails explicitly: TCI export/ABI semantics and a header writer are
  not implemented. It creates no output and does not begin project evaluation.
- `-Llvm-Compiler orc` is recognized and stored in settings, but does not create an ORC LLJIT or change execution today;
  `run` remains the AOT build/link/run path. It is not a usable JIT switch yet.

`resolve` and `update` evaluate the project configuration and refresh `LOCK.sqlite3`.

Lockfile text export is deliberately not a `talac` command. The separately installed `tadc` tool evaluates an exact
`BUILD.kts` and creates a deterministic SQL dump:

```powershell
tadc -Projectfile .\BUILD.kts -Output .\Project.sqlite3.dump
```

## Exit behavior

Command parsing errors return a nonzero status. Compilation diagnostics are printed to standard error. `run` propagates
build failures and, after a successful link, returns the native process exit status unchanged. This applies equally to an
explicit `.tala` source, a resumed Core/Xpp/Xmm artifact, and a project executable target; a program result such as `37` is
not collapsed into the compiler's generic failure status `1`.

Parse diagnostics retain context. Unknown commands/options name the rejected spelling; invalid typed values name the
option and its accepted domain; duplicate, missing-value, wrong-command-scope, positional, and invalid process-vector
errors are reported independently.

## Bundled executable layout

The public command is `talac`. A current local distribution also contains the private Haskell `tala-frontend` shared library,
which runs the lexer-through-Core stages in-process over a C11 ABI. It has no independent public CLI contract and is not a
substitute for `talac`.

Keep the driver, shared library, and REPL executable in the layout produced by `go run ./helpers/cmd/develop bundle`. The
driver resolves the library relative to its own location rather than searching the current project or accepting an
arbitrary same-named program from `PATH`. This pairing prevents a frontend with a different Core wire contract from being
selected accidentally.

The frontend runtime is initialized once and stopped at normal process teardown.
After shutdown, its successfully loaded shared-library image remains mapped
until the operating system releases the process. It is not a reloadable plugin:
GHC/base retain process-lifetime allocator caches in dependent shared images.
Unloading those images before LeakSanitizer's exit check removes the cache roots
and prevents useful allocator symbolization. Initialization failures still
release handles that never started a runtime. Leak detection is not disabled or
suppressed by this lifetime policy.

The bundle command validates this installed-path behavior by invoking the staged driver, compiling a real `.tala` input to
a `.vxse`, and running that output. `SHA256SUMS` and the staged legal files describe the complete local payload; they do not
add another user-facing command.

## Filesystem and overwrite behavior

Paths are interpreted by the owning command. Project discovery begins at the current/requested location and walks upward for
`BUILD.kts`; `-File` names one explicit input. The project evaluator and Haskell source loader canonicalize contained
roots rather than trusting textual prefixes.

`talac build` replaces the artifact selected for the current invocation when that build succeeds. It does not preserve an old
artifact merely because it already exists, and it does not execute that old artifact after a failed `run` build. Temporary
Core/object files are implementation details and are cleaned on every owned exit path.

## Examples by intent

Validate a project with its evaluated defaults:

```powershell
talac check
```

Override only the current target and warning policy:

```powershell
talac check -Target x86_64-pc-windows-msvc -Warnings all -Werror true
```

Build a project executable using the project output directory:

```powershell
talac build
```

Build one explicit source into LLVM IR without requiring its path to match a namespace:

```powershell
talac build -File .\Scratch\Bootstrap.tala -Emit llvmll
```

Validate a public Core artifact without writing output:

```powershell
talac check -Build core -File .\Artifacts\Bootstrap.core
```

Convert that Core artifact to a native executable:

```powershell
talac build -Build core -File .\Artifacts\Bootstrap.core -Emit binary
```

Refresh a project's binary lockfile:

```powershell
talac resolve
talac update
```

The two package-resolution commands currently share project evaluation and lock refresh behavior. A future transitive solver
or registry client must preserve their typed command identity instead of collapsing the public command surface into a string
switch.
