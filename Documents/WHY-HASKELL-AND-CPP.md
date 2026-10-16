<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Why Tala Uses Haskell and C++

Tala uses Haskell for its language frontend and C++20 for its native
compiler pipeline and LLVM backend. This is an intentional boundary, not a
temporary comparison between languages.

## Why Haskell for the frontend?

Lexing, parsing, name resolution, type checking, and the immutable syntax and
Core trees are a natural fit for Haskell. Algebraic data types make language
constructs explicit, pattern matching keeps transformations exhaustive, and
immutable trees make compiler passes easier to reason about: a pass produces a
new value instead of mutating shared syntax behind another pass's back.

This is particularly useful while the grammar and semantic rules are changing.
The frontend can express those rules directly and test each transformation at
the level of the language model.

## Why C++20 after Core?

The native pipeline consumes verified Core and performs the adapting CorePrep
step, Xpp and Xmm lowering, verification, LLVM IR construction, and native code
generation. LLVM's `llvm/IR` APIs, ORC JIT, target machinery, and support
libraries are C++ interfaces. C++ keeps those objects and their ownership in
the environment for which LLVM was designed, rather than adding another
language/runtime boundary around LLVM.

## Why a C11 ABI between them?

The Haskell frontend is built as a shared library and loaded into Talac; it is
not a second frontend executable. The boundary is a small, versioned C ABI
declared in `Talac/Headers/Progmasoft/Tala/Frontend.h`. C is used only for
that ABI contract. The implementation on each side remains Haskell or C++20.

The ABI exchanges bounded byte spans and a synchronous output callback. The
producer owns an output buffer and lends it only for the duration of that
callback; the C++ caller copies accepted bytes into an owned vector before the
callback returns. No Haskell heap object, C++ class, exception, or allocator
crosses the boundary. The receiver validates the ABI version, pointer/length
pairs, payload kind, and size limits before consuming a result.

This removes the extra frontend process and temporary Core hand-off file while
keeping the language frontend independently testable. When a user explicitly
requests a `.core` artifact, Talac writes that artifact as normal output; the
compiler does not create one merely to pass data between its own stages.

## Why not Rust?

Rust is not part of the planned production compiler implementation. Adding it
would introduce another compiler toolchain, language boundary, build graph,
and maintenance surface without improving the fit of either side of the
chosen architecture: Haskell already models the immutable language frontend
well, and LLVM's compiler/backend APIs are native C++.

This is a project-specific engineering choice, not a claim that Rust is a poor
systems language. The goal is to keep each component in the language and
runtime that best matches its data model and ecosystem, then make their seam
small enough to audit.

## How the project controls memory-safety risk

No single test technique proves a compiler memory-safe. Tala therefore
layers explicit boundaries and dynamic checks around native code:

- Haskell owns frontend values; only validated, length-bounded wire bytes leave
  that runtime.
- C++ copies callback data into owned storage and verifies Core, CorePrep, Xpp,
  and Xmm before each lowering boundary. LLVM modules are verified before
  emission or JIT registration.
- AddressSanitizer, UndefinedBehaviorSanitizer, and ThreadSanitizer exercise
  native tests where the host supports them. AddressSanitizer also runs with
  libFuzzer in scheduled campaigns.
- Coverage-guided targets exercise the lexer, parser, artifact decoders and
  semantic verifiers, and source-to-LLVM path. Their seed corpora are versioned
  with the repository; CI preserves and reuses discovered corpus entries.
- Resource limits cap input sizes, parser/wire depth, fuzz duration, per-target
  RSS, and JIT input size. A bounded arithmetic oracle compares generated
  expressions against an independent evaluator and compares optimized and
  unoptimized native pipelines.

These checks reduce the chance that malformed source or an invalid intermediate
representation reaches unsafe native operations. They do not replace careful
review, and they are not a formal proof that every execution is free of bugs.

## Will Rust be used later?

There is no planned Rust rewrite or production Rust compiler component. A future
proposal would need to identify a concrete safety or maintenance gap that the
current Haskell/C++ split and its verification strategy cannot address, and
show that a third toolchain is worth its integration cost. Until then, the
compiler remains Haskell at the frontend and C++20 from Core through LLVM.
