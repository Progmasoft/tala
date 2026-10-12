// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <ranges>
#include <string_view>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep/Prepare.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Core/Verifier.hpp"
#include "Progmasoft/Tala/Core/Wire.hpp"

// An `else if` reaches Core as a false branch that holds exactly one nested
// conditional statement, so a chain of N links is N levels of nesting. The
// native wire reader and writer, the Core verifier and the Core-to-CorePrep
// adapter walk such a chain in a loop: walking it by recursion uses stack in
// proportion to its length, and a chain of 150 links in valid source used to
// end the compiler with a stack overflow. These tests pin that the loops
// read, check and lower exactly what the nested formulation describes, and
// that a chain far longer than the old limit passes through every stage.

namespace
{
    namespace Core = Progmasoft::Tala::Core;
    namespace Prepared = tala::core;

    constexpr std::uint64_t kValue = 2U;

    [[nodiscard]] auto
    Integer(std::int64_t value) -> Core::Expression
    {
        return Core::Expression::Constant(value, Core::Type::int64());
    }

    [[nodiscard]] auto
    Value() -> Core::Expression
    {
        return Core::Expression::Variable({ kValue, U"value" },
                                          Core::Type::int64());
    }

    /// `value == literal`.
    [[nodiscard]] auto
    Is(std::int64_t literal) -> Core::Expression
    {
        return Core::Expression::InvokePrimitive(Core::Primitive::Equal,
                                                 { Value(), Integer(literal) },
                                                 Core::Type::boolean());
    }

    /// The statement `return literal;`.
    [[nodiscard]] auto
    Give(std::int64_t literal) -> Core::Statement
    {
        return Core::Statement::Return(Integer(literal));
    }

    /**
     * @brief `if (value == 0) { return 1; } else if (value == 1) { ... }`.
     *
     * Link `index` tests `value == index` and returns `index * 3 + 1`. The
     * chain is built from the innermost link outwards, so building it needs
     * no recursion either. The given statements are the false branch of the
     * last link.
     */
    [[nodiscard]] auto
    Chain(std::size_t links, std::vector<Core::Statement> finalBranch)
        -> Core::Statement
    {
        REQUIRE(links > 0U);
        const auto literal = [](std::size_t index) {
            return static_cast<std::int64_t>(index);
        };
        auto statement
            = Core::Statement::If(Is(literal(links - 1U)),
                                  { Give(literal(links - 1U) * 3 + 1) },
                                  std::move(finalBranch));
        for (std::size_t index = links - 1U; index-- > 0U;)
        {
            std::vector<Core::Statement> nested;
            nested.push_back(std::move(statement));
            statement = Core::Statement::If(Is(literal(index)),
                                            { Give(literal(index) * 3 + 1) },
                                            std::move(nested));
        }
        return statement;
    }

    /// `long Pick(long value)` with one body.
    [[nodiscard]] auto
    Module(std::vector<Core::Statement> body) -> Core::Module
    {
        return { { U"Chain" },
                 { Core::Function{
                     { 1U, U"Pick" },
                     { { { kValue, U"value" }, Core::Type::int64() } },
                     Core::Type::int64(),
                     std::move(body) } } };
    }

    /// A chain without an else, followed by `return 0;`.
    [[nodiscard]] auto
    OpenChain(std::size_t links) -> Core::Module
    {
        std::vector<Core::Statement> body;
        body.push_back(Chain(links, {}));
        body.push_back(Give(0));
        return Module(std::move(body));
    }

    /// A chain whose last link has an else that returns.
    [[nodiscard]] auto
    ClosedChain(std::size_t links) -> Core::Module
    {
        std::vector<Core::Statement> body;
        body.push_back(Chain(links, { Give(0) }));
        return Module(std::move(body));
    }

    /// The length of the `else if` chain a statement starts.
    [[nodiscard]] auto
    Links(const Core::Statement &first) -> std::size_t
    {
        std::size_t count = 0U;
        const Core::Statement *link = &first;
        for (;;)
        {
            if (link->kind != Core::Statement::Kind::If)
                return count;
            ++count;
            if (link->falseBranch.size() != 1U)
                return count;
            link = &link->falseBranch.front();
        }
    }

    [[nodiscard]] auto
    HasIssue(const Core::Module &module, std::string_view code) -> bool
    {
        return std::ranges::any_of(Core::Verify(module),
                                   [code](const auto &issue) {
                                       return issue.code == code;
                                   });
    }

    [[nodiscard]] auto
    PrepareVerified(const Core::Module &module) -> Prepared::Function
    {
        for (const auto &issue : Core::Verify(module))
            FAIL_CHECK("Core " << issue.code << ": " << issue.message);
        REQUIRE(Core::Verify(module).empty());
        auto prepared = Core::CorePrep::Prepare(module);
        for (const auto &issue : Prepared::verify(prepared))
            FAIL_CHECK("CorePrep " << issue.code << ": " << issue.message
                                   << " (block " << issue.block << ")");
        REQUIRE(Prepared::verify(prepared).empty());
        REQUIRE(prepared.functions.size() == 1U);
        return std::move(prepared.functions.front());
    }

    [[nodiscard]] auto
    Find(const Prepared::Function &function, Prepared::BlockId id)
        -> const Prepared::Block &
    {
        const auto found
            = std::ranges::find(function.blocks, id, &Prepared::Block::id);
        REQUIRE(found != function.blocks.end());
        return *found;
    }

    [[nodiscard]] auto
    IsJumpTo(const Prepared::Block &block, Prepared::BlockId target) -> bool
    {
        return block.terminator.kind == Prepared::Terminator::Kind::Jump
               && block.terminator.true_target == target;
    }

    [[nodiscard]] auto
    Branches(const Prepared::Function &function) -> std::size_t
    {
        return static_cast<std::size_t>(
            std::ranges::count_if(function.blocks, [](const auto &block) {
                return block.terminator.kind
                       == Prepared::Terminator::Kind::Branch;
            }));
    }

    [[nodiscard]] auto
    Returns(const Prepared::Function &function) -> std::size_t
    {
        return static_cast<std::size_t>(
            std::ranges::count_if(function.blocks, [](const auto &block) {
                return block.terminator.kind
                       == Prepared::Terminator::Kind::Return;
            }));
    }

    // Lengths around the first links, where an off-by-one in the loops would
    // show, and lengths well past the depth that used to overflow the stack.
    constexpr std::array<std::size_t, 6U> kLengths{
        1U, 2U, 3U, 17U, 300U, 600U
    };
} // namespace

TEST_CASE("an else-if chain round-trips through the Core wire at any length",
          "[core][wire][chain]")
{
    for (const auto links : kLengths)
    {
        CAPTURE(links);
        for (const auto &module : { OpenChain(links), ClosedChain(links) })
        {
            const auto encoded = Core::Wire::Encode(module);
            REQUIRE(encoded);
            const auto decoded = Core::Wire::Decode(encoded.bytes);
            REQUIRE(decoded);
            CHECK(Links(decoded.module->functions.front().body.front())
                  == links);
            CHECK(*decoded.module == module);
            // The writer and the reader agree on the bytes of every link.
            const auto again = Core::Wire::Encode(*decoded.module);
            REQUIRE(again);
            CHECK(again.bytes == encoded.bytes);
        }
    }
}

TEST_CASE("every link of a chain adds the same number of wire bytes",
          "[core][wire][chain]")
{
    // A link is written as its condition, its true branch, the count of its
    // false branch and the tag of the next link, whatever its position. A
    // writer that lost or repeated a field at the join between two links
    // would break the constant step.
    const auto size = [](std::size_t links) {
        const auto encoded = Core::Wire::Encode(OpenChain(links));
        REQUIRE(encoded);
        return encoded.bytes.size();
    };
    const auto step = size(2U) - size(1U);
    CHECK(step > 0U);
    CHECK(size(3U) - size(2U) == step);
    CHECK(size(9U) - size(8U) == step);
    CHECK(size(300U) - size(299U) == step);
}

TEST_CASE("a false branch that is not exactly one conditional ends the chain",
          "[core][wire][chain]")
{
    SECTION("a conditional followed by another statement")
    {
        std::vector<Core::Statement> branch;
        branch.push_back(Chain(2U, {}));
        branch.push_back(Core::Statement::Evaluate(Value()));
        std::vector<Core::Statement> body;
        body.push_back(Chain(1U, std::move(branch)));
        body.push_back(Give(0));
        const auto module = Module(std::move(body));
        const auto encoded = Core::Wire::Encode(module);
        REQUIRE(encoded);
        const auto decoded = Core::Wire::Decode(encoded.bytes);
        REQUIRE(decoded);
        CHECK(*decoded.module == module);
        const auto &first = decoded.module->functions.front().body.front();
        REQUIRE(first.falseBranch.size() == 2U);
        CHECK(Links(first.falseBranch.front()) == 2U);
    }
    SECTION("a single statement that is not a conditional")
    {
        const auto module = ClosedChain(3U);
        const auto encoded = Core::Wire::Encode(module);
        REQUIRE(encoded);
        const auto decoded = Core::Wire::Decode(encoded.bytes);
        REQUIRE(decoded);
        CHECK(*decoded.module == module);
    }
    SECTION("an empty false branch")
    {
        const auto module = OpenChain(1U);
        const auto encoded = Core::Wire::Encode(module);
        REQUIRE(encoded);
        const auto decoded = Core::Wire::Decode(encoded.bytes);
        REQUIRE(decoded);
        CHECK(
            decoded.module->functions.front().body.front().falseBranch.empty());
        CHECK(*decoded.module == module);
    }
}

TEST_CASE("every proper prefix of a chain document is rejected",
          "[core][wire][chain]")
{
    // The reader takes the tag of the next link itself. Input that ends at
    // any byte, including between a false branch count and that tag, must
    // fail as truncated and must not read past the end.
    const auto encoded = Core::Wire::Encode(ClosedChain(4U));
    REQUIRE(encoded);
    for (std::size_t length = 0U; length < encoded.bytes.size(); ++length)
    {
        CAPTURE(length);
        const std::vector<std::uint8_t> prefix(
            encoded.bytes.begin(),
            encoded.bytes.begin() + static_cast<std::ptrdiff_t>(length));
        CHECK_FALSE(Core::Wire::Decode(prefix));
    }
}

TEST_CASE("the verifier checks every link of a chain", "[core][verify][chain]")
{
    for (const auto links : kLengths)
    {
        CAPTURE(links);
        CHECK(Core::Verify(OpenChain(links)).empty());
        CHECK(Core::Verify(ClosedChain(links)).empty());
    }

    SECTION("a condition that is not Boolean is reported in a late link")
    {
        // The last link of forty tests a string.
        auto text = Core::Statement::If(
            Core::Expression::Constant(std::u32string(U"text"),
                                       Core::Type::string()),
            { Give(1) },
            {});
        std::vector<Core::Statement> last;
        last.push_back(std::move(text));
        std::vector<Core::Statement> body;
        body.push_back(Chain(39U, std::move(last)));
        body.push_back(Give(0));
        const auto module = Module(std::move(body));
        CHECK(HasIssue(module, "TAC1017"));
        CHECK_FALSE(HasIssue(OpenChain(40U), "TAC1017"));
    }

    SECTION("a return of the wrong type is reported in a late link")
    {
        auto wrong = Core::Statement::If(
            Is(39),
            { Core::Statement::Return(
                Core::Expression::Constant(true, Core::Type::boolean())) },
            {});
        std::vector<Core::Statement> last;
        last.push_back(std::move(wrong));
        std::vector<Core::Statement> body;
        body.push_back(Chain(39U, std::move(last)));
        body.push_back(Give(0));
        const auto module = Module(std::move(body));
        CHECK(HasIssue(module, "TAC1016"));
        CHECK_FALSE(HasIssue(OpenChain(40U), "TAC1016"));
    }
}

TEST_CASE("a chain returns on every path only when its last link has an else",
          "[core][verify][chain]")
{
    for (const auto links : kLengths)
    {
        CAPTURE(links);
        // Every link returns and the else returns: nothing may follow.
        CHECK_FALSE(HasIssue(ClosedChain(links), "TAC1005"));
        // Without an else the function falls off its end.
        std::vector<Core::Statement> open;
        open.push_back(Chain(links, {}));
        const auto checked = Module(std::move(open));
        CHECK(HasIssue(checked, "TAC1005"));
    }

    SECTION("a link whose true branch does not return keeps the path open")
    {
        // The middle link evaluates instead of returning.
        std::vector<Core::Statement> tail;
        tail.push_back(Chain(2U, { Give(0) }));
        auto middle
            = Core::Statement::If(Is(7),
                                  { Core::Statement::Evaluate(Value()) },
                                  std::move(tail));
        std::vector<Core::Statement> rest;
        rest.push_back(std::move(middle));
        std::vector<Core::Statement> body;
        body.push_back(Chain(2U, std::move(rest)));
        const auto module = Module(std::move(body));
        CHECK(HasIssue(module, "TAC1005"));
    }

    SECTION("statements after an open chain still decide")
    {
        // The chain does not return on every path, the return after it does.
        CHECK_FALSE(HasIssue(OpenChain(5U), "TAC1005"));
    }
}

TEST_CASE("the adapter numbers the blocks of a chain as nested conditionals",
          "[core][coreprep][chain]")
{
    // Link k takes blocks 3k + 1, 3k + 2 and 3k + 3 for its true branch, its
    // false branch and its join. The joins are completed from the innermost
    // outwards, each falling through to the join of the link around it, and
    // the statement after the chain continues in the join of the first link.
    const auto function = PrepareVerified(OpenChain(3U));
    CHECK(function.blocks.size() == 10U);
    CHECK(Branches(function) == 3U);

    const auto &entry = Find(function, 0U);
    REQUIRE(entry.terminator.kind == Prepared::Terminator::Kind::Branch);
    CHECK(entry.terminator.true_target == 1U);
    CHECK(entry.terminator.false_target == 2U);

    const auto &second = Find(function, 2U);
    REQUIRE(second.terminator.kind == Prepared::Terminator::Kind::Branch);
    CHECK(second.terminator.true_target == 4U);
    CHECK(second.terminator.false_target == 5U);

    const auto &third = Find(function, 5U);
    REQUIRE(third.terminator.kind == Prepared::Terminator::Kind::Branch);
    CHECK(third.terminator.true_target == 7U);
    CHECK(third.terminator.false_target == 8U);

    for (const Prepared::BlockId trueBlock : { 1U, 4U, 7U })
        CHECK(Find(function, trueBlock).terminator.kind
              == Prepared::Terminator::Kind::Return);

    // The empty false branch of the last link, then the joins outwards.
    CHECK(IsJumpTo(Find(function, 8U), 9U));
    CHECK(IsJumpTo(Find(function, 9U), 6U));
    CHECK(IsJumpTo(Find(function, 6U), 3U));
    CHECK(Find(function, 3U).terminator.kind
          == Prepared::Terminator::Kind::Return);
}

TEST_CASE("the adapter prepares a chain of any length",
          "[core][coreprep][chain]")
{
    for (const auto links : kLengths)
    {
        CAPTURE(links);
        const auto open = PrepareVerified(OpenChain(links));
        CHECK(open.blocks.size() == links * 3U + 1U);
        CHECK(Branches(open) == links);
        // One return in every link and the one after the chain.
        CHECK(Returns(open) == links + 1U);

        const auto closed = PrepareVerified(ClosedChain(links));
        CHECK(Branches(closed) == links);
        // One return in every link and the one in the else.
        CHECK(Returns(closed) == links + 1U);
    }
}

TEST_CASE("a loop that cannot be left never falls off the end of a body",
          "[core][verifier]")
{
    const auto always = [] {
        return Core::Expression::Constant(true, Core::Type::boolean());
    };
    // The function is moved into its module. A braced list would copy it,
    // and copying a statement recurses once per level of nesting.
    const auto ends = [](Core::Statement loop) {
        Core::Function function{ { 1U, U"Pick" },
                                 { { { kValue, U"value" },
                                     Core::Type::int64() } },
                                 Core::Type::int64(),
                                 {} };
        function.body.push_back(std::move(loop));
        Core::Module module{ { U"Chain" }, {} };
        module.functions.push_back(std::move(function));
        return module;
    };

    SECTION("an endless loop of each kind ends a body that returns a value")
    {
        CHECK_FALSE(
            HasIssue(ends(Core::Statement::While(always(), {})), "TAC1005"));
        CHECK_FALSE(
            HasIssue(ends(Core::Statement::DoWhile({}, always())), "TAC1005"));
        CHECK_FALSE(
            HasIssue(ends(Core::Statement::For(always(), {}, {})), "TAC1005"));
    }

    SECTION("a break leaves the loop, from its body and from its update")
    {
        CHECK(HasIssue(ends(Core::Statement::While(
                           always(),
                           { Core::Statement::If(Is(1),
                                                 { Core::Statement::Break() },
                                                 {}) })),
                       "TAC1005"));
        CHECK(HasIssue(ends(Core::Statement::For(always(),
                                                 {},
                                                 { Core::Statement::Break() })),
                       "TAC1005"));
    }

    SECTION("a break at the end of a long else-if chain is found")
    {
        // The search walks the chain from a list, not by recursion. The
        // chain is moved into the loop: copying one recurses per link.
        constexpr std::size_t kLinks = 600U;
        const auto around = [&](std::vector<Core::Statement> last) {
            std::vector<Core::Statement> body;
            body.push_back(Chain(kLinks, std::move(last)));
            return ends(Core::Statement::While(always(), std::move(body)));
        };
        std::vector<Core::Statement> leaves;
        leaves.push_back(Core::Statement::Break());
        const auto left = around(std::move(leaves));
        CHECK(HasIssue(left, "TAC1005"));
        CHECK_FALSE(HasIssue(around({}), "TAC1005"));
    }

    SECTION("a loop with a condition, or left only by a nested break")
    {
        CHECK(HasIssue(ends(Core::Statement::While(Is(1), {})), "TAC1005"));
        CHECK_FALSE(HasIssue(
            ends(Core::Statement::While(
                always(),
                { Core::Statement::While(always(),
                                         { Core::Statement::Break() }) })),
            "TAC1005"));
    }
}
