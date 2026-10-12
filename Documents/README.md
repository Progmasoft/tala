<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Tala documentation

This directory explains the repository as it exists today. It is intentionally separate from `Spec/`: the specification
records language design, while these documents describe compiler architecture, supported workflows, implementation
coverage, and contributor contracts.

Tala is experimental. A documented design is not automatically an implemented feature. Every document uses the
following vocabulary:

- **connected** means the behavior is reachable through a supported command and covered by the owning test layer;
- **implemented** means code and focused tests exist, although a public command may not expose it yet;
- **registered** means a public spelling or model value is reserved but its execution route is intentionally rejected;
- **planned** means the design has direction but must not be relied on by programs; and
- **legacy** means retained code is outside the production pipeline and receives no new feature work.

## Start here

| Goal | Document |
| --- | --- |
| Understand the whole repository | [Architecture](ARCHITECTURE.md) and [repository layout](MONOREPO.md) |
| Follow one source file through the compiler | [Compiler pipeline](COMPILER-PIPELINE.md) |
| Understand the typed Core contract | [Core IR](CORE-IR.md), [Core optimization](CORE-OPTIMIZER.md), and [safe-expression inlining](CORE-INLINING.md) |
| Understand short-circuit CFG and initialized storage | [Control-flow safety](CONTROL-FLOW-SAFETY.md) |
| Use or extend `match`, `if` expressions, `guard` and nested blocks | [Match, if expressions, guard and nested blocks](BRANCHING.md) |
| Understand native liveness and dead-code elimination | [Native liveness](LIVENESS-AND-DEAD-CODE.md) |
| Understand native fixed-point scheduling and lattices | [Native dataflow](NATIVE-DATAFLOW.md) |
| Understand native compiler container choices | [Compiler ADT policy](COMPILER-ADTS.md) |
| Understand object ownership and lifetime | [AARC ABI](AARC-ABI.md) |
| Check what works now | [Implementation status](IMPLEMENTATION.md) |
| Build a development checkout | [Building](BUILDING.md) |
| Run the correct verification layers | [Testing](TESTING.md) |
| Read security scans and coverage results | [Code scanning and coverage](COVERAGE-AND-SECURITY.md) |
| Exercise malformed compiler inputs | [Fuzzing](FUZZING.md) |
| Place tests and fixtures | [Test ownership](TEST-OWNERSHIP.md) |
| Measure compiler throughput | [Benchmarking](BENCHMARKING.md) and [recorded baselines](../Benchmarks/README.md) |
| Use `talac` | [CLI](CLI.md) |
| Use or implement the REPL | [Tala Interactive](INTERACTIVE.md) |
| Write `BUILD.kts` | [Project files](PROJECT_FILES.md) |
| Understand per-source object and assembly outputs | [Project native artifacts](PROJECT-ARTIFACTS.md) |
| Understand diagnostics and exit behavior | [Diagnostics](DIAGNOSTICS.md) |
| Use Analyzer, Formatter, or Linter | [Ecosystem tools](ECOSYSTEM.md) |
| Work on LLVM lowering | [LLVM backend](LLVM-BACKEND.md) |
| Work on callable literals | [Closure pipeline](CLOSURE-PIPELINE.md) |
| Work on native callable invocation | [First-class callable ABI](CALLABLE-ABI.md) |
| Work on templates and specialization | [Template monomorphization](MONOMORPHIZATION.md) |
| Work on scalar types and literals | [Numeric types](NUMERIC-TYPES.md) |
| Trace scalars through native lowering | [Scalar pipeline](SCALAR-PIPELINE.md) |
| Maintain compiler wire contracts | [Artifact wire](ARTIFACT-WIRE.md) |
| Read or change language examples | [Specification guide](SPECIFICATION.md) |
| Prepare a change | [Contributor guide](Contributing/README.md) and [cross-component rules](CONTRIBUTING.md) |
| See intended sequencing | [Roadmap](ROADMAP.md) |

## Architecture set

- [Architecture](ARCHITECTURE.md) defines stage ownership and the major process boundaries.
- [Compiler pipeline](COMPILER-PIPELINE.md) follows discovery, parsing, semantic analysis, verified IRs, native lowering,
  emission, and linking in execution order.
- [Core IR](CORE-IR.md) defines the typed tree, symbol, verifier, closure, and wire contracts.
- [Core optimization](CORE-OPTIMIZER.md) documents fixed-point passes, effects, liveness, metrics, and reporting.
- [Core safe-expression inlining](CORE-INLINING.md) defines candidate proofs, substitution safety, budgets, and typed reports.
- [AARC ABI](AARC-ABI.md) defines value/reference classification, object headers, ownership operations, and closure teardown.
- [Implementation status](IMPLEMENTATION.md) distinguishes connected, partial, registered, planned, and legacy surfaces.
- [LLVM backend](LLVM-BACKEND.md) defines the Xmm-to-LLVM contract, supported values, verification, and artifact ownership.
- [Closure pipeline](CLOSURE-PIPELINE.md) explains capture analysis, owned environments, and LLVM closure lowering.
- [First-class callable ABI](CALLABLE-ABI.md) defines direct versus closure calls, invoke thunks, and capture-call ownership.
- [Template monomorphization](MONOMORPHIZATION.md) defines concrete specialization identity, placement, demand discovery, and current limits.
- [Numeric types](NUMERIC-TYPES.md) records fixed scalar widths and the gap between frontend semantics and the current Core
  transport.
- [Scalar pipeline](SCALAR-PIPELINE.md) follows fixed-width values through verification, Core wire v10, Xpp, Xmm, and LLVM.
- [Artifact wire](ARTIFACT-WIRE.md) defines the bounded internal Core and CorePrep transport contracts.
- [Console output and strings](CONSOLE-IO.md) covers `System.Console`, the output format grammar, the runtime calls
  it compiles to and the runtime library a native executable is linked with.
- [Evaluation by need](EVALUATION.md) says how much of the lazy evaluation of the language the compiler implements,
  how a value is deferred, and what is pending.
- [Match, if expressions, guard and nested blocks](BRANCHING.md) describes the implemented subset of those forms, their
  evaluation order and their limits.
- [Control-flow safety](CONTROL-FLOW-SAFETY.md) defines short-circuit lowering and the shared Xpp/Xmm
  definite-initialization contract.
- [Native liveness](LIVENESS-AND-DEAD-CODE.md) defines backward dataflow, conservative Xpp/Xmm removal policies,
  and memoized trampoline cleanup.
- [Native dataflow](NATIVE-DATAFLOW.md) defines the directional worklist, dense initialization and packed ownership
  lattices, validation-only results, and structural complexity guards.
- [Compiler ADT policy](COMPILER-ADTS.md) defines LLVM ADT adoption, full-range identity adapters, and ownership boundaries.

## User and project set

- [CLI](CLI.md) is the command and option reference. It also explains precedence and intentionally disconnected commands.
- [Tala Interactive](INTERACTIVE.md) defines the REPL command, cell lifecycle, ORC boundary, result support, and known limits.
- [Project files](PROJECT_FILES.md) documents discovery, source policy, entry selection, compiler settings, plugins,
  dependencies, publishing metadata, test suites, and the SQLite lockfile.
- [Project native artifacts](PROJECT-ARTIFACTS.md) documents source ownership, per-file native emission, flattened output
  names, and safe batch replacement.
- [Diagnostics](DIAGNOSTICS.md) describes error ownership, output streams, source positions, artifact safety, and exit status.
- [Ecosystem tools](ECOSYSTEM.md) separates the compiler from tala-analyzer, talafmt, and talalint.

## Developer set

- [Building](BUILDING.md) contains prerequisites, environment discovery, component builds, and troubleshooting.
- [Testing](TESTING.md) maps changes to local gates and GitHub workflows.
- [Fuzzing](FUZZING.md) records the connected wire mutation campaign, its reproducible seed, and remaining input surfaces.
- [Test ownership](TEST-OWNERSHIP.md) assigns suites, fixtures, and Bazel targets to their compiler components.
- [Benchmarking](BENCHMARKING.md) defines measurement ownership, fixture timing, interpretation, and CI policy.
- [Compiler ADT policy](COMPILER-ADTS.md) explains when native code uses LLVM containers and when project adapters are required.
- [Repository layout](MONOREPO.md) explains ownership boundaries and allowed dependency direction.
- [Contributor guide](Contributing/README.md) walks external contributors through onboarding, component ownership,
  validation, style/licensing, and pull-request preparation. [Cross-component rules](CONTRIBUTING.md) record the shared
  code and documentation contract.

## Specification relationship

The public `Spec/` tree is the authoritative language-design catalog. Its files contain independent valid and invalid
examples; they are not one buildable application. The compiler tests are authoritative for current implementation coverage.
When those sources differ, do not rewrite a design example merely to make an incomplete compiler accept it. Instead, state
the implementation gap here and add a focused compiler test when the feature is implemented.

## Documentation maintenance

Documentation changes follow the same ownership rules as code changes:

1. Verify claims against source, tests, and build targets rather than historical names.
2. State whether a route is connected, implemented, registered, planned, or legacy.
3. Use repository-relative links and the canonical `Documents/` directory spelling.
4. Keep machine-specific paths, credentials, hostnames used only for local development, and internal planning notes out of
   public files.
5. Use en-US English and correct spelling, including names that originated as typos.
6. Do not describe CorePrep as a public artifact: it is an internal adapter and transport only.
7. Do not revive retired public intermediate-representation names or the removed C lexer/parser route.
8. Run a stale-link scan and `git diff --check` after moving or adding documents.

The documentation should be useful without knowledge of repository history. Historical decisions belong in the changelog;
the documents in this directory describe the current model and explicitly marked future work.
