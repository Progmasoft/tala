<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# tala-analyzer

tala-analyzer is the compiler-backed language analysis layer used by Tala editor integrations. The
`tala-analyzer` executable is a standard LSP server over stdin/stdout. Editors launch the process and speak
Content-Length-framed JSON-RPC 2.0; there is no proprietary Protobuf transport.

The first implemented boundary reuses the compiler's lexer, parser, resolver, type checker, and CorePrep pipeline. Compiler
diagnostics are translated to zero-based UTF-16 protocol positions without maintaining a second language implementation.
The Hackage `lsp` package owns framing, lifecycle, incremental document synchronization, and dispatch. The server currently
publishes compiler diagnostics on document open/change, clears them on close, and exposes hierarchical document symbols
from the shared parsed AST. It does not claim hover, completion, or workspace-wide indexing yet.

Run the executable from the compiler Cabal project with `cabal run tala-analyzer`. It is intended to be launched by an
LSP client, not used as a human-facing CLI. Ordinary logs are sent to stderr so stdout contains protocol frames only.

The Kotlin module under `sources/main/kotlin` owns the typed `tala-analyzer.kts` configuration surface, canonical
defaults, validation, and immutable snapshots. Script discovery and evaluation are intentionally outside this module.

## Configuration model

The Kotlin configuration module and the Haskell language server are separate components. The module defines the public
configuration data model and validates values; this does not mean that the LSP process evaluates `tala-analyzer.kts`.
Script discovery, execution, and forwarding settings into the running analyzer remain a distinct integration step.

The current model supports three frontend boundaries and groups settings by their owner:

```kotlin
analyzerConfiguration {
  version = "latest"
  analysisMode = AnalysisMode.FULL

  diagnostics {
    compiler = true
    linter = true
    onChange = true
    onSave = true
  }

  inlayHints = true
  formatting = true

  workspace {
    indexDependencies = true
  }

  performance {
    workerThreads = 0
  }
}
```

`AnalysisMode.SYNTAX` stops after parsing, `SEMANTIC` includes name and type checks, and `FULL` follows the currently
connected frontend through CorePrep. A setting can be present before an editor host supports its corresponding LSP
capability; a typed model alone is not evidence that the behavior is active.

Each call to `analyzerConfiguration` creates a new mutable builder. `build()` validates the release selector and worker
count, then copies nested scopes into immutable data classes. An invalid release must be either `latest` or a semantic
version; a negative worker count is rejected. The zero worker value delegates sizing to the eventual runtime. Values in
the returned configuration do not change when a caller later edits a DSL scope.

## Build and verification

The repository wrapper and JDK 25 are the supported build environment for the Kotlin configuration module:

```powershell
.\Tazel\gradlew.bat -p Analyzer test
.\Tazel\gradlew.bat -p Analyzer spotlessCheck
.\Tazel\gradlew.bat -p Analyzer dokkaGenerateHtml
```

The first command exercises default values, validation failures, nested-scope behavior, and snapshot immutability. The
formatter check covers Kotlin and Gradle Kotlin scripts. Dokka renders the KDoc contract from the source; generated HTML
under Gradle's `build/` directory is local output and is not committed.

The LSP executable has its own Cabal test suite. It launches the built binary as a subprocess and checks JSON-RPC
initialization, document open/change/close, diagnostics, and document symbols. For a focused local run, start from
`Talac/`:

```powershell
cabal test tala-analyzer-tests
```

No test requires a Marketplace account or an editor installation. Host-specific smoke testing is performed by the
IntelliJ and VS Code modules described in their adjacent READMEs.
