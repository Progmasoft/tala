<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Compiler pipeline

This document follows a Visual X# source set from project discovery to a native artifact. It describes the connected
production route and names the stage that owns each invariant. See [Implementation status](IMPLEMENTATION.md) for coverage
limits and [Architecture](ARCHITECTURE.md) for component boundaries.

## Route overview

```text
Visual.XSharp.kts or -File
        |
        v
project evaluation / explicit-input validation
        |
        v
source-set discovery and strict UTF-8 decoding
        |
        v
Lexer -> Parser -> Renamer -> Name Resolution -> Type Checker
        |
        v
Desugarer -> Core verifier -> specialization demand graph
        |
        v
Core optimizer -> Core verifier
        |
        v
bounded VXCR transport
        |
        v
Core reader -> Core verifier -> Core-to-CorePrep adapter
        |
        v
CorePrep verifier -> Xpp -> Xpp optimizer -> Xpp verifier
        |
        v
Xmm -> Xmm optimizer -> Xmm verifier
        |
        v
LLVM IR -> LLVM verifier -> optimization -> target machine
        |
        +--> .ll / .bc / .o / .asm
        |
        `--> LLD -> .vxse
```

The user-facing compiler command remains `vxs`. The native driver calls the adjacent Haskell `vxs-frontend` shared library
through a versioned C11 ABI; the library is not a second process or public compiler command. Native middle-end and backend
libraries are linked into `vxs`; CorePrep is never exposed as a command or file type.

## 1. Input selection

The CLI selects exactly one input mode.

### Explicit source

`-File path.vxs` selects one source file. The extension and requested `-Build` kind must agree. The driver does not search
for a project merely to reinterpret that file, although project-independent CLI defaults still apply.

### Project source set

Without `-File`, source commands discover `BUILD.kts` by walking from the requested working directory toward the
filesystem root. The Kotlin evaluator returns a typed project plan containing source roots, exclusions, entry identity,
compiler settings, targets, test suites, output directories, and package metadata.

The evaluator does not expand source roots into a list of `.vxs` files. That distinction keeps filesystem and language
ownership in the frontend, prevents Kotlin and Haskell glob semantics from drifting, and lets Analyzer, Formatter, Linter,
and the compiler share one source policy.

### Explicit artifact

`-Build core -File module.core`, `-Build xpp -File module.xpp`, and `-Build xmm -File module.xmm` select their versioned
readers. Each decoded artifact is checked by its owning verifier before the pipeline continues. Object input is meaningful
only for a build operation and does not pass through frontend analysis.

## 2. Source-set loading

The Haskell driver owns recursive source discovery. For each configured root it:

1. canonicalizes the project and source-root paths;
2. rejects a root or traversed filesystem link that escapes the project root;
3. walks directories in deterministic project-relative order;
4. selects files whose extension is exactly `.vxs`;
5. applies normalized project-relative exclusion patterns;
6. de-duplicates the same physical file reached through overlapping roots; and
7. decodes every selected file as strict UTF-8 before lexing.

`*` and `?` do not cross a path separator. A complete `**` segment may span zero or more directories. Exclusion matching is
about repository paths, not namespace spelling.

A physical file is a parsing unit. It is not a language module and need not mirror namespace segments in its directory
path. Files declaring the same namespace are merged after parsing and before semantic identity is assigned.

## 3. Lexer and parser

The Haskell lexer creates positioned tokens and retains enough source information for diagnostics. It validates literal
structure early: radix digits, separators, escapes, Unicode scalar values, and unterminated constructs are lexical
responsibilities.

Source-oriented tools do not reconstruct text from those semantic tokens. `Visual.XSharp.SourceText` provides a parallel,
lossless fragment stream whose concatenation is exactly the original source. Code, line comments, long comments, character
literals, normal strings, and raw strings retain their original spelling and half-open source spans. A masked view preserves
line endings and character positions while hiding protected payloads, allowing structural tools to inspect braces without
mistaking literal or comment text for syntax. Multi-line protected ranges are explicit so a formatter cannot accidentally
trim or reindent payload data.

The parser constructs a parsed AST rather than a mutable tree shared by later passes. It owns grammar and precedence, but it
does not decide which declaration an identifier denotes. Recovery must preserve the first useful source error and avoid
turning one malformed token into a cascade of unrelated names.

The grammar does not acquire C-family constructs merely because the native backend is C++20. In particular, documentation
and tests must use Visual X# declarations and control-flow forms from `Spec/`, not substitute `switch`, `case`, or a
top-level C-style entry function.

## 4. Renaming

The Renamer assigns stable `SymbolId` values to declarations and local binders. Textual spelling remains available for
diagnostics, but identity after this stage is not a string comparison.

The Renamer owns:

- lexical scope construction;
- duplicate binder detection within the scope it creates;
- fresh identities for parameters, locals, captures, types, methods, and synthetic bindings;
- preservation of source spans on renamed nodes; and
- deterministic identity allocation for deterministic input order.

Method declarations that form an overload set share source spelling but not identity. The Renamer keeps the
source-ordered binding assigned to each declaration rather than looking it up again by spelling. This prevents a later
overload from replacing every declaration's `SymbolId`; the Type Checker uses that stable identity to attach the selected
candidate to each call.

A later verifier must compare the same identity model. Reconstructing identities from display names would make shadowing,
overloads, and cross-file namespace merging inconsistent.

## 5. Name Resolution

Name Resolution binds renamed references to declarations. It distinguishes namespace/type/member lookup from local lexical
lookup and reports unresolved or ambiguous references without inventing a dynamic fallback.

All files in the same namespace participate in one semantic namespace. Different namespaces are currently validated as
separate frontend units. Cross-namespace imports and the future multi-module Core link unit are not connected, so a project
must not silently fold unrelated namespaces into the entry namespace.

Callable capture initializers resolve in the surrounding scope. Capture-private aliases become visible only in the callable
body. Explicit capture mode forbids unlisted outer bindings.

A member selector's receiver is resolved as an expression at this stage. The selector name remains source text until the
Type Checker has the type catalog and overload signatures; Name Resolution does not guess whether the receiver is a type.

## 6. Type checking

The Type Checker produces a typed AST. It owns declared/inferred local types, call signatures, return compatibility,
condition conversion, assignment compatibility, operator rules, literal target selection, and entry-method validation.

Important current invariants include:

- a project entry names a namespace-qualified class;
- the selected class provides parameterless `public static void Main()`;
- source `void` is the only no-result type; the native `unit` spelling is an internal marker;
- scalar widths are Visual X# widths, not C or host widths;
- numeric boolean context treats zero as false and nonzero as true;
- two computed arithmetic operands must already have the same scalar type; and
- range checks use unbounded compiler arithmetic before selecting a fixed-width representation.

The first connected member-call slice follows the source forms in `Spec/Language/Decls.vxs` Examples 187–189. Direct
`Type.Member(arguments)` calls resolve against top-level type declarations in the current semantic namespace. Method
overloads are keyed by spelling and ordered parameter types; access, return type, and staticness do not distinguish a
signature. Type-qualified calls consider only static candidates, filter access, and require one exact-type match. A
successful call is rewritten to reference the selected method's `SymbolId`; no dynamic member lookup or implicit numeric
conversion is inserted. Unqualified calls to the current type use its complete overload family.

This does not connect instance field/property lookup, instance dispatch, nested types, namespace-qualified type paths,
cross-namespace imports, extension lookup, inherited protected access, or native overload mangling. The implementation
boundary and diagnostics are recorded in [Static member calls and method overloads](STATIC-MEMBER-RESOLUTION.md).

The checker preserves normalized floating spelling until target-aware native conversion is available. Unsupported transport
payloads fail explicitly instead of rounding through a host `Double`.

## 7. Desugaring and Core

The Desugarer converts typed source constructs into target-independent Core. It removes source conveniences but must not
choose LLVM layouts, calling conventions, object formats, or target triples.

Core retains stable symbols, typed functions, expressions, calls, branches, returns, literals, and closure metadata. The
Core optimizer may simplify expressions while preserving types, evaluation order, source behavior, and symbol identity.

Before Desugarer, the Haskell frontend walks all type-bearing positions in
ordinary TypedAST declarations and discovers concrete template layout demands.
It binds and coalesces those applications, clones the closed declarations,
freshens every declaration/member/parameter/local/capture identity, derives
structural internal names, and verifies the complete plan. Ordinary and cloned
declarations are lowered separately, merged, and verified again as Core.

After that initial Core verification, the Haskell specialization-demand pass
walks all type-bearing Core boundaries. It interns concrete parameterized
types, retains semantic origin paths, follows nested type arguments to a fixed
point, checks resource limits, validates dependency-graph invariants, and
derives a stable child-before-parent emission order. Neither plan is serialized
as part of `VXCR`.

This connected pass is not the complete template engine. Constraint ordering,
lazy resolved-member reachability, explicit instantiation, a public native
mangling ABI, and persistent incremental caching remain separate work. The
backend never guesses those source semantics.

The Core verifier is not optional. It checks artifacts produced by the frontend and artifacts loaded from disk. The Haskell
and C++20 implementations share the versioned `VXCR` contract and equivalent structural expectations. Limits cover document
size, collection counts, text lengths, nesting depth, expression depth, Unicode scalars, and closure structure.

Source `void` is mapped once to the current resultless Core ABI marker. The marker's historical implementation name is
`unit`, but `unit` is not a source-language type and must not escape in source-facing diagnostics or artifacts.

## 8. Process transport

The private frontend writes bounded `VXCR` bytes to a temporary artifact selected by the native driver. The driver locates
the frontend relative to its installed or build-tree layout rather than searching the current directory or trusting an
unrelated executable on `PATH`.

Temporary files have one cleanup owner and are removed on success and failure. The native reader validates framing before
allocating nested structures. A malformed document never reaches Xpp or LLVM merely because it has a `.core` extension.

An internal `VXCP` CorePrep codec exists for contract and embedding tests. It is not accepted by `-Build core`, has no public
extension, and is not an emit choice.

## 9. Core-to-CorePrep adaptation

CorePrep is the normalization seam between the high-level Core model and Xpp. The dedicated adapter:

- atomizes nested calls and primitive expressions in evaluation order;
- creates deterministic temporary symbols;
- turns source conditionals into explicit blocks, branches, joins, and terminators;
- normalizes numeric boolean context into a canonical boolean comparison;
- lifts callable bodies and preserves ordered capture metadata; and
- carries types and symbol identities forward without re-running semantic inference.

CorePrep does not optimize and does not reconstruct missing types. Its verifier checks block ownership, unique block and
symbol identities, branch targets, terminators, operand types, callable targets, captures, and unresolved types.

## 10. Xpp

Xpp is a target-independent C++20 IR. Lowering from verified CorePrep preserves function identity, signatures, storage
declarations, typed operands, calls, branches, jumps, returns, and closure creation metadata.

Xpp optimization is a separate phase. The connected passes include control-flow cleanup, safe self-copy elimination, and
backward-liveness removal of unused `Define Copy` chains. Store, discard, call, allocation, arithmetic, and ownership
instructions remain observable. Every optimized module passes the Xpp-owned verifier; an optimization is not allowed to rely on the later Xmm
or LLVM verifier to catch its mistakes.

The verifier also adapts explicit AARC operations to the shared ownership-flow analysis. It distinguishes strong object
references from weak and unowned control handles, rejects release-after-release and use-after-release, and preserves every
possible state at a control-flow join. See [Ownership-flow verification](OWNERSHIP-FLOW.md).

The public `.xpp` artifact uses the bounded versioned `VXPP` reader/writer. Ordinary compilation still keeps Xpp in RAM
unless the user explicitly selects Xpp input or output. The corresponding `.xmm` `VXMM` reader/writer also supports
verified forward resumption into LLVM.

## 11. Xmm

Xmm lowers storage and values into a typed virtual-register model while remaining independent of LLVM objects. Function
symbols remain distinct from data registers. Calls retain complete signatures, and each instruction declares the type of
its result or side effect.

Xmm optimization includes safe virtual-register move simplification and liveness-based removal of unused `LoadImmediate`
and result-producing `Move` chains. Calls, arithmetic, closure construction, resultless evaluation, and ownership actions
are retained. The Xmm-owned verifier checks register
declarations, parameter mappings, operand and result types, function targets, call arity and types, block targets, and
terminators.

The Xpp and Xmm verifiers share the directional scheduler and compact lattices described in
[Native dataflow](NATIVE-DATAFLOW.md). Forward definite-initialization and ownership analyses notify successors only when
their output changes; backward liveness notifies predecessors. Production validation keeps exact issues and fixed points
without expanding unused per-block fact vectors.

Definite initialization and ownership are separate checks. A register may be defined yet unsafe because its token has been
consumed or carries the wrong AARC representation. Xmm repeats ownership-flow verification after lowering so native callers
and artifact readers cannot bypass the Xpp boundary.

The backend compatibility `Verify` entry delegates to this verifier, but Xmm remains the owner. `.xmm` is a public artifact
with a bounded, versioned `VXMM` reader/writer. Loaded Xmm is verified before optimization or LLVM lowering and again before
serialization.

## 12. LLVM lowering

The backend creates LLVM objects only after Xmm verification succeeds. It uses the LLVM C++ API, scoped resource ownership,
the new pass manager, target-machine APIs, and native code generation. LLVM-C does not belong in the renewed C++20 route.

Current lowering covers the connected scalar subset, typed calls, mutable virtual-register storage, branches, jumps,
returns, signed division, floor-division adjustment, and Unicode-scalar string constants. Named values without a defined
layout, unresolved types, unsupported scalar payloads, and closure construction without an AARC ABI are rejected.

The generated module is verified before optimization. The selected `-Llvm-OptLevel` maps to an LLVM O0/O1/O2/O3 pipeline,
after which a target machine can produce assembly or an object.

## 13. Artifact emission

Artifact ownership is explicit:

| Emit kind | Producer | Result |
| --- | --- | --- |
| `core` | Haskell frontend | versioned `.core` |
| `llvmll` | LLVM backend | textual `.ll` |
| `llvmbc` | LLVM backend | binary `.bc` |
| `object` | LLVM target machine | `.o` |
| `assembly` | LLVM target machine | `.asm` |
| `binary` | target machine plus LLD | `.vxse` |

`check` writes no artifact. Binary emission creates the required entry bridge, writes a temporary object, invokes LLD with a
typed argument vector rather than a shell string, validates the resulting executable, and removes its temporary object.

Project binary builds produce one executable. The entry namespace's Core v10
preserves source ownership through CorePrep v8, Xpp v7, and Xmm v7. Project
object and assembly emission lowers each source in that selected namespace's
source catalog into a separate `.o` or `.asm` in the selected output directory.
A source with no declarations still receives an output; functions defined by
another source remain external declarations in the current partition. The
compiler rejects flattened basename collisions before writing and commits the
complete artifact set through a same-filesystem staging transaction. See
[Project native artifacts](PROJECT-ARTIFACTS.md) for naming, replacement, and
recovery semantics. Explicit single-file builds remain distinct and emit a
sibling artifact.

## 14. Failure discipline

Every stage rejects invalid input before handing it to the next stage. A useful failure identifies the owning stage, retains
source position when one exists, and does not leave a plausible stale output artifact behind. `run` executes only the exact
binary produced by the current successful build; it never falls back to an older executable.

This layered verification is deliberate. Source can enter through the frontend, Core can enter through a file, and native
libraries can be called directly by tests or embedding code. Each boundary therefore validates its own invariants instead
of assuming all callers followed the longest route.

## 15. Deliberate next seams

The major unfinished seams are:

- cross-namespace import binding;
- a multi-module Core link unit;
- broader object, value, exception, ownership, and standard-library lowering; and
- named test-suite execution through its framework runner.

These gaps should be implemented in the stage that owns the missing invariant. They are not reasons to restore the removed C
frontend, create a second Rust production compiler, or expose CorePrep as a user format.
