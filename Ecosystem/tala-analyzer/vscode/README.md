<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# VS Code host for tala-analyzer

This extension associates `.tala` with Tala and starts the same `tala-analyzer` executable used by other editors.
It contributes no second lexer or analyzer. Install or build the executable first, then put it on `PATH` or set
`tala.analyzer.path` to its location. The path can be a command name; no machine-specific default is committed.

Run `npm ci && npm run check` in this directory. This is an initial host integration, not a published extension package.
Public TypeScript entry points use TSDoc comments. The host keeps TypeScript 7; TypeDoc is intentionally not wired into
this build, and adding it must not require downgrading the TypeScript toolchain.

## Local development

Use Node.js 24 and the checked-in npm lock file to install the extension's pinned dependencies, then run its type check:

```powershell
npm ci
npm run check
```

Open this directory in VS Code and launch the extension host with **Run Extension** to try the integration. In the
extension host, configure `tala.analyzer.path` when `tala-analyzer` is not discoverable through `PATH`. The
setting accepts an executable path or a command name. The extension reports a startup error in VS Code when the setting
is blank or the process cannot start; it does not silently start an alternate analyzer.

The document selector is limited to file-backed documents with the `tala` language id. The extension starts
and stops the LSP client with the VS Code extension lifecycle, leaving JSON-RPC framing and compiler behavior to the
server. This first host slice does not provide completion, hover, formatting, or an analyzer download/update mechanism.

The Marketplace publisher id is `progmasoft`, but the extension is not published. Generated `out/` files, packages, and
dependencies are local build artifacts and stay out of source control.
