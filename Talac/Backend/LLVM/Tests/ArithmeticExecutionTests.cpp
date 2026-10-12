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

// Executable integer-division regressions. The existing backend tests check
// that the rounded-division helper appears in the generated IR; these run the
// code and compare each quotient and remainder with the value the language
// specification gives, for every sign combination, through both native
// optimizer settings.

namespace
{
    namespace Core = Progmasoft::Tala::Core;
    namespace Llvm = Progmasoft::Tala::Backend::LLVM;
    namespace Pipeline = Progmasoft::Tala::Pipeline;

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
            { U"Arithmetic" },
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

        constexpr std::string_view kSymbol = "Arithmetic.Evaluate.1";
        Llvm::JitSession session;
        REQUIRE_FALSE(session.AddModule(pipeline.llvm->bitcode,
                                        "arithmetic-execution",
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

    /// The specification's rounded division: nearest integer, exact halves
    /// away from zero. Written without the compiler's own formula.
    [[nodiscard]] auto
    RoundedQuotient(std::int64_t left, std::int64_t right) -> std::int64_t
    {
        const bool negative = (left < 0) != (right < 0);
        const std::int64_t dividend = left < 0 ? -left : left;
        const std::int64_t divisor = right < 0 ? -right : right;
        const std::int64_t magnitude = (2 * dividend + divisor) / (2 * divisor);
        return negative ? -magnitude : magnitude;
    }
} // namespace

TEST_CASE("rounded integer division matches the specification examples",
          "[llvm][arithmetic][execution]")
{
    // Spec/Language/Operators.tala, "Rounded Integer Division //".
    CheckBothPipelines(Core::Primitive::FloorDivide, 7, 2, 4);
    CheckBothPipelines(Core::Primitive::FloorDivide, 6, 2, 3);
    CheckBothPipelines(Core::Primitive::FloorDivide, 5, 2, 3);
    CheckBothPipelines(Core::Primitive::FloorDivide, -7, 2, -4);
    CheckBothPipelines(Core::Primitive::FloorDivide, -5, 2, -3);
    // Exact halves round away from zero.
    CheckBothPipelines(Core::Primitive::FloorDivide, 1, 2, 1);
    CheckBothPipelines(Core::Primitive::FloorDivide, -1, 2, -1);
}

TEST_CASE("rounded integer division rounds to nearest for every sign pair",
          "[llvm][arithmetic][execution]")
{
    for (std::int64_t left = -13; left <= 13; ++left)
        for (std::int64_t right = -5; right <= 5; ++right)
            if (right != 0)
                CheckBothPipelines(Core::Primitive::FloorDivide,
                                   left,
                                   right,
                                   RoundedQuotient(left, right));
}

TEST_CASE("remainder keeps the sign of its left operand",
          "[llvm][arithmetic][execution]")
{
    // Spec/Language/Operators.tala, "Remainder %".
    CheckBothPipelines(Core::Primitive::Remainder, 7, 3, 1);
    CheckBothPipelines(Core::Primitive::Remainder, -7, 3, -1);
    CheckBothPipelines(Core::Primitive::Remainder, 7, -3, 1);
    for (std::int64_t left = -9; left <= 9; ++left)
        for (std::int64_t right = -4; right <= 4; ++right)
            if (right != 0)
                CheckBothPipelines(Core::Primitive::Remainder,
                                   left,
                                   right,
                                   left % right);
}
