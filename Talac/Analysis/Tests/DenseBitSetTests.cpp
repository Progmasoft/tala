// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <cstddef>
#include <limits>
#include <vector>

#include "Progmasoft/Tala/Analysis/DenseBitSet.hpp"

namespace
{
    using Progmasoft::Tala::Analysis::DenseBitSet;
} // namespace

TEST_CASE("an empty dense bit set has no words or values")
{
    const DenseBitSet values;
    CHECK(values.Size() == 0U);
    CHECK(values.Empty());
    CHECK(values.None());
    CHECK_FALSE(values.Any());
    CHECK(values.Count() == 0U);
    CHECK(values.SetIndices().empty());
}

TEST_CASE("a dense bit set rejects universes outside LLVM's index domain")
{
    if constexpr (std::numeric_limits<std::size_t>::max()
                  > std::numeric_limits<unsigned>::max())
    {
        const auto oversized
            = static_cast<std::size_t>(std::numeric_limits<unsigned>::max())
              + 1U;
        auto result = DenseBitSet::Create(oversized);
        REQUIRE_FALSE(result);
        CHECK(llvm::toString(result.takeError()).find("index domain")
              != std::string::npos);
    }
}

TEST_CASE("a zero-filled dense bit set retains its requested universe")
{
    const DenseBitSet values(130U);
    CHECK(values.Size() == 130U);
    CHECK_FALSE(values.Empty());
    CHECK(values.None());
    CHECK(values.Count() == 0U);
}

TEST_CASE("a one-filled dense bit set masks its unused final word")
{
    const DenseBitSet values(130U, true);
    CHECK(values.Any());
    CHECK(values.Count() == 130U);
    CHECK(values.Test(0U));
    CHECK(values.Test(63U));
    CHECK(values.Test(64U));
    CHECK(values.Test(129U));
    CHECK_FALSE(values.Test(130U));
}

TEST_CASE("set and reset operate across word boundaries")
{
    DenseBitSet values(193U);
    for (const auto index : { 0U, 1U, 63U, 64U, 65U, 127U, 128U, 192U })
        values.Set(index);
    CHECK(values.Count() == 8U);
    CHECK(
        values.SetIndices()
        == std::vector<std::size_t>{ 0U, 1U, 63U, 64U, 65U, 127U, 128U, 192U });

    values.Reset(0U);
    values.Reset(64U);
    values.Reset(192U);
    CHECK(values.SetIndices()
          == std::vector<std::size_t>{ 1U, 63U, 65U, 127U, 128U });
}

TEST_CASE("out-of-range bit operations are conservative")
{
    DenseBitSet values(8U);
    values.Set(8U);
    values.Set(999U);
    values.Reset(999U);
    CHECK(values.None());
    CHECK_FALSE(values.Test(8U));
    CHECK_FALSE(values.Test(999U));
}

TEST_CASE("assign selects set or reset behavior")
{
    DenseBitSet values(4U);
    values.Assign(2U, true);
    CHECK(values.Test(2U));
    values.Assign(2U, false);
    CHECK_FALSE(values.Test(2U));
}

TEST_CASE("clear and fill preserve the universe size")
{
    DenseBitSet values(70U);
    values.Fill();
    CHECK(values.Count() == 70U);
    CHECK(values.Size() == 70U);
    values.Clear();
    CHECK(values.None());
    CHECK(values.Size() == 70U);
}

TEST_CASE("union combines set membership")
{
    DenseBitSet left(130U);
    left.Set(1U);
    left.Set(129U);
    DenseBitSet right(130U);
    right.Set(2U);
    right.Set(129U);

    REQUIRE_FALSE(static_cast<bool>(left.UnionWith(right)));
    CHECK(left.SetIndices() == std::vector<std::size_t>{ 1U, 2U, 129U });
}

TEST_CASE("intersection retains common set membership")
{
    DenseBitSet left(130U);
    left.Set(1U);
    left.Set(2U);
    left.Set(129U);
    DenseBitSet right(130U);
    right.Set(2U);
    right.Set(64U);
    right.Set(129U);

    REQUIRE_FALSE(static_cast<bool>(left.IntersectWith(right)));
    CHECK(left.SetIndices() == std::vector<std::size_t>{ 2U, 129U });
}

TEST_CASE("subtract removes every matching membership")
{
    DenseBitSet left(130U, true);
    DenseBitSet right(130U);
    right.Set(0U);
    right.Set(64U);
    right.Set(129U);

    REQUIRE_FALSE(static_cast<bool>(left.Subtract(right)));
    CHECK(left.Count() == 127U);
    CHECK_FALSE(left.Test(0U));
    CHECK_FALSE(left.Test(64U));
    CHECK_FALSE(left.Test(129U));
}

TEST_CASE("binary operations reject incompatible universes")
{
    DenseBitSet small(4U);
    const DenseBitSet large(5U);
    small.Set(1U);
    CHECK(llvm::toString(small.UnionWith(large)).find("different sizes")
          != std::string::npos);
    CHECK(llvm::toString(small.IntersectWith(large)).find("different sizes")
          != std::string::npos);
    CHECK(llvm::toString(small.Subtract(large)).find("different sizes")
          != std::string::npos);
    CHECK(small.SetIndices() == std::vector<std::size_t>{ 1U });
}

TEST_CASE("copying a dense bit set preserves value semantics")
{
    DenseBitSet original(80U);
    original.Set(7U);
    original.Set(72U);
    auto copy = original;
    copy.Set(20U);

    CHECK(original.SetIndices() == std::vector<std::size_t>{ 7U, 72U });
    CHECK(copy.SetIndices() == std::vector<std::size_t>{ 7U, 20U, 72U });
    CHECK_FALSE(original == copy);
}

TEST_CASE("dense indices are returned in stable ascending order")
{
    DenseBitSet values(512U);
    for (std::size_t remaining = 512U; remaining >= 17U; remaining -= 17U)
        values.Set(remaining - 1U);
    const auto indices = values.SetIndices();
    CHECK(std::ranges::is_sorted(indices));
    CHECK(indices.size() == values.Count());
}

TEST_CASE("word-aligned full sets do not lose their last word")
{
    DenseBitSet values(128U, true);
    CHECK(values.Count() == 128U);
    CHECK(values.Test(127U));
    values.Reset(127U);
    CHECK(values.Count() == 127U);
}

TEST_CASE("large bit sets retain exact cardinality")
{
    constexpr std::size_t kSize = 8193U;
    DenseBitSet values(kSize);
    for (std::size_t index = 0U; index < kSize; index += 3U)
        values.Set(index);
    CHECK(values.Count() == 2731U);
    CHECK(values.SetIndices().front() == 0U);
    CHECK(values.SetIndices().back() == 8190U);
}
