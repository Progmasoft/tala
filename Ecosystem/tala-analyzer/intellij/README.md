<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# IntelliJ Platform host for tala-analyzer

This Kotlin plugin starts the shared `tala-analyzer` LSP process for `.tala` files. It uses the IntelliJ Platform LSP API;
it does not duplicate compiler analysis. Install or build `tala-analyzer` and put it on `PATH`, or set
`TALA_ANALYZER_PATH` before launching the IDE. No absolute toolchain paths are embedded in the plugin.

The initial target is IntelliJ IDEA 2026.2.3 with Java 25 and the 2026.1.4+ `LspIntegrationProvider` API. The LSP module
is not present in IntelliJ IDEA Community or Android Studio; those products are intentionally outside this first slice.
Run the repository's Gradle wrapper with `-p Ecosystem/tala-analyzer/intellij buildPlugin` to build the plugin.
KDoc comments are rendered by Dokka with the `dokkaGenerateHtml` Gradle task.

## Local development

Build and generate API documentation with the repository's pinned Gradle wrapper:

```powershell
.\Tazel\gradlew.bat -p Ecosystem/tala-analyzer/intellij compileKotlin processResources dokkaGenerateHtml
```

`runIde` starts a disposable IntelliJ instance for manual smoke testing. Set `TALA_ANALYZER_PATH` in the environment
of the Gradle process to point it at a locally built server when the executable is not available through `PATH`. The
plugin reads this variable when it creates the project-wide LSP client, so restarting the IDE after changing it is
required.

The platform extension point is registered in `META-INF/plugin.xml`. The integration provider starts the client for
`.tala` files, and the project-wide descriptor uses the same extension filter and process command. This keeps the host
from starting another process for unrelated documents. Diagnostics and symbols are supplied by the shared server.

The initial host does not add a second parser, custom compiler settings UI, or a bundled copy of the analyzer executable.
Development builds remain local Gradle outputs. The plugin has not been uploaded to JetBrains Marketplace.
