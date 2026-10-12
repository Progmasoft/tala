/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.cli

import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class CommandLineTest {
  private fun parsed(vararg arguments: String): Command {
    val result = parseCommandLine(arguments.toList())
    return assertIs<ParseResult.Parsed>(result, "rejected: $result").command
  }

  private fun rejected(vararg arguments: String): String =
    assertIs<ParseResult.Rejected>(parseCommandLine(arguments.toList())).message

  private val everything = TargetSelection()

  @Test
  fun noArgumentsAskForTheGeneralHelp() {
    assertEquals(Command.Help(null), parsed())
    assertEquals(Command.Help(null), parsed("help"))
  }

  @Test
  fun commandsOfOneWordParseToTheirValue() {
    assertEquals(Command.Check(everything), parsed("check"))
    assertEquals(Command.Build(everything), parsed("build"))
    assertEquals(Command.Run(everything, emptyList()), parsed("run"))
    assertEquals(Command.Test(everything), parsed("test"))
    assertEquals(Command.Update, parsed("update"))
    assertEquals(Command.Version, parsed("version"))
    assertEquals(Command.Fmt(emptyList()), parsed("fmt"))
    assertEquals(Command.Lint(false, everything, emptyList()), parsed("lint"))
  }

  @Test
  fun commandsOfTwoWordsParseToTheirValue() {
    assertEquals(Command.LockResolve, parsed("lock", "resolve"))
    assertEquals(Command.LockCreateDump, parsed("lock", "create-dump"))
    assertEquals(Command.ViPkgCreate, parsed("vipkg", "create"))
    assertEquals(Command.ViGetPush, parsed("viget", "push"))
    assertEquals(Command.ViGetUpdate, parsed("viget", "update"))
    assertContains(rejected("lock"), "tazel lock resolve or tazel lock create-dump")
    assertContains(rejected("lock", "dump"), "'dump' is not an action of tazel lock")
    assertContains(rejected("viget", "create"), "tazel viget push or tazel viget update")
    assertContains(rejected("vipkg"), "tazel vipkg create")
    assertContains(rejected("lock", "resolve", "now"), "'now' is not an argument")
  }

  @Test
  fun everyCommandNameSelectsItsCommand() {
    val expected =
      mapOf(
        CommandName.CHECK to parsed("check"),
        CommandName.BUILD to parsed("build"),
        CommandName.RUN to parsed("run"),
        CommandName.TEST to parsed("test"),
        CommandName.LOCK_RESOLVE to parsed("lock", "resolve"),
        CommandName.LOCK_CREATE_DUMP to parsed("lock", "create-dump"),
        CommandName.UPDATE to parsed("update"),
        CommandName.INSTALL to parsed("install", "Publisher.Name"),
        CommandName.VIPKG_CREATE to parsed("vipkg", "create"),
        CommandName.VIGET_PUSH to parsed("viget", "push"),
        CommandName.VIGET_UPDATE to parsed("viget", "update"),
        CommandName.VERSION to parsed("version"),
        CommandName.HELP to parsed("help"),
        CommandName.FMT to parsed("fmt"),
        CommandName.LINT to parsed("lint"),
      )
    assertEquals(CommandName.entries.toSet(), expected.keys)
    expected.forEach { (name, command) -> assertEquals(name, command.name) }
  }

  @Test
  fun targetsAreSelectedInBothFormsAndMayRepeat() {
    assertEquals(
      Command.Build(TargetSelection(viPkgs = listOf("Name", "Other2"))),
      parsed("build", "--vipkg", "Name", "-p", "Other2"),
    )
    assertEquals(
      Command.Run(TargetSelection(executables = listOf("Name", "Other2")), emptyList()),
      parsed("run", "--executable", "Name", "-e", "Other2"),
    )
    assertEquals(
      Command.Build(TargetSelection(libraries = listOf("Name", "Other2"))),
      parsed("build", "-l", "Name", "--library", "Other2"),
    )
    assertEquals(
      Command.Test(TargetSelection(listOf("Server"), listOf("Tool"), listOf("Core"))),
      parsed("test", "-p", "Server", "-e", "Tool", "-l", "Core"),
    )
    assertEquals(
      Command.Check(TargetSelection(executables = listOf("Tool"))),
      parsed("check", "-e", "Tool"),
    )
  }

  @Test
  fun aSelectionFlagNeedsANameItHasNotSeen() {
    assertContains(rejected("build", "--vipkg"), "--vipkg requires a value")
    assertContains(rejected("build", "-p", "-e"), "'-e' is an option")
    assertContains(rejected("build", "-p", "Name", "-p", "Name"), "-p Name is written twice")
    assertContains(rejected("build", "-e", "My.Tool"), "'My.Tool' is not one")
    assertContains(rejected("build", "-e", "9lives"), "'9lives' is not one")
    assertContains(rejected("build", "--vipkg=Name"), "'--vipkg=Name' is not an argument")
    assertContains(rejected("build", "--release"), "'--release' is not an argument of tazel build")
    assertContains(rejected("check", "Sources"), "'Sources' is not an argument of tazel check")
    // The same name may be a package and an executable; the lists are separate.
    assertTrue(parsed("build", "-p", "Name", "-e", "Name") is Command.Build)
  }

  @Test
  fun programArgumentsFollowADoubleDashUnread() {
    assertEquals(
      Command.Run(everything, listOf("--verbose", "-p", "8080", "--")),
      parsed("run", "--", "--verbose", "-p", "8080", "--"),
    )
    assertEquals(
      Command.Run(TargetSelection(executables = listOf("Server")), listOf("start")),
      parsed("run", "-e", "Server", "--", "start"),
    )
    assertEquals(Command.Run(everything, emptyList()), parsed("run", "--"))
    assertContains(rejected("run", "start"), "program arguments follow '--'")
    // Only run hands arguments to a program.
    assertContains(rejected("build", "--", "start"), "'--' is not an argument of tazel build")
  }

  @Test
  fun installTakesOnePackageAndMayBeGlobal() {
    val coordinate = PackageCoordinate("Publisher", "Name")
    assertEquals(Command.Install(coordinate, false), parsed("install", "Publisher.Name"))
    assertEquals(Command.Install(coordinate, true), parsed("install", "--global", "Publisher.Name"))
    assertEquals(Command.Install(coordinate, true), parsed("install", "Publisher.Name", "-g"))
    assertEquals("Publisher.Name", coordinate.toString())
    assertContains(rejected("install"), "tazel install Publisher.Name")
    assertContains(rejected("install", "-g"), "tazel install Publisher.Name")
    assertContains(rejected("install", "Name"), "'Name' is not")
    assertContains(rejected("install", "A.B.C"), "'A.B.C' is not")
    assertContains(rejected("install", "A..B"), "'A..B' is not")
    assertContains(rejected("install", "A.B", "C.D"), "'C.D' is a second")
    assertContains(rejected("install", "-g", "--global", "A.B"), "--global is written twice")
    assertContains(rejected("install", "--force", "A.B"), "'--force' is not an option")
  }

  @Test
  fun helpNamesACommandByItsWords() {
    assertEquals(Command.Help(CommandName.BUILD), parsed("help", "build"))
    assertEquals(Command.Help(CommandName.LOCK_CREATE_DUMP), parsed("help", "lock", "create-dump"))
    assertEquals(Command.Help(CommandName.VIGET_PUSH), parsed("help", "viget", "push"))
    assertEquals(Command.Help(CommandName.HELP), parsed("help", "help"))
    assertContains(rejected("help", "lock"), "'lock' is not a command")
    assertContains(rejected("help", "compile"), "'compile' is not a command")
  }

  @Test
  fun formatterOptionsFollowADoubleDashUnread() {
    assertEquals(Command.Fmt(listOf("--check")), parsed("fmt", "--", "--check"))
    assertEquals(Command.Fmt(listOf("--emit=json")), parsed("fmt", "--", "--emit=json"))
    assertEquals(Command.Fmt(emptyList()), parsed("fmt", "--"))
    assertContains(rejected("fmt", "--check"), "options of talafmt follow '--'")
  }

  @Test
  fun lintTakesAWorkspaceOrASelectionAndHandsOnItsOptions() {
    assertEquals(Command.Lint(true, everything, emptyList()), parsed("lint", "--workspace"))
    assertEquals(Command.Lint(false, everything, listOf("--fix")), parsed("lint", "--", "--fix"))
    assertEquals(
      Command.Lint(true, everything, listOf("--fix")),
      parsed("lint", "--workspace", "--", "--fix"),
    )
    assertEquals(
      Command.Lint(false, TargetSelection(viPkgs = listOf("Server")), listOf("--fix")),
      parsed("lint", "-p", "Server", "--", "--fix"),
    )
    assertContains(rejected("lint", "--fix"), "options of talalint follow '--'")
    assertContains(rejected("lint", "--workspace", "--workspace"), "--workspace is written twice")
    assertContains(rejected("lint", "--workspace", "-p", "Server"), "cannot be combined")
  }

  @Test
  fun whatIsNotACommandIsRejectedByName() {
    assertContains(rejected("compile"), "'compile' is not a command of tazel")
    assertContains(rejected("--help"), "'--help' is not a command of tazel")
    assertContains(rejected("Build"), "'Build' is not a command of tazel")
    assertContains(rejected("version", "--short"), "'--short' is not an argument of tazel version")
    assertContains(rejected("update", "all"), "'all' is not an argument of tazel update")
  }
}
