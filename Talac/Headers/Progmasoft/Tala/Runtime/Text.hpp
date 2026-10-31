// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstddef>
#include <cstdint>

#include "Progmasoft/Tala/Runtime/Text.h"

namespace Progmasoft::Tala::Runtime::Console
{
    /** Receives the bytes of one console write.
     *
     * `stream` is `TALA_CONSOLE_OUTPUT` or `TALA_CONSOLE_ERROR`; a line
     * terminator the write asked for is part of the bytes. The bytes are
     * UTF-8 and are valid only for the duration of the call.
     */
    using Sink = void (*)(std::int64_t stream,
                          const char *bytes,
                          std::size_t count,
                          void *context) noexcept;

    /** Send console output to a function instead of the standard streams.
     *
     * A process that hosts generated code, such as a test or the
     * interactive shell, uses this to read what a program wrote. Passing
     * null restores the standard streams. The sink is not part of the C
     * ABI, and a native executable never sets one.
     *
     * @param sink The receiver, or null.
     * @param context Passed to every call of the sink unchanged.
     */
    void
    SetSink(Sink sink, void *context) noexcept;
} // namespace Progmasoft::Tala::Runtime::Console

namespace Progmasoft::Tala::Runtime::Testing
{
    /** 0 when no test of the run failed, 1 otherwise. */
    [[nodiscard]] auto
    Status() noexcept -> std::int32_t;

    /** Forget the tests run so far. A process that hosts generated code
     * calls this before it runs another test build. */
    void
    Reset() noexcept;
} // namespace Progmasoft::Tala::Runtime::Testing
