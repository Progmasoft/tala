// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <initializer_list>
#include <limits>
#include <ranges>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Analysis/Liveness.hpp"

namespace
{
    namespace Live = Progmasoft::Tala::Analysis::Liveness;

    [[nodiscard]] auto
    Read(const std::size_t instruction,
         std::initializer_list<Live::StorageId> reads) -> Live::Access
    {
        return { instruction, false, { reads }, std::nullopt, false };
    }

    [[nodiscard]] auto
    Write(const std::size_t instruction,
          const Live::StorageId destination,
          std::initializer_list<Live::StorageId> reads = {}) -> Live::Access
    {
        return { instruction, false, { reads }, destination, true };
    }

    [[nodiscard]] auto
    Effect(const std::size_t instruction,
           std::initializer_list<Live::StorageId> reads) -> Live::Access
    {
        return { instruction, false, { reads }, std::nullopt, false };
    }

    [[nodiscard]] auto
    Terminator(std::initializer_list<Live::StorageId> reads) -> Live::Access
    {
        return { 99U, true, { reads }, std::nullopt, false };
    }

    [[nodiscard]] auto
    Block(const Live::BlockId id,
          std::vector<Live::BlockId> successors,
          std::vector<Live::Access> accesses) -> Live::Block
    {
        return { id, std::move(successors), std::move(accesses) };
    }

    [[nodiscard]] auto
    Facts(const Live::Result &result, const Live::BlockId block)
        -> const Live::BlockFacts &
    {
        const auto found
            = std::ranges::find(result.facts, block, &Live::BlockFacts::block);
        REQUIRE(found != result.facts.end());
        return *found;
    }

    [[nodiscard]] auto
    Retained(const Live::BlockFacts &facts) -> std::vector<bool>
    {
        std::vector<bool> retained;
        retained.reserve(facts.accesses.size());
        for (const auto &access : facts.accesses)
            retained.push_back(access.retained);
        return retained;
    }
} // namespace

TEST_CASE("liveness removes a complete dead producer chain in one result")
{
    const auto result = Live::Analyze({
        0U,
        { Block(0U,
                {},
                { Write(0U, 1U),
                  Write(1U, 2U, { 1U }),
                  Write(2U, 3U, { 2U }),
                  Terminator({}) }) },
    });

    REQUIRE(result.valid());
    const auto &facts = Facts(result, 0U);
    CHECK(Retained(facts) == std::vector<bool>{ false, false, false, true });
    CHECK(facts.liveOnEntry.empty());
    CHECK(facts.liveOnExit.empty());
}

TEST_CASE("an observable use retains its transitive producer chain")
{
    const auto result = Live::Analyze({
        0U,
        { Block(0U,
                {},
                { Write(0U, 1U),
                  Write(1U, 2U, { 1U }),
                  Effect(2U, { 2U }),
                  Terminator({}) }) },
    });

    REQUIRE(result.valid());
    const auto &facts = Facts(result, 0U);
    CHECK(Retained(facts) == std::vector<bool>{ true, true, true, true });
    CHECK(facts.accesses[0].liveAfter == std::vector<Live::StorageId>{ 1U });
    CHECK(facts.accesses[1].liveAfter == std::vector<Live::StorageId>{ 2U });
}

TEST_CASE("a terminator keeps its condition and the condition producer live")
{
    const auto result = Live::Analyze({
        0U,
        { Block(0U, { 1U, 2U }, { Write(0U, 5U), Terminator({ 5U }) }),
          Block(1U, {}, { Terminator({}) }),
          Block(2U, {}, { Terminator({}) }) },
    });

    REQUIRE(result.valid());
    CHECK(Retained(Facts(result, 0U)) == std::vector<bool>{ true, true });
    CHECK(Facts(result, 0U).liveOnEntry.empty());
}

TEST_CASE("successor uses are united across branch edges")
{
    const auto result = Live::Analyze({
        0U,
        { Block(0U,
                { 1U, 2U },
                { Write(0U, 10U), Write(1U, 20U), Terminator({}) }),
          Block(1U, {}, { Read(0U, { 10U }), Terminator({}) }),
          Block(2U, {}, { Read(0U, { 20U }), Terminator({}) }) },
    });

    REQUIRE(result.valid());
    CHECK(Retained(Facts(result, 0U)) == std::vector<bool>{ true, true, true });
    CHECK(Facts(result, 0U).liveOnExit
          == std::vector<Live::StorageId>{ 10U, 20U });
}

TEST_CASE("loop-carried liveness reaches a fixed point")
{
    const auto result = Live::Analyze({
        0U,
        { Block(0U, { 1U }, { Write(0U, 1U), Terminator({}) }),
          Block(1U, { 1U, 2U }, { Write(0U, 1U, { 1U }), Terminator({ 1U }) }),
          Block(2U, {}, { Read(0U, { 1U }), Terminator({}) }) },
    });

    REQUIRE(result.valid());
    CHECK(Retained(Facts(result, 0U)).front());
    CHECK(Retained(Facts(result, 1U)).front());
    CHECK(Facts(result, 1U).liveOnEntry == std::vector<Live::StorageId>{ 1U });
    CHECK(Facts(result, 1U).liveOnExit == std::vector<Live::StorageId>{ 1U });
}

TEST_CASE("unreachable blocks receive conservative non-removal facts")
{
    const auto result = Live::Analyze({
        0U,
        { Block(0U, {}, { Terminator({}) }),
          Block(9U, {}, { Write(0U, 7U), Terminator({}) }) },
    });

    REQUIRE(result.valid());
    const auto &unreachable = Facts(result, 9U);
    CHECK_FALSE(unreachable.reachable);
    CHECK(Retained(unreachable) == std::vector<bool>{ true, true });
}

TEST_CASE("facts are independent of block presentation order")
{
    const Live::Function ordered{
        0U,
        { Block(0U, { 1U }, { Write(0U, 8U), Terminator({}) }),
          Block(1U, {}, { Read(0U, { 8U }), Terminator({}) }) },
    };
    const Live::Function shuffled{
        0U,
        { Block(1U, {}, { Read(0U, { 8U }), Terminator({}) }),
          Block(0U, { 1U }, { Write(0U, 8U), Terminator({}) }) },
    };

    CHECK(Live::Analyze(ordered).facts == Live::Analyze(shuffled).facts);
}

TEST_CASE("malformed control flow remains diagnostic and finite")
{
    const auto missingEntry
        = Live::Analyze({ 9U, { Block(0U, { 4U }, { Terminator({}) }) } });
    REQUIRE(missingEntry.issues.size() == 2U);
    CHECK(missingEntry.issues[0].kind
          == Progmasoft::Tala::Analysis::ControlFlowIssueKind::MissingEntry);
    CHECK(missingEntry.issues[1].kind
          == Progmasoft::Tala::Analysis::ControlFlowIssueKind::MissingTarget);
}

TEST_CASE("backward liveness evaluates an acyclic chain once per block")
{
    constexpr Live::BlockId kBlockCount = 1024U;
    Live::Function function;
    function.entry = 0U;
    function.blocks.reserve(kBlockCount);
    for (Live::BlockId id = 0U; id < kBlockCount; ++id)
    {
        Live::Block block;
        block.id = id;
        if (id + 1U < kBlockCount)
            block.successors.push_back(id + 1U);
        block.accesses.push_back(Write(
            0U,
            static_cast<Live::StorageId>(id) + 1U,
            id + 1U < kBlockCount
                ? std::initializer_list<
                      Live::StorageId>{ static_cast<Live::StorageId>(id) + 2U }
                : std::initializer_list<Live::StorageId>{}));
        function.blocks.push_back(std::move(block));
    }

    const auto result = Live::Analyze(function);
    CHECK(result.valid());
    CHECK(result.statistics.blockEvaluations == kBlockCount);
    CHECK(result.statistics.scheduledBlocks == kBlockCount);
}

TEST_CASE("backward liveness worklist converges through a loop")
{
    const auto result = Live::Analyze({
        0U,
        {
            Block(0U, { 1U }, { Write(0U, 1U), Terminator({}) }),
            Block(1U,
                  { 2U, 3U },
                  { Read(0U, { 1U }), Write(1U, 2U), Terminator({}) }),
            Block(2U,
                  { 1U },
                  { Read(0U, { 2U }), Write(1U, 3U), Terminator({}) }),
            Block(3U, {}, { Read(0U, { 2U }), Terminator({}) }),
        },
    });
    CHECK(result.valid());
    CHECK(result.statistics.blockEvaluations >= 4U);
    CHECK(result.statistics.blockEvaluations <= 16U);
    CHECK(result.statistics.changeNotifications <= 12U);
}

TEST_CASE("liveness catalogs sparse maximum-width storage identities")
{
    constexpr auto kLow = Live::StorageId{ 3U };
    constexpr auto kHigh = std::numeric_limits<Live::StorageId>::max();
    const auto result = Live::Analyze({
        0U,
        { Block(0U,
                {},
                { Write(0U, kLow),
                  Write(1U, kHigh, { kLow }),
                  Effect(2U, { kHigh, kHigh }),
                  Terminator({}) }) },
    });

    REQUIRE(result.valid());
    const auto &facts = Facts(result, 0U);
    CHECK(Retained(facts) == std::vector<bool>{ true, true, true, true });
    CHECK(facts.accesses[0].liveAfter == std::vector<Live::StorageId>{ kLow });
    CHECK(facts.accesses[1].liveAfter == std::vector<Live::StorageId>{ kHigh });
    // Repeated reads are one liveness fact, not duplicate public entries.
    CHECK(facts.accesses[2].liveBefore
          == std::vector<Live::StorageId>{ kHigh });
}

TEST_CASE("dense liveness crosses several machine-word boundaries")
{
    constexpr std::size_t kStorageCount = 130U;
    std::vector<Live::Access> accesses;
    accesses.reserve(kStorageCount + 2U);
    for (std::size_t index = 0U; index < kStorageCount; ++index)
        accesses.push_back(
            Write(index, static_cast<Live::StorageId>(index + 1U)));
    accesses.push_back(
        Effect(kStorageCount, { 1U, 64U, 65U, 128U, 129U, 130U }));
    accesses.push_back(Terminator({}));

    const auto result = Live::Analyze({
        0U,
        { Block(0U, {}, std::move(accesses)) },
    });

    REQUIRE(result.valid());
    const auto &facts = Facts(result, 0U);
    std::size_t retainedWrites{};
    for (std::size_t index = 0U; index < kStorageCount; ++index)
        retainedWrites += facts.accesses[index].retained ? 1U : 0U;
    CHECK(retainedWrites == 6U);
    CHECK(facts.accesses[kStorageCount].liveBefore
          == std::vector<Live::StorageId>{ 1U, 64U, 65U, 128U, 129U, 130U });
}

TEST_CASE("retention-only mode preserves optimizer decisions without expanding "
          "live sets")
{
    const Live::Function function{
        0U,
        { Block(0U, { 1U }, { Write(0U, 7U), Write(1U, 8U), Terminator({}) }),
          Block(1U, {}, { Effect(0U, { 8U }), Terminator({}) }) },
    };

    const auto complete = Live::Analyze(function);
    const auto retentionOnly
        = Live::Analyze(function, { .materializeLiveSets = false });

    REQUIRE(complete.valid());
    REQUIRE(retentionOnly.valid());
    REQUIRE(complete.facts.size() == retentionOnly.facts.size());
    for (std::size_t blockIndex = 0U; blockIndex < complete.facts.size();
         ++blockIndex)
    {
        const auto &completeBlock = complete.facts[blockIndex];
        const auto &retentionBlock = retentionOnly.facts[blockIndex];
        CHECK(completeBlock.block == retentionBlock.block);
        CHECK(completeBlock.reachable == retentionBlock.reachable);
        CHECK(Retained(completeBlock) == Retained(retentionBlock));
        CHECK(retentionBlock.liveOnEntry.empty());
        CHECK(retentionBlock.liveOnExit.empty());
        for (const auto &access : retentionBlock.accesses)
        {
            CHECK(access.liveBefore.empty());
            CHECK(access.liveAfter.empty());
        }
    }
}
