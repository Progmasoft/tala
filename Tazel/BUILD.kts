/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

project {
  name = "Example"
  version = "0.3.2"
  stability = Stability.BETA
  description = "A Tala project"
  authors("Leitwolf", "Helmut")
  defaultFeatures("TOML")
}

compiler {
  version = "0.5.1"
  standard = "26"
  backend = Backend.LLVM
  buildMode = BuildMode.RELEASE
  werror = true
  warnings = Warnings.ALL
  wexperimental = false
  wshadow = true
  wundef = true

  unsafe {
    xppOptimizationPasses = true
    xmmOptimizationPasses = true
    typeSafeFormat = true
  }

  llvm {
    optLevel = LlvmOptLevel.O3
    compiler = LlvmCompiler.AOT
    lto = LlvmLto.THIN
  }
}

outdirs {
  release = "build/release"
  debug = "build/debug"
}

targets {
  target(
    "x86_64-unknown-linux-gnu",
    "aarch64-apple-darwin",
    "x86_64-pc-windows-msvc",
    "aarch64-pc-windows-msvc",
  )
}

pml {
  enabled = true
}

dependencies {
  dependency("Publisher") {
    name = "Name"
    version = "0.1.0"
    stability = Stability.STABLE
  }
}

sources {
  viget {
    push = false
    exclude("build/**")
  }

  executable {
    name = "Example"
    srcDir = "Sources"
    entry = "Example.Main"
    exclude("Tests/**")
  }

  test("unit") {
    testDir = "Tests/Unit"
    framework = "tests"
  }
}
