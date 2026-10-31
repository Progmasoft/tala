// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

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

// Executable conditional-expression regressions. Each program is compiled
// from Core through Xpp, Xmm and LLVM, run by the ORC JIT, and compared with
// a value the test computes itself. Where it matters, one arm is only well
// defined when the test selects it: a division whose divisor the test
// excludes, or a recursive call the test terminates. A pipeline that
// evaluates both arms traps or never returns, so these programs observe the
// laziness of the conditional rather than only the value it selects.

namespace
{
    namespace Core = Progmasoft::Tala::Core;
    namespace Llvm = Progmasoft::Tala::Backend::LLVM;
    namespace Pipeline = Progmasoft::Tala::Pipeline;

    constexpr std::uint64_t kValue = 2U;
    constexpr std::uint64_t kTotal = 3U;
    constexpr std::uint64_t kLocal = 4U;
    constexpr std::uint64_t kSum = 10U;
    constexpr std::uint64_t kSumParameter = 11U;

    [[nodiscard]] auto
    Integer(std::int64_t value) -> Core::Expression
    {
        return Core::Expression::Constant(value, Core::Type::int64());
    }

    [[nodiscard]] auto
    Boolean(bool value) -> Core::Expression
    {
        return Core::Expression::Constant(value, Core::Type::boolean());
    }

    [[nodiscard]] auto
    Floating(std::string spelling) -> Core::Expression
    {
        return Core::Expression::Constant(
            tala::core::FloatingLiteral{ std::move(spelling) },
            Core::Type::float64());
    }

    [[nodiscard]] auto
    Variable(std::uint64_t id,
             std::u32string spelling,
             Core::Type type = Core::Type::int64()) -> Core::Expression
    {
        return Core::Expression::Variable({ id, std::move(spelling) },
                                          std::move(type));
    }

    [[nodiscard]] auto
    Value() -> Core::Expression
    {
        return Variable(kValue, U"value");
    }

    [[nodiscard]] auto
    Total() -> Core::Expression
    {
        return Variable(kTotal, U"total");
    }

    [[nodiscard]] auto
    Binary(Core::Primitive operation,
           Core::Expression left,
           Core::Expression right,
           Core::Type type = Core::Type::int64()) -> Core::Expression
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
    Choose(Core::Expression test,
           Core::Expression whenTrue,
           Core::Expression whenFalse,
           Core::Type type = Core::Type::int64()) -> Core::Expression
    {
        return Core::Expression::Conditional(std::move(test),
                                             std::move(whenTrue),
                                             std::move(whenFalse),
                                             std::move(type));
    }

    [[nodiscard]] auto
    SetTotal(Core::Expression value) -> Core::Statement
    {
        return Core::Statement::Assign({ kTotal, U"total" }, std::move(value));
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
        body.push_back(Core::Statement::Return(Total()));
        return { { 1U, U"Evaluate" },
                 {},
                 Core::Type::int64(),
                 std::move(body) };
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

        constexpr std::string_view kSymbol = "Conditional.Evaluate.1";
        Llvm::JitSession session;
        const auto rejected = session.AddModule(pipeline.llvm->bitcode,
                                                "conditional-execution",
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
        const Core::Module module{ { U"Conditional" }, std::move(functions) };
        CHECK(Run(module, false) == expected);
        CHECK(Run(module, true) == expected);
    }
} // namespace

TEST_CASE("a conditional does not evaluate the division its test excludes",
          "[llvm][conditional][execution]")
{
    for (std::int64_t input = -3; input <= 3; ++input)
    {
        CAPTURE(input);
        SECTION("the division is the first result")
        {
            const std::int64_t expected = input != 0 ? 12 / input : 99;
            CheckBothPipelines(
                { Evaluate(
                    input,
                    { SetTotal(Choose(
                        Compare(Core::Primitive::NotEqual, Value(), Integer(0)),
                        Binary(Core::Primitive::Divide, Integer(12), Value()),
                        Integer(99))) }) },
                expected);
        }
        SECTION("the division is the second result")
        {
            const std::int64_t expected = input == 0 ? 99 : 12 / input;
            CheckBothPipelines(
                { Evaluate(
                    input,
                    { SetTotal(Choose(
                        Compare(Core::Primitive::Equal, Value(), Integer(0)),
                        Integer(99),
                        Binary(Core::Primitive::Divide,
                               Integer(12),
                               Value()))) }) },
                expected);
        }
    }
}

TEST_CASE("a numeric conditional test selects by truth",
          "[llvm][conditional][execution]")
{
    for (std::int64_t input = -2; input <= 2; ++input)
    {
        CAPTURE(input);
        CheckBothPipelines(
            { Evaluate(input,
                       { SetTotal(Choose(Value(), Integer(5), Integer(9))) }) },
            input != 0 ? 5 : 9);
    }
}

TEST_CASE("chained conditionals select exactly one leaf",
          "[llvm][conditional][execution]")
{
    // value < 0 ? (value < -1 ? 1 : 2) : value == 0 ? 3 : value > 1 ? 4 : 5
    const auto classify = [] {
        return Choose(
            Compare(Core::Primitive::LessThan, Value(), Integer(0)),
            Choose(Compare(Core::Primitive::LessThan, Value(), Integer(-1)),
                   Integer(1),
                   Integer(2)),
            Choose(
                Compare(Core::Primitive::Equal, Value(), Integer(0)),
                Integer(3),
                Choose(
                    Compare(Core::Primitive::GreaterThan, Value(), Integer(1)),
                    Integer(4),
                    Integer(5))));
    };
    for (std::int64_t input = -3; input <= 3; ++input)
    {
        const std::int64_t expected = input < 0    ? (input < -1 ? 1 : 2)
                                      : input == 0 ? 3
                                      : input > 1  ? 4
                                                   : 5;
        CAPTURE(input);
        CheckBothPipelines({ Evaluate(input, { SetTotal(classify()) }) },
                           expected);
    }
}

TEST_CASE("a conditional test may itself be a conditional",
          "[llvm][conditional][execution]")
{
    // (value > 0 ? value < 3 : value < -2) ? 7 : 11
    for (std::int64_t input = -4; input <= 4; ++input)
    {
        const bool test = input > 0 ? input < 3 : input < -2;
        CAPTURE(input);
        CheckBothPipelines(
            { Evaluate(
                input,
                { SetTotal(Choose(
                    Choose(
                        Compare(Core::Primitive::GreaterThan,
                                Value(),
                                Integer(0)),
                        Compare(Core::Primitive::LessThan, Value(), Integer(3)),
                        Compare(Core::Primitive::LessThan,
                                Value(),
                                Integer(-2)),
                        Core::Type::boolean()),
                    Integer(7),
                    Integer(11))) }) },
            test ? 7 : 11);
    }
}

TEST_CASE("a conditional is an ordinary operand after its join",
          "[llvm][conditional][execution]")
{
    // total = value * 10 + (value > 1 ? value : 0 - value) - 1
    for (std::int64_t input = -2; input <= 4; ++input)
    {
        const std::int64_t expected
            = input * 10 + (input > 1 ? input : 0 - input) - 1;
        CAPTURE(input);
        CheckBothPipelines(
            { Evaluate(
                input,
                { SetTotal(Binary(
                    Core::Primitive::Subtract,
                    Binary(
                        Core::Primitive::Add,
                        Binary(Core::Primitive::Multiply, Value(), Integer(10)),
                        Choose(Compare(Core::Primitive::GreaterThan,
                                       Value(),
                                       Integer(1)),
                               Value(),
                               Binary(Core::Primitive::Subtract,
                                      Integer(0),
                                      Value()))),
                    Integer(1))) }) },
            expected);
    }
}

TEST_CASE("a Boolean conditional value survives later statements",
          "[llvm][conditional][execution]")
{
    // The value, not only a branch on it, must be the selected arm: bind
    // it, overwrite an unrelated variable, then test the binding.
    for (std::int64_t input = -2; input <= 2; ++input)
    {
        const bool flag = input != 0 ? 8 / input == 4 : true;
        CAPTURE(input);
        CheckBothPipelines(
            { Evaluate(input,
                       { Core::Statement::Bind(
                             { { kLocal, U"flag" },
                               Core::Type::boolean(),
                               false,
                               Choose(Compare(Core::Primitive::NotEqual,
                                              Value(),
                                              Integer(0)),
                                      Compare(Core::Primitive::Equal,
                                              Binary(Core::Primitive::Divide,
                                                     Integer(8),
                                                     Value()),
                                              Integer(4)),
                                      Boolean(true),
                                      Core::Type::boolean()) }),
                         SetTotal(Integer(5)),
                         Core::Statement::If(
                             Variable(kLocal, U"flag", Core::Type::boolean()),
                             { SetTotal(Integer(7)) },
                             {}) }) },
            flag ? 7 : 5);
    }
}

TEST_CASE("a floating conditional keeps the selected value",
          "[llvm][conditional][execution]")
{
    // double ratio = value > 0 ? 1.5 : -2.5;
    // total = ratio > 0.0 ? 1 : ratio < -2.0 ? 2 : 3;
    for (std::int64_t input = -1; input <= 1; ++input)
    {
        const double ratio = input > 0 ? 1.5 : -2.5;
        const std::int64_t expected = ratio > 0.0 ? 1 : ratio < -2.0 ? 2 : 3;
        const auto ratioRead = [] {
            return Variable(kLocal, U"ratio", Core::Type::float64());
        };
        CAPTURE(input);
        CheckBothPipelines(
            { Evaluate(
                input,
                { Core::Statement::Bind(
                      { { kLocal, U"ratio" },
                        Core::Type::float64(),
                        false,
                        Choose(Compare(Core::Primitive::GreaterThan,
                                       Value(),
                                       Integer(0)),
                               Floating("1.5"),
                               Floating("-2.5"),
                               Core::Type::float64()) }),
                  SetTotal(Choose(Compare(Core::Primitive::GreaterThan,
                                          ratioRead(),
                                          Floating("0.0")),
                                  Integer(1),
                                  Choose(Compare(Core::Primitive::LessThan,
                                                 ratioRead(),
                                                 Floating("-2.0")),
                                         Integer(2),
                                         Integer(3)))) }) },
            expected);
    }
}

TEST_CASE("guarded recursion terminates through a conditional",
          "[llvm][conditional][execution]")
{
    // int Sum(int n) { return n == 0 ? 0 : n + Sum(n - 1); }
    // Evaluating the second result eagerly recurses below zero without
    // bound.
    const auto sumType
        = Core::Type::function({ Core::Type::int64() }, Core::Type::int64());
    const auto parameter = [] {
        return Variable(kSumParameter, U"n");
    };
    const Core::Function sum{
        { kSum, U"Sum" },
        { { { kSumParameter, U"n" }, Core::Type::int64() } },
        Core::Type::int64(),
        { Core::Statement::Return(Choose(
            Compare(Core::Primitive::Equal, parameter(), Integer(0)),
            Integer(0),
            Binary(Core::Primitive::Add,
                   parameter(),
                   Core::Expression::Apply(
                       Core::Expression::Variable({ kSum, U"Sum" }, sumType),
                       { Binary(Core::Primitive::Subtract,
                                parameter(),
                                Integer(1)) },
                       Core::Type::int64())))) },
    };
    for (std::int64_t input = 0; input <= 8; ++input)
    {
        CAPTURE(input);
        CheckBothPipelines(
            { sum,
              Evaluate(
                  input,
                  { SetTotal(Core::Expression::Apply(
                      Core::Expression::Variable({ kSum, U"Sum" }, sumType),
                      { Value() },
                      Core::Type::int64())) }) },
            input * (input + 1) / 2);
    }
}

TEST_CASE("a conditional loop condition is re-evaluated on every iteration",
          "[llvm][conditional][execution]")
{
    // while (value > 3 ? value < 10 : value < 2) { value++; total++; }
    for (std::int64_t input = -1; input <= 6; ++input)
    {
        std::int64_t value = input;
        std::int64_t expected = 0;
        while (value > 3 ? value < 10 : value < 2)
        {
            ++value;
            ++expected;
        }
        CAPTURE(input);
        CheckBothPipelines(
            { Evaluate(
                input,
                { Core::Statement::While(
                    Choose(
                        Compare(Core::Primitive::GreaterThan,
                                Value(),
                                Integer(3)),
                        Compare(Core::Primitive::LessThan,
                                Value(),
                                Integer(10)),
                        Compare(Core::Primitive::LessThan, Value(), Integer(2)),
                        Core::Type::boolean()),
                    { Core::Statement::Assign(
                          { kValue, U"value" },
                          Binary(Core::Primitive::Add, Value(), Integer(1))),
                      SetTotal(Binary(Core::Primitive::Add,
                                      Total(),
                                      Integer(1))) }) }) },
            expected);
    }
}

TEST_CASE("the truthy-coalescing lowering keeps a nonzero left value",
          "[llvm][conditional][execution]")
{
    // `left ?: fallback` reaches Core as
    //     let subject = left in (subject ? subject : fallback)
    // The fallback divides by `3 - value`. It is selected only at value == 2,
    // where the divisor is one; at value == 3 it is undefined and must not
    // be evaluated.
    for (std::int64_t input = 0; input <= 5; ++input)
    {
        const std::int64_t left = input - 2;
        const std::int64_t expected = left != 0 ? left : 12 / (3 - input);
        const auto subject = [] {
            return Variable(kLocal, U"$coalesce4");
        };
        CAPTURE(input);
        CheckBothPipelines(
            { Evaluate(
                input,
                { SetTotal(Core::Expression::Let(
                    { kLocal, U"$coalesce4" },
                    Core::Type::int64(),
                    Binary(Core::Primitive::Subtract, Value(), Integer(2)),
                    Choose(subject(),
                           subject(),
                           Binary(Core::Primitive::Divide,
                                  Integer(12),
                                  Binary(Core::Primitive::Subtract,
                                         Integer(3),
                                         Value()))),
                    Core::Type::int64())) }) },
            expected);
    }
}

TEST_CASE("compound assignment lowering reads the target it writes",
          "[llvm][conditional][execution]")
{
    // The frontend lowers `total op= operand` to `total = total op operand`.
    // Run one of each integer operator over the same accumulator.
    struct Step final
    {
        Core::Primitive operation;
        std::int64_t operand;
    };
    const std::vector<Step> steps{
        { Core::Primitive::Add, 9 },
        { Core::Primitive::Multiply, 6 },
        { Core::Primitive::Subtract, 4 },
        { Core::Primitive::ShiftLeft, 3 },
        { Core::Primitive::BitwiseXor, 21 },
        { Core::Primitive::BitwiseOr, 64 },
        { Core::Primitive::BitwiseAnd, 1023 },
        { Core::Primitive::ShiftRight, 1 },
        { Core::Primitive::Remainder, 37 },
        { Core::Primitive::Divide, 2 },
    };
    for (std::int64_t input = 1; input <= 4; ++input)
    {
        std::int64_t expected = input;
        std::vector<Core::Statement> statements{ SetTotal(Value()) };
        for (const auto &step : steps)
        {
            switch (step.operation)
            {
                case Core::Primitive::Add:
                    expected += step.operand;
                    break;
                case Core::Primitive::Multiply:
                    expected *= step.operand;
                    break;
                case Core::Primitive::Subtract:
                    expected -= step.operand;
                    break;
                case Core::Primitive::ShiftLeft:
                    expected <<= step.operand;
                    break;
                case Core::Primitive::BitwiseXor:
                    expected ^= step.operand;
                    break;
                case Core::Primitive::BitwiseOr:
                    expected |= step.operand;
                    break;
                case Core::Primitive::BitwiseAnd:
                    expected &= step.operand;
                    break;
                case Core::Primitive::ShiftRight:
                    expected >>= step.operand;
                    break;
                case Core::Primitive::Remainder:
                    expected %= step.operand;
                    break;
                default:
                    expected /= step.operand;
                    break;
            }
            statements.push_back(SetTotal(
                Binary(step.operation, Total(), Integer(step.operand))));
        }
        // Every intermediate value is non-negative, so the host operators
        // above agree with the language's truncating and logical rules.
        REQUIRE(expected >= 0);
        CAPTURE(input);
        CheckBothPipelines({ Evaluate(input, std::move(statements)) },
                           expected);
    }
}

TEST_CASE("a discarded non-call value lowers through every stage",
          "[llvm][conditional][execution]")
{
    // `_ = value;` evaluates an arbitrary expression and drops the result.
    // Later stages accept a dropped result only from a call or a closure
    // creation, so any other value has to be computed into a temporary.
    // Each program below was rejected by the Xmm verifier before that.
    const auto discard = [](Core::Expression value) {
        return Core::Statement::Evaluate(std::move(value));
    };
    SECTION("an arithmetic primitive")
    {
        CheckBothPipelines({ Evaluate(4,
                                      { discard(Binary(Core::Primitive::Divide,
                                                       Integer(12),
                                                       Value())),
                                        SetTotal(Integer(3)) }) },
                           3);
    }
    SECTION("a conditional expression")
    {
        CheckBothPipelines(
            { Evaluate(
                4,
                { discard(Choose(
                      Compare(Core::Primitive::GreaterThan,
                              Value(),
                              Integer(1)),
                      Binary(Core::Primitive::Divide, Integer(12), Value()),
                      Integer(0))),
                  SetTotal(Integer(5)) }) },
            5);
    }
    SECTION("a plain variable and a literal")
    {
        CheckBothPipelines({ Evaluate(4,
                                      { discard(Value()),
                                        discard(Integer(9)),
                                        SetTotal(Integer(7)) }) },
                           7);
    }
    SECTION("a comparison of a let-bound value")
    {
        CheckBothPipelines(
            { Evaluate(4,
                       { discard(Core::Expression::Let(
                             { kLocal, U"subject" },
                             Core::Type::int64(),
                             Binary(Core::Primitive::Add, Value(), Integer(1)),
                             Compare(Core::Primitive::GreaterThan,
                                     Variable(kLocal, U"subject"),
                                     Integer(3)),
                             Core::Type::boolean())),
                         SetTotal(Integer(11)) }) },
            11);
    }
}
