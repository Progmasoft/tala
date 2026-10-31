<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

# Your first contribution

## 1. Choose a bounded issue

Read the root [README](../../README.md), [implementation status](../IMPLEMENTATION.md), and the relevant page in
[`Spec/`](../../Spec/README.md). Look for a change with a clear before/after result and one owning component. If an issue
is broad, propose a narrow first slice and the test that would prove it. Ask whether a design example is implemented before
turning it into a compiler regression test.

Good first slices include a reproducible CLI diagnostic, a focused verifier rejection, a missing malformed-input test, a
stale public link, or a small component-owned refactor with unchanged behavior. A new operator, wire format, ownership rule,
or ABI is not a one-file first issue: it needs a design discussion and multiple producer/consumer checks.

## 2. Fork and get a clean checkout

For an external contributor, fork `Progmasoft/tala` on GitHub and clone your fork. Replace `<your-account>` below
with your own GitHub account:

```text
git clone --recurse-submodules https://github.com/<your-account>/tala.git
cd tala
git remote add upstream https://github.com/Progmasoft/tala.git
git fetch upstream
git switch -c fix/short-description upstream/main
git submodule status --recursive
git status --short
```

If you cloned without `--recurse-submodules`, run `git submodule update --init --recursive`. A clean `git status --short`
before editing makes it possible to distinguish your work from generated files. Do not run a broad clean or reset to make
someone else's changes disappear. Create a new branch for each independent pull request.

The pinned `third_party/catch3`, indicators, and tabulate checkouts are dependencies, not places for Tala changes.
Contribute to their own repositories when their implementation needs to change. Never edit a submodule and assume the
parent commit will include those edits automatically.

## 3. Prepare the host

Official development hosts are Windows 10/11, macOS 26 Tahoe on Apple silicon and Ubuntu 26.04 LTS. First inspect the toolchain without installing
anything:

```text
go run ./helpers/cmd/prebuild check
go run ./helpers/cmd/develop doctor
```

The [building guide](../BUILDING.md) explains Bazelisk, standalone Clang/LLD, LLVM development files, GHC/Cabal,
and platform SDK requirements. `go run ./helpers/cmd/prebuild install` can install missing tools on a supported host, but it
changes your machine; review its output and choose when to run it. Reopen the terminal after installation. Set `LLVM_ROOT`
locally or put `llvm-config` on `PATH`; do not add your machine's absolute path to tracked build files.

You do not need the entire toolchain for a documentation-only change. For a code change, run the smallest relevant
preflight before implementation so you can tell a missing tool from a regression you introduced.

## 4. Make one coherent change

Use the [component map](COMPONENTS.md) to choose ownership. Read the entire affected model, verifier, lowering, tests, and
Bazel/Cabal target—not just the first search result. Follow the current file's style, add comments for non-obvious
invariants, and keep a change scoped enough that reviewers can understand its contract. Do not reformat vendored sources
or generated outputs as part of a source PR.

For a bug, create a test that fails for the old behavior and passes after the fix. For a new feature, cover both a valid
case and a rejected or boundary case. If the feature crosses Haskell Core into C++20, one side's round-trip test is not
enough; see [test ownership](../TEST-OWNERSHIP.md) and [validation](VALIDATION.md).

## 5. Validate and submit

Run the focused test during development, then the applicable integrated gates in [validation](VALIDATION.md). Before
opening a pull request:

```text
git diff --check
git status --short
git diff --stat
```

Review the changed-file list for caches, generated artifacts, private notes, and unrelated edits. Commit with a clear
English message and push your feature branch to your fork. Open a pull request against `Progmasoft/tala:main`.
The [PR guide](PULL-REQUESTS.md) explains the evidence reviewers need and how to handle CI or a missing local tool.

The repository's `helpers/cmd/githelper/main.go update` command is a maintainer convenience: it stages, commits, and pushes the
*current branch* to `origin`. External contributors may use ordinary Git commands instead; never run the helper without
checking which repository and branch `origin` names.
