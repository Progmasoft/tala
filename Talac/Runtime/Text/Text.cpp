// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include "Format.hpp"
#include "Platform.hpp"
#include "Progmasoft/Tala/Runtime/AARC.hpp"
#include "Progmasoft/Tala/Runtime/Text.h"
#include "Scalars.hpp"

// The C entry points of the text runtime. Each builds its result in a
// sequence of scalars and hands it to the ownership runtime as a string.

namespace Progmasoft::Tala::Runtime::Text
{
    namespace
    {
        constexpr char32_t kReplacement = U'\xfffd';

        /// The string that holds the scalars, owned by the caller. The
        /// program stops when the string cannot be allocated: a text
        /// routine has no way to report failure, and a null result would
        /// only move the failure to whoever reads it.
        [[nodiscard]] auto
        Finish(const Scalars &scalars) noexcept -> void *
        {
            auto *string = Aarc::MakeString(scalars.Data(), scalars.Size());
            if (string == nullptr)
                Platform::Fail();
            return string;
        }

        [[nodiscard]] auto
        ConversionOf(const std::int64_t flags,
                     const std::int64_t width,
                     const std::int64_t precision) noexcept -> Conversion
        {
            return { flags, width, precision };
        }

        /// A `char` holds a Unicode scalar value. Storage that holds
        /// something else is written as the replacement character rather
        /// than put into a string, which admits scalar values only.
        [[nodiscard]] auto
        Scalar(const std::uint32_t value) noexcept -> char32_t
        {
            return value > 0x10ffffU || (value >= 0xd800U && value <= 0xdfffU)
                       ? kReplacement
                       : static_cast<char32_t>(value);
        }

        [[nodiscard]] auto
        Magnitude(const std::int64_t value) noexcept -> std::uint64_t
        {
            // Negating in unsigned arithmetic gives the magnitude of the
            // least value as well, which has no positive counterpart.
            return value < 0
                       ? std::uint64_t{ 0U } - static_cast<std::uint64_t>(value)
                       : static_cast<std::uint64_t>(value);
        }
    } // namespace
} // namespace Progmasoft::Tala::Runtime::Text

extern "C"
{
    auto
    tala_text_equals(void *left, void *right) noexcept -> bool
    {
        using namespace Progmasoft::Tala::Runtime;
        const auto first = Aarc::ViewString(left);
        const auto second = Aarc::ViewString(right);
        if (first.count != second.count)
            return false;
        for (std::size_t index = 0U; index < first.count; ++index)
            if (first.scalars[index] != second.scalars[index])
                return false;
        return true;
    }

    auto
    tala_text_concat(void *left, void *right) noexcept -> void *
    {
        using namespace Progmasoft::Tala::Runtime;
        const auto first = Aarc::ViewString(left);
        const auto second = Aarc::ViewString(right);
        Text::Scalars scalars;
        scalars.Append(first.scalars, first.count);
        scalars.Append(second.scalars, second.count);
        return Text::Finish(scalars);
    }

    auto
    tala_text_from_signed(const std::int64_t value) noexcept -> void *
    {
        using namespace Progmasoft::Tala::Runtime;
        Text::Scalars scalars;
        Text::AppendInteger(scalars, value < 0, Text::Magnitude(value), {});
        return Text::Finish(scalars);
    }

    auto
    tala_text_from_unsigned(const std::uint64_t value) noexcept -> void *
    {
        using namespace Progmasoft::Tala::Runtime;
        Text::Scalars scalars;
        Text::AppendInteger(scalars, false, value, {});
        return Text::Finish(scalars);
    }

    auto
    tala_text_from_bool(const bool value) noexcept -> void *
    {
        using namespace Progmasoft::Tala::Runtime;
        Text::Scalars scalars;
        scalars.AppendAscii(value ? "true" : "false");
        return Text::Finish(scalars);
    }

    auto
    tala_text_from_char(const std::uint32_t value) noexcept -> void *
    {
        using namespace Progmasoft::Tala::Runtime;
        Text::Scalars scalars;
        scalars.Append(Text::Scalar(value));
        return Text::Finish(scalars);
    }

    auto
    tala_text_format_signed(const std::int64_t flags,
                            const std::int64_t width,
                            const std::int64_t precision,
                            const std::int64_t value) noexcept -> void *
    {
        using namespace Progmasoft::Tala::Runtime;
        Text::Scalars scalars;
        Text::AppendInteger(scalars,
                            value < 0,
                            Text::Magnitude(value),
                            Text::ConversionOf(flags, width, precision));
        return Text::Finish(scalars);
    }

    auto
    tala_text_format_unsigned(const std::int64_t flags,
                              const std::int64_t width,
                              const std::int64_t precision,
                              const std::uint64_t value) noexcept -> void *
    {
        using namespace Progmasoft::Tala::Runtime;
        Text::Scalars scalars;
        Text::AppendInteger(scalars,
                            false,
                            value,
                            Text::ConversionOf(flags, width, precision));
        return Text::Finish(scalars);
    }

    auto
    tala_text_format_floating(const std::int64_t flags,
                              const std::int64_t width,
                              const std::int64_t precision,
                              const double value) noexcept -> void *
    {
        using namespace Progmasoft::Tala::Runtime;
        Text::Scalars scalars;
        Text::AppendFloating(scalars,
                             value,
                             Text::ConversionOf(flags, width, precision));
        return Text::Finish(scalars);
    }

    auto
    tala_text_format_string(const std::int64_t flags,
                            const std::int64_t width,
                            const std::int64_t precision,
                            void *value) noexcept -> void *
    {
        using namespace Progmasoft::Tala::Runtime;
        const auto view = Aarc::ViewString(value);
        Text::Scalars scalars;
        Text::AppendText(scalars,
                         view.scalars,
                         view.count,
                         Text::ConversionOf(flags, width, precision));
        return Text::Finish(scalars);
    }

    auto
    tala_text_format_char(const std::int64_t flags,
                          const std::int64_t width,
                          const std::int64_t precision,
                          const std::uint32_t value) noexcept -> void *
    {
        using namespace Progmasoft::Tala::Runtime;
        const auto scalar = Text::Scalar(value);
        Text::Scalars scalars;
        // A character has no precision; the argument is there so that every
        // conversion has one signature.
        static_cast<void>(precision);
        Text::AppendText(scalars,
                         &scalar,
                         1U,
                         Text::ConversionOf(flags, width, TALA_TEXT_ABSENT));
        return Text::Finish(scalars);
    }

    auto
    tala_text_newline() noexcept -> void *
    {
        using namespace Progmasoft::Tala::Runtime;
        Text::Scalars scalars;
        scalars.AppendAscii(Platform::LineTerminator());
        return Text::Finish(scalars);
    }
}
