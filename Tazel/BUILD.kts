/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

// The whole project DSL in one file. A real project writes only what differs from the defaults.

project {
  // With `sources.viget.push = true` every field below is required; otherwise each is optional.
  name = "Example"
  version = "0.1.0"
  stability = Stability.STABLE // STABLE, UNSTABLE, BETA, NIGHTLY, ALPHA or DEV
  description = "A Tala project"
  authors("Leitwolf", "Helmut")
  defaultFeatures("TOML")
}

compiler {
  standard = talaStandardOf(26) // default: talaStandardOf(26)
  backend = Backend.LLVM // default: Backend.LLVM
  buildMode = BuildMode.RELEASE // default: BuildMode.DEBUG

  werror = true // default: false
  warnings = Warnings.MEDIUM // default: MEDIUM; ALL, MEDIUM, LOW or NONE
  wshadow = true // default: false; no warning level turns it on
  xppOptimizationPasses = false // default: true
  xmmOptimizationPasses = false // default: true
  optLevel = OptLevel.O3 // default: O0 for DEBUG and O3 for RELEASE; O0, O1, O2, O3 or OG

  llvm {
    compiler = LlvmCompiler.AOT // default: AOT; AOT or ORC
    lto = LlvmLto.THIN // default: NONE; FAT, THIN or NONE
    args("-time-passes", "-print-after-all") // default: none; handed to LLVM as written
  }
}

outdirs {
  release = "build/release" // default: "build/release"
  debug = "build/debug" // default: "build/debug"
}

targets {
  // default: the LLVM target of the host
  target(
    "x86_64-unknown-linux-gnu",
    "aarch64-apple-darwin",
    "x86_64-pc-windows-msvc",
    "aarch64-pc-windows-msvc",
  )
}

pml {
  enabled = true // default: true; without it the Progmasoft Library cannot be reached
}

dependencies {
  localDependency { path = "Dependency.vipkg" }

  dependency("Publisher") {
    name = "Name"
    version = "0.1.0"
    stability = Stability.STABLE
  }

  dependency("Publisher") {
    name = "Toml"
    version = "1.0.0"
    stability = Stability.STABLE
    feature = "TOML" // only brought in when the feature TOML of this project is on
    defaultFeatures = false // default: true
    feature("Serde") { enabled = true } // a feature of the dependency; default: false
  }

  localTestDependency { path = "TestDependency.vipkg" }

  testDependency("Publisher") {
    name = "TestDep"
    version = "0.1.0"
    stability = Stability.STABLE
  }
}

workspace {
  members("./Server", "../Shared", "Client") // each directory has a project file of its own
  defaultMembers("./Server", "../Shared")
  exclude("OldProject")
}

sources {
  viget {
    push = true // default: false
    exclude("build/**/*") // default: none; test sources never enter a .vipkg
  }

  executable {
    name = "Example" // default: the name of the project
    srcDir = "Sources" // default: "Sources"
    exclude("Sources/Generated") // default: none; relative to the project file
    entry = "Example.Program" // the class whose `public static void Main()` starts the program
  }

  library {
    name = "ExampleLibrary" // default: the name of the project
    viPkgType(ViPkgType.TALALIB, ViPkgType.STATICLIB) // default: TALALIB; also CDYLIB
    srcDir = "Sources" // default: "Sources"
    exclude("Sources/Program.tala")
    namespace = "Example.Library" // default: none; a library has no entry point
  }

  test("Unit") {
    testDir = "Tests/Unit" // default: "Tests/<name of the suite>"
    exclude("Tests/Unit/Fixtures/**") // default: none
  }

  test("Integration") { testDir = "Tests/Integration" }
}

println("Tala compiler version: ${compiler.version}")
println("Tala standard: ${compiler.standard}")
println("Project: ${project.name}, ${project.version}, ${project.stability}")
