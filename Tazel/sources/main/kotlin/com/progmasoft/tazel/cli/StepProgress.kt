/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.tazel.cli

import com.github.ajalt.mordant.animation.progress.ThreadProgressTaskAnimator
import com.github.ajalt.mordant.animation.progress.animateOnThread
import com.github.ajalt.mordant.animation.progress.execute
import com.github.ajalt.mordant.rendering.TextColors.brightBlue
import com.github.ajalt.mordant.rendering.TextColors.brightCyan
import com.github.ajalt.mordant.rendering.TextStyles.bold
import com.github.ajalt.mordant.rendering.TextStyles.dim
import com.github.ajalt.mordant.terminal.Terminal
import com.github.ajalt.mordant.widgets.Spinner
import com.github.ajalt.mordant.widgets.progress.completed
import com.github.ajalt.mordant.widgets.progress.progressBar
import com.github.ajalt.mordant.widgets.progress.progressBarContextLayout
import com.github.ajalt.mordant.widgets.progress.spinner
import com.github.ajalt.mordant.widgets.progress.text
import com.github.ajalt.mordant.widgets.progress.timeElapsed
import java.util.concurrent.Future

/**
 * A progress bar under the status lines while a command works through a known number of steps: a
 * spinner, the verb, the step in hand, the bar, the count and the time so far.
 *
 * It is drawn only on an interactive terminal that can move its cursor. In a pipe, in CI and in the
 * tests nothing is drawn, and the status lines tell the same story. Everything else Tazel prints
 * goes through the same [Terminal], which keeps the bar below it.
 */
internal class StepProgress
private constructor(
  private val animation: ThreadProgressTaskAnimator<String>?,
  private val runner: Future<*>?,
) : AutoCloseable {
  /** True when the bar is drawn; output of other programs then has to go through the terminal. */
  val drawing: Boolean
    get() = animation != null

  /** Shows [step] as the one in hand. */
  fun working(step: String) {
    animation?.update { context = step }
  }

  /** Counts one step as done. */
  fun done() {
    animation?.update { completed += 1 }
  }

  /** Ends the bar and removes it, whether every step finished or one failed. */
  override fun close() {
    val animation = animation ?: return
    animation.update { completed = total ?: completed }
    animation.clear()
    runner?.cancel(true)
  }

  companion object {
    /** Starts a bar of [total] steps for [verb], or one that draws nothing where it cannot. */
    fun start(
      terminal: Terminal,
      verb: String,
      total: Int,
    ): StepProgress {
      val info = terminal.terminalInfo
      if (total < 1 || !info.outputInteractive || !info.supportsAnsiCursor) {
        return StepProgress(null, null)
      }
      val layout =
        progressBarContextLayout<String> {
          spinner(Spinner.Dots(brightCyan))
          text((bold + brightCyan)(verb))
          text { context }
          progressBar()
          completed(style = brightBlue)
          timeElapsed(style = dim.style)
        }
      val animation =
        layout.animateOnThread(
          terminal,
          context = "",
          total = total.toLong(),
          clearWhenFinished = true,
        )
      return StepProgress(animation, animation.execute())
    }
  }
}
