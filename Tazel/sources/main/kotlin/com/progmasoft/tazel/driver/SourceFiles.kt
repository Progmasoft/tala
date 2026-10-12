/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.driver

import com.progmasoft.tazel.dsl.ProjectConfigurationException
import java.nio.file.Files
import java.nio.file.Path

const val SOURCE_EXTENSION = ".tala"

/**
 * Finds the sources of a target: every `.tala` file below a directory of the project that no
 * exclusion pattern matches.
 *
 * Patterns and results are paths relative to the project root, written with `/`. `*` and `?` stay
 * inside one path segment; a segment that is `**` stands for any number of segments. A pattern that
 * names a directory excludes everything below it. Names are compared the way the host compares file
 * names: without regard to case on Windows, exactly elsewhere.
 */
class SourceFiles(private val ignoreCase: Boolean) {
  fun discover(
    root: Path,
    directory: String,
    excludes: List<String>,
    setting: String,
  ): List<String> {
    val projectRoot = root.toAbsolutePath().normalize()
    val start = projectRoot.resolve(directory).normalize()
    if (!start.startsWith(projectRoot)) {
      throw ProjectConfigurationException("$setting escapes the project root: $directory")
    }
    if (!Files.isDirectory(start)) {
      throw ProjectConfigurationException("$setting is not a directory: $start")
    }
    val patterns = excludes.map(::segments)
    val found = mutableListOf<String>()
    walk(projectRoot, start, patterns, found)
    return found.sortedWith(compareBy { if (ignoreCase) it.lowercase() else it })
  }

  private fun walk(
    root: Path,
    directory: Path,
    patterns: List<List<String>>,
    found: MutableList<String>,
  ) {
    val entries =
      try {
        Files.newDirectoryStream(directory).use { it.toList() }
      } catch (error: java.io.IOException) {
        throw ProjectConfigurationException("cannot list $directory: ${error.message}")
      }
    for (entry in entries) {
      val relative = segments(root.relativize(entry).toString())
      // A link is not followed: it could lead outside the project or back into it.
      if (Files.isSymbolicLink(entry)) continue
      if (Files.isDirectory(entry)) {
        if (patterns.none { excludesDirectory(it, relative) }) walk(root, entry, patterns, found)
      } else if (
        entry.fileName.toString().endsWith(SOURCE_EXTENSION) &&
          patterns.none { matches(it, relative) }
      ) {
        found += relative.joinToString("/")
      }
    }
  }

  /** True when the glob [pattern] matches the project-relative [path]. */
  fun matches(
    pattern: String,
    path: String,
  ) = matches(segments(pattern), segments(path))

  private fun excludesDirectory(
    pattern: List<String>,
    directory: List<String>,
  ) = matches(pattern, directory) || matches(pattern + "**", directory)

  private fun matches(
    pattern: List<String>,
    path: List<String>,
  ): Boolean {
    if (pattern.isEmpty()) return path.isEmpty()
    if (pattern.first() == "**") {
      val rest = pattern.drop(1)
      return (0..path.size).any { skipped -> matches(rest, path.drop(skipped)) }
    }
    return path.isNotEmpty() &&
      matchesSegment(pattern.first(), 0, path.first(), 0) &&
      matches(pattern.drop(1), path.drop(1))
  }

  private fun matchesSegment(
    pattern: String,
    patternIndex: Int,
    text: String,
    textIndex: Int,
  ): Boolean {
    if (patternIndex == pattern.length) return textIndex == text.length
    return when (val expected = pattern[patternIndex]) {
      '*' ->
        (textIndex..text.length).any { next ->
          matchesSegment(pattern, patternIndex + 1, text, next)
        }
      '?' ->
        textIndex < text.length && matchesSegment(pattern, patternIndex + 1, text, textIndex + 1)
      else ->
        textIndex < text.length &&
          expected.equals(text[textIndex], ignoreCase) &&
          matchesSegment(pattern, patternIndex + 1, text, textIndex + 1)
    }
  }

  private fun segments(path: String) =
    path.replace('\\', '/').split('/').filter { it.isNotEmpty() && it != "." }
}
