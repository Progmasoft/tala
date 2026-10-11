---
name: Compiler or tooling bug
about: Report a reproducible Visual X# compiler, runtime, CLI, or tool failure
title: "[Bug] "
---

<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

This repository owns the Visual X# language, compiler, project DSL, runtime, formatter, linter, and analyzer. Website, Progmasoft account/ViGet, and Xide issues belong in their own repositories. The public language contract is in `Spec/`; please distinguish a specification mismatch from an unimplemented feature. Do not post secrets or private source. Send security vulnerabilities privately to support@progmasoft.com.

If you plan to submit a fix, see the [contributor guide](https://github.com/Progmasoft/visual-xsharp/blob/main/CONTRIBUTING.md).

### Component and stage

- [ ] Haskell lexer, parser, resolver, type checker, Core, or CorePrep
- [ ] C++20 Xpp, Xmm, LLVM backend, linker, or AARC runtime
- [ ] `vxs`/`vxsi` CLI or Kotlin project DSL
- [ ] Visual Formatter, Linter, or Analyzer
- [ ] Specification, examples, or documentation

### Observed and expected behavior

What happened? What should happen according to the relevant `Spec/` page or documented CLI contract? Include the exact diagnostic or exit code; do not paraphrase compiler output.

### Minimal reproduction

Provide the smallest `.vxs` source or `BUILD.kts` fragment that reproduces the issue, the exact `vxs` command, and the resulting output. If an artifact is involved, name its format (`.core`, `.xpp`, `.xmm`, object, or `.vxse`) without attaching private binaries. State whether it reproduces without a project file.

### Environment

- Visual X# version or commit (`vxs version`):
- OS (Windows 10/11, macOS Sequoia/Tahoe, or other) and architecture:
- Relevant toolchain versions (Bazelisk, GHC, Clang/LLVM, JDK) if building from source:
- Clean checkout and recursive submodules? Yes/No:

### Additional context

Attach sanitized logs, a reduced test case, or a link to an existing failing CI run. Avoid screenshots when copyable diagnostics are available.
