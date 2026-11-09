// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <cstddef>

#include "Platform.hpp"
#include "Progmasoft/Tala/Runtime/AARC.h"
#include "Progmasoft/Tala/Runtime/AARC.hpp"
#include "Progmasoft/Tala/Runtime/Text.h"
#include "Progmasoft/Tala/Runtime/Text.hpp"

// The test runtime. The runner of a test build calls each [Fact] method and
// then `tala_test_end` with its name; a false `#expect` calls
// `tala_test_fail` on the way. The counts live here, so an expectation in a
// helper method is recorded for the test that called it. Everything is
// written to standard output in the order it happens: the report of each
// failed expectation, then the verdict of its test, and at the end the
// totals.

namespace Progmasoft::Tala::Runtime::Testing
{
    namespace
    {
        // A process that hosts generated code runs one program at a time
        // on one thread.
        // NOLINTBEGIN(cppcoreguidelines-avoid-non-const-global-variables)
        std::uint64_t currentFailures = 0U;
        std::uint64_t passedTests = 0U;
        std::uint64_t failedTests = 0U;
        // NOLINTEND(cppcoreguidelines-avoid-non-const-global-variables)

        /// Write an ASCII literal, which is its own scalars, to standard
        /// output. The length comes from the array type, so nothing scans
        /// for the terminator: the runtime library links without the C
        /// library on Windows, where that scan would be a call to strlen.
        template<std::size_t Size>
        void
        Write(const char (&text)[Size], const bool line) noexcept
        {
            static_assert(Size >= 2U && Size <= 65U,
                          "a reporter message holds 1 to 64 characters");
            constexpr std::size_t count = Size - 1U;
            char32_t scalars[count];
            for (std::size_t index = 0U; index < count; ++index)
                scalars[index] = static_cast<char32_t>(text[index]);
            auto *string = Aarc::MakeString(scalars, count);
            if (string == nullptr)
                Platform::Fail();
            tala_console_write(string,
                               line ? TALA_CONSOLE_OUTPUT_LINE
                                    : TALA_CONSOLE_OUTPUT);
            tala_aarc_release_strong(string);
        }

        void
        WriteCount(const std::uint64_t value) noexcept
        {
            auto *string = tala_text_from_unsigned(value);
            tala_console_write(string, TALA_CONSOLE_OUTPUT);
            tala_aarc_release_strong(string);
        }
    } // namespace

    auto
    Status() noexcept -> std::int32_t
    {
        return failedTests == 0U ? 0 : 1;
    }

    void
    Reset() noexcept
    {
        currentFailures = 0U;
        passedTests = 0U;
        failedTests = 0U;
    }
} // namespace Progmasoft::Tala::Runtime::Testing

extern "C"
{
    void
    tala_test_fail(void *report) noexcept
    {
        using namespace Progmasoft::Tala::Runtime::Testing;
        ++currentFailures;
        tala_console_write(report, TALA_CONSOLE_OUTPUT_LINE);
    }

    void
    tala_test_end(void *name) noexcept
    {
        using namespace Progmasoft::Tala::Runtime::Testing;
        if (currentFailures == 0U)
        {
            ++passedTests;
            Write("PASS ", false);
            tala_console_write(name, TALA_CONSOLE_OUTPUT_LINE);
        }
        else
        {
            ++failedTests;
            Write("FAIL ", false);
            tala_console_write(name, TALA_CONSOLE_OUTPUT);
            Write(" (", false);
            WriteCount(currentFailures);
            if (currentFailures == 1U)
                Write(" failed expectation)", true);
            else
                Write(" failed expectations)", true);
        }
        currentFailures = 0U;
    }

    void
    tala_test_finish() noexcept
    {
        using namespace Progmasoft::Tala::Runtime::Testing;
        WriteCount(passedTests + failedTests);
        if (passedTests + failedTests == 1U)
            Write(" test, ", false);
        else
            Write(" tests, ", false);
        WriteCount(passedTests);
        Write(" passed, ", false);
        WriteCount(failedTests);
        Write(" failed", true);
    }

    auto
    tala_test_status() noexcept -> std::int32_t
    {
        return Progmasoft::Tala::Runtime::Testing::Status();
    }
}
