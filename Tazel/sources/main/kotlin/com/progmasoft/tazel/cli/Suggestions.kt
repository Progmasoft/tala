/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.cli

/**
 * The candidate that [word] was most likely meant to be, or null when none is close enough to be a
 * typo. Case is ignored first, so `Build` finds `build`; otherwise the edit distance, with two
 * swapped letters counting as one edit, must be at most one for a short word and two for a longer
 * one, and below the length of the word. On a tie the earlier candidate wins.
 */
fun closestTo(
  word: String,
  candidates: Iterable<String>,
): String? {
  val choices = candidates.toList()
  choices
    .firstOrNull { it.equals(word, ignoreCase = true) && it != word }
    ?.let {
      return it
    }
  val limit = if (word.length <= 4) 1 else 2
  return choices
    .map { it to editDistance(word.lowercase(), it.lowercase()) }
    .filter { (_, distance) -> distance in 1..limit && distance < word.length }
    .minByOrNull { (_, distance) -> distance }
    ?.first
}

/**
 * The number of insertions, deletions, substitutions and swaps of two neighbouring letters that
 * turn [first] into [second] (optimal string alignment).
 */
internal fun editDistance(
  first: String,
  second: String,
): Int {
  val distances = Array(first.length + 1) { IntArray(second.length + 1) }
  for (i in 0..first.length) distances[i][0] = i
  for (j in 0..second.length) distances[0][j] = j
  for (i in 1..first.length) {
    for (j in 1..second.length) {
      val cost = if (first[i - 1] == second[j - 1]) 0 else 1
      var best =
        minOf(distances[i - 1][j] + 1, distances[i][j - 1] + 1, distances[i - 1][j - 1] + cost)
      if (i > 1 && j > 1 && first[i - 1] == second[j - 2] && first[i - 2] == second[j - 1]) {
        best = minOf(best, distances[i - 2][j - 2] + 1)
      }
      distances[i][j] = best
    }
  }
  return distances[first.length][second.length]
}

/** Short asides that follow a suggestion; the word that was typed picks one, so a run repeats. */
private val asides =
  listOf(
    "Fingers sometimes outrun the keyboard.",
    "One letter wandered off.",
    "Typos happen to the best of us.",
    "So close the keys almost had it.",
    "The keyboard is innocent, probably.",
  )

/** The aside for a suggestion made for [word]. */
fun asideFor(word: String): String = asides[Math.floorMod(word.hashCode(), asides.size)]

/** The hint printed under an error: the suggestion and its aside. */
fun didYouMean(
  word: String,
  suggestion: String,
): String = "did you mean $suggestion? ${asideFor(word)}"
