// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <string>
#include <vector>

#include "Talac/Tazel/Bridge/ProjectDriver.hpp"

namespace
{
    auto
    Records() -> std::vector<std::string>
    {
        return { "tala-sources-v6",
                 "0.4.0",
                 "default",
                 "llvm",
                 "debug",
                 "all",
                 "true",
                 "false",
                 "false",
                 "false",
                 "true",
                 "true",
                 "true",
                 "0",
                 "aot",
                 "none",
                 "build/debug",
                 "0",
                 "1",
                 "0",
                 "0",
                 "Application",
                 "Example.Program",
                 "Sources",
                 "0" };
    }
    auto
    Frame(const std::vector<std::string> &records) -> std::string
    {
        std::string framed;
        for (const auto &record : records)
        {
            framed.append(record);
            framed.push_back('\0');
        }
        return framed;
    }
} // namespace

TEST_CASE(
    "project registry copies valid source records and rejects oversized counts")
{
    namespace Driver = Progmasoft::Tala::Driver;
    auto records = Records();
    auto framed = Frame(records);
    const auto project = Driver::ParseProjectRegistry(framed, true);
    REQUIRE(project);
    CHECK(project->executables.size() == 1U);
    CHECK(project->entry == "Example.Program");
    framed.assign(framed.size(), 'x');
    CHECK(project->entry == "Example.Program");
    for (const auto index : { 17U, 18U, 19U, 20U, 24U })
    {
        auto oversized = records;
        oversized[index] = "18446744073709551615";
        CHECK_FALSE(Driver::ParseProjectRegistry(Frame(oversized), false));
        oversized[index] = "1000000";
        CHECK_FALSE(Driver::ParseProjectRegistry(Frame(oversized), false));
    }
}

TEST_CASE("project registry validates framing and source requirements before "
          "allocation")
{
    namespace Driver = Progmasoft::Tala::Driver;
    CHECK_FALSE(Driver::ParseProjectRegistry({}, false));
    std::string oversized(4U * 1024U * 1024U + 1U, '\0');
    CHECK_FALSE(Driver::ParseProjectRegistry(oversized, false));
    auto records = Records();
    records.resize(21U);
    records[18U] = "0";
    auto framed = Frame(records);
    CHECK(Driver::ParseProjectRegistry(framed, false));
    CHECK_FALSE(Driver::ParseProjectRegistry(framed, true));
    framed.pop_back();
    CHECK_FALSE(Driver::ParseProjectRegistry(framed, false));
}
