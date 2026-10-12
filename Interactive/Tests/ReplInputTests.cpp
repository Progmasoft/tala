// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <sstream>
#include <string>
#include <string_view>

#include "Progmasoft/Tala/Interactive/ReplInput.hpp"

namespace
{
    using Progmasoft::Tala::Interactive::InputLineStatus;
    using Progmasoft::Tala::Interactive::ParseReplCommand;
    using Progmasoft::Tala::Interactive::ReadInputLine;
    using Progmasoft::Tala::Interactive::ReplCommandKind;
} // namespace

TEST_CASE(
    "REPL input accepts the exact byte bound and preserves following lines",
    "[tali][input][limits]")
{
    std::istringstream input("1234\nnext\n");
    std::string line;

    REQUIRE(ReadInputLine(input, line, 4U) == InputLineStatus::Complete);
    REQUIRE(line == "1234");
    REQUIRE(ReadInputLine(input, line, 4U) == InputLineStatus::Complete);
    REQUIRE(line == "next");
    REQUIRE(ReadInputLine(input, line, 4U) == InputLineStatus::End);
}

TEST_CASE("REPL input drains overlong lines rather than exposing their suffix",
          "[tali][input][recovery]")
{
    std::istringstream input("12345\nnext\n");
    std::string line;

    REQUIRE(ReadInputLine(input, line, 4U) == InputLineStatus::TooLong);
    REQUIRE(line.empty());
    REQUIRE(ReadInputLine(input, line, 4U) == InputLineStatus::Complete);
    REQUIRE(line == "next");
}

TEST_CASE("REPL input reports an oversized final line at EOF",
          "[tali][input][eof]")
{
    std::istringstream input("12345");
    std::string line;

    REQUIRE(ReadInputLine(input, line, 4U) == InputLineStatus::TooLong);
    REQUIRE(line.empty());
    REQUIRE(ReadInputLine(input, line, 4U) == InputLineStatus::End);
}

TEST_CASE("REPL input delivers an unterminated final line exactly once",
          "[tali][input][eof]")
{
    std::istringstream input("last expression");
    std::string line;

    REQUIRE(ReadInputLine(input, line, 64U) == InputLineStatus::Complete);
    REQUIRE(line == "last expression");
    REQUIRE(ReadInputLine(input, line, 64U) == InputLineStatus::End);
}

TEST_CASE("REPL input limits count UTF-8 bytes without returning partial lines",
          "[tali][input][utf8]")
{
    std::istringstream input("\xc3\xa9\nnext\n");
    std::string line;

    REQUIRE(ReadInputLine(input, line, 1U) == InputLineStatus::TooLong);
    REQUIRE(line.empty());
    REQUIRE(ReadInputLine(input, line, 4U) == InputLineStatus::Complete);
    REQUIRE(line == "next");
}

TEST_CASE("REPL commands are exact and preserve source text after type",
          "[tali][commands]")
{
    REQUIRE(ParseReplCommand(":help").kind == ReplCommandKind::Help);
    REQUIRE(ParseReplCommand(":history").kind == ReplCommandKind::History);
    REQUIRE(ParseReplCommand(":reset").kind == ReplCommandKind::Reset);
    REQUIRE(ParseReplCommand(":quit").kind == ReplCommandKind::Quit);
    REQUIRE(ParseReplCommand(":type").kind
            == ReplCommandKind::TypeMissingExpression);
    REQUIRE(ParseReplCommand(":type   ").kind
            == ReplCommandKind::TypeMissingExpression);

    const auto spacedType = ParseReplCommand(":type   5 + 5");
    REQUIRE(spacedType.kind == ReplCommandKind::Type);
    REQUIRE(spacedType.expression == "5 + 5");

    const auto tabbedType = ParseReplCommand(":type\t\"hello world\"");
    REQUIRE(tabbedType.kind == ReplCommandKind::Type);
    REQUIRE(tabbedType.expression == "\"hello world\"");

    REQUIRE(ParseReplCommand(":typex").kind == ReplCommandKind::Unknown);
    REQUIRE(ParseReplCommand(":unknown").kind == ReplCommandKind::Unknown);
}

TEST_CASE("REPL source lines are forwarded byte-for-byte and are not mistaken "
          "for commands",
          "[tali][commands]")
{
    const auto expression = ParseReplCommand("  5 + 5  ");
    REQUIRE(expression.kind == ReplCommandKind::Expression);
    REQUIRE(expression.expression == "  5 + 5  ");

    const auto unicode = ParseReplCommand("\"caf\xc3\xa9\"");
    REQUIRE(unicode.kind == ReplCommandKind::Expression);
    REQUIRE(unicode.expression == "\"caf\xc3\xa9\"");

    REQUIRE(ParseReplCommand("").kind == ReplCommandKind::Expression);
}
