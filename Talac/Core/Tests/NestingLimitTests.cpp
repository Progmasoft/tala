// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep/Prepare.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Core/Verifier.hpp"
#include "Progmasoft/Tala/Core/Wire.hpp"
#include "Progmasoft/Tala/Support/CompilerStack.hpp"

// The native stages recurse once per level of statement nesting. The wire
// reader is the boundary at which untrusted Core enters them, so it bounds
// that level as it bounds type and expression depth, and the writer refuses
// what the reader would reject. These tests pin where the level is counted:
// every body is one level below the statement or closure that holds it, the
// links of an `else if` chain share a level, and an empty body costs none.
// The last tests nest far deeper than the stack of a test process allows and
// run on the compiler stack, the one the limits are stated against.

namespace
{
    namespace Core = Progmasoft::Tala::Core;
    namespace Prepared = tala::core;
    namespace Wire = Progmasoft::Tala::Core::Wire;

    constexpr std::uint64_t kValue = 2U;
    constexpr std::uint64_t kTotal = 3U;

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

    [[nodiscard]] auto
    Total() -> Core::Expression
    {
        return Core::Expression::Variable({ kTotal, U"total" },
                                          Core::Type::int64());
    }

    /// `value > literal`.
    [[nodiscard]] auto
    Exceeds(std::int64_t literal) -> Core::Expression
    {
        return Core::Expression::InvokePrimitive(Core::Primitive::GreaterThan,
                                                 { Value(), Integer(literal) },
                                                 Core::Type::boolean());
    }

    /// `total = total + 1;`
    [[nodiscard]] auto
    Count() -> Core::Statement
    {
        return Core::Statement::Assign(
            { kTotal, U"total" },
            Core::Expression::InvokePrimitive(Core::Primitive::Add,
                                              { Total(), Integer(1) },
                                              Core::Type::int64()));
    }

    /**
     * @brief `if (value > 0) { if (value > 1) { ... total = total + 1; } }`.
     *
     * With `levels` conditionals the assignment is `levels` bodies below the
     * function body. The nest is built from the inside out, so building it
     * does not recurse.
     */
    [[nodiscard]] auto
    Nest(std::size_t levels) -> Core::Statement
    {
        auto statement = Count();
        for (std::size_t index = levels; index-- > 0U;)
        {
            std::vector<Core::Statement> body;
            body.push_back(std::move(statement));
            statement
                = Core::Statement::If(Exceeds(static_cast<std::int64_t>(index)),
                                      std::move(body),
                                      {});
        }
        return statement;
    }

    /// `long Pick(long value) { long total = 0; <statement> return total; }`
    [[nodiscard]] auto
    Module(Core::Statement statement) -> Core::Module
    {
        std::vector<Core::Statement> body;
        body.push_back(
            Core::Statement::Bind(Core::Binding{ { kTotal, U"total" },
                                                 Core::Type::int64(),
                                                 true,
                                                 Integer(0) }));
        body.push_back(std::move(statement));
        body.push_back(Core::Statement::Return(Total()));
        // The function is moved into the module. A braced list would copy
        // it, and copying nested statements recurses once per level.
        Core::Module module;
        module.name = { U"Nesting" };
        module.functions.push_back(
            Core::Function{ { 1U, U"Pick" },
                            { { { kValue, U"value" }, Core::Type::int64() } },
                            Core::Type::int64(),
                            std::move(body) });
        return module;
    }

    [[nodiscard]] auto
    WithDepth(std::size_t depth) -> Wire::Limits
    {
        Wire::Limits limits;
        limits.maximumStatementDepth = depth;
        return limits;
    }

    [[nodiscard]] auto
    IsLimit(const std::optional<Wire::Error> &error) -> bool
    {
        return error && error->kind == Wire::ErrorKind::LimitExceeded;
    }
} // namespace

TEST_CASE("the default statement depth limit matches the expression limit",
          "[core][wire][nesting]")
{
    const Wire::Limits limits;
    CHECK(limits.maximumStatementDepth == 4096U);
    CHECK(limits.maximumExpressionDepth == 4096U);
}

TEST_CASE("the wire bounds the nesting of statement bodies",
          "[core][wire][nesting]")
{
    // The function body is level 1, so `levels` conditionals put the
    // innermost body at level `levels + 1`.
    constexpr std::size_t kLevels = 7U;
    const auto module = Module(Nest(kLevels));
    REQUIRE(Core::Verify(module).empty());

    SECTION("a module at the limit is written and read")
    {
        const auto limits = WithDepth(kLevels + 1U);
        const auto encoded = Wire::Encode(module, limits);
        REQUIRE(encoded);
        const auto decoded = Wire::Decode(encoded.bytes, limits);
        REQUIRE(decoded);
        CHECK(*decoded.module == module);
    }
    SECTION("the writer refuses a module one level beyond the limit")
    {
        const auto encoded = Wire::Encode(module, WithDepth(kLevels));
        CHECK_FALSE(encoded);
        CHECK(IsLimit(encoded.error));
    }
    SECTION("the reader refuses a document one level beyond the limit")
    {
        const auto encoded = Wire::Encode(module);
        REQUIRE(encoded);
        const auto decoded = Wire::Decode(encoded.bytes, WithDepth(kLevels));
        CHECK_FALSE(decoded);
        CHECK(IsLimit(decoded.error));
    }
    SECTION("a limit of zero refuses any body with a statement")
    {
        const auto encoded = Wire::Encode(module);
        REQUIRE(encoded);
        CHECK(IsLimit(Wire::Decode(encoded.bytes, WithDepth(0U)).error));
        CHECK(IsLimit(Wire::Encode(module, WithDepth(0U)).error));
    }
}

TEST_CASE("the links of an else-if chain share one nesting level",
          "[core][wire][nesting]")
{
    // if (value > 0) { count } else if (value > 1) { count } ... : the
    // bodies of all links are at level 2, whatever the length of the chain.
    auto statement = Core::Statement::If(Exceeds(99), { Count() }, { Count() });
    for (std::int64_t index = 98; index >= 0; --index)
    {
        std::vector<Core::Statement> next;
        next.push_back(std::move(statement));
        statement
            = Core::Statement::If(Exceeds(index), { Count() }, std::move(next));
    }
    const auto module = Module(std::move(statement));
    REQUIRE(Core::Verify(module).empty());

    const auto atLimit = WithDepth(2U);
    const auto encoded = Wire::Encode(module, atLimit);
    REQUIRE(encoded);
    const auto decoded = Wire::Decode(encoded.bytes, atLimit);
    REQUIRE(decoded);
    CHECK(*decoded.module == module);

    CHECK(IsLimit(Wire::Encode(module, WithDepth(1U)).error));
    CHECK(IsLimit(Wire::Decode(encoded.bytes, WithDepth(1U)).error));
}

TEST_CASE("an empty body costs no nesting level", "[core][wire][nesting]")
{
    // Two conditionals nested through their true branches, each with an
    // empty false branch. The innermost body is at level 3; the empty
    // branches need no level of their own, at the limit or beyond it.
    std::vector<Core::Statement> inner;
    inner.push_back(Core::Statement::If(Exceeds(1), { Count() }, {}));
    const auto module
        = Module(Core::Statement::If(Exceeds(0), std::move(inner), {}));
    REQUIRE(Core::Verify(module).empty());

    const auto limits = WithDepth(3U);
    const auto encoded = Wire::Encode(module, limits);
    REQUIRE(encoded);
    const auto decoded = Wire::Decode(encoded.bytes, limits);
    REQUIRE(decoded);
    CHECK(*decoded.module == module);
    CHECK(IsLimit(Wire::Encode(module, WithDepth(2U)).error));
    CHECK(IsLimit(Wire::Decode(encoded.bytes, WithDepth(2U)).error));

    // A body of only empty branches is written at a limit of one level.
    const auto hollow = Module(Core::Statement::If(Exceeds(0), {}, {}));
    const auto shallow = Wire::Encode(hollow, WithDepth(1U));
    REQUIRE(shallow);
    CHECK(Wire::Decode(shallow.bytes, WithDepth(1U)));
}

TEST_CASE("a loop body and a closure body are one level below their owner",
          "[core][wire][nesting]")
{
    SECTION("while")
    {
        const auto module
            = Module(Core::Statement::While(Exceeds(0), { Count() }));
        CHECK(Wire::Encode(module, WithDepth(2U)));
        CHECK(IsLimit(Wire::Encode(module, WithDepth(1U)).error));
    }
    SECTION("closure")
    {
        // The closure is an operand of a statement in the function body, so
        // its own body is at level 2 and the conditional's body at level 3.
        auto closure = Core::Expression::Closure(
            {},
            {},
            Core::Type::int64(),
            { Core::Statement::If(
                  Core::Expression::Constant(true, Core::Type::boolean()),
                  { Core::Statement::Return(Integer(1)) },
                  {}),
              Core::Statement::Return(Integer(0)) },
            Core::Type::function({}, Core::Type::int64()));
        const auto module
            = Module(Core::Statement::Evaluate(std::move(closure)));
        const auto encoded = Wire::Encode(module, WithDepth(3U));
        REQUIRE(encoded);
        const auto decoded = Wire::Decode(encoded.bytes, WithDepth(3U));
        REQUIRE(decoded);
        CHECK(*decoded.module == module);
        CHECK(IsLimit(Wire::Encode(module, WithDepth(2U)).error));
        CHECK(IsLimit(Wire::Decode(encoded.bytes, WithDepth(2U)).error));
    }
}

TEST_CASE("the compiler stack carries a result back to its caller",
          "[core][stack]")
{
    CHECK(Progmasoft::Tala::Support::RunOnCompilerStack([] {
              return 42;
          })
          == 42);
    int touched = 0;
    Progmasoft::Tala::Support::RunOnCompilerStack([&touched] {
        touched = 7;
    });
    CHECK(touched == 7);
    CHECK(Progmasoft::Tala::Support::kCompilerStackBytes
          == std::size_t{ 256U } * 1024U * 1024U);
}

TEST_CASE("every native Core stage walks deep nesting on the compiler stack",
          "[core][nesting][stack]")
{
    // 1500 levels is more than five times the frontend's statement limit
    // and far beyond what the stack of this process could carry: about 80
    // levels fit in one megabyte. Building, comparing and destroying the
    // nest recurse as well, so all of it happens on the compiler stack.
    constexpr std::size_t kLevels = 1500U;
    const auto outcome = Progmasoft::Tala::Support::RunOnCompilerStack([] {
        const auto module = Module(Nest(kLevels));
        if (!Core::Verify(module).empty())
            return 1;
        const auto encoded = Wire::Encode(module);
        if (!encoded)
            return 2;
        const auto decoded = Wire::Decode(encoded.bytes);
        if (!decoded || !(*decoded.module == module))
            return 3;
        const auto prepared = Core::CorePrep::Prepare(*decoded.module);
        if (!Prepared::verify(prepared).empty())
            return 4;
        // One branch per conditional.
        std::size_t branches = 0U;
        for (const auto &block : prepared.functions.front().blocks)
            if (block.terminator.kind == Prepared::Terminator::Kind::Branch)
                ++branches;
        return branches == kLevels ? 0 : 5;
    });
    CHECK(outcome == 0);
}

TEST_CASE("the reader refuses nesting beyond the default limit",
          "[core][wire][nesting][stack]")
{
    // One level beyond the default. The writer is given a larger limit so
    // that the document exists; the reader with the default must refuse it
    // with a limit error and without walking it.
    constexpr std::size_t kLevels = 4096U;
    const auto outcome = Progmasoft::Tala::Support::RunOnCompilerStack([] {
        const auto module = Module(Nest(kLevels));
        const auto encoded = Wire::Encode(module, WithDepth(kLevels + 1U));
        if (!encoded)
            return 1;
        if (!IsLimit(Wire::Encode(module).error))
            return 2;
        return IsLimit(Wire::Decode(encoded.bytes).error) ? 0 : 3;
    });
    CHECK(outcome == 0);
}

TEST_CASE("the adapter prepares a long chain without copying the module",
          "[core][coreprep][nesting]")
{
    // A chain of 3000 links is 3000 levels of nested statements. Copying
    // such a statement recurses once per level, and the adapter used to
    // copy every function before preparing it, which overflowed the stack
    // near 1500 links. Verification and preparation themselves walk a chain
    // in a loop; building and destroying the module still recurse, so the
    // whole test runs on the compiler stack.
    constexpr std::size_t kLinks = 3000U;
    const auto outcome = Progmasoft::Tala::Support::RunOnCompilerStack([] {
        auto statement = Core::Statement::If(Exceeds(0), { Count() }, {});
        for (std::size_t index = 1U; index < kLinks; ++index)
        {
            std::vector<Core::Statement> next;
            next.push_back(std::move(statement));
            statement
                = Core::Statement::If(Exceeds(static_cast<std::int64_t>(index)),
                                      { Count() },
                                      std::move(next));
        }
        const auto module = Module(std::move(statement));
        if (!Core::Verify(module).empty())
            return 1;
        const auto prepared = Core::CorePrep::Prepare(module);
        if (!Prepared::verify(prepared).empty())
            return 2;
        std::size_t branches = 0U;
        for (const auto &block : prepared.functions.front().blocks)
            if (block.terminator.kind == Prepared::Terminator::Kind::Branch)
                ++branches;
        return branches == kLinks ? 0 : 3;
    });
    CHECK(outcome == 0);
}

namespace
{
    /// `value + value + ...` with the given number of additions, each sum
    /// the first operand of the next.
    [[nodiscard]] auto
    LeftChain(std::size_t additions) -> Core::Expression
    {
        auto expression = Value();
        for (std::size_t index = 0U; index < additions; ++index)
        {
            std::vector<Core::Expression> operands;
            operands.push_back(std::move(expression));
            operands.push_back(Value());
            expression = Core::Expression::InvokePrimitive(Core::Primitive::Add,
                                                           std::move(operands),
                                                           Core::Type::int64());
        }
        return expression;
    }

    /// `value + (value + (...))` with the given number of additions, each
    /// sum the second operand of the one around it.
    [[nodiscard]] auto
    RightChain(std::size_t additions) -> Core::Expression
    {
        auto expression = Value();
        for (std::size_t index = 0U; index < additions; ++index)
        {
            std::vector<Core::Expression> operands;
            operands.push_back(Value());
            operands.push_back(std::move(expression));
            expression = Core::Expression::InvokePrimitive(Core::Primitive::Add,
                                                           std::move(operands),
                                                           Core::Type::int64());
        }
        return expression;
    }

    [[nodiscard]] auto
    WithExpressionDepth(std::size_t depth) -> Wire::Limits
    {
        Wire::Limits limits;
        limits.maximumExpressionDepth = depth;
        return limits;
    }
} // namespace

TEST_CASE("a chain of operators is one expression level",
          "[core][wire][nesting]")
{
    // The first operand of a primitive is at the level of the primitive.
    // A sum of 20001 operands therefore fits a depth limit of one, and the
    // whole test runs on the stack the test process starts with: the
    // writer, the reader, the verifier and the adapter walk the chain in a
    // loop, and releasing the module does not recurse along it either.
    constexpr std::size_t kAdditions = 20000U;
    const auto module = Module(
        Core::Statement::Assign({ kTotal, U"total" }, LeftChain(kAdditions)));
    const auto limits = WithExpressionDepth(1U);
    const auto encoded = Wire::Encode(module, limits);
    REQUIRE(encoded);
    const auto decoded = Wire::Decode(encoded.bytes, limits);
    REQUIRE(decoded);
    REQUIRE(decoded.module);
    const auto again = Wire::Encode(*decoded.module, limits);
    REQUIRE(again);
    CHECK(again.bytes == encoded.bytes);
    CHECK(Core::Verify(*decoded.module).empty());
    const auto prepared = Core::CorePrep::Prepare(*decoded.module);
    CHECK(Prepared::verify(prepared).empty());
    REQUIRE(prepared.functions.size() == 1U);
    // One block: the binding of `total`, a temporary for every addition,
    // and the assignment that copies the last one.
    REQUIRE(prepared.functions.front().blocks.size() == 1U);
    CHECK(prepared.functions.front().blocks.front().instructions.size()
          == kAdditions + 2U);
}

TEST_CASE("an operand after the first is one expression level deeper",
          "[core][wire][nesting]")
{
    // Five additions that nest to the right put the innermost operand at
    // depth five; the expression of the statement is at depth zero.
    const auto module
        = Module(Core::Statement::Assign({ kTotal, U"total" }, RightChain(5U)));
    CHECK(Wire::Encode(module, WithExpressionDepth(5U)));
    CHECK(IsLimit(Wire::Encode(module, WithExpressionDepth(4U)).error));
    const auto encoded = Wire::Encode(module, WithExpressionDepth(5U));
    REQUIRE(encoded);
    CHECK(Wire::Decode(encoded.bytes, WithExpressionDepth(5U)));
    CHECK(IsLimit(Wire::Decode(encoded.bytes, WithExpressionDepth(4U)).error));
}

TEST_CASE("a long else-if chain is handled on the default stack",
          "[core][coreprep][nesting]")
{
    // 20000 links are 20000 levels of nested statements. Every native Core
    // stage walks them in a loop and the statements are released from a
    // list, so none of this needs the compiler stack.
    constexpr std::size_t kLinks = 20000U;
    auto statement = Core::Statement::If(Exceeds(0), { Count() }, {});
    for (std::size_t index = 1U; index < kLinks; ++index)
    {
        std::vector<Core::Statement> next;
        next.push_back(std::move(statement));
        statement
            = Core::Statement::If(Exceeds(static_cast<std::int64_t>(index)),
                                  { Count() },
                                  std::move(next));
    }
    const auto module = Module(std::move(statement));
    const auto encoded = Wire::Encode(module);
    REQUIRE(encoded);
    const auto decoded = Wire::Decode(encoded.bytes);
    REQUIRE(decoded);
    REQUIRE(decoded.module);
    CHECK(Core::Verify(*decoded.module).empty());
    const auto prepared = Core::CorePrep::Prepare(*decoded.module);
    CHECK(Prepared::verify(prepared).empty());
}
