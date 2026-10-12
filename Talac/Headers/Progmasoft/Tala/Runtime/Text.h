// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#ifndef TALA_RUNTIME_TEXT_H
#define TALA_RUNTIME_TEXT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* The text and console entry points of the Tala runtime.
 *
 * Generated code calls these functions for string concatenation, for the
 * conversions of `Console.Printf` and `Console.Format`, and for console
 * output. Each is one member of the runtime-call catalog of the compiler;
 * `Tala/Core/RuntimeCall.hpp` gives the member that names it.
 *
 * Ownership follows the convention of every generated call: a string
 * argument is borrowed for the duration of the call, and a string result is
 * returned with one strong reference that the caller releases. A null
 * string argument is the empty string. A function that cannot allocate its
 * result stops the program; none returns null.
 *
 * A string is a sequence of Unicode scalar values. Width, precision and
 * padding count scalar values, not bytes and not display columns.
 */

#ifdef __cplusplus
#    define TALA_TEXT_NOEXCEPT noexcept
extern "C"
{
#else
#    define TALA_TEXT_NOEXCEPT
#endif

/* A conversion takes its flags, its width and its precision before the value
 * it converts. That is the order in which the arguments of a format stand: a
 * width or a precision written as `*` is given before the value, and the
 * operands of a call are evaluated in order. */

/* Flags of a conversion, combined in the `flags` argument of the
 * `tala_text_format_*` functions. The frontend rejects the combinations the
 * language does not define, so the runtime gives the remaining ones the
 * meaning stated here and ignores a flag that has none for a conversion. */

/** `-`: the value stands at the left of its field. */
#define TALA_TEXT_FLAG_LEFT INT64_C(1)
/** `0`: a number is padded with zeros after its sign and prefix. */
#define TALA_TEXT_FLAG_ZERO INT64_C(2)
/** `+`: a number that is not negative is written with a plus sign. */
#define TALA_TEXT_FLAG_PLUS INT64_C(4)
/** space: a number that is not negative is written with a leading space. */
#define TALA_TEXT_FLAG_SPACE INT64_C(8)
/** `#`: a hexadecimal number is written with the prefix `0x`. */
#define TALA_TEXT_FLAG_ALTERNATE INT64_C(16)
/** `'`: the integer digits of a decimal number are grouped in threes with
 * apostrophes. */
#define TALA_TEXT_FLAG_GROUP INT64_C(32)
/** `%x`: an integer is written in hexadecimal with lowercase digits. */
#define TALA_TEXT_FLAG_HEXADECIMAL INT64_C(64)

/** A width or a precision that the conversion does not have. */
#define TALA_TEXT_ABSENT INT64_C(-1)

/* Where `tala_console_write` writes, and whether a line ends after it. */

/** Standard output. */
#define TALA_CONSOLE_OUTPUT INT64_C(0)
/** Standard output, followed by the line terminator of the platform. */
#define TALA_CONSOLE_OUTPUT_LINE INT64_C(1)
/** Standard error. */
#define TALA_CONSOLE_ERROR INT64_C(2)
/** Standard error, followed by the line terminator of the platform. */
#define TALA_CONSOLE_ERROR_LINE INT64_C(3)

    /** Whether the two strings hold the same scalar values in the same
     * order. Strings are compared by what they hold, never by where they are
     * kept. */
    bool
    tala_text_equals(void *left, void *right) TALA_TEXT_NOEXCEPT;

    /** The two strings one after the other. */
    void *
    tala_text_concat(void *left, void *right) TALA_TEXT_NOEXCEPT;

    /** A signed integer in decimal, with a minus sign when negative. */
    void *
    tala_text_from_signed(int64_t value) TALA_TEXT_NOEXCEPT;

    /** An unsigned integer in decimal. */
    void *
    tala_text_from_unsigned(uint64_t value) TALA_TEXT_NOEXCEPT;

    /** `true` or `false`. */
    void *
    tala_text_from_bool(bool value) TALA_TEXT_NOEXCEPT;

    /** The one character. A value that is not a Unicode scalar value is
     * written as U+FFFD. */
    void *
    tala_text_from_char(uint32_t value) TALA_TEXT_NOEXCEPT;

    /** `%d` and `%x` of a signed integer. A negative number is its minus
     * sign and its magnitude in either base; it is never the bit pattern of
     * its representation. */
    void *
    tala_text_format_signed(int64_t flags,
                            int64_t width,
                            int64_t precision,
                            int64_t value) TALA_TEXT_NOEXCEPT;

    /** `%u` and `%x` of an unsigned integer. */
    void *
    tala_text_format_unsigned(int64_t flags,
                              int64_t width,
                              int64_t precision,
                              uint64_t value) TALA_TEXT_NOEXCEPT;

    /** `%f`: the decimal expansion of the value, correctly rounded to
     * `precision` digits after the point, six when absent. The digits are
     * those of the exact binary value; a tie rounds to the even digit. No
     * locale changes the point or adds grouping. A value that is not
     * finite is `nan`, `inf` or `-inf`. */
    void *
    tala_text_format_floating(int64_t flags,
                              int64_t width,
                              int64_t precision,
                              double value) TALA_TEXT_NOEXCEPT;

    /** `%s`: at most `precision` characters of the string when a precision
     * is present. */
    void *
    tala_text_format_string(int64_t flags,
                            int64_t width,
                            int64_t precision,
                            void *value) TALA_TEXT_NOEXCEPT;

    /** `%c`. */
    void *
    tala_text_format_char(int64_t flags,
                          int64_t width,
                          int64_t precision,
                          uint32_t value) TALA_TEXT_NOEXCEPT;

    /** `%n`: the line terminator of the platform, carriage return and line
     * feed on Windows and line feed elsewhere. */
    void *
    tala_text_newline(void) TALA_TEXT_NOEXCEPT;

    /** Write a string to a standard stream as UTF-8, or as UTF-16 to a
     * Windows console. `target` is one of the `TALA_CONSOLE_*` values. The
     * bytes reach the stream before the function returns: the runtime keeps
     * no buffer of its own. A stream that cannot be written to is ignored.
     */
    void
    tala_console_write(void *text, int64_t target) TALA_TEXT_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#undef TALA_TEXT_NOEXCEPT
#endif
