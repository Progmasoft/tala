<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Tala roadmap

This roadmap records intended sequencing rather than a compatibility promise.
An item remains unavailable until its implementation, runtime contract, and
tests are merged.

## Current compiler priority

The primary goal is to complete the production compiler pipeline:

```text
Source -> Lexer -> Parser -> Renamer -> Name Resolution -> Type Checker
       -> Desugarer -> Core -> Core Optimizations -> CorePrep
       -> Xpp -> Xpp Optimizations -> Xmm -> Xmm Optimizations -> LLVM
```

Intermediate representations remain internal unless an explicit emit format is
documented. CorePrep is an adapter between Core and Xpp and is not a user-facing
emit format.

Current work prioritizes semantic completeness, stage verification, native
executable generation, and removal of obsolete C implementation paths. New
runtime features must not displace completion of that pipeline.

## Sequencing

### 1. Frontend semantic completeness

- extend Parser/AST coverage using the public specification examples;
- keep Renamer identity and Core verifier identity consistent through `SymbolId`;
- complete cross-file and cross-namespace reference semantics;
- expand target-aware scalar and constant-expression behavior;
- complete object/value, generic/template, exception, ownership, generator, FFI, and assembly semantics; and
- preserve source positions and reusable semantic facts for tools built on the compiler.

### 2. Core and module boundary

- introduce the multi-module Core link unit required by cross-namespace projects;
- carry physical source ownership when an output kind is per source;
- version complete fixed-width integer and floating payloads without changing old bytes in place;
- preserve source `void` while keeping the historically named internal no-result marker private;
- keep CorePrep an internal adapter rather than a public artifact; and
- add compatibility fixtures for every supported public Core wire version.

### 3. Native middle end

- broaden CorePrep-to-Xpp lowering after the corresponding semantic contracts exist;
- add optimizations only with pre/post verifier coverage;
- complete Xpp/Xmm value, call, ownership, exception, and control-flow forms;
- design versioned `.xpp` and `.xmm` codecs before connecting CLI emission; and
- continue the subsystem-by-subsystem `Tala` namespace migration without incidental public API breakage.

### 4. Native backend and executable completeness

- complete fixed-width integer and floating LLVM lowering;
- define aggregate, object, value, optional, exception, and ownership layouts;
- define the AARC closure environment and indirect invocation ABI;
- connect project-wide object/assembly output with unambiguous names;
- validate target-specific calling conventions and link inputs; and
- keep Talac as the only public compiler command while the private Haskell frontend remains an adjacent companion process.

### 5. Legacy removal completed

The duplicate C and Rust compiler implementations are removed. The C lexer/parser route is not restored, and compiler work
continues only in the maintained Haskell and C++20 owners. Compatibility is expressed through explicit artifact and runtime
ABIs rather than dormant source trees.

## Milestone acceptance

A roadmap item becomes connected only when:

1. the public or internal contract is explicit;
2. the owning representation can express it without lossy placeholders;
3. malformed input is rejected by the owning verifier;
4. focused tests cover valid, invalid, boundary, and deterministic behavior;
5. the next stage preserves the contract;
6. CLI/project behavior and artifact safety are documented; and
7. every affected CI workflow passes.

Registering a CLI spelling or adding a DSL key alone does not satisfy these conditions.

## Concurrent cycle collection

Concurrent Bacon–Rajan cycle collection with trial deletion is planned only
after the compiler is complete. It is not implemented by the current runtime or
compiler. Bacon–Rajan supplies the concurrent candidate-processing framework;
trial deletion proves that a candidate component has no external strong owner
before reclamation. Neither half is an optional alias for the other.

The intended project/CLI setting is:

```text
--cycle-collector=true
```

The default is `false`. A program therefore continues to use normal AARC
behavior unless cycle collection is explicitly enabled.

When enabled, the collector must remain demand-driven:

- it does not run when no candidate cycle exists;
- it does not run after a candidate cycle has already been broken manually;
- ordinary acyclic AARC objects stay on retain/release paths;
- collection work is concurrent rather than a global stop-the-world scan;
- trial deletion is limited to buffered candidate components rather than the
  complete object graph;
- a trial is cancelled when concurrent mutation restores an external owner;
- weak and unowned reference semantics remain unchanged;
- a strong cycle remains programmer-managed when the option is disabled.

The future design must specify candidate detection, color/state transitions,
root buffering, trial-reference accounting, restoration after a failed trial,
synchronization, safe-point interaction, shutdown behavior, diagnostics, and
deterministic testing before implementation begins.

No compiler pass should currently assume that a cycle collector exists. Closure
conversion and ownership lowering must preserve enough AARC information for the
future runtime to identify candidates without changing source semantics.

Acceptance work for that milestone will include stress tests for concurrent
mutation, candidate cancellation after manual cycle breaking, nested closure
cycles, shutdown races, weak promotion during collection, and deterministic
memory-accounting assertions. Benchmarks must compare the disabled path against
plain AARC to ensure that the default configuration does not pay collector
coordination costs.

The option will be rejected on runtimes which do not advertise the matching ABI
capability. It will not silently downgrade to a different collector, and it will
not change the ownership meaning of source declarations. Diagnostic output must
make activation, candidate processing, and unsupported-target failures
observable without exposing unstable internal colors as a language contract.
