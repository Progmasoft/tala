// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Backend/LLVM.hpp"
#include "Progmasoft/Tala/Core/IR.hpp"
#include "Progmasoft/Tala/Core/Wire.hpp"
#include "Progmasoft/Tala/Pipeline.hpp"

// Executable short-circuit regressions. The right operand of each case is
// only well defined when the left operand guards it: a division whose
// divisor the guard excludes, or a recursive call the guard terminates. A
// pipeline that evaluates both operands traps or never returns, so these
// programs observe laziness itself rather than only the final Boolean.

namespace
{
    namespace Core = Progmasoft::Tala::Core;
    namespace Llvm = Progmasoft::Tala::Backend::LLVM;
    namespace Pipeline = Progmasoft::Tala::Pipeline;

    constexpr std::uint64_t kValue = 2U;
    constexpr std::uint64_t kTotal = 3U;
    constexpr std::uint64_t kDown = 10U;
    constexpr std::uint64_t kDownParameter = 11U;

    [[nodiscard]] auto
    Integer(std::int64_t value) -> Core::Expression
    {
        return Core::Expression::Constant(value, Core::Type::int64());
    }

    [[nodiscard]] auto
    Variable(std::uint64_t id, std::u32string spelling) -> Core::Expression
    {
        return Core::Expression::Variable({ id, std::move(spelling) },
                                          Core::Type::int64());
    }

    [[nodiscard]] auto
    Value() -> Core::Expression
    {
        return Variable(kValue, U"value");
    }

    [[nodiscard]] auto
    Binary(Core::Primitive operation,
           Core::Expression left,
           Core::Expression right,
           Core::Type type) -> Core::Expression
    {
        return Core::Expression::InvokePrimitive(
            operation,
            { std::move(left), std::move(right) },
            std::move(type));
    }

    [[nodiscard]] auto
    Compare(Core::Primitive operation,
            Core::Expression left,
            Core::Expression right) -> Core::Expression
    {
        return Binary(operation,
                      std::move(left),
                      std::move(right),
                      Core::Type::boolean());
    }

    [[nodiscard]] auto
    Quotient(std::int64_t dividend, Core::Expression divisor)
        -> Core::Expression
    {
        return Binary(Core::Primitive::Divide,
                      Integer(dividend),
                      std::move(divisor),
                      Core::Type::int64());
    }

    /// `int value = <input>; int total = 0; <statements>; return total;`
    [[nodiscard]] auto
    Evaluate(std::int64_t input, std::vector<Core::Statement> statements)
        -> Core::Function
    {
        std::vector<Core::Statement> body{
            Core::Statement::Bind({ { kValue, U"value" },
                                    Core::Type::int64(),
                                    true,
                                    Integer(input) }),
            Core::Statement::Bind(
                { { kTotal, U"total" }, Core::Type::int64(), true, Integer(0) })
        };
        body.insert(body.end(),
                    std::make_move_iterator(statements.begin()),
                    std::make_move_iterator(statements.end()));
        body.push_back(Core::Statement::Return(Variable(kTotal, U"total")));
        return { { 1U, U"Evaluate" },
                 {},
                 Core::Type::int64(),
                 std::move(body) };
    }

    [[nodiscard]] auto
    SetTotal(std::int64_t value) -> Core::Statement
    {
        return Core::Statement::Assign({ kTotal, U"total" }, Integer(value));
    }

    [[nodiscard]] auto
    Run(const Core::Module &module, bool optimize) -> std::int64_t
    {
        const auto encoded = Core::Wire::Encode(module);
        REQUIRE(encoded);
        Pipeline::Options options;
        options.optimize_xpp = optimize;
        options.optimize_xmm = optimize;
        options.llvm.optimization = optimize ? Llvm::OptimizationLevel::Default
                                             : Llvm::OptimizationLevel::Debug;
        const auto pipeline = Pipeline::ConsumeCore(encoded.bytes, options);
        REQUIRE(pipeline);
        REQUIRE(pipeline.llvm);

        constexpr std::string_view kSymbol = "ShortCircuit.Evaluate.1";
        Llvm::JitSession session;
        const auto rejected = session.AddModule(pipeline.llvm->bitcode,
                                                "short-circuit-execution",
                                                kSymbol,
                                                Core::Type::int64());
        REQUIRE_FALSE(rejected);
        const auto result = session.InvokeScalar(kSymbol, Core::Type::int64());
        REQUIRE(result);
        return std::get<std::int64_t>(result.value->payload);
    }

    void
    CheckBothPipelines(std::vector<Core::Function> functions,
                       std::int64_t expected)
    {
        const Core::Module module{ { U"ShortCircuit" }, std::move(functions) };
        CHECK(Run(module, false) == expected);
        CHECK(Run(module, true) == expected);
    }
} // namespace

TEST_CASE("logical and does not evaluate a division its left operand excludes",
          "[llvm][shortcircuit][execution]")
{
    for (std::int64_t input = -3; input <= 3; ++input)
    {
        const std::int64_t expected = (input != 0 && 12 / input > 2) ? 1 : 0;
        CAPTURE(input);
        CheckBothPipelines(
            { Evaluate(
                input,
                { Core::Statement::If(
                    Compare(
                        Core::Primitive::LogicalAnd,
                        Compare(Core::Primitive::NotEqual, Value(), Integer(0)),
                        Compare(Core::Primitive::GreaterThan,
                                Quotient(12, Value()),
                                Integer(2))),
                    { SetTotal(1) },
                    {}) }) },
            expected);
    }
}

TEST_CASE("logical or does not evaluate a division its left operand excludes",
          "[llvm][shortcircuit][execution]")
{
    for (std::int64_t input = -3; input <= 3; ++input)
    {
        const std::int64_t expected = (input == 0 || 12 / input < 0) ? 1 : 0;
        CAPTURE(input);
        CheckBothPipelines(
            { Evaluate(
                input,
                { Core::Statement::If(
                    Compare(
                        Core::Primitive::LogicalOr,
                        Compare(Core::Primitive::Equal, Value(), Integer(0)),
                        Compare(Core::Primitive::LessThan,
                                Quotient(12, Value()),
                                Integer(0))),
                    { SetTotal(1) },
                    {}) }) },
            expected);
    }
}

TEST_CASE("short-circuit value is usable as an ordinary Boolean binding",
          "[llvm][shortcircuit][execution]")
{
    // The operator's value, not only its branch, must be the lazy result:
    // bind it, then test the binding after an unrelated statement.
    constexpr std::uint64_t kFlag = 4U;
    for (std::int64_t input = -2; input <= 2; ++input)
    {
        const bool flag = input != 0 && 8 / input == 4;
        const std::int64_t expected = flag ? 7 : 5;
        CAPTURE(input);
        CheckBothPipelines(
            { Evaluate(input,
                       { Core::Statement::Bind(
                             { { kFlag, U"flag" },
                               Core::Type::boolean(),
                               false,
                               Compare(Core::Primitive::LogicalAnd,
                                       Compare(Core::Primitive::NotEqual,
                                               Value(),
                                               Integer(0)),
                                       Compare(Core::Primitive::Equal,
                                               Quotient(8, Value()),
                                               Integer(4))) }),
                         SetTotal(5),
                         Core::Statement::If(
                             Core::Expression::Variable({ kFlag, U"flag" },
                                                        Core::Type::boolean()),
                             { SetTotal(7) },
                             {}) }) },
            expected);
    }
}

TEST_CASE("guarded recursion terminates through a short-circuit operator",
          "[llvm][shortcircuit][execution]")
{
    // bool Down(int n) { return n == 0 || Down(n - 1); }
    // Evaluating the call eagerly recurses below zero without bound.
    const auto downType
        = Core::Type::function({ Core::Type::int64() }, Core::Type::boolean());
    const auto parameter = [] {
        return Variable(kDownParameter, U"n");
    };
    Core::Function down{
        { kDown, U"Down" },
        { { { kDownParameter, U"n" }, Core::Type::int64() } },
        Core::Type::boolean(),
        { Core::Statement::Return(Compare(
            Core::Primitive::LogicalOr,
            Compare(Core::Primitive::Equal, parameter(), Integer(0)),
            Core::Expression::Apply(
                Core::Expression::Variable({ kDown, U"Down" }, downType),
                { Binary(Core::Primitive::Subtract,
                         parameter(),
                         Integer(1),
                         Core::Type::int64()) },
                Core::Type::boolean()))) },
    };
    for (std::int64_t input = 0; input <= 6; ++input)
    {
        CAPTURE(input);
        CheckBothPipelines(
            { down,
              Evaluate(input,
                       { Core::Statement::If(
                           Core::Expression::Apply(
                               Core::Expression::Variable({ kDown, U"Down" },
                                                          downType),
                               { Value() },
                               Core::Type::boolean()),
                           { SetTotal(1) },
                           {}) }) },
            1);
    }
}

TEST_CASE("short-circuit loop condition guards its own right operand",
          "[llvm][shortcircuit][execution]")
{
    // while (value < limit && 100 / (limit - value) > 0) { ... }
    // The division is undefined exactly when the left operand is false.
    for (std::int64_t limit = 0; limit <= 6; ++limit)
    {
        std::int64_t expected{};
        std::int64_t value{};
        while (value < limit && 100 / (limit - value) > 0)
        {
            expected += value;
            ++value;
        }
        const auto remaining = [limit] {
            return Binary(Core::Primitive::Subtract,
                          Integer(limit),
                          Value(),
                          Core::Type::int64());
        };
        CAPTURE(limit);
        CheckBothPipelines(
            { Evaluate(
                0,
                { Core::Statement::While(
                    Compare(Core::Primitive::LogicalAnd,
                            Compare(Core::Primitive::LessThan,
                                    Value(),
                                    Integer(limit)),
                            Compare(Core::Primitive::GreaterThan,
                                    Quotient(100, remaining()),
                                    Integer(0))),
                    { Core::Statement::Assign({ kTotal, U"total" },
                                              Binary(Core::Primitive::Add,
                                                     Variable(kTotal, U"total"),
                                                     Value(),
                                                     Core::Type::int64())),
                      Core::Statement::Assign(
                          { kValue, U"value" },
                          Binary(Core::Primitive::Add,
                                 Value(),
                                 Integer(1),
                                 Core::Type::int64())) }) }) },
            expected);
    }
}
