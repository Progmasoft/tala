// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstddef>
#include <cstdint>

// What the text runtime asks of the system it runs on. Everything else in
// the runtime is arithmetic on memory it was given, so that the same source
// serves a process that hosts generated code and a native executable that
// is linked without a C runtime.

namespace Progmasoft::Tala::Runtime::Platform
{
    /** Stop the program. The runtime calls this when it cannot go on:
     * memory for a result is exhausted. It does not return. */
    [[noreturn]] void
    Fail() noexcept;

    /** Write bytes of UTF-8 to standard output (`error` false) or standard
     * error. The bytes are whole encoded characters. A stream that cannot
     * be written to is ignored. */
    void
    Write(bool error, const char *bytes, std::size_t count) noexcept;

    /** The line terminator of the platform, as ASCII. */
    [[nodiscard]] constexpr auto
    LineTerminator() noexcept -> const char *
    {
#ifdef _WIN32
        return "\r\n";
#else
        return "\n";
#endif
    }
} // namespace Progmasoft::Tala::Runtime::Platform
