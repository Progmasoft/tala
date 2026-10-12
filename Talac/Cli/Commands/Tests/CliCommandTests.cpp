// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <catch2/catch_test_macros.hpp>
#include <initializer_list>
#include <string>
#include <vector>

#include "Talac/Cli/Commands/Commands.hpp"

namespace
{
    /// Status of `talac` started with the given arguments. None of the
    /// invocations of this file reaches the frontend: each is refused before
    /// a file is opened.
    [[nodiscard]] auto
    Status(std::initializer_list<const char *> written) -> int
    {
        std::vector<std::string> storage{ "talac" };
        for (const auto *argument : written)
            storage.emplace_back(argument);
        std::vector<char *> arguments;
        arguments.reserve(storage.size() + 1U);
        for (auto &argument : storage)
            arguments.push_back(argument.data());
        arguments.push_back(nullptr);
        return Progmasoft::Tala::Cli::Run(static_cast<int>(storage.size()),
                                          arguments.data());
    }
} // namespace

TEST_CASE("help and version succeed without an input")
{
    CHECK(Status({ "--help" }) == 0);
    CHECK(Status({ "-h" }) == 0);
    CHECK(Status({ "--version" }) == 0);
    CHECK(Status({ "-v" }) == 0);
}

TEST_CASE("a command line that cannot be parsed is a usage error")
{
    CHECK(Status({}) == 2);
    CHECK(Status({ "Main.tala" }) == 2);
    CHECK(Status({ "Main.tala", "--entry=Demo.Program", "--emit=exe" }) == 2);
}

TEST_CASE("what is accepted but not implemented is refused by name")
{
    // A C header belongs to the Tala C Interface, which is not built yet.
    CHECK(Status({ "Main.tala", "--vipkg-type=staticlib", "--header" }) == 2);
    CHECK(Status({ "Main.tala", "--vipkg-type=talalib" }) == 2);
    CHECK(Status({ "Main.tala", "--entry=Demo.Program", "--llvm-compiler=orc" })
          == 2);
    CHECK(Status({ "Main.tala", "--entry=Demo.Program", "--llvm-lto=thin" })
          == 2);
    CHECK(
        Status(
            { "Main.tala", "--entry=Demo.Program", "--llvm-args=-time-passes" })
        == 2);
    CHECK(Status({ "Main.ll", "--build=llvm-ir" }) == 2);
}

TEST_CASE("the kind of the inputs decides which files and outputs fit")
{
    CHECK(Status({ "Main.core", "--entry=Demo.Program" }) == 2);
    CHECK(Status({ "Main.tala", "--build=core" }) == 2);
    CHECK(Status({ "One.core", "Two.core", "--build=core" }) == 2);
    // An output cannot stand earlier in the pipeline than its input.
    CHECK(Status({ "Main.xmm", "--build=xmm", "--emit=xpp" }) == 2);
    CHECK(Status({ "Main.core", "--build=core", "--emit=core" }) == 2);
    CHECK(Status({ "Main.o", "--build=object", "--emit=object" }) == 2);
}
