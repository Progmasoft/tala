<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

# Prepare a pull request

External contributors normally push a topic branch to their own fork and open a PR against
`Progmasoft/tala:main`. The repository's protected `main` branch is not a request to force-push or to bypass
review; it prevents branch deletion and non-fast-forward pushes. A PR is the practical way for a contributor without
direct write access to submit a change.

## Make the change reviewable

Keep one public outcome and its required producer/consumer tests together. A broad compiler change may touch several
components; splitting it into unrelated one-file PRs can hide a broken pipeline. Conversely, a formatting sweep or
repository-wide rename should not be mixed with an unrelated bug fix. If the design is still unsettled, open a draft PR
or issue that states the unanswered contract before building a large implementation on it.

Your PR description should let a reviewer answer these questions without reconstructing your local session:

1. What user-visible behavior or invariant changed, and why?
2. Which public `Spec/` or documented contract applies? Is the feature connected today or only designed?
3. Which component owns the change, and what is the next boundary consuming it?
4. What positive, negative, malformed-input, or cross-language tests were added?
5. Which exact local commands passed, failed, or could not run, and on which host?
6. What compatibility, wire-version, CLI, ABI, performance, or license impact should reviewers consider?

A useful PR body can be short if it is precise:

```text
Problem: <observable failure or unmet use case>
Contract: <public Spec/documentation link and implementation status>
Change: <owning components and behavior>
Tests: <exact commands and results; note anything not run>
Compatibility: <none, or details of API/artifact/ABI changes>
```

Do not claim that a new syntax feature is complete solely because a `Spec/` example exists. Do not call a target
"passing" when Bazel only built it; execute the test through the repository command or the binary.

## Before requesting review

- [ ] The branch is based on a reasonably current `main`, and the diff contains only intended files.
- [ ] Public behavior is documented in en-US English without citing private planning material.
- [ ] The owning component has focused tests; the next boundary is tested when representations cross.
- [ ] Formatting and relevant local gates pass, or missing tools/failures are stated plainly.
- [ ] No generated output, secrets, private fixtures, or unrelated submodule changes are staged.
- [ ] New or copied files have appropriate copyright/SPDX information and third-party provenance.
- [ ] `git diff --check` is clean; links and command spellings were checked.

The workflow matrix is in [Validation](VALIDATION.md). GitHub runs separate Compiler Tier 1/2/3, Language Layers,
Haskell Coverage, Component Coverage, CodeQL, Benchmarks, and Coverage-Guided Fuzzing jobs. Inspect every job triggered by your
commit; a green single job does not mean the entire change is verified. If CI differs from local results, report the first
failing command and environment, not only a screenshot of a red badge.

## Review and follow-up

Expect questions about ownership, missing negative tests, dependency direction, and claims ahead of implementation.
Respond with evidence from source, tests, and public `Spec/`; update the same PR branch with a normal push. Do not rewrite
published history or force-push unless maintainers explicitly coordinate that workflow. Review feedback is about the
contract and maintainability, not about the contributor.

Do not create release tags, upload packages, modify deployment systems, or change branch protection as part of an
ordinary contribution. Those are separate maintainer operations with their own verification and authority. If your
change spans another Progmasoft repository, link a separate issue or PR for that repository rather than staging a
nested checkout in this one.
