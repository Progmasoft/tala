/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.cli

import com.github.ajalt.mordant.rendering.TextColors.brightBlue
import com.github.ajalt.mordant.rendering.TextColors.brightCyan
import com.github.ajalt.mordant.rendering.TextStyles.bold
import com.github.ajalt.mordant.rendering.TextStyles.dim
import com.progmasoft.tazel.dsl.DependencyManifest
import com.progmasoft.tazel.dsl.DependencyScope
import com.progmasoft.tazel.dsl.Stability
import com.progmasoft.tazel.dsl.coordinate

/** A package a project depends on: one version of a ViGet package, or a local `.vipkg`. */
internal sealed interface GraphPackage {
  /** What `--invert` matches: `Publisher.Name`, or the path of the `.vipkg`. */
  val key: String

  val label: String

  data class Remote(
    val coordinate: String,
    val version: String,
    val stability: Stability,
  ) : GraphPackage {
    override val key = coordinate
    override val label: String
      get() {
        val tag = if (stability == Stability.STABLE) "" else " " + dim("(${stability.text})")
        return bold(coordinate) + " " + version + tag
      }
  }

  data class Local(val path: String) : GraphPackage {
    override val key = path
    override val label: String
      get() = bold(path) + " " + dim("(local)")
  }
}

private val Stability.text: String
  get() = name.lowercase()

/**
 * One dependency of a project as the project asks for it. [features] are the features of the
 * dependency it chooses; [byFeature] is the feature of the project that brings the dependency in.
 */
internal data class GraphEdge(
  val scope: DependencyScope,
  val target: GraphPackage,
  val byFeature: String? = null,
  val defaultFeatures: Boolean = true,
  val features: List<String> = emptyList(),
) {
  val note: String
    get() =
      listOfNotNull(
          features.takeIf { it.isNotEmpty() }?.let { "features: " + it.joinToString(", ") },
          "no default features".takeUnless { defaultFeatures },
          byFeature?.let { "by feature $it" },
        )
        .joinToString("; ")
}

/** A project of the graph and the dependencies it has with the features that are on. */
internal data class GraphProject(
  val name: String,
  val edges: List<GraphEdge>,
)

/**
 * The dependencies of one project. A dependency that a feature of the project brings in is part of
 * the graph when that feature is on: by default the features of `defaultFeatures`, every feature
 * with [allFeatures].
 */
internal fun graphProject(
  name: String,
  dependencies: DependencyManifest,
  defaultFeatures: List<String>,
  allFeatures: Boolean,
): GraphProject {
  val on = defaultFeatures.toSet()
  val remote =
    dependencies.declarations
      .filter { it.feature == null || allFeatures || it.feature in on }
      .map {
        GraphEdge(
          it.scope,
          GraphPackage.Remote(
            it.dependency.coordinate,
            it.dependency.version,
            it.dependency.stability,
          ),
          it.feature,
          it.defaultFeatures,
          it.features.filterValues { enabled -> enabled }.keys.sorted(),
        )
      }
  val local = dependencies.local.map { GraphEdge(it.scope, GraphPackage.Local(it.path)) }
  return GraphProject(name, (remote + local).sortedBy { it.scope })
}

/** How `tazel lock graph` prints the graph; see [Command.LockGraph]. */
internal data class GraphView(
  val duplicates: Boolean = false,
  val invert: String? = null,
  val depth: Int? = null,
)

/** The lines of the graph of [projects] as [view] asks for them, projects apart by a blank line. */
internal fun renderGraph(
  projects: List<GraphProject>,
  view: GraphView,
): List<String> {
  val trees =
    when {
      view.invert != null -> inverted(projects, projects.packagesWithKey(view.invert))
      view.duplicates -> inverted(projects, duplicatePackages(projects))
      else -> projects.map(::forward)
    }
  return trees.flatMapIndexed { index, tree ->
    (if (index == 0) emptyList() else listOf("")) + tree.lines(view.depth)
  }
}

/** Every package of the graph whose key is [key]. */
internal fun List<GraphProject>.packagesWithKey(key: String): List<GraphPackage> =
  flatMap { project -> project.edges.map { it.target } }.filter { it.key == key }.distinct()

/** Every key of the graph, for a hint when `--invert` names none of them. */
internal fun List<GraphProject>.packageKeys(): List<String> =
  flatMap { project -> project.edges.map { it.target.key } }.distinct()

/** The versions of every ViGet package that the graph holds in more than one version. */
internal fun duplicatePackages(projects: List<GraphProject>): List<GraphPackage> =
  projects
    .flatMap { project -> project.edges.map { it.target } }
    .filterIsInstance<GraphPackage.Remote>()
    .distinct()
    .groupBy { it.coordinate }
    .filterValues { it.size > 1 }
    .values
    .flatten()
    .sortedWith(compareBy(GraphPackage.Remote::coordinate, GraphPackage.Remote::version))

private class Tree(
  val label: String,
  val children: List<Tree> = emptyList(),
) {
  /** The lines of the tree; [depth] levels below the root at most, every level when absent. */
  fun lines(depth: Int?): List<String> = buildList {
    add(label)
    addChildren(this, children, "", depth)
  }

  private fun addChildren(
    lines: MutableList<String>,
    children: List<Tree>,
    indent: String,
    depth: Int?,
  ) {
    if (depth != null && depth <= 0) return
    children.forEachIndexed { index, child ->
      val last = index == children.lastIndex
      lines += indent + dim(if (last) "└── " else "├── ") + child.label
      addChildren(
        lines,
        child.children,
        indent + dim(if (last) "    " else "│   "),
        depth?.minus(1),
      )
    }
  }
}

private fun edgeLabel(edge: GraphEdge): String =
  edge.target.label +
    edge.note.takeIf(String::isNotEmpty)?.let { " " + brightBlue("[$it]") }.orEmpty()

private fun projectLabel(name: String) = (bold + brightCyan)(name)

/** A project with its dependencies under it; those of the test suites under a `[test]` line. */
private fun forward(project: GraphProject): Tree {
  val build = project.edges.filter { it.scope == DependencyScope.BUILD }.map { Tree(edgeLabel(it)) }
  val test = project.edges.filter { it.scope == DependencyScope.TEST }.map { Tree(edgeLabel(it)) }
  val testGroup = if (test.isEmpty()) emptyList() else listOf(Tree(dim("[test]"), test))
  return Tree(projectLabel(project.name), build + testGroup)
}

/** A project that `--invert` named: its name, its version when it has one, and where it is. */
internal data class NamedProject(
  val name: String,
  val version: String?,
  val place: String,
)

/** True when [edge] uses the package that a project called [name] becomes. */
private fun usesProject(
  edge: GraphEdge,
  name: String,
): Boolean =
  when (val target = edge.target) {
    is GraphPackage.Remote -> target.coordinate.substringAfter('.') == name
    // The name is as case-sensitive as project.name; only the extension may be spelled otherwise.
    is GraphPackage.Local -> {
      val file = target.path.substringAfterLast('/')
      file.startsWith(name) && file.substring(name.length).equals(".vipkg", ignoreCase = true)
    }
  }

/**
 * Each of [targets] with the projects of [projects] that depend on it under it, and how: the ViGet
 * package or the local `.vipkg` they use.
 */
internal fun renderDependents(
  targets: List<NamedProject>,
  projects: List<GraphProject>,
  depth: Int?,
): List<String> =
  targets
    .map { target ->
      val dependents = projects.flatMap { project ->
        project.edges
          .filter { usesProject(it, target.name) }
          .map { edge ->
            val scope = if (edge.scope == DependencyScope.TEST) " " + dim("[test]") else ""
            val note = edge.note.takeIf(String::isNotEmpty)?.let { " " + brightBlue("[$it]") }
            Tree(
              projectLabel(project.name) +
                " " +
                dim("as") +
                " " +
                edge.target.label +
                scope +
                note.orEmpty()
            )
          }
      }
      val version = target.version?.let { " $it" }.orEmpty()
      Tree(projectLabel(target.name) + version + " " + dim("(${target.place})"), dependents)
    }
    .flatMapIndexed { index, tree ->
      (if (index == 0) emptyList() else listOf("")) + tree.lines(depth)
    }

/** Each of [packages] with the projects that depend on it under it. */
private fun inverted(
  projects: List<GraphProject>,
  packages: List<GraphPackage>,
): List<Tree> = packages.map { target ->
  val dependents = projects.flatMap { project ->
    project.edges
      .filter { it.target == target }
      .map { edge ->
        val scope = if (edge.scope == DependencyScope.TEST) " " + dim("[test]") else ""
        val note = edge.note.takeIf(String::isNotEmpty)?.let { " " + brightBlue("[$it]") }
        Tree(projectLabel(project.name) + scope + note.orEmpty())
      }
  }
  Tree(target.label, dependents)
}
