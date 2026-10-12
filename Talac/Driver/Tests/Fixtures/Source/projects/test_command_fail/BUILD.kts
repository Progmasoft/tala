// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

project { name = "FailingTestCommand"; version = "0.2.1"; stability = Stability.BETA }
sources {
  main { srcDir = "Sources"; entry = "FailingTestCommand.Main"; exclude("Test/**") }
  test("unit") { testDir = "Sources/Test"; framework = "tests" }
}
