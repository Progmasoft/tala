// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "BranchingExecutionCases.hpp"
#include "ExecutionCases.hpp"

// Executable regressions for `match`, for `if` used as an expression and for
// `guard`. Each case is a method body, the arguments it runs on and the value
// it must return. The expected values are written by hand from the language
// rules: the subjects of a match are evaluated once and left to right, the
// arms are tested in order, a guard runs only when the patterns of its arm
// accept, exactly one body runs, and the block of a guard runs only when its
// condition is false. The cases are written in `Cases/Selection.cases`; the
// rows here and the list `selectionCases` that the frontend test suite runs
// in a reference evaluator are generated from that file by
// `go -C helpers run ./cmd/execution-cases generate`. Here every case runs
// through CorePrep, Xpp, Xmm, LLVM and the ORC JIT, unoptimized and
// optimized. The cases that leave instead of yielding a value are in
// `LeavingExecutionCases.cpp`.

namespace Progmasoft::Tala::Fuzzing
{
    namespace
    {
        constexpr auto kCases = std::to_array<ExecutionCase>({
#include "Generated/SelectionCases.inc"
        });

        // The methods a body may call besides `Run` itself.
        constexpr std::string_view kHelpers
            = "    public static int Twice(_ int value) { return value + "
              "value; }\n";

        // A match with many arms. Arm `index` yields `index * 3 + 1` and the
        // catch-all yields 0.
        [[nodiscard]] auto
        WideMatchBody(int arms) -> std::string
        {
            std::string body = "return match (left) { ";
            for (int index = 0; index < arms; ++index)
                body += std::to_string(index) + " -> "
                        + std::to_string(index * 3 + 1) + ", ";
            return body + "_ -> 0 };";
        }

        // The same table written as an `else if` chain.
        [[nodiscard]] auto
        ElseIfChainBody(int links) -> std::string
        {
            std::string body;
            for (int index = 0; index < links; ++index)
                body += std::string(index == 0 ? "if" : " else if")
                        + " (left == " + std::to_string(index) + ") { return "
                        + std::to_string(index * 3 + 1) + "; }";
            return body + " return 0;";
        }

        // `if (left > 0) { if (left > 1) { ... total += 1; } }`
        [[nodiscard]] auto
        NestedIfBody(int levels) -> std::string
        {
            std::string body = "int total = 0; ";
            for (int index = 0; index < levels; ++index)
                body += "if (left > " + std::to_string(index) + ") { ";
            body += "total += 1; ";
            for (int index = 0; index < levels; ++index)
                body += "} ";
            return body + "return total;";
        }

        // `Id(Id(...Id(left)...))`: calls nested in arguments, which is
        // the shape that costs most compiler stack for each level.
        [[nodiscard]] auto
        NestedCallBody(int levels) -> std::string
        {
            std::string body = "return ";
            for (int index = 0; index < levels; ++index)
                body += "Id(";
            body += "left";
            body.append(static_cast<std::size_t>(levels), ')');
            return body + ";";
        }

        // `left + left + ... + left`
        [[nodiscard]] auto
        SumBody(int operands) -> std::string
        {
            std::string body = "return left";
            for (int index = 1; index < operands; ++index)
                body += " + left";
            return body + ";";
        }

        // The value of arm or link `index` in the tables above.
        [[nodiscard]] constexpr auto
        TableValue(int index) -> std::int64_t
        {
            return std::int64_t{ index } * 3 + 1;
        }
    } // namespace

    void
    ExerciseBranchingCases()
    {
        ExerciseExecutionCases("Branching execution", kCases, kHelpers);

        // Programs whose size is the point. Every body is compiled once and
        // all of its runs are checked by that one program.
        std::vector<ExecutionCase> large;

        // The subjects select the first arm, arms around a multiple of
        // sixteen, an arm in the middle, the last arm and the catch-all. A
        // lowering that nested one level per arm would overflow the stack
        // of the stages after Core long before this many arms.
        constexpr int kWideArms = 200;
        const auto wide = WideMatchBody(kWideArms);
        for (const auto subject : { 0, 15, 16, 17, 150, 199, 200 })
            large.push_back({ false,
                              false,
                              subject,
                              0,
                              subject < kWideArms ? TableValue(subject) : 0,
                              wide });

        // An `else if` chain of 300 links. The native wire reader, the Core
        // verifier and the CorePrep adapter walk a chain in a loop; when
        // they recursed, 150 links overflowed the stack. Both CorePrep
        // lowerings are compared on it as on every other program here.
        constexpr int kChainLinks = 300;
        const auto chain = ElseIfChainBody(kChainLinks);
        for (const auto subject : { 0, 149, 150, 299, 300 })
            large.push_back({ false,
                              false,
                              subject,
                              0,
                              subject < kChainLinks ? TableValue(subject) : 0,
                              chain });

        // Programs at the nesting limits of the frontend: a statement at
        // level 256 and an expression at level 1024. They compile only on
        // the compiler stack, which the smoke program runs on like `talac`.
        constexpr int kLevels = 255;
        const auto nested = NestedIfBody(kLevels);
        for (const auto argument : { kLevels, kLevels - 1 })
            large.push_back({ false,
                              false,
                              argument,
                              0,
                              argument == kLevels ? 1 : 0,
                              nested });
        // 1023 calls nested in each other's arguments put the innermost
        // operand at expression level 1024.
        constexpr int kNestedCalls = 1023;
        const auto calls = NestedCallBody(kNestedCalls);
        large.push_back({ false, false, 3, 0, 3, calls });
        constexpr int kOperands = 1024;
        const auto sum = SumBody(kOperands);
        large.push_back(
            { false, false, 3, 0, std::int64_t{ 3 } * kOperands, sum });

        ExerciseExecutionCases("Branching execution", large, kHelpers);
    }
} // namespace Progmasoft::Tala::Fuzzing
