<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Contributor guide

Welcome. Tala is an experimental language and compiler, not a finished SDK. Contributions are valuable when they
improve a well-defined contract and make the result easier to verify. A public specification example may describe intended
behavior that the current compiler cannot yet execute; treat the implementation status and tests as a separate question.

This guide is for contributors who do not already know the repository's internal history. You do not need permission to
open an issue or a pull request. For a large language or ABI change, discuss the intended public behavior before writing
several dependent passes. Never post credentials, private project files, or exploit details in a public issue; use
support@progmasoft.com for private security reports.

## Choose a path

| If you want to... | Start with... |
| --- | --- |
| Make a first contribution | [First contribution](FIRST-CONTRIBUTION.md) |
| Find the owning component and its tests | [Component map](COMPONENTS.md) |
| Build and validate a change | [Validation guide](VALIDATION.md) |
| Diagnose a first-checkout failure | [Troubleshooting](TROUBLESHOOTING.md) |
| Match source style and preserve licenses | [Style and licensing](STYLE-AND-LICENSING.md) |
| Prepare a reviewable pull request | [Pull requests](PULL-REQUESTS.md) |

The short [cross-component contribution contract](../CONTRIBUTING.md) remains applicable. The canonical language-design
examples are in [`Spec/`](../../Spec/README.md); [implementation status](../IMPLEMENTATION.md) describes what is connected
today. For more detail, use [building](../BUILDING.md), [testing](../TESTING.md), [test ownership](../TEST-OWNERSHIP.md), and
the [repository layout](../MONOREPO.md). If a command or directory here becomes stale, prefer the actual build target and
fix this guide in the same change.

## Repository boundaries

`Progmasoft/tala` contains the compiler, the language specification and Interactive.
The Tala language website, Progmasoft accounts/ViGet, Xide, and Catch3 each have their own repository and issue tracker.
A nested checkout may sit physically below this directory without belonging to its Git index. Check `git remote -v` and
`git status --short` before editing or committing across a repository boundary.

## What a complete contribution looks like

1. State the observable problem and the owning contract.
2. Change the narrowest layer that owns it; avoid a parallel implementation in another language.
3. Add a focused positive or negative test and, when data crosses a boundary, a consumer-side test.
4. Update affected public documentation and examples without claiming unfinished behavior works.
5. Run the relevant local gates, explain any gate you could not run, and submit a reviewable diff.

The project does not require every contributor to own every subsystem. A good first PR can fix a broken link, improve a
diagnostic test, or clarify a documented limitation—provided its claim is checked against source and tests.
