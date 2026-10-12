// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include "Platform.hpp"
#include "Progmasoft/Tala/Runtime/AARC.hpp"
#include "Progmasoft/Tala/Runtime/Text.hpp"

// Console output. A string is a sequence of scalar values; a stream takes
// bytes. The scalars are encoded as UTF-8 a block at a time, each block
// ending between two characters, and every block is handed to the platform
// before the write returns: the runtime keeps no buffer, so output appears
// in the order the program wrote it and nothing is lost when the program
// stops.

namespace Progmasoft::Tala::Runtime::Console
{
    namespace
    {
        // The receiver a host installed, if any. A process that hosts
        // generated code runs one program at a time on one thread.
        // NOLINTNEXTLINE(cppcoreguidelines-avoid-non-const-global-variables)
        Sink installedSink = nullptr;
        // NOLINTNEXTLINE(cppcoreguidelines-avoid-non-const-global-variables)
        void *installedContext = nullptr;

        constexpr std::size_t kBlock = 512U;

        void
        Deliver(const bool error,
                const char *bytes,
                const std::size_t count) noexcept
        {
            if (count == 0U)
                return;
            if (installedSink != nullptr)
                installedSink(error ? TALA_CONSOLE_ERROR : TALA_CONSOLE_OUTPUT,
                              bytes,
                              count,
                              installedContext);
            else
                Platform::Write(error, bytes, count);
        }

        /// Encodes one scalar value and returns the number of bytes.
        [[nodiscard]] auto
        Encode(const char32_t scalar, char *bytes) noexcept -> std::size_t
        {
            const auto value = static_cast<std::uint32_t>(scalar);
            if (value < 0x80U)
            {
                bytes[0] = static_cast<char>(value);
                return 1U;
            }
            if (value < 0x800U)
            {
                bytes[0] = static_cast<char>(0xc0U | (value >> 6U));
                bytes[1] = static_cast<char>(0x80U | (value & 0x3fU));
                return 2U;
            }
            if (value < 0x10000U)
            {
                bytes[0] = static_cast<char>(0xe0U | (value >> 12U));
                bytes[1] = static_cast<char>(0x80U | ((value >> 6U) & 0x3fU));
                bytes[2] = static_cast<char>(0x80U | (value & 0x3fU));
                return 3U;
            }
            bytes[0] = static_cast<char>(0xf0U | (value >> 18U));
            bytes[1] = static_cast<char>(0x80U | ((value >> 12U) & 0x3fU));
            bytes[2] = static_cast<char>(0x80U | ((value >> 6U) & 0x3fU));
            bytes[3] = static_cast<char>(0x80U | (value & 0x3fU));
            return 4U;
        }
    } // namespace

    void
    SetSink(const Sink sink, void *context) noexcept
    {
        installedSink = sink;
        installedContext = context;
    }
} // namespace Progmasoft::Tala::Runtime::Console

extern "C"
{
    void
    tala_console_write(void *text, const std::int64_t target) noexcept
    {
        using namespace Progmasoft::Tala::Runtime;
        const auto error
            = target == TALA_CONSOLE_ERROR || target == TALA_CONSOLE_ERROR_LINE;
        const auto line = target == TALA_CONSOLE_OUTPUT_LINE
                          || target == TALA_CONSOLE_ERROR_LINE;
        const auto view = Aarc::ViewString(text);

        char block[Console::kBlock];
        std::size_t used = 0U;
        for (std::size_t index = 0U; index < view.count; ++index)
        {
            // A character is at most four bytes; a block never ends inside
            // one.
            if (used + 4U > Console::kBlock)
            {
                Console::Deliver(error, block, used);
                used = 0U;
            }
            used += Console::Encode(view.scalars[index], block + used);
        }
        if (line)
        {
            if (used + 2U > Console::kBlock)
            {
                Console::Deliver(error, block, used);
                used = 0U;
            }
            for (const auto *terminator = Platform::LineTerminator();
                 *terminator != '\0';
                 ++terminator)
                block[used++] = *terminator;
        }
        Console::Deliver(error, block, used);
    }
}
