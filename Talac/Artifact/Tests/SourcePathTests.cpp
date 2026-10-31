// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <string>
#include <string_view>
#include <vector>

#include "Talac/Artifact/SourcePath.hpp"

namespace
{
    using Progmasoft::Tala::Artifact::IsNormalizedSourcePath;

    struct PathCase final
    {
        std::u32string_view path;
        bool expected{};
        std::string_view reason;
    };
} // namespace

TEST_CASE("source identity accepts canonical portable project-relative paths")
{
    const std::vector<PathCase> cases{
        { U"Main.tala", true, "one source segment" },
        { U"Sources/Main.tala", true, "slash-separated source root" },
        { U"Sources/Nested/Helper.tala", true, "nested source unit" },
        { U"Türkçe/Örnek.tala", true, "Unicode source segments" },
        { U"Generated/🚀.tala", true, "non-BMP Unicode scalar" },
        { U"folder with spaces/source file.tala",
          true,
          "portable spaces in a path segment" },
    };

    for (const auto &test : cases)
    {
        CAPTURE(test.reason);
        CHECK(IsNormalizedSourcePath(test.path) == test.expected);
    }
}

TEST_CASE("source identity rejects roots aliases and malformed segments")
{
    const std::vector<PathCase> cases{
        { U"", false, "empty path" },
        { U"/Sources/Main.tala", false, "POSIX rooted path" },
        { U"\\Sources\\Main.tala", false, "Windows rooted path" },
        { U"C:/Sources/Main.tala", false, "drive-rooted path" },
        { U"C:Main.tala", false, "drive-relative path" },
        { U"../Main.tala", false, "parent traversal" },
        { U"Sources/../Main.tala", false, "interior parent traversal" },
        { U"./Main.tala", false, "current-directory alias" },
        { U"Sources/./Main.tala", false, "interior current-directory alias" },
        { U"Sources//Main.tala", false, "empty interior segment" },
        { U"Sources/Main.tala/", false, "trailing separator" },
        { U"Sources/\\Main.tala", false, "mixed path separators" },
        { U"Sources/Main.TALA", false, "case-changed extension" },
        { U"Sources/Main.cpp", false, "non-source extension" },
        { U"Sources/.tala", false, "empty basename" },
        { U"Sources/..tala", true, "dot-leading but non-alias filename" },
        { U"Sources/a:b.tala", false, "drive separator in a segment" },
    };

    for (const auto &test : cases)
    {
        CAPTURE(test.reason);
        CHECK(IsNormalizedSourcePath(test.path) == test.expected);
    }
}

TEST_CASE("source identity rejects invalid Unicode scalar values")
{
    std::u32string surrogate = U"Sources/";
    surrogate.push_back(static_cast<char32_t>(0xd800U));
    surrogate += U".tala";

    std::u32string beyondUnicode = U"Sources/";
    beyondUnicode.push_back(static_cast<char32_t>(0x110000U));
    beyondUnicode += U".tala";

    std::u32string embeddedNull = U"Sources/";
    embeddedNull.push_back(U'\0');
    embeddedNull += U"Main.tala";

    CHECK_FALSE(IsNormalizedSourcePath(surrogate));
    CHECK_FALSE(IsNormalizedSourcePath(beyondUnicode));
    CHECK_FALSE(IsNormalizedSourcePath(embeddedNull));
}

TEST_CASE("source path validation does not normalize malformed input")
{
    // A verifier rejects noncanonical identities rather than silently fixing
    // them. Otherwise two different artifact bytes could name one source.
    CHECK_FALSE(IsNormalizedSourcePath(U"Sources\\Main.tala"));
    CHECK_FALSE(IsNormalizedSourcePath(U"Sources//Main.tala"));
    CHECK_FALSE(IsNormalizedSourcePath(U"Sources/../Main.tala"));
    CHECK(IsNormalizedSourcePath(U"Sources/Main.tala"));
}
