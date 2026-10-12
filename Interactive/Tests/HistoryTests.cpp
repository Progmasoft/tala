// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <cstddef>
#include <string>

#include "Progmasoft/Tala/Interactive/History.hpp"

namespace
{
    namespace History = Progmasoft::Tala::Interactive::Runtime;
} // namespace

TEST_CASE("interactive history preserves successful-cell order and duplicates",
          "[tali][history]")
{
    History::History history;

    history.Append("1 + 2");
    history.Append("1 + 2");
    history.Append("3 * 4");

    REQUIRE(history.Entries().size() == 3U);
    REQUIRE(history.Entries()[0] == "1 + 2");
    REQUIRE(history.Entries()[1] == "1 + 2");
    REQUIRE(history.Entries()[2] == "3 * 4");
}

TEST_CASE("interactive history ignores empty cells", "[tali][history][input]")
{
    History::History history;

    history.Append("");
    REQUIRE(history.Entries().empty());

    history.Append("   ");
    REQUIRE(history.Entries().size() == 1U);
    REQUIRE(history.Entries().front() == "   ");
}

TEST_CASE(
    "interactive history retains a fixed newest-window and evicts oldest first",
    "[tali][history][limits]")
{
    History::History history;

    for (std::size_t index = 0U; index < History::History::kMaximumEntries;
         ++index)
        history.Append("cell-" + std::to_string(index));

    REQUIRE(history.Entries().size() == History::History::kMaximumEntries);
    REQUIRE(history.Entries().front() == "cell-0");
    REQUIRE(history.Entries().back() == "cell-255");

    history.Append("cell-256");
    REQUIRE(history.Entries().size() == History::History::kMaximumEntries);
    REQUIRE(history.Entries().front() == "cell-1");
    REQUIRE(history.Entries().back() == "cell-256");
}

TEST_CASE("interactive history clear permits a fresh session history",
          "[tali][history][reset]")
{
    History::History history;
    history.Append("before reset");

    history.Clear();
    REQUIRE(history.Entries().empty());

    history.Append("after reset");
    REQUIRE(history.Entries().size() == 1U);
    REQUIRE(history.Entries().front() == "after reset");
}
