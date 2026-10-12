// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <string_view>
#include <vector>

#include "Progmasoft/Tala/Runtime/AARC.hpp"
#include "Progmasoft/Tala/Runtime/Text.hpp"

// The text and console runtime, called the way generated code calls it:
// through its C entry points, with strings that are objects of the ownership
// runtime. Each expected text is written by hand, or, for the digits of a
// floating-point number, taken from the C library of the host, which
// produces the exact decimal expansion too and shares no code with the
// runtime.
//
// Every case releases what it was given, and the last case of the file
// checks that the runtime holds no more objects than before the first.

namespace
{
    namespace Aarc = Progmasoft::Tala::Runtime::Aarc;
    namespace Console = Progmasoft::Tala::Runtime::Console;

    /// The scalars of a string as UTF-32, and the string released.
    [[nodiscard]] auto
    Take(void *string) -> std::u32string
    {
        REQUIRE(string != nullptr);
        const auto view = Aarc::ViewString(string);
        std::u32string scalars(view.scalars, view.count);
        tala_aarc_release_strong(string);
        return scalars;
    }

    /// An ASCII text as the UTF-32 the runtime works in.
    [[nodiscard]] auto
    Wide(std::string_view text) -> std::u32string
    {
        std::u32string scalars;
        for (const auto character : text)
            scalars.push_back(
                static_cast<char32_t>(static_cast<unsigned char>(character)));
        return scalars;
    }

    [[nodiscard]] auto
    Make(std::u32string_view scalars) -> void *
    {
        auto *string = Aarc::MakeString(scalars.data(), scalars.size());
        REQUIRE(string != nullptr);
        return string;
    }

    [[nodiscard]] auto
    Signed(std::int64_t value,
           std::int64_t flags = 0,
           std::int64_t width = TALA_TEXT_ABSENT) -> std::u32string
    {
        return Take(
            tala_text_format_signed(flags, width, TALA_TEXT_ABSENT, value));
    }

    [[nodiscard]] auto
    Unsigned(std::uint64_t value,
             std::int64_t flags = 0,
             std::int64_t width = TALA_TEXT_ABSENT) -> std::u32string
    {
        return Take(
            tala_text_format_unsigned(flags, width, TALA_TEXT_ABSENT, value));
    }

    [[nodiscard]] auto
    Floating(double value,
             std::int64_t precision = TALA_TEXT_ABSENT,
             std::int64_t flags = 0,
             std::int64_t width = TALA_TEXT_ABSENT) -> std::u32string
    {
        return Take(tala_text_format_floating(flags, width, precision, value));
    }

    [[nodiscard]] auto
    Text(std::u32string_view value,
         std::int64_t flags = 0,
         std::int64_t width = TALA_TEXT_ABSENT,
         std::int64_t precision = TALA_TEXT_ABSENT) -> std::u32string
    {
        auto *string = Make(value);
        auto result
            = Take(tala_text_format_string(flags, width, precision, string));
        tala_aarc_release_strong(string);
        return result;
    }

    /// What the C library of the host writes for `%.*f`.
    [[nodiscard]] auto
    HostFixed(double value, int precision) -> std::u32string
    {
        std::string buffer(2048U, '\0');
        const auto written = std::snprintf(buffer.data(),
                                           buffer.size(),
                                           "%.*f",
                                           precision,
                                           value);
        REQUIRE(written > 0);
        REQUIRE(static_cast<std::size_t>(written) < buffer.size());
        buffer.resize(static_cast<std::size_t>(written));
        return Wide(buffer);
    }

    /// Writes one integer with the C library of the host: the buffer, its
    /// size, a width and the value.
    template<typename Integer>
    using HostPrint = int (*)(char *, std::size_t, int, Integer);

    /// A row of a comparison with the host: the flags the runtime is given
    /// and the conversion of the C library that means the same. The format
    /// is a literal where it is used, so the compiler checks it.
#define HOST_ROW(Integer, flags, format)                                       \
    { (flags),                                                                 \
      (format),                                                                \
      [](char *buffer, std::size_t size, int width, Integer value) {           \
          return std::snprintf(buffer, size, (format), width, value);          \
      } }

    template<typename Integer>
    struct HostRow final
    {
        std::int64_t flags;
        const char *format;
        HostPrint<Integer> print;
    };

    /// What the C library of the host writes for one integer conversion.
    template<typename Integer>
    [[nodiscard]] auto
    HostInteger(HostPrint<Integer> print, int width, Integer value)
        -> std::u32string
    {
        std::string buffer(128U, '\0');
        const auto written = print(buffer.data(), buffer.size(), width, value);
        REQUIRE(written > 0);
        REQUIRE(static_cast<std::size_t>(written) < buffer.size());
        buffer.resize(static_cast<std::size_t>(written));
        return Wide(buffer);
    }

    /// A sequence of 64-bit values that is the same on every run.
    class Sequence final
    {
    public:
        [[nodiscard]] auto
        Next() noexcept -> std::uint64_t
        {
            state += 0x9e3779b97f4a7c15ULL;
            auto value = state;
            value = (value ^ (value >> 30U)) * 0xbf58476d1ce4e5b9ULL;
            value = (value ^ (value >> 27U)) * 0x94d049bb133111ebULL;
            return value ^ (value >> 31U);
        }

    private:
        std::uint64_t state{ 0x5eedULL };
    };

    /// Values of every magnitude: each draw is cut to a number of bits that
    /// is drawn as well, so that small numbers are as frequent as large.
    [[nodiscard]] auto
    Magnitudes(std::size_t count) -> std::vector<std::uint64_t>
    {
        Sequence sequence;
        std::vector<std::uint64_t> values{
            0U,
            1U,
            9U,
            10U,
            999U,
            1000U,
            std::numeric_limits<std::uint64_t>::max(),
            static_cast<std::uint64_t>(
                std::numeric_limits<std::int64_t>::max()),
            static_cast<std::uint64_t>(
                std::numeric_limits<std::int64_t>::min()),
        };
        while (values.size() < count)
        {
            const auto bits = 1U + static_cast<unsigned>(sequence.Next() % 64U);
            values.push_back(sequence.Next() >> (64U - bits));
        }
        return values;
    }

    /// The bytes one sink received, by stream.
    struct Captured final
    {
        std::string output;
        std::string error;
        std::size_t deliveries{};
    };

    void
    Receive(std::int64_t stream,
            const char *bytes,
            std::size_t count,
            void *context) noexcept
    {
        auto *captured = static_cast<Captured *>(context);
        (stream == TALA_CONSOLE_ERROR ? captured->error : captured->output)
            .append(bytes, count);
        ++captured->deliveries;
    }

    /// Writes a string to a target with the sink installed.
    [[nodiscard]] auto
    Write(std::u32string_view scalars, std::int64_t target) -> Captured
    {
        Captured captured;
        Console::SetSink(Receive, &captured);
        auto *string = Make(scalars);
        tala_console_write(string, target);
        tala_aarc_release_strong(string);
        Console::SetSink(nullptr, nullptr);
        return captured;
    }

#ifdef _WIN32
    constexpr std::string_view kLine = "\r\n";
#else
    constexpr std::string_view kLine = "\n";
#endif

    // What the runtime held before the first case of this file ran.
    // NOLINTNEXTLINE(cppcoreguidelines-avoid-non-const-global-variables)
    const auto liveAtStart = Aarc::LiveAllocations();
} // namespace

TEST_CASE("an integer is written in decimal with its sign")
{
    CHECK(Take(tala_text_from_signed(0)) == U"0");
    CHECK(Take(tala_text_from_signed(42)) == U"42");
    CHECK(Take(tala_text_from_signed(-42)) == U"-42");
    CHECK(Take(tala_text_from_signed(std::numeric_limits<std::int64_t>::max()))
          == U"9223372036854775807");
    // The least value has no positive counterpart; its magnitude is still
    // written whole.
    CHECK(Take(tala_text_from_signed(std::numeric_limits<std::int64_t>::min()))
          == U"-9223372036854775808");
    CHECK(Take(tala_text_from_unsigned(0U)) == U"0");
    CHECK(
        Take(tala_text_from_unsigned(std::numeric_limits<std::uint64_t>::max()))
        == U"18446744073709551615");
}

TEST_CASE("a Boolean is written as a word and a character as itself")
{
    CHECK(Take(tala_text_from_bool(true)) == U"true");
    CHECK(Take(tala_text_from_bool(false)) == U"false");
    CHECK(Take(tala_text_from_char(U'a')) == U"a");
    CHECK(Take(tala_text_from_char(0x1f600U))
          == std::u32string(1U, U'\U0001f600'));
    CHECK(Take(tala_text_from_char(0U)) == std::u32string(1U, U'\0'));
}

TEST_CASE("storage that is not a scalar value is written as the replacement "
          "character")
{
    CHECK(Take(tala_text_from_char(0xd800U)) == U"\xfffd");
    CHECK(Take(tala_text_from_char(0xdfffU)) == U"\xfffd");
    CHECK(Take(tala_text_from_char(0x110000U)) == U"\xfffd");
    CHECK(Take(tala_text_format_char(0, 3, TALA_TEXT_ABSENT, 0xffffffffU))
          == U"  \xfffd");
}

TEST_CASE("two strings are joined in order")
{
    auto *left = Make(U"Hello, ");
    auto *right = Make(U"world");
    auto *empty = Make(U"");
    CHECK(Take(tala_text_concat(left, right)) == U"Hello, world");
    CHECK(Take(tala_text_concat(right, left)) == U"worldHello, ");
    CHECK(Take(tala_text_concat(left, empty)) == U"Hello, ");
    CHECK(Take(tala_text_concat(empty, empty)).empty());
    // The operands are borrowed: they are what they were.
    CHECK(Take(tala_text_concat(left, left)) == U"Hello, Hello, ");
    tala_aarc_release_strong(left);
    tala_aarc_release_strong(right);
    tala_aarc_release_strong(empty);
}

TEST_CASE("a string that is not there is the empty string")
{
    auto *text = Make(U"kept");
    CHECK(Take(tala_text_concat(nullptr, text)) == U"kept");
    CHECK(Take(tala_text_concat(text, nullptr)) == U"kept");
    CHECK(Take(tala_text_concat(nullptr, nullptr)).empty());
    CHECK(tala_text_equals(nullptr, nullptr));
    CHECK_FALSE(tala_text_equals(nullptr, text));
    CHECK(Take(tala_text_format_string(0, 4, TALA_TEXT_ABSENT, nullptr))
          == U"    ");
    tala_aarc_release_strong(text);
}

TEST_CASE("a long result leaves the buffer it started in")
{
    // Longer than what a result keeps in place before it allocates.
    std::u32string longText(1000U, U'x');
    auto *left = Make(longText);
    auto *right = Make(longText);
    const auto joined = Take(tala_text_concat(left, right));
    CHECK(joined.size() == 2000U);
    CHECK(joined == longText + longText);
    tala_aarc_release_strong(left);
    tala_aarc_release_strong(right);
    CHECK(Signed(7, 0, 500).size() == 500U);
    CHECK(Signed(7, 0, 500).back() == U'7');
    CHECK(Signed(7, TALA_TEXT_FLAG_ZERO, 500)
          == std::u32string(499U, U'0') + U"7");
}

TEST_CASE("strings are compared by the scalars they hold")
{
    auto *first = Make(U"same");
    auto *second = Make(U"same");
    auto *shorter = Make(U"sam");
    auto *other = Make(U"sane");
    CHECK(first != second);
    CHECK(tala_text_equals(first, second));
    CHECK(tala_text_equals(first, first));
    CHECK_FALSE(tala_text_equals(first, shorter));
    CHECK_FALSE(tala_text_equals(shorter, first));
    CHECK_FALSE(tala_text_equals(first, other));
    for (auto *string : { first, second, shorter, other })
        tala_aarc_release_strong(string);
}

TEST_CASE("%d pads to its width at the left, the right, or with zeros")
{
    CHECK(Signed(42, 0, 5) == U"   42");
    CHECK(Signed(42, TALA_TEXT_FLAG_LEFT, 5) == U"42   ");
    CHECK(Signed(42, TALA_TEXT_FLAG_ZERO, 5) == U"00042");
    CHECK(Signed(-42, 0, 5) == U"  -42");
    CHECK(Signed(-42, TALA_TEXT_FLAG_LEFT, 5) == U"-42  ");
    // Zeros stand after the sign.
    CHECK(Signed(-42, TALA_TEXT_FLAG_ZERO, 5) == U"-0042");
    // A width the number already fills adds nothing, and neither does one
    // that is absent, zero or negative.
    CHECK(Signed(12345, 0, 2) == U"12345");
    CHECK(Signed(42, 0, 0) == U"42");
    CHECK(Signed(42, 0, -7) == U"42");
    CHECK(Signed(42, TALA_TEXT_FLAG_ZERO, 2) == U"42");
}

TEST_CASE("%d writes a sign for a number that is not negative when asked")
{
    CHECK(Signed(42, TALA_TEXT_FLAG_PLUS) == U"+42");
    CHECK(Signed(0, TALA_TEXT_FLAG_PLUS) == U"+0");
    CHECK(Signed(-42, TALA_TEXT_FLAG_PLUS) == U"-42");
    CHECK(Signed(42, TALA_TEXT_FLAG_SPACE) == U" 42");
    CHECK(Signed(-42, TALA_TEXT_FLAG_SPACE) == U"-42");
    CHECK(Signed(42, TALA_TEXT_FLAG_PLUS | TALA_TEXT_FLAG_ZERO, 6)
          == U"+00042");
    CHECK(Signed(42, TALA_TEXT_FLAG_PLUS, 6) == U"   +42");
}

TEST_CASE("the ' flag groups decimal digits in threes")
{
    CHECK(Signed(0, TALA_TEXT_FLAG_GROUP) == U"0");
    CHECK(Signed(123, TALA_TEXT_FLAG_GROUP) == U"123");
    CHECK(Signed(1234, TALA_TEXT_FLAG_GROUP) == U"1'234");
    CHECK(Signed(123456, TALA_TEXT_FLAG_GROUP) == U"123'456");
    CHECK(Signed(1234567, TALA_TEXT_FLAG_GROUP) == U"1'234'567");
    CHECK(Signed(-1234567, TALA_TEXT_FLAG_GROUP) == U"-1'234'567");
    CHECK(Signed(std::numeric_limits<std::int64_t>::min(), TALA_TEXT_FLAG_GROUP)
          == U"-9'223'372'036'854'775'808");
    CHECK(Unsigned(std::numeric_limits<std::uint64_t>::max(),
                   TALA_TEXT_FLAG_GROUP)
          == U"18'446'744'073'709'551'615");
    CHECK(Signed(1234567, TALA_TEXT_FLAG_GROUP, 12) == U"   1'234'567");
}

TEST_CASE("%x writes a magnitude in lowercase hexadecimal")
{
    constexpr auto kHex = TALA_TEXT_FLAG_HEXADECIMAL;
    CHECK(Signed(0, kHex) == U"0");
    CHECK(Signed(255, kHex) == U"ff");
    CHECK(Signed(48879, kHex) == U"beef");
    // A negative number is a sign and its magnitude, never the bit pattern
    // of its representation.
    CHECK(Signed(-255, kHex) == U"-ff");
    CHECK(Signed(-1, kHex) == U"-1");
    CHECK(Signed(std::numeric_limits<std::int64_t>::min(), kHex)
          == U"-8000000000000000");
    CHECK(Unsigned(std::numeric_limits<std::uint64_t>::max(), kHex)
          == U"ffffffffffffffff");
    CHECK(Signed(255, kHex | TALA_TEXT_FLAG_ALTERNATE) == U"0xff");
    CHECK(Signed(-255, kHex | TALA_TEXT_FLAG_ALTERNATE) == U"-0xff");
    // Zeros stand after the sign and the prefix.
    CHECK(Signed(255, kHex | TALA_TEXT_FLAG_ALTERNATE | TALA_TEXT_FLAG_ZERO, 8)
          == U"0x0000ff");
    CHECK(Signed(255, kHex | TALA_TEXT_FLAG_ZERO, 8) == U"000000ff");
    CHECK(Signed(255, kHex, 6) == U"    ff");
    // Grouping is a flag of the decimal conversions.
    CHECK(Signed(0x1234567, kHex | TALA_TEXT_FLAG_GROUP) == U"1234567");
}

TEST_CASE("%s pads, and keeps at most its precision of characters")
{
    CHECK(Text(U"abc") == U"abc");
    CHECK(Text(U"abc", 0, 6) == U"   abc");
    CHECK(Text(U"abc", TALA_TEXT_FLAG_LEFT, 6) == U"abc   ");
    CHECK(Text(U"abcdef", 0, TALA_TEXT_ABSENT, 2) == U"ab");
    CHECK(Text(U"abc", 0, TALA_TEXT_ABSENT, 5) == U"abc");
    CHECK(Text(U"abc", 0, TALA_TEXT_ABSENT, 0).empty());
    CHECK(Text(U"abcdef", 0, 5, 1) == U"    a");
    // Zeros are for numbers; a string is padded with spaces whatever the
    // flag says.
    CHECK(Text(U"abc", TALA_TEXT_FLAG_ZERO, 6) == U"   abc");
    CHECK(Text(U"", 0, 3) == U"   ");
}

TEST_CASE("width and precision count characters, not bytes")
{
    // Three characters that take two, three and four bytes in UTF-8.
    const std::u32string mixed{ U'\xe9', U'\x20ac', U'\U0001f600' };
    CHECK(Text(mixed, 0, 5) == U"  " + mixed);
    CHECK(Text(mixed, 0, TALA_TEXT_ABSENT, 2) == mixed.substr(0U, 2U));
    CHECK(Take(tala_text_format_char(0, 3, TALA_TEXT_ABSENT, 0x20acU))
          == std::u32string(U"  ") + U'\x20ac');
    CHECK(Take(tala_text_format_char(TALA_TEXT_FLAG_LEFT,
                                     3,
                                     TALA_TEXT_ABSENT,
                                     U'q'))
          == U"q  ");
}

TEST_CASE("%f writes six digits after the point unless told otherwise")
{
    CHECK(Floating(0.0) == U"0.000000");
    CHECK(Floating(1.0) == U"1.000000");
    CHECK(Floating(12.5) == U"12.500000");
    CHECK(Floating(-12.5) == U"-12.500000");
    CHECK(Floating(12.5, 2) == U"12.50");
    CHECK(Floating(12.5, 0) == U"12");
    CHECK(Floating(3.14159, 3) == U"3.142");
    CHECK(Floating(1e6, 1) == U"1000000.0");
    CHECK(Floating(123456789.0, 0) == U"123456789");
}

TEST_CASE("%f rounds the exact value, a tie to the even digit")
{
    // These values are exact in binary, so the tie is real.
    CHECK(Floating(0.5, 0) == U"0");
    CHECK(Floating(1.5, 0) == U"2");
    CHECK(Floating(2.5, 0) == U"2");
    CHECK(Floating(3.5, 0) == U"4");
    CHECK(Floating(0.125, 2) == U"0.12");
    CHECK(Floating(0.375, 2) == U"0.38");
    CHECK(Floating(0.25, 1) == U"0.2");
    CHECK(Floating(0.75, 1) == U"0.8");
    CHECK(Floating(-2.5, 0) == U"-2");
    // 0.1 is not exact: it lies above one tenth, which its digits show.
    CHECK(Floating(0.1, 20) == U"0.10000000000000000555");
    CHECK(Floating(0.1, 1) == U"0.1");
    CHECK(Floating(0.15, 1) == U"0.1");
    CHECK(Floating(0.25, 0) == U"0");
    // Rounding carries into the integer part.
    CHECK(Floating(9.999, 2) == U"10.00");
    CHECK(Floating(0.999, 0) == U"1");
    CHECK(Floating(99.5, 0) == U"100");
}

TEST_CASE("%f keeps the sign of a negative zero and of what rounds to zero")
{
    CHECK(Floating(-0.0) == U"-0.000000");
    CHECK(Floating(-0.0, 0) == U"-0");
    CHECK(Floating(-0.001, 1) == U"-0.0");
    CHECK(Floating(0.0, 0, TALA_TEXT_FLAG_PLUS) == U"+0");
}

TEST_CASE("%f pads, signs and groups like the integer conversions")
{
    CHECK(Floating(3.14159, 3, 0, 10) == U"     3.142");
    CHECK(Floating(3.14159, 3, TALA_TEXT_FLAG_LEFT, 10) == U"3.142     ");
    CHECK(Floating(3.14159, 3, TALA_TEXT_FLAG_ZERO, 10) == U"000003.142");
    CHECK(Floating(-3.14159, 3, TALA_TEXT_FLAG_ZERO, 10) == U"-00003.142");
    CHECK(Floating(1.5, 1, TALA_TEXT_FLAG_PLUS) == U"+1.5");
    CHECK(Floating(1.5, 1, TALA_TEXT_FLAG_SPACE) == U" 1.5");
    // Only the integer digits are grouped.
    CHECK(Floating(1234567.5, 2, TALA_TEXT_FLAG_GROUP) == U"1'234'567.50");
    CHECK(Floating(1234.56789, 5, TALA_TEXT_FLAG_GROUP) == U"1'234.56789");
    CHECK(Floating(999.5, 0, TALA_TEXT_FLAG_GROUP) == U"1'000");
}

TEST_CASE("%f writes what is not a finite number as a word")
{
    const auto infinity = std::numeric_limits<double>::infinity();
    const auto notANumber = std::numeric_limits<double>::quiet_NaN();
    CHECK(Floating(infinity) == U"inf");
    CHECK(Floating(-infinity) == U"-inf");
    CHECK(Floating(notANumber) == U"nan");
    CHECK(Floating(infinity, TALA_TEXT_ABSENT, TALA_TEXT_FLAG_PLUS) == U"+inf");
    // A word is padded with spaces, also where a number would get zeros.
    CHECK(Floating(infinity, TALA_TEXT_ABSENT, TALA_TEXT_FLAG_ZERO, 6)
          == U"   inf");
    CHECK(Floating(notANumber, 2, TALA_TEXT_FLAG_LEFT, 5) == U"nan  ");
}

TEST_CASE("%f writes every digit of the extremes of the type")
{
    const auto least = std::numeric_limits<double>::denorm_min();
    const auto greatest = std::numeric_limits<double>::max();
    // The least positive value has 1074 digits after the point, the last of
    // which is not zero; one more digit is a zero.
    const auto digits = Floating(least, 1074);
    CHECK(digits.size() == 1076U);
    CHECK(digits.substr(0U, 10U) == U"0.00000000");
    CHECK(digits.back() == U'5');
    CHECK(Floating(least, 1075).back() == U'0');
    CHECK(Floating(least, 1075).substr(0U, 1076U) == digits);
    CHECK(Floating(least, 1100).size() == 1102U);
    CHECK(Floating(least) == U"0.000000");
    // The greatest value has 309 digits before the point and is an integer.
    const auto whole = Floating(greatest, 0);
    CHECK(whole.size() == 309U);
    CHECK(whole.substr(0U, 17U) == U"17976931348623157");
    CHECK(Floating(greatest, 2).substr(309U) == U".00");
    CHECK(Floating(-greatest, 0) == U"-" + whole);
}

TEST_CASE("%f agrees with the C library of the host")
{
    // The library of the host writes the correctly rounded expansion of the
    // exact value as well; the two are independent implementations.
    const std::vector<double> values{ 0.0,
                                      1.0,
                                      0.1,
                                      0.2,
                                      0.3,
                                      1.0 / 3.0,
                                      2.0 / 3.0,
                                      1e-5,
                                      1e-10,
                                      1e-20,
                                      123.456,
                                      1e15,
                                      1e16,
                                      1e17,
                                      1e22,
                                      1e23,
                                      9.87654321e30,
                                      5e-324,
                                      2.2250738585072014e-308,
                                      1.7976931348623157e308,
                                      4.35,
                                      0.045,
                                      1.005,
                                      2.675,
                                      1234567.891,
                                      0.000123456789,
                                      8.5,
                                      1e100,
                                      3.0e-7,
                                      0.5e-6,
                                      1.9999999,
                                      65536.0,
                                      4294967296.5,
                                      0.999999999999999889 };
    for (const auto value : values)
        for (const int precision : { 0, 1, 2, 3, 6, 9, 15, 17, 20, 40 })
        {
            CAPTURE(value, precision);
            CHECK(Floating(value, precision) == HostFixed(value, precision));
            CHECK(Floating(-value, precision) == HostFixed(-value, precision));
        }
}

TEST_CASE("%f agrees with the host over a sweep of binary exponents")
{
    // One value in every tenth binade, with a significand that uses all of
    // its bits, so that the scaling and the rounding meet every size of
    // number.
    for (int exponent = -1070; exponent <= 1020; exponent += 10)
    {
        const auto value = std::ldexp(1.2345678901234567, exponent);
        for (const int precision : { 0, 3, 12, 30 })
        {
            CAPTURE(exponent, precision);
            CHECK(Floating(value, precision) == HostFixed(value, precision));
        }
    }
}

TEST_CASE("%d agrees with the C library of the host over many values")
{
    const HostRow<long long> kRows[] = {
        HOST_ROW(long long, 0, "%*lld"),
        HOST_ROW(long long, TALA_TEXT_FLAG_LEFT, "%-*lld"),
        HOST_ROW(long long, TALA_TEXT_FLAG_ZERO, "%0*lld"),
        HOST_ROW(long long, TALA_TEXT_FLAG_PLUS, "%+*lld"),
        HOST_ROW(long long, TALA_TEXT_FLAG_SPACE, "% *lld"),
        HOST_ROW(long long,
                 TALA_TEXT_FLAG_PLUS | TALA_TEXT_FLAG_ZERO,
                 "%+0*lld"),
        HOST_ROW(long long,
                 TALA_TEXT_FLAG_SPACE | TALA_TEXT_FLAG_ZERO,
                 "% 0*lld"),
        HOST_ROW(long long,
                 TALA_TEXT_FLAG_PLUS | TALA_TEXT_FLAG_LEFT,
                 "%-+*lld"),
        HOST_ROW(long long,
                 TALA_TEXT_FLAG_SPACE | TALA_TEXT_FLAG_LEFT,
                 "%- *lld"),
    };
    std::size_t compared = 0U;
    for (const auto magnitude : Magnitudes(400U))
    {
        const auto value = static_cast<std::int64_t>(magnitude);
        for (const auto &row : kRows)
        {
            for (const int width : { 0, 1, 7, 19, 20, 21, 40 })
            {
                const auto written = Signed(value, row.flags, width);
                const auto expected
                    = HostInteger(row.print,
                                  width,
                                  static_cast<long long>(value));
                if (written != expected)
                {
                    CAPTURE(value);
                    CAPTURE(row.format);
                    CAPTURE(width);
                    CHECK(written == expected);
                }
                ++compared;
            }
        }
    }
    CHECK(compared == std::size_t{ 25200U });
}

TEST_CASE("%u and %x agree with the C library of the host over many values")
{
    const HostRow<unsigned long long> kRows[] = {
        HOST_ROW(unsigned long long, 0, "%*llu"),
        HOST_ROW(unsigned long long, TALA_TEXT_FLAG_LEFT, "%-*llu"),
        HOST_ROW(unsigned long long, TALA_TEXT_FLAG_ZERO, "%0*llu"),
        HOST_ROW(unsigned long long, TALA_TEXT_FLAG_HEXADECIMAL, "%*llx"),
        HOST_ROW(unsigned long long,
                 TALA_TEXT_FLAG_HEXADECIMAL | TALA_TEXT_FLAG_LEFT,
                 "%-*llx"),
        HOST_ROW(unsigned long long,
                 TALA_TEXT_FLAG_HEXADECIMAL | TALA_TEXT_FLAG_ZERO,
                 "%0*llx"),
    };
    std::size_t compared = 0U;
    for (const auto value : Magnitudes(400U))
    {
        for (const auto &row : kRows)
        {
            for (const int width : { 0, 1, 7, 16, 17, 20, 21, 40 })
            {
                const auto written = Unsigned(value, row.flags, width);
                const auto expected
                    = HostInteger(row.print,
                                  width,
                                  static_cast<unsigned long long>(value));
                if (written != expected)
                {
                    CAPTURE(value);
                    CAPTURE(row.format);
                    CAPTURE(width);
                    CHECK(written == expected);
                }
                ++compared;
            }
        }
    }
    CHECK(compared == std::size_t{ 19200U });
}

TEST_CASE("grouping only adds apostrophes, every third digit from the right")
{
    for (const auto value : Magnitudes(400U))
    {
        const auto plain = Unsigned(value);
        const auto grouped = Unsigned(value, TALA_TEXT_FLAG_GROUP);
        std::u32string rebuilt;
        for (std::size_t index = 0U; index < plain.size(); ++index)
        {
            if (index != 0U && (plain.size() - index) % 3U == 0U)
                rebuilt.push_back(U'\'');
            rebuilt.push_back(plain[index]);
        }
        if (grouped != rebuilt)
        {
            CAPTURE(value);
            CHECK(grouped == rebuilt);
        }
        // A sign stands before the first group and is not counted in it.
        const auto negative = -static_cast<std::int64_t>(value >> 1U);
        if (negative != 0)
        {
            const auto signedGrouped = Signed(negative, TALA_TEXT_FLAG_GROUP);
            const auto magnitude = Unsigned(value >> 1U, TALA_TEXT_FLAG_GROUP);
            if (signedGrouped != U"-" + magnitude)
            {
                CAPTURE(negative);
                CHECK(signedGrouped == U"-" + magnitude);
            }
        }
    }
}

TEST_CASE("%f agrees with the host over numbers drawn from every exponent")
{
    // Any bit pattern that is a finite number: the sign, the exponent and
    // the fraction are all drawn, so subnormal numbers, numbers with
    // hundreds of digits before the point and numbers with hundreds of
    // zeros after it all occur.
    Sequence sequence;
    std::size_t compared = 0U;
    while (compared < 3000U)
    {
        const auto bits = sequence.Next();
        double value = 0.0;
        static_assert(sizeof(value) == sizeof(bits));
        std::memcpy(&value, &bits, sizeof(value));
        if (!std::isfinite(value))
            continue;
        const auto precision = static_cast<int>(sequence.Next() % 25U);
        const auto written = Floating(value, precision);
        const auto expected = HostFixed(value, precision);
        if (written != expected)
        {
            CAPTURE(bits);
            CAPTURE(precision);
            CHECK(written == expected);
        }
        ++compared;
    }
    CHECK(compared == 3000U);
}

TEST_CASE("%f agrees with the host on numbers a digit decides the rounding "
          "of")
{
    // Multiples of a power of two small enough to be exact: half of them
    // lie exactly between two numbers of the precision that is asked for.
    std::size_t compared = 0U;
    for (int numerator = -2000; numerator <= 2000; ++numerator)
    {
        for (const double denominator : { 2.0, 8.0, 32.0, 1024.0 })
        {
            const auto value = static_cast<double>(numerator) / denominator;
            for (int precision = 0; precision <= 4; ++precision)
            {
                const auto written = Floating(value, precision);
                const auto expected = HostFixed(value, precision);
                if (written != expected)
                {
                    CAPTURE(numerator);
                    CAPTURE(denominator);
                    CAPTURE(precision);
                    CHECK(written == expected);
                }
                ++compared;
            }
        }
    }
    CHECK(compared == std::size_t{ 80020U });
}

TEST_CASE("a field is never shorter than its width and never loses a digit")
{
    for (const auto magnitude : Magnitudes(200U))
    {
        const auto value = static_cast<std::int64_t>(magnitude);
        const auto plain = Signed(value);
        for (std::int64_t width = 0; width <= 48; width += 3)
        {
            for (const auto flags :
                 { INT64_C(0), TALA_TEXT_FLAG_LEFT, TALA_TEXT_FLAG_ZERO })
            {
                const auto field = Signed(value, flags, width);
                const auto least = static_cast<std::size_t>(width);
                if (field.size()
                    != (plain.size() > least ? plain.size() : least))
                {
                    CAPTURE(value);
                    CAPTURE(width);
                    CAPTURE(flags);
                    CHECK(field.size() == least);
                }
            }
        }
    }
}

TEST_CASE("%n is the line terminator of the platform")
{
    CHECK(Take(tala_text_newline()) == Wide(kLine));
}

TEST_CASE("the console receives a string as UTF-8")
{
    CHECK(Write(U"plain", TALA_CONSOLE_OUTPUT).output == "plain");
    CHECK(Write(U"", TALA_CONSOLE_OUTPUT).output.empty());
    // One character of each encoded length.
    const std::u32string mixed{ U'a', U'\xe9', U'\x20ac', U'\U0001f600' };
    CHECK(Write(mixed, TALA_CONSOLE_OUTPUT).output
          == "a\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80");
    // The first and the last scalar of each length.
    CHECK(Write(std::u32string{ U'\x7f', U'\x80' }, TALA_CONSOLE_OUTPUT).output
          == "\x7f\xc2\x80");
    CHECK(
        Write(std::u32string{ U'\x7ff', U'\x800' }, TALA_CONSOLE_OUTPUT).output
        == "\xdf\xbf\xe0\xa0\x80");
    CHECK(Write(std::u32string{ U'\xffff', U'\U00010000' }, TALA_CONSOLE_OUTPUT)
              .output
          == "\xef\xbf\xbf\xf0\x90\x80\x80");
    CHECK(Write(std::u32string{ U'\U0010ffff' }, TALA_CONSOLE_OUTPUT).output
          == "\xf4\x8f\xbf\xbf");
}

TEST_CASE("the target of a write selects the stream and the line ending")
{
    const auto output = Write(U"a", TALA_CONSOLE_OUTPUT);
    CHECK(output.output == "a");
    CHECK(output.error.empty());

    const auto outputLine = Write(U"a", TALA_CONSOLE_OUTPUT_LINE);
    CHECK(outputLine.output == "a" + std::string(kLine));
    CHECK(outputLine.error.empty());

    const auto error = Write(U"a", TALA_CONSOLE_ERROR);
    CHECK(error.output.empty());
    CHECK(error.error == "a");

    const auto errorLine = Write(U"a", TALA_CONSOLE_ERROR_LINE);
    CHECK(errorLine.output.empty());
    CHECK(errorLine.error == "a" + std::string(kLine));

    // An empty line is its terminator.
    CHECK(Write(U"", TALA_CONSOLE_OUTPUT_LINE).output == kLine);
    // Nothing is delivered for nothing.
    CHECK(Write(U"", TALA_CONSOLE_OUTPUT).deliveries == 0U);
}

TEST_CASE("a long write is delivered whole, in blocks that end between "
          "characters")
{
    // Four-byte characters, enough of them for several blocks, offset so
    // that a block boundary would fall inside a character if the encoder
    // let it.
    std::u32string scalars(U"x");
    scalars.append(1000U, U'\U0001f600');
    const auto captured = Write(scalars, TALA_CONSOLE_OUTPUT_LINE);
    std::string expected = "x";
    for (int index = 0; index < 1000; ++index)
        expected += "\xf0\x9f\x98\x80";
    expected += kLine;
    CHECK(captured.output == expected);
    CHECK(captured.deliveries > 1U);
}

TEST_CASE("writes reach the sink in the order they were made")
{
    Captured captured;
    Console::SetSink(Receive, &captured);
    for (const auto *text : { U"one", U"two", U"three" })
    {
        auto *string = Make(text);
        tala_console_write(string, TALA_CONSOLE_OUTPUT);
        tala_console_write(string, TALA_CONSOLE_ERROR_LINE);
        tala_aarc_release_strong(string);
    }
    Console::SetSink(nullptr, nullptr);
    CHECK(captured.output == "onetwothree");
    CHECK(captured.error
          == "one" + std::string(kLine) + "two" + std::string(kLine) + "three"
                 + std::string(kLine));
}

TEST_CASE("the text runtime leaves no object behind")
{
    // Every case above released what it was given and what it made.
    CHECK(Aarc::LiveAllocations() == liveAtStart);
}
