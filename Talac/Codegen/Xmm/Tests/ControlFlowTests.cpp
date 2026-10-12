// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <cstdint>
#include <initializer_list>
#include <optional>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Xmm/ControlFlow.hpp"
#include "Progmasoft/Tala/Xpp/ControlFlow.hpp"

namespace
{
    namespace Analysis = Progmasoft::Tala::Analysis;
    namespace Xmm = tala::xmm;

    [[nodiscard]] auto
    Return() -> Xmm::Terminator
    {
        Xmm::Terminator value;
        value.kind = Xmm::Terminator::Kind::Return;
        return value;
    }

    [[nodiscard]] auto
    Jump(const Xmm::BlockId target) -> Xmm::Terminator
    {
        Xmm::Terminator value;
        value.kind = Xmm::Terminator::Kind::Jump;
        value.true_target = target;
        return value;
    }

    [[nodiscard]] auto
    Branch(const Xmm::BlockId yes, const Xmm::BlockId no) -> Xmm::Terminator
    {
        Xmm::Terminator value;
        value.kind = Xmm::Terminator::Kind::Branch;
        value.true_target = yes;
        value.false_target = no;
        return value;
    }

    [[nodiscard]] auto
    Block(const Xmm::BlockId id, Xmm::Terminator terminator) -> Xmm::Block
    {
        return { id, {}, std::move(terminator) };
    }

    [[nodiscard]] auto
    Function(std::initializer_list<Xmm::Block> blocks,
             const Xmm::BlockId entry = 0U) -> Xmm::Function
    {
        Xmm::Function function;
        function.symbol = { 1U, U"ControlFlow" };
        function.entry = entry;
        function.blocks = blocks;
        return function;
    }

    [[nodiscard]] auto
    Facts(const Analysis::DominanceResult &result, const Xmm::BlockId block)
        -> const Analysis::DominanceBlockFacts &
    {
        const auto *facts = Analysis::FactsFor(result, block);
        REQUIRE(facts != nullptr);
        return *facts;
    }
} // namespace

TEST_CASE("Xmm control adapter preserves a linear function")
{
    const auto result = Xmm::AnalyzeControlStructure(Function(
        { Block(0U, Jump(1U)), Block(1U, Jump(2U)), Block(2U, Return()) }));
    CHECK(result.validForTransformation());
    CHECK(result.controlFlow.reversePostorder
          == std::vector<Xmm::BlockId>{ 0U, 1U, 2U });
    CHECK(Facts(result, 2U).dominators
          == std::vector<Xmm::BlockId>{ 0U, 1U, 2U });
    CHECK(Facts(result, 0U).immediatePostDominator
          == std::optional<Xmm::BlockId>{ 1U });
}

TEST_CASE("Xmm control adapter maps true and false branch edges")
{
    const auto result
        = Xmm::AnalyzeControlStructure(Function({ Block(0U, Branch(1U, 2U)),
                                                  Block(1U, Jump(3U)),
                                                  Block(2U, Jump(3U)),
                                                  Block(3U, Return()) }));
    CHECK(result.controlFlow.preorder
          == std::vector<Xmm::BlockId>{ 0U, 1U, 3U, 2U });
    CHECK(Facts(result, 1U).dominanceFrontier
          == std::vector<Xmm::BlockId>{ 3U });
    CHECK(Facts(result, 2U).dominanceFrontier
          == std::vector<Xmm::BlockId>{ 3U });
}

TEST_CASE("Xmm return and unreachable terminators are exits")
{
    auto unreachable = Xmm::Terminator{};
    unreachable.kind = Xmm::Terminator::Kind::Unreachable;
    const auto result
        = Xmm::AnalyzeControlStructure(Function({ Block(0U, Branch(1U, 2U)),
                                                  Block(1U, Return()),
                                                  Block(2U, unreachable) }));
    CHECK(result.exits == std::vector<Xmm::BlockId>{ 1U, 2U });
    CHECK(result.hasPostDominance);
}

TEST_CASE("Xmm loop structure reaches native loop analysis")
{
    const auto result
        = Xmm::AnalyzeControlStructure(Function({ Block(0U, Jump(1U)),
                                                  Block(1U, Branch(2U, 4U)),
                                                  Block(2U, Jump(3U)),
                                                  Block(3U, Jump(1U)),
                                                  Block(4U, Return()) }));
    REQUIRE(result.naturalLoops.size() == 1U);
    CHECK(result.naturalLoops.front().header == 1U);
    CHECK(result.naturalLoops.front().latch == 3U);
    CHECK(result.naturalLoops.front().members
          == std::vector<Xmm::BlockId>{ 1U, 2U, 3U });
    CHECK(result.naturalLoops.front().exits == std::vector<Xmm::BlockId>{ 4U });
}

TEST_CASE("Xmm irreducible graph is retained as a capability boundary")
{
    const auto result
        = Xmm::AnalyzeControlStructure(Function({ Block(0U, Branch(1U, 2U)),
                                                  Block(1U, Branch(2U, 3U)),
                                                  Block(2U, Branch(1U, 3U)),
                                                  Block(3U, Return()) }));
    REQUIRE(result.irreducibleRegions.size() == 1U);
    CHECK(result.irreducibleRegions.front().members
          == std::vector<Xmm::BlockId>{ 1U, 2U });
    CHECK(result.irreducibleRegions.front().entries
          == std::vector<Xmm::BlockId>{ 1U, 2U });
}

TEST_CASE("Xmm missing jump target invalidates transformation facts")
{
    const auto result
        = Xmm::AnalyzeControlStructure(Function({ Block(0U, Jump(99U)) }));
    CHECK_FALSE(result.validForTransformation());
    REQUIRE(result.controlFlow.issues.size() == 1U);
    CHECK(result.controlFlow.issues.front().kind
          == Analysis::ControlFlowIssueKind::MissingTarget);
    CHECK(result.controlFlow.issues.front().target == 99U);
}

TEST_CASE("Xmm missing entry invalidates transformation facts")
{
    const auto result
        = Xmm::AnalyzeControlStructure(Function({ Block(1U, Return()) }, 0U));
    CHECK_FALSE(result.validForTransformation());
    CHECK(result.controlFlow.preorder.empty());
    CHECK_FALSE(Facts(result, 1U).reachable);
}

TEST_CASE("Xmm unreachable blocks do not alter loop structure")
{
    const auto result
        = Xmm::AnalyzeControlStructure(Function({ Block(0U, Return()),
                                                  Block(10U, Branch(11U, 12U)),
                                                  Block(11U, Jump(12U)),
                                                  Block(12U, Jump(11U)) }));
    CHECK(result.naturalLoops.empty());
    CHECK(result.irreducibleRegions.empty());
    CHECK_FALSE(Facts(result, 11U).reachable);
}

TEST_CASE("Xmm block presentation does not change structural facts")
{
    const auto ordered
        = Xmm::AnalyzeControlStructure(Function({ Block(0U, Branch(1U, 2U)),
                                                  Block(1U, Jump(3U)),
                                                  Block(2U, Jump(3U)),
                                                  Block(3U, Return()) }));
    const auto shuffled
        = Xmm::AnalyzeControlStructure(Function({ Block(3U, Return()),
                                                  Block(2U, Jump(3U)),
                                                  Block(0U, Branch(1U, 2U)),
                                                  Block(1U, Jump(3U)) }));
    CHECK(shuffled.facts == ordered.facts);
    CHECK(shuffled.naturalLoops == ordered.naturalLoops);
    CHECK(shuffled.irreducibleRegions == ordered.irreducibleRegions);
}

TEST_CASE("equivalent Xpp and Xmm graphs receive equal structural facts")
{
    const auto xmm
        = Xmm::AnalyzeControlStructure(Function({ Block(0U, Branch(1U, 2U)),
                                                  Block(1U, Jump(3U)),
                                                  Block(2U, Jump(3U)),
                                                  Block(3U, Branch(4U, 5U)),
                                                  Block(4U, Jump(3U)),
                                                  Block(5U, Return()) }));

    namespace Xpp = tala::xpp;
    auto xppReturn = Xpp::Terminator{};
    xppReturn.kind = Xpp::Terminator::Kind::Return;
    auto xppJump = [](const Xpp::BlockId target) {
        Xpp::Terminator value;
        value.kind = Xpp::Terminator::Kind::Jump;
        value.true_target = target;
        return value;
    };
    auto xppBranch = [](const Xpp::BlockId yes, const Xpp::BlockId no) {
        Xpp::Terminator value;
        value.kind = Xpp::Terminator::Kind::Branch;
        value.true_target = yes;
        value.false_target = no;
        return value;
    };
    Xpp::Function xppFunction;
    xppFunction.entry = 0U;
    xppFunction.blocks = {
        { 0U, {}, xppBranch(1U, 2U) }, { 1U, {}, xppJump(3U) },
        { 2U, {}, xppJump(3U) },       { 3U, {}, xppBranch(4U, 5U) },
        { 4U, {}, xppJump(3U) },       { 5U, {}, xppReturn },
    };
    const auto xpp = Xpp::AnalyzeControlStructure(xppFunction);

    CHECK(xmm.facts == xpp.facts);
    CHECK(xmm.naturalLoops == xpp.naturalLoops);
    CHECK(xmm.irreducibleRegions == xpp.irreducibleRegions);
    CHECK(xmm.exits == xpp.exits);
}
