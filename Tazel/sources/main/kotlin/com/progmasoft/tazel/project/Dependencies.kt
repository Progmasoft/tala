/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.project

import java.nio.file.InvalidPathException
import java.nio.file.Path
import kotlin.io.path.extension

@TalaKts
class DependenciesScope internal constructor() {
  internal val required = mutableListOf<PackageDependency>()
  internal val optional = mutableListOf<OptionalPackageDependency>()
  internal val selections = mutableListOf<PackageFeatureSelection>()
  internal val local = mutableListOf<LocalPackageDependency>()

  internal fun add(dependency: PackageDependency) {
    required += dependency
  }

  internal fun addOptional(
    feature: String,
    dependency: PackageDependency,
    enabled: Boolean,
  ) {
    val normalizedFeature = requireFeatureName(feature)
    optional += OptionalPackageDependency(normalizedFeature, dependency)
    selections += PackageFeatureSelection(dependency.coordinate, normalizedFeature, enabled)
  }

  internal fun addLocal(path: String) {
    local +=
      LocalPackageDependency(requireLocalArtifactPath(path, "vipkg", "local dependency path"))
  }
}

// Validate and canonicalize only what the project declared. This deliberately does not
// fetch registry metadata, choose transitive versions or claim to be a package solver.
internal fun validateDependencies(
  required: List<PackageDependency>,
  optional: List<OptionalPackageDependency>,
  selections: List<PackageFeatureSelection>,
  local: List<LocalPackageDependency> = emptyList(),
): DependencyManifest {
  val requiredByName = linkedMapOf<String, PackageDependency>()
  required.forEach { dependency ->
    val normalized = normalizeDependency(dependency)
    val coordinate = normalized.coordinate
    val previous = requiredByName[coordinate]
    if (previous != null && previous != normalized) {
      throw ProjectConfigurationException("package '$coordinate' has conflicting declarations")
    }
    requiredByName[coordinate] = normalized
  }

  val optionalByKey = linkedMapOf<Pair<String, String>, OptionalPackageDependency>()
  optional.forEach { declaration ->
    val dependency = normalizeDependency(declaration.dependency)
    val feature = requireFeatureName(declaration.feature)
    if (dependency.coordinate in requiredByName) {
      throw ProjectConfigurationException(
        "package '${dependency.coordinate}' cannot be both required and optional"
      )
    }
    val key = dependency.coordinate to feature
    val previous = optionalByKey[key]
    val normalized = OptionalPackageDependency(feature, dependency)
    if (previous != null && previous != normalized) {
      throw ProjectConfigurationException(
        "optional package '${dependency.coordinate}' has conflicting declarations"
      )
    }
    optionalByKey[key] = normalized
  }

  val selectedByKey = linkedMapOf<Pair<String, String>, PackageFeatureSelection>()
  selections.forEach { selection ->
    val normalized =
      PackageFeatureSelection(
        requireDependencyCoordinate(selection.packageName),
        requireFeatureName(selection.feature),
        selection.enabled,
      )
    val key = normalized.packageName to normalized.feature
    if (key !in optionalByKey) {
      throw ProjectConfigurationException(
        "feature '${normalized.feature}' is not declared by optional package '${normalized.packageName}'"
      )
    }
    selectedByKey[key] = normalized
  }

  val completeSelections =
    optionalByKey.keys
      .map { key -> selectedByKey[key] ?: PackageFeatureSelection(key.first, key.second, false) }
      .sortedWith(compareBy(PackageFeatureSelection::packageName, PackageFeatureSelection::feature))
  return DependencyManifest(
    requiredByName.values.sortedWith(packageDependencyOrder),
    optionalByKey.values.sortedWith(
      compareBy<OptionalPackageDependency> { it.dependency.coordinate }
        .thenBy(OptionalPackageDependency::feature)
        .thenBy { it.dependency.stability }
        .thenBy { it.dependency.version }
    ),
    completeSelections,
    local
      .map {
        LocalPackageDependency(requireLocalArtifactPath(it.path, "vipkg", "local dependency path"))
      }
      .distinct()
      .sortedBy(LocalPackageDependency::path),
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
  PackageDependency(
    requirePackageSegment(dependency.publisher, "dependency publisher"),
    requirePackageSegment(dependency.name, "dependency name"),
    requirePackageVersion(dependency.version),
    dependency.stability,
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
  val name = requireText(value, "dependency feature")
  if (!name.matches(Regex("[A-Za-z_][A-Za-z0-9_]*"))) {
    throw ProjectConfigurationException("dependency feature must be one identifier: $name")
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
