/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.driver

import com.progmasoft.tazel.cli.TargetSelection
import com.progmasoft.tazel.dsl.ExecutableSourceTarget
import com.progmasoft.tazel.dsl.LibrarySourceTarget
import com.progmasoft.tazel.dsl.LoadedProject
import com.progmasoft.tazel.dsl.ProjectConfigurationException
import com.progmasoft.tazel.dsl.ProjectLoader
import com.progmasoft.tazel.dsl.ProjectLocation
import com.progmasoft.tazel.dsl.projectFileIn

/** The project a command was started in and the members of its workspace. */
data class LoadedWorkspace(
  val root: LoadedProject,
  val members: List<LoadedProject>,
) {
  /** Every ViPkg: the root when it has targets of its own, then the members. */
  val all: List<LoadedProject>
    get() = listOf(root).filter(LoadedProject::hasTargets) + members

  /**
   * The ViPkgs a command works on when no flag selects any: the default members of a workspace that
   * names some, the root otherwise.
   */
  val default: List<LoadedProject>
    get() {
      val names = root.plan.workspace?.defaultMembers.orEmpty()
      if (names.isEmpty()) return listOf(root).filter(LoadedProject::hasTargets).ifEmpty { members }
      return names.map { name -> members.first { it.location.root == memberRoot(root, name) } }
    }
}

val LoadedProject.hasTargets: Boolean
  get() = plan.executables.isNotEmpty() || plan.libraries.isNotEmpty()

/** The name a ViPkg is selected and reported by: the name of its project, or its directory. */
val LoadedProject.displayName: String
  get() = plan.identity?.name ?: location.root.fileName?.toString() ?: location.root.toString()

private fun memberRoot(
  root: LoadedProject,
  member: String,
) = root.location.root.resolve(member).normalize()

/** Loads the project at [location] and, when it is the root of a workspace, its members. */
fun loadWorkspace(
  loader: ProjectLoader,
  location: ProjectLocation,
): LoadedWorkspace {
  val root = loader.load(location)
  val workspace = root.plan.workspace ?: return LoadedWorkspace(root, emptyList())
  val members =
    workspace.members.filterNot(workspace.exclude::contains).map { member ->
      val directory = memberRoot(root, member)
      val memberLocation =
        projectFileIn(directory)
          ?: throw ProjectConfigurationException(
            "workspace member '$member' has no project file in $directory"
          )
      loader.load(memberLocation)
    }
  val missingDefaults = workspace.defaultMembers.filter(workspace.exclude::contains)
  if (missingDefaults.isNotEmpty()) {
    throw ProjectConfigurationException(
      "workspace default members are excluded: ${missingDefaults.joinToString()}"
    )
  }
  return LoadedWorkspace(root, members)
}

/** The targets of one ViPkg that a command works on. */
data class SelectedTargets(
  val project: LoadedProject,
  val executables: List<ExecutableSourceTarget>,
  val libraries: List<LibrarySourceTarget>,
)

/**
 * A selection named targets that do not exist. [names] are the unknown ones, [known] the targets of
 * the same kind that do, so the command line can suggest what was meant; [flag] is the long flag
 * that selects this kind.
 */
class UnknownTargetException(
  kind: String,
  val flag: String,
  val names: List<String>,
  val known: List<String>,
) : Exception("no $kind is named ${names.joinToString()}")

/**
 * Applies the selection flags of a command line to [projects].
 *
 * `--vipkg` keeps the named ViPkgs. `--executable` and `--library` keep the named targets, and once
 * either is written only named targets remain. Every name has to exist: a flag that selects nothing
 * is a mistake and not an empty build.
 */
fun select(
  projects: List<LoadedProject>,
  selection: TargetSelection,
): List<SelectedTargets> {
  val unknownViPkgs =
    selection.viPkgs.filterNot { name -> projects.any { it.plan.identity?.name == name } }
  if (unknownViPkgs.isNotEmpty()) {
    throw UnknownTargetException(
      "ViPkg",
      "--vipkg",
      unknownViPkgs,
      projects.mapNotNull { it.plan.identity?.name },
    )
  }
  val kept =
    if (selection.viPkgs.isEmpty()) projects
    else projects.filter { it.plan.identity?.name in selection.viPkgs }
  val named = selection.executables.isNotEmpty() || selection.libraries.isNotEmpty()
  val selected = kept.map { project ->
    SelectedTargets(
      project,
      project.plan.executables.filter { !named || it.name in selection.executables },
      project.plan.libraries.filter { !named || it.name in selection.libraries },
    )
  }
  val unknownExecutables =
    selection.executables.filterNot { name ->
      selected.any { targets -> targets.executables.any { it.name == name } }
    }
  if (unknownExecutables.isNotEmpty()) {
    throw UnknownTargetException(
      "executable",
      "--executable",
      unknownExecutables,
      selected.flatMap { targets -> targets.executables.map { it.name } },
    )
  }
  val unknownLibraries =
    selection.libraries.filterNot { name ->
      selected.any { targets -> targets.libraries.any { it.name == name } }
    }
  if (unknownLibraries.isNotEmpty()) {
    throw UnknownTargetException(
      "library",
      "--library",
      unknownLibraries,
      selected.flatMap { targets -> targets.libraries.map { it.name } },
    )
  }
  return selected
}
