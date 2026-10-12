// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <cstdint>
#include <limits>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Backend/LLVM.hpp"
#include "Progmasoft/Tala/Core/IR.hpp"
#include "Progmasoft/Tala/Core/Wire.hpp"
#include "Progmasoft/Tala/Pipeline.hpp"

// Values that cannot be computed, and the one that only seems not to be.
//
// An integer quotient or remainder by zero has no value, and neither has a
// shift by an amount that is negative or not less than the width of the
// shifted value. A program that needs such a value stops. The machine
// instructions for these operations give no such promise: LLVM assigns them
// no meaning on those operands, and an optimizer may then delete the
// computation together with whatever depended on it. The backend therefore
// checks the operand first. These cases pin that the check is there, that
// it does not disturb the values that can be computed, and that the least
// integer divided by minus one, which a processor refuses, wraps the way
// generated code lets every other integer result that does not fit wrap.
// The language has not fixed what such a result is; this pins that the
// backend treats the division like the sum and the product.

namespace
{
    namespace Core = Progmasoft::Tala::Core;
    namespace Llvm = Progmasoft::Tala::Backend::LLVM;
    namespace Pipeline = Progmasoft::Tala::Pipeline;

    constexpr auto kLeast = std::numeric_limits<std::int64_t>::min();
    constexpr auto kGreatest = std::numeric_limits<std::int64_t>::max();

    /// `int left = <left>; int right = <right>; return left <op> right;`
    /// The operands are mutable locals so the operation is lowered as a
    /// run-time instruction in the unoptimized pipeline.
    [[nodiscard]] auto
    Binary(Core::Primitive operation, std::int64_t left, std::int64_t right)
        -> Core::Module
    {
        const auto local =
            [](std::uint64_t id, std::u32string name, std::int64_t value) {
                return Core::Statement::Bind(
                    { { id, std::move(name) },
                      Core::Type::int64(),
                      true,
                      Core::Expression::Constant(value, Core::Type::int64()) });
            };
        const auto read = [](std::uint64_t id, std::u32string name) {
            return Core::Expression::Variable({ id, std::move(name) },
                                              Core::Type::int64());
        };
        return {
            { U"Computability" },
            { Core::Function{
                { 1U, U"Evaluate" },
                {},
                Core::Type::int64(),
                { local(2U, U"left", left),
                  local(3U, U"right", right),
                  Core::Statement::Return(Core::Expression::InvokePrimitive(
                      operation,
                      { read(2U, U"left"), read(3U, U"right") },
                      Core::Type::int64())) },
            } }
        };
    }

    [[nodiscard]] auto
    Lower(const Core::Module &module, bool optimize) -> Llvm::Artifact
    {
        const auto encoded = Core::Wire::Encode(module);
        REQUIRE(encoded);
        Pipeline::Options options;
        options.optimize_xpp = optimize;
        options.optimize_xmm = optimize;
        options.llvm.optimization = optimize ? Llvm::OptimizationLevel::Default
                                             : Llvm::OptimizationLevel::Debug;
        auto pipeline = Pipeline::ConsumeCore(encoded.bytes, options);
        REQUIRE(pipeline);
        REQUIRE(pipeline.llvm);
        return *pipeline.llvm;
    }

    [[nodiscard]] auto
    Run(const Core::Module &module, bool optimize) -> std::int64_t
    {
        const auto artifact = Lower(module, optimize);
        constexpr std::string_view kSymbol = "Computability.Evaluate.1";
        Llvm::JitSession session;
        REQUIRE_FALSE(session.AddModule(artifact.bitcode,
                                        "computability-execution",
                                        kSymbol,
                                        Core::Type::int64()));
        const auto result = session.InvokeScalar(kSymbol, Core::Type::int64());
        REQUIRE(result);
        return std::get<std::int64_t>(result.value->payload);
    }

    void
    CheckBothPipelines(Core::Primitive operation,
                       std::int64_t left,
                       std::int64_t right,
                       std::int64_t expected)
    {
        CAPTURE(left, right);
        const auto module = Binary(operation, left, right);
        CHECK(Run(module, false) == expected);
        CHECK(Run(module, true) == expected);
    }

    /// Whether the code of the operation can stop the program.
    [[nodiscard]] auto
    Stops(Core::Primitive operation,
          std::int64_t left,
          std::int64_t right,
          bool optimize) -> bool
    {
        const auto artifact = Lower(Binary(operation, left, right), optimize);
        return artifact.llvm_ir.find("call void @llvm.trap()")
               != std::string::npos;
    }
} // namespace

TEST_CASE("an integer quotient by zero stops the program",
          "[llvm][computability]")
{
    for (const auto operation : { Core::Primitive::Divide,
                                  Core::Primitive::FloorDivide,
                                  Core::Primitive::Remainder })
        for (const std::int64_t dividend : { std::int64_t{ 0 },
                                             std::int64_t{ 6 },
                                             std::int64_t{ -6 },
                                             kLeast,
                                             kGreatest })
        {
            CAPTURE(dividend);
            // Unoptimized, the check stands before the instruction.
            // Optimized, the operands are known and what is left of the
            // function is the stop itself: the division is not deleted as
            // if it had never been needed.
            CHECK(Stops(operation, dividend, 0, false));
            CHECK(Stops(operation, dividend, 0, true));
        }
}

TEST_CASE("a quotient whose divisor is known not to be zero is not checked",
          "[llvm][computability]")
{
    for (const auto operation : { Core::Primitive::Divide,
                                  Core::Primitive::FloorDivide,
                                  Core::Primitive::Remainder })
        for (const std::int64_t divisor : { std::int64_t{ 1 },
                                            std::int64_t{ -1 },
                                            std::int64_t{ 7 },
                                            kLeast,
                                            kGreatest })
        {
            CAPTURE(divisor);
            CHECK_FALSE(Stops(operation, 42, divisor, true));
        }
}

TEST_CASE("the check leaves every quotient that has a value unchanged",
          "[llvm][computability][execution]")
{
    for (std::int64_t left = -7; left <= 7; ++left)
        for (std::int64_t right = -3; right <= 3; ++right)
            if (right != 0)
            {
                CheckBothPipelines(Core::Primitive::Divide,
                                   left,
                                   right,
                                   left / right);
                CheckBothPipelines(Core::Primitive::Remainder,
                                   left,
                                   right,
                                   left % right);
            }
    CheckBothPipelines(Core::Primitive::Divide, kGreatest, 1, kGreatest);
    CheckBothPipelines(Core::Primitive::Divide, kGreatest, -1, -kGreatest);
    CheckBothPipelines(Core::Primitive::Divide, kLeast, 1, kLeast);
    CheckBothPipelines(Core::Primitive::Divide, kLeast, 2, kLeast / 2);
    CheckBothPipelines(Core::Primitive::Divide, kLeast, kLeast, 1);
    CheckBothPipelines(Core::Primitive::Divide, kGreatest, kLeast, 0);
    CheckBothPipelines(Core::Primitive::Remainder, kLeast, 2, 0);
    CheckBothPipelines(Core::Primitive::Remainder, kLeast, 3, kLeast % 3);
    CheckBothPipelines(Core::Primitive::Remainder,
                       kGreatest,
                       kLeast,
                       kGreatest);
}

TEST_CASE("the least integer divided by minus one wraps",
          "[llvm][computability][execution]")
{
    // The quotient is one above the greatest value. Generated code wraps
    // it, so the result is the least value again, as it is for `0 - least`
    // and for `least * -1`.
    CheckBothPipelines(Core::Primitive::Subtract, 0, kLeast, kLeast);
    CheckBothPipelines(Core::Primitive::Multiply, kLeast, -1, kLeast);
    CheckBothPipelines(Core::Primitive::Divide, kLeast, -1, kLeast);
    CheckBothPipelines(Core::Primitive::FloorDivide, kLeast, -1, kLeast);
    // The division is exact, so nothing remains.
    CheckBothPipelines(Core::Primitive::Remainder, kLeast, -1, 0);
    // It is not a division by zero, and does not stop the program.
    CHECK_FALSE(Stops(Core::Primitive::Divide, kLeast, -1, true));
    CHECK_FALSE(Stops(Core::Primitive::FloorDivide, kLeast, -1, true));
    CHECK_FALSE(Stops(Core::Primitive::Remainder, kLeast, -1, true));
}

TEST_CASE("a shift by an amount within the width has its value",
          "[llvm][computability][execution]")
{
    CheckBothPipelines(Core::Primitive::ShiftLeft, 1, 0, 1);
    CheckBothPipelines(Core::Primitive::ShiftLeft, 1, 3, 8);
    CheckBothPipelines(Core::Primitive::ShiftLeft, 1, 62, kGreatest / 2 + 1);
    CheckBothPipelines(Core::Primitive::ShiftLeft, 1, 63, kLeast);
    CheckBothPipelines(Core::Primitive::ShiftLeft, -1, 63, kLeast);
    CheckBothPipelines(Core::Primitive::ShiftRight, 8, 3, 1);
    CheckBothPipelines(Core::Primitive::ShiftRight, -8, 1, -4);
    CheckBothPipelines(Core::Primitive::ShiftRight, kLeast, 63, -1);
    CheckBothPipelines(Core::Primitive::ShiftRight, kGreatest, 63, 0);
    for (const auto operation :
         { Core::Primitive::ShiftLeft, Core::Primitive::ShiftRight })
        for (const std::int64_t amount :
             { std::int64_t{ 0 }, std::int64_t{ 1 }, std::int64_t{ 63 } })
        {
            CAPTURE(amount);
            CHECK_FALSE(Stops(operation, 5, amount, true));
        }
}

TEST_CASE("a shift by an amount outside the width stops the program",
          "[llvm][computability]")
{
    for (const auto operation :
         { Core::Primitive::ShiftLeft, Core::Primitive::ShiftRight })
        for (const std::int64_t amount : { std::int64_t{ 64 },
                                           std::int64_t{ 65 },
                                           std::int64_t{ -1 },
                                           kLeast,
                                           kGreatest })
        {
            CAPTURE(amount);
            CHECK(Stops(operation, 5, amount, false));
            CHECK(Stops(operation, 5, amount, true));
        }
}

TEST_CASE("operations that always have a value are not checked",
          "[llvm][computability]")
{
    for (const auto operation : { Core::Primitive::Add,
                                  Core::Primitive::Subtract,
                                  Core::Primitive::Multiply,
                                  Core::Primitive::BitwiseAnd,
                                  Core::Primitive::BitwiseOr,
                                  Core::Primitive::BitwiseXor })
    {
        CHECK_FALSE(Stops(operation, kLeast, 0, false));
        CHECK_FALSE(Stops(operation, kLeast, 0, true));
    }
}
