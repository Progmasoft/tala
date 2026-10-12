/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.project

/** A small, non-executing parser for the declarative plugins block. */
object PluginPreamble {
  fun parse(script: String): List<PluginRequest> {
    val tokens = Lexer(script).tokens()
    val start = tokens.indexOfFirst { !it.string && it.text == "plugins" }
    if (start < 0) return emptyList()
    val parser = Parser(tokens, start)
    return parser.parsePlugins()
  }

  private data class Token(
    val text: String,
    val string: Boolean = false,
  )

  private class Lexer(private val source: String) {
    private var index = 0

    fun tokens(): List<Token> = buildList {
      while (index < source.length) {
        val current = source[index]
        when {
          current.isWhitespace() -> index++
          source.startsWith("//", index) -> skipLine()
          source.startsWith("/*", index) -> skipBlockComment()
          source.startsWith("\"\"\"", index) -> skipRawString()
          current == '"' -> add(readString())
          current == '\'' -> skipCharacter()
          current.isLetterOrDigit() || current == '_' -> add(readIdentifier())
          current in "{}()=.;," -> {
            add(Token(current.toString()))
            index++
          }
          else -> index++
        }
      }
    }

    private fun skipLine() {
      index += 2
      while (index < source.length && source[index] != '\n') index++
    }

    private fun skipBlockComment() {
      var depth = 1
      index += 2
      while (index < source.length && depth > 0) {
        when {
          source.startsWith("/*", index) -> {
            depth++
            index += 2
          }
          source.startsWith("*/", index) -> {
            depth--
            index += 2
          }
          else -> index++
        }
      }
      if (depth != 0) throw ProjectConfigurationException("unterminated comment in plugin preamble")
    }

    private fun skipRawString() {
      val end = source.indexOf("\"\"\"", index + 3)
      if (end < 0) throw ProjectConfigurationException("unterminated raw string in plugin preamble")
      index = end + 3
    }

    private fun skipCharacter() {
      index++
      if (index >= source.length)
        throw ProjectConfigurationException("unterminated character in plugin preamble")
      if (source[index] == '\\') index++
      index++
      if (index >= source.length || source[index] != '\'') {
        throw ProjectConfigurationException("unterminated character in plugin preamble")
      }
      index++
    }

    private fun readIdentifier(): Token {
      val start = index
      while (index < source.length && (source[index].isLetterOrDigit() || source[index] == '_')) {
        index++
      }
      return Token(source.substring(start, index))
    }

    private fun readString(): Token {
      index++
      val value = StringBuilder()
      while (index < source.length) {
        val current = source[index++]
        if (current == '"') return Token(value.toString(), true)
        if (current == '\\') {
          if (index >= source.length)
            throw ProjectConfigurationException("unterminated escape in plugin preamble")
          val escaped = source[index++]
          value.append(
            when (escaped) {
              'n' -> '\n'
              'r' -> '\r'
              't' -> '\t'
              '"' -> '"'
              '\\' -> '\\'
              else ->
                throw ProjectConfigurationException(
                  "unsupported escape in plugin preamble: \\$escaped"
                )
            }
          )
        } else {
          value.append(current)
        }
      }
      throw ProjectConfigurationException("unterminated string in plugin preamble")
    }
  }

  private class Parser(
    private val tokens: List<Token>,
    start: Int,
  ) {
    private var index = start

    fun parsePlugins(): List<PluginRequest> {
      expect("plugins")
      expect("{")
      val requests = mutableListOf<PluginRequest>()
      while (!accept("}")) {
        expect("plugin")
        expect("(")
        val publisher = string()
        expect(")")
        expect("{")
        var name: String? = null
        var version: String? = null
        var path: String? = null
        while (!accept("}")) {
          val field = next().text
          expect("=")
          when (field) {
            "name" -> name = string()
            "version" -> version = string()
            "path" -> path = string()
            else -> throw ProjectConfigurationException("unknown plugin declaration field '$field'")
          }
          accept(";")
        }
        requests += validateRequest(publisher, name, version, path)
      }
      return requests.also(::rejectDuplicates)
    }

    private fun string(): String {
      val token = next()
      if (!token.string) throw ProjectConfigurationException("plugin declaration requires a string")
      return token.text
    }

    private fun accept(text: String): Boolean {
      if (tokens.getOrNull(index)?.text != text) return false
      index++
      return true
    }

    private fun expect(text: String) {
      if (!accept(text)) throw ProjectConfigurationException("expected '$text' in plugin preamble")
    }

    private fun next(): Token =
      tokens.getOrNull(index++)
        ?: throw ProjectConfigurationException("unexpected end of plugin preamble")
  }

  private fun validateRequest(
    publisher: String,
    name: String?,
    version: String?,
    path: String?,
  ): PluginRequest {
    if (publisher == "local") {
      if (name != null || version != null) {
        throw ProjectConfigurationException(
          "local plugin accepts only path; name and version come from its JAR descriptor"
        )
      }
      return PluginRequest(
        publisher = "local",
        name = null,
        version = null,
        path = requireLocalArtifactPath(path, "jar", "local plugin path"),
      )
    }
    if (path != null)
      throw ProjectConfigurationException("hosted plugin does not accept a local path")
    val validPublisher = requireModuleSegment(publisher, "plugin publisher")
    val validName =
      requireModuleSegment(
        name ?: throw ProjectConfigurationException("plugin name is required"),
        "plugin name",
      )
    val validVersion = version?.let(::requirePackageVersion)
    return PluginRequest(validPublisher, validName, validVersion)
  }

  private fun rejectDuplicates(requests: List<PluginRequest>) {
    val duplicate =
      requests.groupBy(PluginRequest::coordinate).entries.firstOrNull { it.value.size > 1 }
    if (duplicate != null) {
      throw ProjectConfigurationException("plugin '${duplicate.key}' is declared more than once")
    }
  }
}
