/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.dsl

import java.nio.file.InvalidPathException
import java.nio.file.Path
import kotlin.io.path.extension

@TazelDsl
class DependenciesScope internal constructor() {
  internal val declarations = mutableListOf<DependencyDeclaration>()
  internal val local = mutableListOf<LocalPackageDependency>()

  /** A package of ViGet that the targets of the project use. */
  fun dependency(
    publisher: String,
    block: DependencyDeclarationScope.() -> Unit,
  ) {
    declarations +=
      DependencyDeclarationScope(publisher, DependencyScope.BUILD).apply(block).build()
  }

  /** A package of ViGet that only the test suites of the project use. */
  fun testDependency(
    publisher: String,
    block: DependencyDeclarationScope.() -> Unit,
  ) {
    declarations += DependencyDeclarationScope(publisher, DependencyScope.TEST).apply(block).build()
  }

  /** A `.vipkg` of the project directory that the targets of the project use. */
  fun localDependency(block: LocalDependencyScope.() -> Unit) {
    local += LocalDependencyScope().apply(block).build(DependencyScope.BUILD)
  }

  /** A `.vipkg` of the project directory that only the test suites of the project use. */
  fun localTestDependency(block: LocalDependencyScope.() -> Unit) {
    local += LocalDependencyScope().apply(block).build(DependencyScope.TEST)
  }
}

@TazelDsl
class LocalDependencyScope internal constructor() {
  var path: String? = null

  internal fun build(scope: DependencyScope) =
    LocalPackageDependency(requireLocalArtifactPath(path, "vipkg", "local dependency path"), scope)
}

@TazelDsl
class DependencyDeclarationScope
internal constructor(
  private val publisher: String,
  private val scope: DependencyScope,
) {
  var name: String? = null
  var version: String? = null
  var stability: Stability = Stability.STABLE

  /** The feature of this project that brings the dependency in; required when absent. */
  var feature: String? = null

  /** Whether the default features of the dependency are enabled. */
  var defaultFeatures: Boolean = true
  private val features = linkedMapOf<String, Boolean>()

  /** Chooses one feature of the dependency. */
  fun feature(
    name: String,
    block: DependencyFeatureScope.() -> Unit,
  ) {
    val normalized = requireFeatureName(name)
    if (normalized in features) {
      throw ProjectConfigurationException("dependency feature '$normalized' is chosen twice")
    }
    features[normalized] = DependencyFeatureScope().apply(block).enabled
  }

  internal fun build(): DependencyDeclaration {
    val packageName = name ?: throw ProjectConfigurationException("dependency requires name")
    val packageVersion =
      version ?: throw ProjectConfigurationException("dependency requires version")
    return DependencyDeclaration(
      packageDependency(publisher, packageName, stability, packageVersion),
      scope,
      feature?.let(::requireFeatureName),
      defaultFeatures,
      features.toSortedMap(),
    )
  }
}

@TazelDsl
class DependencyFeatureScope internal constructor() {
  var enabled: Boolean = false
}

// Validate and canonicalize only what the project declared. This deliberately does not
// fetch registry metadata, choose transitive versions or claim to be a package solver.
internal fun validateDependencies(manifest: DependencyManifest): DependencyManifest {
  val byKey = linkedMapOf<Pair<String, DependencyScope>, DependencyDeclaration>()
  manifest.declarations.forEach { declaration ->
    val normalized =
      declaration.copy(
        dependency = normalizeDependency(declaration.dependency),
        feature = declaration.feature?.let(::requireFeatureName),
        features = declaration.features.mapKeys { requireFeatureName(it.key) }.toSortedMap(),
      )
    val key = normalized.dependency.coordinate to normalized.scope
    val previous = byKey[key]
    if (previous != null && previous != normalized) {
      throw ProjectConfigurationException("package '${key.first}' has conflicting declarations")
    }
    byKey[key] = normalized
  }
  val local =
    manifest.local
      .map {
        it.copy(path = requireLocalArtifactPath(it.path, "vipkg", "local dependency path"))
      }
      .distinct()
      .sortedWith(compareBy(LocalPackageDependency::scope, LocalPackageDependency::path))
  return DependencyManifest(
    byKey.values.sortedWith(
      compareBy<DependencyDeclaration> { it.scope }
        .thenBy { it.dependency.publisher }
        .thenBy { it.dependency.name }
    ),
    local,
  )
}

internal fun requireLocalArtifactPath(
  value: String?,
  extension: String,
  field: String,
): String {
  val text = requireText(value ?: throw ProjectConfigurationException("$field is required"), field)
  val path =
    try {
      Path.of(text)
    } catch (_: InvalidPathException) {
      throw ProjectConfigurationException("$field is not a valid path: $text")
    }
  if (path.isAbsolute || path.any { it.toString() == ".." }) {
    throw ProjectConfigurationException("$field must stay inside the project root: $text")
  }
  if (!path.extension.equals(extension, ignoreCase = true)) {
    throw ProjectConfigurationException("$field must use the .$extension extension: $text")
  }
  return path.normalize().joinToString("/")
}

internal fun packageDependency(
  publisher: String,
  name: String,
  stability: Stability,
  version: String,
) =
  PackageDependency(
    requirePackageSegment(publisher, "dependency publisher"),
    requirePackageSegment(name, "dependency name"),
    requirePackageVersion(version),
    stability,
  )

private fun normalizeDependency(dependency: PackageDependency) =
  packageDependency(
    dependency.publisher,
    dependency.name,
    dependency.stability,
    dependency.version,
  )

internal val PackageDependency.coordinate: String
  get() = "$publisher.$name"

internal fun requireDependencyCoordinate(value: String): String {
  val parts = requireText(value, "package coordinate").split('.')
  if (parts.size != 2)
    throw ProjectConfigurationException("package coordinate must be Publisher.Name: $value")
  val publisher = requirePackageSegment(parts[0], "dependency publisher")
  val name = requirePackageSegment(parts[1], "dependency name")
  return "$publisher.$name"
}

internal fun requirePackageSegment(
  value: String,
  field: String,
): String {
  val name = requireText(value, field)
  if (!name.matches(Regex("[A-Za-z][A-Za-z0-9_]*"))) {
    throw ProjectConfigurationException("$field must be one package identifier: $name")
  }
  return name
}

internal fun requireFeatureName(value: String): String {
  val name = requireText(value, "feature")
  if (!name.matches(Regex("[A-Za-z_][A-Za-z0-9_]*"))) {
    throw ProjectConfigurationException("a feature must be one identifier: $name")
  }
  return name
}

internal fun requirePackageVersion(value: String): String {
  val version = requireText(value, "package version")
  val component = "(?:0|[1-9][0-9]*)"
  if (!version.matches(Regex("$component\\.$component\\.$component(?:-[0-9A-Za-z.-]+)?"))) {
    throw ProjectConfigurationException(
      "package version must be an exact semantic version: $version"
    )
  }
  return version
}
