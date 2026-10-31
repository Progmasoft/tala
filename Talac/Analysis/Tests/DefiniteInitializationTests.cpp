// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <optional>
#include <ranges>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Analysis/DefiniteInitialization.hpp"

namespace
{
    namespace Analysis = Progmasoft::Tala::Analysis;

    [[nodiscard]] auto
    Read(const Analysis::StorageId storage, const std::size_t instruction = 0U)
        -> Analysis::AccessPoint
    {
        return { instruction, false, { storage }, std::nullopt };
    }

    [[nodiscard]] auto
    ReadMany(std::initializer_list<Analysis::StorageId> storage,
             const std::size_t instruction = 0U) -> Analysis::AccessPoint
    {
        return { instruction, false, storage, std::nullopt };
    }

    [[nodiscard]] auto
    Write(const Analysis::StorageId storage, const std::size_t instruction = 0U)
        -> Analysis::AccessPoint
    {
        return { instruction, false, {}, storage };
    }

    [[nodiscard]] auto
    ReadThenWrite(const Analysis::StorageId read,
                  const Analysis::StorageId write,
                  const std::size_t instruction = 0U) -> Analysis::AccessPoint
    {
        return { instruction, false, { read }, write };
    }

    [[nodiscard]] auto
    TerminatorRead(const Analysis::StorageId storage,
                   const std::size_t instruction) -> Analysis::AccessPoint
    {
        return { instruction, true, { storage }, std::nullopt };
    }

    [[nodiscard]] auto
    Block(const Analysis::BlockId id,
          std::initializer_list<Analysis::BlockId> successors = {},
          std::initializer_list<Analysis::AccessPoint> accesses = {})
        -> Analysis::Block
    {
        return { id, successors, accesses };
    }

    [[nodiscard]] auto
    Function(std::initializer_list<Analysis::StorageId> declarations,
             std::initializer_list<Analysis::StorageId> initialized,
             std::initializer_list<Analysis::Block> blocks,
             const Analysis::BlockId entry = 0U) -> Analysis::Function
    {
        return { entry, declarations, initialized, blocks };
    }

    [[nodiscard]] auto
    HasIssue(const Analysis::Result &result, const Analysis::IssueKind kind)
        -> bool
    {
        return std::ranges::any_of(result.issues, [kind](const auto &issue) {
            return issue.kind == kind;
        });
    }

    [[nodiscard]] auto
    IssuesOf(const Analysis::Result &result, const Analysis::IssueKind kind)
        -> std::vector<Analysis::Issue>
    {
        std::vector<Analysis::Issue> issues;
        std::ranges::copy_if(result.issues,
                             std::back_inserter(issues),
                             [kind](const auto &issue) {
                                 return issue.kind == kind;
                             });
        return issues;
    }

    [[nodiscard]] auto
    FactsFor(const Analysis::Result &result, const Analysis::BlockId block)
        -> const Analysis::BlockFacts &
    {
        const auto found = std::ranges::find(result.facts,
                                             block,
                                             &Analysis::BlockFacts::block);
        REQUIRE(found != result.facts.end());
        return *found;
    }

    [[nodiscard]] auto
    Diamond(const bool writeTrue, const bool writeFalse) -> Analysis::Function
    {
        auto trueAccesses = writeTrue ? std::vector{ Write(10U) }
                                      : std::vector<Analysis::AccessPoint>{};
        auto falseAccesses = writeFalse ? std::vector{ Write(10U) }
                                        : std::vector<Analysis::AccessPoint>{};
        return {
            0U,
            { 1U, 10U },
            { 1U },
            {
                { 0U, { 1U, 2U }, { Read(1U) } },
                { 1U, { 3U }, std::move(trueAccesses) },
                { 2U, { 3U }, std::move(falseAccesses) },
                { 3U, {}, { Read(10U) } },
            },
        };
    }
} // namespace

TEST_CASE("an initialized parameter is readable in the entry block")
{
    const auto result = Analysis::Analyze(
        Function({ 1U }, { 1U }, { Block(0U, {}, { Read(1U) }) }));
    CHECK(result.valid());
    CHECK(FactsFor(result, 0U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U });
}

TEST_CASE("a local read before its first write is rejected")
{
    const auto result = Analysis::Analyze(
        Function({ 1U }, {}, { Block(0U, {}, { Read(1U) }) }));
    REQUIRE_FALSE(result.valid());
    const auto issues
        = IssuesOf(result, Analysis::IssueKind::ReadBeforeInitialization);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().block == 0U);
    CHECK(issues.front().storage == 1U);
    CHECK(issues.front().instruction == 0U);
    CHECK_FALSE(issues.front().terminator);
}

TEST_CASE("a write makes a local readable by later instructions")
{
    const auto result = Analysis::Analyze(
        Function({ 7U },
                 {},
                 { Block(0U, {}, { Write(7U, 0U), Read(7U, 1U) }) }));
    CHECK(result.valid());
    CHECK(FactsFor(result, 0U).initializedOnEntry.empty());
    CHECK(FactsFor(result, 0U).initializedOnExit
          == std::vector<Analysis::StorageId>{ 7U });
}

TEST_CASE("reads happen before writes at one access point")
{
    const auto result = Analysis::Analyze(
        Function({ 7U }, {}, { Block(0U, {}, { ReadThenWrite(7U, 7U, 4U) }) }));
    const auto issues
        = IssuesOf(result, Analysis::IssueKind::ReadBeforeInitialization);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().instruction == 4U);
    CHECK(FactsFor(result, 0U).initializedOnExit
          == std::vector<Analysis::StorageId>{ 7U });
}

TEST_CASE("a write reaches a direct successor")
{
    const auto result = Analysis::Analyze(Function(
        { 2U },
        {},
        { Block(0U, { 9U }, { Write(2U) }), Block(9U, {}, { Read(2U) }) }));
    CHECK(result.valid());
    CHECK(FactsFor(result, 9U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 2U });
}

TEST_CASE("all diamond predecessors must initialize a joined local")
{
    CHECK(Analysis::Analyze(Diamond(true, true)).valid());
    CHECK_FALSE(Analysis::Analyze(Diamond(true, false)).valid());
    CHECK_FALSE(Analysis::Analyze(Diamond(false, true)).valid());
    CHECK_FALSE(Analysis::Analyze(Diamond(false, false)).valid());
}

TEST_CASE("diamond intersection retains only common initialized storage")
{
    const auto function
        = Function({ 1U, 2U, 3U, 4U },
                   { 1U },
                   {
                       Block(0U, { 1U, 2U }),
                       Block(1U, { 3U }, { Write(2U), Write(4U) }),
                       Block(2U, { 3U }, { Write(3U), Write(4U) }),
                       Block(3U),
                   });
    const auto facts = FactsFor(Analysis::Analyze(function), 3U);
    CHECK(facts.initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U, 4U });
}

TEST_CASE("a terminator read participates in initialization checking")
{
    const auto result = Analysis::Analyze(
        Function({ 8U }, {}, { Block(0U, {}, { TerminatorRead(8U, 12U) }) }));
    const auto issues
        = IssuesOf(result, Analysis::IssueKind::ReadBeforeInitialization);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().terminator);
    CHECK(issues.front().instruction == 12U);
}

TEST_CASE("an unreachable read does not reject a function")
{
    const auto result = Analysis::Analyze(
        Function({ 5U }, {}, { Block(0U), Block(99U, {}, { Read(5U) }) }));
    CHECK(result.valid());
    CHECK_FALSE(FactsFor(result, 99U).reachable);
    CHECK(FactsFor(result, 99U).initializedOnEntry.empty());
    CHECK(FactsFor(result, 99U).initializedOnExit.empty());
}

TEST_CASE("an unreachable predecessor cannot weaken a reachable join")
{
    const auto result
        = Analysis::Analyze(Function({ 3U },
                                     {},
                                     {
                                         Block(0U, { 2U }, { Write(3U) }),
                                         Block(1U, { 2U }),
                                         Block(2U, {}, { Read(3U) }),
                                     }));
    CHECK(result.valid());
    CHECK(FactsFor(result, 2U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 3U });
}

TEST_CASE("a loop body receives initialization established before the loop")
{
    const auto result
        = Analysis::Analyze(Function({ 2U },
                                     {},
                                     {
                                         Block(0U, { 1U }, { Write(2U) }),
                                         Block(1U, { 1U, 2U }, { Read(2U) }),
                                         Block(2U, {}, { Read(2U) }),
                                     }));
    CHECK(result.valid());
    CHECK(FactsFor(result, 1U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 2U });
}

TEST_CASE("a write performed only in a loop is not available on first entry")
{
    const auto result = Analysis::Analyze(
        Function({ 2U },
                 {},
                 {
                     Block(0U, { 1U }),
                     Block(1U, { 1U, 2U }, { Read(2U, 0U), Write(2U, 1U) }),
                     Block(2U),
                 }));
    CHECK(HasIssue(result, Analysis::IssueKind::ReadBeforeInitialization));
    CHECK(FactsFor(result, 1U).initializedOnEntry.empty());
}

TEST_CASE("an entry backedge cannot manufacture initialization")
{
    const auto result
        = Analysis::Analyze(Function({ 6U },
                                     {},
                                     {
                                         Block(0U, { 1U }, { Read(6U) }),
                                         Block(1U, { 0U }, { Write(6U) }),
                                     }));
    CHECK(HasIssue(result, Analysis::IssueKind::ReadBeforeInitialization));
    CHECK(FactsFor(result, 0U).initializedOnEntry.empty());
}

TEST_CASE("a parameter remains initialized across an entry backedge")
{
    const auto result
        = Analysis::Analyze(Function({ 6U },
                                     { 6U },
                                     {
                                         Block(0U, { 1U }, { Read(6U) }),
                                         Block(1U, { 0U }, { Read(6U) }),
                                     }));
    CHECK(result.valid());
    CHECK(FactsFor(result, 0U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 6U });
}

TEST_CASE("block presentation order does not affect fixed-point facts")
{
    auto ordered = Diamond(true, true);
    auto shuffled = ordered;
    shuffled.blocks = { ordered.blocks[3],
                        ordered.blocks[1],
                        ordered.blocks[0],
                        ordered.blocks[2] };
    const auto first = Analysis::Analyze(ordered);
    const auto second = Analysis::Analyze(shuffled);
    CHECK(first.issues == second.issues);
    CHECK(first.facts == second.facts);
}

TEST_CASE("every permutation of a linear function has identical facts")
{
    auto function = Function({ 1U, 2U, 3U },
                             { 1U },
                             {
                                 Block(0U, { 1U }, { ReadThenWrite(1U, 2U) }),
                                 Block(1U, { 2U }, { ReadThenWrite(2U, 3U) }),
                                 Block(2U, {}, { Read(3U) }),
                             });
    const auto expected = Analysis::Analyze(function);
    REQUIRE(expected.valid());
    std::ranges::sort(function.blocks, {}, &Analysis::Block::id);
    do
    {
        const auto actual = Analysis::Analyze(function);
        CHECK(actual.issues == expected.issues);
        CHECK(actual.facts == expected.facts);
    } while (
        std::ranges::next_permutation(function.blocks, {}, &Analysis::Block::id)
            .found);
}

TEST_CASE("duplicate successors count as one predecessor edge")
{
    const auto result = Analysis::Analyze(Function(
        { 1U },
        {},
        { Block(0U, { 1U, 1U }, { Write(1U) }), Block(1U, {}, { Read(1U) }) }));
    CHECK(result.valid());
    CHECK(FactsFor(result, 1U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U });
}

TEST_CASE("missing entry blocks are structural errors")
{
    const auto result = Analysis::Analyze(Function({}, {}, { Block(4U) }, 0U));
    CHECK(HasIssue(result, Analysis::IssueKind::MissingEntry));
    CHECK_FALSE(FactsFor(result, 4U).reachable);
}

TEST_CASE("missing successor targets retain source location")
{
    const auto result = Analysis::Analyze(
        Function({}, {}, { Block(4U, { 88U }, { Write(1U), Write(2U) }) }, 4U));
    const auto issues = IssuesOf(result, Analysis::IssueKind::MissingTarget);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().block == 4U);
    CHECK(issues.front().target == 88U);
    CHECK(issues.front().instruction == 2U);
    CHECK(issues.front().terminator);
}

TEST_CASE("duplicate block identities are rejected")
{
    const auto result
        = Analysis::Analyze(Function({}, {}, { Block(0U), Block(0U) }));
    CHECK(HasIssue(result, Analysis::IssueKind::DuplicateBlock));
}

TEST_CASE("duplicate storage declarations are rejected")
{
    const auto result
        = Analysis::Analyze(Function({ 7U, 7U }, {}, { Block(0U) }));
    const auto issues
        = IssuesOf(result, Analysis::IssueKind::DuplicateDeclaration);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().storage == 7U);
}

TEST_CASE("unknown initial storage is rejected without entering the seed set")
{
    const auto result
        = Analysis::Analyze(Function({ 1U }, { 1U, 99U }, { Block(0U) }));
    CHECK(HasIssue(result, Analysis::IssueKind::UnknownInitialStorage));
    CHECK(FactsFor(result, 0U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U });
}

TEST_CASE("unknown read storage is distinct from an uninitialized declaration")
{
    const auto result = Analysis::Analyze(
        Function({ 1U }, {}, { Block(0U, {}, { ReadMany({ 1U, 99U }) }) }));
    CHECK(IssuesOf(result, Analysis::IssueKind::ReadBeforeInitialization).size()
          == 1U);
    CHECK(IssuesOf(result, Analysis::IssueKind::UnknownReadStorage).size()
          == 1U);
}

TEST_CASE("unknown writes are reported and do not enter outgoing facts")
{
    const auto result = Analysis::Analyze(
        Function({ 1U }, {}, { Block(0U, {}, { Write(99U) }) }));
    CHECK(HasIssue(result, Analysis::IssueKind::UnknownWriteStorage));
    CHECK(FactsFor(result, 0U).initializedOnExit.empty());
}

TEST_CASE("facts use sorted storage identities for deterministic diagnostics")
{
    const auto result = Analysis::Analyze(
        Function({ 90U, 3U, 40U, 2U },
                 { 40U, 2U },
                 { Block(0U, {}, { Write(90U), Write(3U) }) }));
    CHECK(FactsFor(result, 0U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 2U, 40U });
    CHECK(FactsFor(result, 0U).initializedOnExit
          == std::vector<Analysis::StorageId>{ 2U, 3U, 40U, 90U });
}

TEST_CASE("facts use sorted block identities independent of presentation")
{
    const auto result = Analysis::Analyze(
        Function({}, {}, { Block(40U), Block(0U), Block(7U) }));
    REQUIRE(result.facts.size() == 3U);
    CHECK(result.facts[0].block == 0U);
    CHECK(result.facts[1].block == 7U);
    CHECK(result.facts[2].block == 40U);
}

TEST_CASE("multiple reads at one point produce one issue per storage")
{
    const auto result = Analysis::Analyze(
        Function({ 1U, 2U, 3U },
                 {},
                 { Block(0U, {}, { ReadMany({ 1U, 2U, 3U }, 9U) }) }));
    const auto issues
        = IssuesOf(result, Analysis::IssueKind::ReadBeforeInitialization);
    REQUIRE(issues.size() == 3U);
    CHECK(std::ranges::all_of(issues, [](const auto &issue) {
        return issue.instruction == 9U;
    }));
}

TEST_CASE("repeated reads preserve diagnostic multiplicity")
{
    const auto result = Analysis::Analyze(
        Function({ 1U },
                 {},
                 { Block(0U, {}, { ReadMany({ 1U, 1U, 1U }, 2U) }) }));
    CHECK(IssuesOf(result, Analysis::IssueKind::ReadBeforeInitialization).size()
          == 3U);
}

TEST_CASE("writes in nested diamonds converge at the outer join")
{
    const auto result = Analysis::Analyze(
        Function({ 1U, 2U },
                 {},
                 {
                     Block(0U, { 1U, 2U }),
                     Block(1U, { 3U, 4U }),
                     Block(2U, { 5U }, { Write(1U) }),
                     Block(3U, { 5U }, { Write(1U), Write(2U) }),
                     Block(4U, { 5U }, { Write(1U) }),
                     Block(5U, {}, { Read(1U), Read(2U) }),
                 }));
    const auto issues
        = IssuesOf(result, Analysis::IssueKind::ReadBeforeInitialization);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().storage == 2U);
    CHECK(FactsFor(result, 5U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U });
}

TEST_CASE("a self-loop without an entry predecessor remains unreachable")
{
    const auto result = Analysis::Analyze(
        Function({ 1U }, {}, { Block(0U), Block(2U, { 2U }, { Read(1U) }) }));
    CHECK(result.valid());
    CHECK_FALSE(FactsFor(result, 2U).reachable);
}

TEST_CASE("a reachable self-loop uses the first-entry predecessor intersection")
{
    const auto result = Analysis::Analyze(Function(
        { 1U },
        {},
        { Block(0U, { 2U }), Block(2U, { 2U }, { Read(1U), Write(1U) }) }));
    CHECK(HasIssue(result, Analysis::IssueKind::ReadBeforeInitialization));
    CHECK(FactsFor(result, 2U).initializedOnEntry.empty());
}

TEST_CASE(
    "two loop-carried writes cannot initialize a value absent on loop entry")
{
    const auto result
        = Analysis::Analyze(Function({ 1U },
                                     {},
                                     {
                                         Block(0U, { 1U }),
                                         Block(1U, { 2U, 3U }),
                                         Block(2U, { 1U }, { Write(1U) }),
                                         Block(3U, { 1U }, { Write(1U) }),
                                         Block(4U, {}, { Read(1U) }),
                                     }));
    CHECK(FactsFor(result, 1U).initializedOnEntry.empty());
}

TEST_CASE("independent locals retain independent initialization facts")
{
    const auto result = Analysis::Analyze(
        Function({ 1U, 2U, 3U },
                 {},
                 {
                     Block(0U, { 1U }, { Write(1U) }),
                     Block(1U, { 2U }, { ReadThenWrite(1U, 2U) }),
                     Block(2U, {}, { Read(1U), Read(2U), Read(3U) }),
                 }));
    const auto issues
        = IssuesOf(result, Analysis::IssueKind::ReadBeforeInitialization);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().storage == 3U);
    CHECK(FactsFor(result, 2U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U, 2U });
}

TEST_CASE("an empty valid function has one reachable empty fact")
{
    const auto result = Analysis::Analyze(Function({}, {}, { Block(0U) }));
    CHECK(result.valid());
    REQUIRE(result.facts.size() == 1U);
    CHECK(result.facts.front().reachable);
    CHECK(result.facts.front().initializedOnEntry.empty());
    CHECK(result.facts.front().initializedOnExit.empty());
}

TEST_CASE("a function with no blocks reports only its missing entry")
{
    const auto result = Analysis::Analyze(Function({}, {}, {}));
    REQUIRE(result.issues.size() == 1U);
    CHECK(result.issues.front().kind == Analysis::IssueKind::MissingEntry);
    CHECK(result.facts.empty());
}

TEST_CASE("duplicate blocks cannot make the fixed point oscillate")
{
    const auto result
        = Analysis::Analyze(Function({ 1U },
                                     {},
                                     {
                                         Block(0U, { 1U }),
                                         Block(1U, { 1U }, { Write(1U) }),
                                         Block(1U, { 1U }),
                                     }));
    CHECK(HasIssue(result, Analysis::IssueKind::DuplicateBlock));
    CHECK(result.facts.size() == 2U);
}

TEST_CASE("the first duplicate block owns the analyzed CFG identity")
{
    const auto result
        = Analysis::Analyze(Function({ 1U },
                                     {},
                                     {
                                         Block(0U, { 1U }, { Write(1U) }),
                                         Block(0U, {}, { Read(1U) }),
                                         Block(1U, {}, { Read(1U) }),
                                     }));
    CHECK(HasIssue(result, Analysis::IssueKind::DuplicateBlock));
    CHECK(FactsFor(result, 0U).initializedOnExit
          == std::vector<Analysis::StorageId>{ 1U });
    CHECK(FactsFor(result, 1U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U });
}

TEST_CASE("multiple independent joins retain only path-common writes")
{
    const auto result = Analysis::Analyze(
        Function({ 1U, 2U, 3U },
                 {},
                 {
                     Block(0U, { 1U, 2U }, { Write(1U) }),
                     Block(1U, { 3U }, { Write(2U) }),
                     Block(2U, { 3U }, { Write(2U), Write(3U) }),
                     Block(3U, { 4U, 5U }, { Read(1U), Read(2U) }),
                     Block(4U, { 6U }, { Write(3U) }),
                     Block(5U, { 6U }),
                     Block(6U, {}, { Read(1U), Read(2U), Read(3U) }),
                 }));
    const auto issues
        = IssuesOf(result, Analysis::IssueKind::ReadBeforeInitialization);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().storage == 3U);
    CHECK(FactsFor(result, 3U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U, 2U });
    CHECK(FactsFor(result, 6U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U, 2U });
}

TEST_CASE("a parameter and local remain distinct across a branch")
{
    const auto result
        = Analysis::Analyze(Function({ 1U, 2U },
                                     { 1U },
                                     {
                                         Block(0U, { 1U, 2U }, { Read(1U) }),
                                         Block(1U, { 3U }, { Write(2U) }),
                                         Block(2U, { 3U }, { Read(1U) }),
                                         Block(3U, {}, { Read(1U), Read(2U) }),
                                     }));
    const auto issues
        = IssuesOf(result, Analysis::IssueKind::ReadBeforeInitialization);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().storage == 2U);
    CHECK(FactsFor(result, 3U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U });
}

TEST_CASE("writes after a read do not erase the earlier diagnostic")
{
    const auto result = Analysis::Analyze(Function(
        { 1U },
        {},
        {
            Block(0U, {}, { Read(1U, 0U), Write(1U, 1U), Read(1U, 2U) }),
        }));
    const auto issues
        = IssuesOf(result, Analysis::IssueKind::ReadBeforeInitialization);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().instruction == 0U);
    CHECK(FactsFor(result, 0U).initializedOnExit
          == std::vector<Analysis::StorageId>{ 1U });
}

TEST_CASE("many writes to initialized storage remain idempotent")
{
    const auto result = Analysis::Analyze(Function(
        { 1U },
        { 1U },
        {
            Block(
                0U,
                {},
                { Write(1U, 0U), Write(1U, 1U), Write(1U, 2U), Read(1U, 3U) }),
        }));
    CHECK(result.valid());
    CHECK(FactsFor(result, 0U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U });
    CHECK(FactsFor(result, 0U).initializedOnExit
          == std::vector<Analysis::StorageId>{ 1U });
}

TEST_CASE(
    "an unknown read never becomes a declared fact after an unknown write")
{
    const auto result = Analysis::Analyze(
        Function({},
                 {},
                 {
                     Block(0U, {}, { Write(90U, 0U), Read(90U, 1U) }),
                 }));
    CHECK(IssuesOf(result, Analysis::IssueKind::UnknownWriteStorage).size()
          == 1U);
    CHECK(IssuesOf(result, Analysis::IssueKind::UnknownReadStorage).size()
          == 1U);
    CHECK(IssuesOf(result, Analysis::IssueKind::ReadBeforeInitialization)
              .empty());
}

TEST_CASE("a missing target does not become reachable by accident")
{
    const auto result
        = Analysis::Analyze(Function({ 1U },
                                     {},
                                     {
                                         Block(0U, { 99U }),
                                         Block(1U, {}, { Read(1U) }),
                                     }));
    CHECK(HasIssue(result, Analysis::IssueKind::MissingTarget));
    CHECK_FALSE(FactsFor(result, 1U).reachable);
    CHECK_FALSE(
        HasIssue(result, Analysis::IssueKind::ReadBeforeInitialization));
}

TEST_CASE("terminator reads observe writes from the last instruction")
{
    const auto result = Analysis::Analyze(
        Function({ 1U },
                 {},
                 {
                     Block(0U, {}, { Write(1U, 0U), TerminatorRead(1U, 1U) }),
                 }));
    CHECK(result.valid());
}

TEST_CASE("terminator reads preserve one-past-instruction locations")
{
    const auto result = Analysis::Analyze(Function(
        { 1U },
        {},
        {
            Block(0U,
                  {},
                  { Write(1U, 0U), Read(1U, 1U), TerminatorRead(2U, 2U) }),
        }));
    const auto issues
        = IssuesOf(result, Analysis::IssueKind::UnknownReadStorage);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().instruction == 2U);
    CHECK(issues.front().terminator);
}

TEST_CASE("a wide diamond computes all common facts")
{
    Analysis::Function function;
    function.entry = 0U;
    function.declarations = { 1U, 2U };
    function.blocks.push_back({ 0U, {}, {} });
    for (Analysis::BlockId id = 1U; id <= 16U; ++id)
    {
        function.blocks.front().successors.push_back(id);
        function.blocks.push_back(
            { id, { 17U }, { Write(1U), id == 16U ? Write(2U) : Read(1U) } });
    }
    function.blocks.push_back({ 17U, {}, { Read(1U), Read(2U) } });

    const auto result = Analysis::Analyze(function);
    const auto issues
        = IssuesOf(result, Analysis::IssueKind::ReadBeforeInitialization);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().storage == 2U);
    CHECK(FactsFor(result, 17U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U });
}

TEST_CASE("analysis is stable when declaration order changes")
{
    auto first
        = Function({ 1U, 2U, 3U, 4U },
                   { 1U, 3U },
                   { Block(0U, {}, { Write(2U), ReadMany({ 1U, 2U, 3U }) }) });
    auto second = first;
    std::ranges::reverse(second.declarations);
    std::ranges::reverse(second.initiallyInitialized);
    const auto firstResult = Analysis::Analyze(first);
    const auto secondResult = Analysis::Analyze(second);
    CHECK(firstResult.issues == secondResult.issues);
    CHECK(firstResult.facts == secondResult.facts);
}

TEST_CASE("a bypass edge removes facts written only on the long path")
{
    const auto result
        = Analysis::Analyze(Function({ 1U },
                                     {},
                                     {
                                         Block(0U, { 1U, 3U }),
                                         Block(1U, { 2U }, { Write(1U) }),
                                         Block(2U, { 3U }, { Read(1U) }),
                                         Block(3U, {}, { Read(1U) }),
                                     }));
    const auto issues
        = IssuesOf(result, Analysis::IssueKind::ReadBeforeInitialization);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().block == 3U);
}

TEST_CASE("an initialized seed survives arbitrarily many empty blocks")
{
    auto function = Function({ 1U }, { 1U }, { Block(0U) });
    for (Analysis::BlockId id = 1U; id < 20U; ++id)
        function.blocks.push_back(Block(id));
    for (std::size_t index = 0U; index + 1U < function.blocks.size(); ++index)
        function.blocks[index].successors.push_back(
            function.blocks[index + 1U].id);
    function.blocks.back().accesses.push_back(Read(1U));

    const auto result = Analysis::Analyze(function);
    CHECK(result.valid());
    CHECK(FactsFor(result, 19U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U });
}

TEST_CASE("empty intermediary blocks do not initialize a local")
{
    auto function = Function({ 1U }, {}, { Block(0U) });
    for (Analysis::BlockId id = 1U; id < 20U; ++id)
        function.blocks.push_back(Block(id));
    for (std::size_t index = 0U; index + 1U < function.blocks.size(); ++index)
        function.blocks[index].successors.push_back(
            function.blocks[index + 1U].id);
    function.blocks.back().accesses.push_back(Read(1U));

    const auto result = Analysis::Analyze(function);
    CHECK(HasIssue(result, Analysis::IssueKind::ReadBeforeInitialization));
    CHECK(FactsFor(result, 19U).initializedOnEntry.empty());
}

TEST_CASE(
    "two initialized parameters stay available after independent branches")
{
    const auto result = Analysis::Analyze(
        Function({ 1U, 2U },
                 { 1U, 2U },
                 {
                     Block(0U, { 1U, 2U }),
                     Block(1U, { 3U }, { Read(1U) }),
                     Block(2U, { 3U }, { Read(2U) }),
                     Block(3U, {}, { ReadMany({ 1U, 2U }) }),
                 }));
    CHECK(result.valid());
    CHECK(FactsFor(result, 3U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U, 2U });
}

TEST_CASE("a write in the entry is visible on every branch successor")
{
    const auto result
        = Analysis::Analyze(Function({ 1U },
                                     {},
                                     {
                                         Block(0U, { 1U, 2U }, { Write(1U) }),
                                         Block(1U, {}, { Read(1U) }),
                                         Block(2U, {}, { Read(1U) }),
                                     }));
    CHECK(result.valid());
    CHECK(FactsFor(result, 1U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U });
    CHECK(FactsFor(result, 2U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U });
}

TEST_CASE("issue locations distinguish instruction and terminator reads")
{
    const auto result = Analysis::Analyze(
        Function({ 1U },
                 {},
                 {
                     Block(0U, {}, { Read(1U, 3U), TerminatorRead(1U, 4U) }),
                 }));
    const auto issues
        = IssuesOf(result, Analysis::IssueKind::ReadBeforeInitialization);
    REQUIRE(issues.size() == 2U);
    CHECK(issues[0].instruction == 3U);
    CHECK_FALSE(issues[0].terminator);
    CHECK(issues[1].instruction == 4U);
    CHECK(issues[1].terminator);
}

TEST_CASE("an unreachable cycle remains absent from reachable facts")
{
    const auto result
        = Analysis::Analyze(Function({ 1U },
                                     {},
                                     {
                                         Block(0U),
                                         Block(10U, { 11U }, { Write(1U) }),
                                         Block(11U, { 10U }, { Read(1U) }),
                                     }));
    CHECK(result.valid());
    CHECK_FALSE(FactsFor(result, 10U).reachable);
    CHECK_FALSE(FactsFor(result, 11U).reachable);
}

TEST_CASE("a reachable cycle exit retains values initialized by its preheader")
{
    const auto result
        = Analysis::Analyze(Function({ 1U },
                                     {},
                                     {
                                         Block(0U, { 10U }, { Write(1U) }),
                                         Block(10U, { 11U }, { Read(1U) }),
                                         Block(11U, { 10U, 12U }, { Read(1U) }),
                                         Block(12U, {}, { Read(1U) }),
                                     }));
    CHECK(result.valid());
    CHECK(FactsFor(result, 12U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U });
}

TEST_CASE("writes remain visible after a long acyclic chain")
{
    Analysis::Function function;
    function.entry = 0U;
    function.declarations = { 1U };
    for (Analysis::BlockId id = 0U; id < 64U; ++id)
    {
        Analysis::Block block;
        block.id = id;
        if (id == 0U)
            block.accesses.push_back(Write(1U));
        else
            block.accesses.push_back(Read(1U));
        if (id + 1U < 64U)
            block.successors.push_back(id + 1U);
        function.blocks.push_back(std::move(block));
    }
    const auto result = Analysis::Analyze(function);
    CHECK(result.valid());
    CHECK(FactsFor(result, 63U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ 1U });
}

TEST_CASE("a late branch cannot hide an uninitialized path")
{
    Analysis::Function function;
    function.entry = 0U;
    function.declarations = { 1U };
    for (Analysis::BlockId id = 0U; id < 32U; ++id)
    {
        Analysis::Block block;
        block.id = id;
        if (id + 1U < 32U)
            block.successors.push_back(id + 1U);
        function.blocks.push_back(std::move(block));
    }
    function.blocks[8].successors.push_back(24U);
    function.blocks[23].accesses.push_back(Write(1U));
    function.blocks[31].accesses.push_back(Read(1U));

    const auto result = Analysis::Analyze(function);
    CHECK(HasIssue(result, Analysis::IssueKind::ReadBeforeInitialization));
    CHECK(FactsFor(result, 31U).initializedOnEntry.empty());
}

TEST_CASE("definite initialization can suppress materialized block facts")
{
    const auto function
        = Function({ 1U, 2U },
                   { 1U },
                   {
                       Block(0U, { 1U }, { Read(1U), Write(2U) }),
                       Block(1U, {}, { Read(2U) }),
                   });
    const auto full = Analysis::Analyze(function);
    const auto validationOnly
        = Analysis::Analyze(function, { .materializeFacts = false });

    CHECK(full.issues == validationOnly.issues);
    CHECK(full.statistics == validationOnly.statistics);
    CHECK(full.facts.size() == 2U);
    CHECK(validationOnly.facts.empty());
}

TEST_CASE("validation-only analysis retains semantic and graph diagnostics")
{
    const auto uninitialized = Analysis::Analyze(
        Function({ 9U }, {}, { Block(0U, {}, { Read(9U, 4U) }) }),
        { .materializeFacts = false });
    REQUIRE(uninitialized.facts.empty());
    const auto reads = IssuesOf(uninitialized,
                                Analysis::IssueKind::ReadBeforeInitialization);
    REQUIRE(reads.size() == 1U);
    CHECK(reads.front().storage == 9U);
    CHECK(reads.front().instruction == 4U);

    const auto malformed
        = Analysis::Analyze(Function({}, {}, { Block(0U, { 77U }) }),
                            { .materializeFacts = false });
    CHECK(malformed.facts.empty());
    CHECK(HasIssue(malformed, Analysis::IssueKind::MissingTarget));
}

TEST_CASE("an acyclic initialization chain has a linear evaluation bound")
{
    constexpr Analysis::BlockId kBlockCount = 1024U;
    Analysis::Function function;
    function.entry = 0U;
    function.declarations.reserve(kBlockCount);
    function.blocks.reserve(kBlockCount);
    for (Analysis::BlockId id = 0U; id < kBlockCount; ++id)
    {
        function.declarations.push_back(static_cast<Analysis::StorageId>(id)
                                        + 1U);
        Analysis::Block block;
        block.id = id;
        block.accesses.push_back(
            Write(static_cast<Analysis::StorageId>(id) + 1U));
        if (id > 0U)
            block.accesses.push_back(Read(id));
        if (id + 1U < kBlockCount)
            block.successors.push_back(id + 1U);
        function.blocks.push_back(std::move(block));
    }

    const auto result
        = Analysis::Analyze(function, { .materializeFacts = false });
    CHECK(result.valid());
    CHECK(result.statistics.blockEvaluations == kBlockCount);
    CHECK(result.statistics.scheduledBlocks == kBlockCount);
    CHECK(result.statistics.peakPendingBlocks == kBlockCount);
}

TEST_CASE("an uninitialized acyclic chain still has a linear evaluation bound")
{
    constexpr Analysis::BlockId kBlockCount = 512U;
    Analysis::Function function;
    function.entry = 0U;
    function.declarations = { 1U };
    function.blocks.reserve(kBlockCount);
    for (Analysis::BlockId id = 0U; id < kBlockCount; ++id)
    {
        Analysis::Block block;
        block.id = id;
        if (id + 1U < kBlockCount)
            block.successors.push_back(id + 1U);
        function.blocks.push_back(std::move(block));
    }
    function.blocks.back().accesses.push_back(Read(1U));

    const auto result
        = Analysis::Analyze(function, { .materializeFacts = false });
    CHECK(HasIssue(result, Analysis::IssueKind::ReadBeforeInitialization));
    CHECK(result.statistics.blockEvaluations == kBlockCount);
    CHECK(result.statistics.changeNotifications == kBlockCount - 1U);
}

TEST_CASE("dense initialization preserves sparse 64-bit storage identities")
{
    constexpr Analysis::StorageId kLow = 1U;
    constexpr Analysis::StorageId kMiddle = 0x1'0000'0001ULL;
    constexpr Analysis::StorageId kHigh = 0xFFFF'FFFF'FFFF'FFF0ULL;
    const auto result = Analysis::Analyze(
        Function({ kHigh, kLow, kMiddle },
                 { kHigh },
                 { Block(0U,
                         {},
                         { Write(kLow),
                           Write(kMiddle),
                           ReadMany({ kLow, kMiddle, kHigh }) }) }));

    CHECK(result.valid());
    CHECK(FactsFor(result, 0U).initializedOnEntry
          == std::vector<Analysis::StorageId>{ kHigh });
    CHECK(FactsFor(result, 0U).initializedOnExit
          == std::vector<Analysis::StorageId>{ kLow, kMiddle, kHigh });
}

TEST_CASE("dense initialization handles a universe crossing many words")
{
    Analysis::Function function;
    function.entry = 0U;
    constexpr std::size_t kStorageCount = 4097U;
    function.declarations.reserve(kStorageCount);
    function.blocks = { Block(0U) };
    for (std::size_t index = 0U; index < kStorageCount; ++index)
    {
        const auto storage = static_cast<Analysis::StorageId>(index) * 13U + 5U;
        function.declarations.push_back(storage);
        if (index % 3U == 0U)
            function.initiallyInitialized.push_back(storage);
    }

    const auto result = Analysis::Analyze(function);
    CHECK(result.valid());
    CHECK(FactsFor(result, 0U).initializedOnEntry.size() == 1366U);
    CHECK(FactsFor(result, 0U).initializedOnExit.size() == 1366U);
}
