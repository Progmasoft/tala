---
name: Language or tooling proposal
about: Propose a Tala language, compiler, DSL, or tooling improvement
title: "[Proposal] "
---

<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

Check `Spec/` and existing issues before proposing syntax or semantics. An implementation gap for an already specified feature is usually a bug or implementation task, not a new language design. Public proposals must not cite private internal notes as the language contract.

For an implementation proposal, see the [contributor guide](https://github.com/Progmasoft/tala/blob/main/CONTRIBUTING.md).

### Problem

What real program or workflow is difficult today? Show a short Tala example using current syntax when possible.

### Proposed behavior

Describe the user-visible result. If this changes language syntax or semantics, identify the affected `Spec/` section and show valid and invalid examples. Do not assume C#, Kotlin, or C++ syntax automatically applies to Tala.

### Affected layers

Which parts need work: parser, type checker, Core/CorePrep, Xpp/Xmm, runtime, CLI, or documentation? Note any ABI, artifact, or compatibility impact you expect.

### Alternatives and acceptance checks

What workaround exists? What tests or examples would demonstrate completion without confusing specified behavior with compiler support?
