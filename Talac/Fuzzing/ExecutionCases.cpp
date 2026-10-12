// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <cstddef>
#include <cstdint>
#include <llvm/Support/raw_ostream.h>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "ExecutionCases.hpp"
#include "SourceFuzz.hpp"

namespace Progmasoft::Tala::Fuzzing
{
    namespace
    {
        // Each run of a program owns one bit of its result, which is an
        // `int`. Twenty bits keep every sum well inside its range.
        constexpr std::size_t kMaximumRunsPerProgram = 20U;
        // Small bodies share a program; the cost of a program under
        // sanitizers is mostly the fixed cost of compiling one at all.
        constexpr std::size_t kMaximumBodiesPerProgram = 8U;
        // A body larger than this is a program of its own: its size is what
        // it tests, and its cost should be visible on its own line.
        constexpr std::size_t kMaximumSharedBodyBytes = 1024U;

        /// One body and the runs that call it.
        struct Method final
        {
            std::string_view body;
            std::vector<const ExecutionCase *> runs;
        };

        [[nodiscard]] auto
        Truth(bool value) -> std::string
        {
            // `Id` is recursive, so the optimizer cannot fold the arguments
            // away and the body really executes on run-time values.
            return value ? "Id(1) > 0" : "Id(0) > 0";
        }

        /// A literal has no sign, so a negative value is spelled as a
        /// subtraction.
        [[nodiscard]] auto
        Literal(std::int64_t value) -> std::string
        {
            return value < 0 ? "(0 - " + std::to_string(-value) + ")"
                             : std::to_string(value);
        }

        [[nodiscard]] auto
        Call(std::size_t method, const ExecutionCase &run) -> std::string
        {
            return "Run" + std::to_string(method) + "(" + Truth(run.flag) + ", "
                   + Truth(run.other) + ", Id(" + std::to_string(run.left)
                   + "), Id(" + std::to_string(run.right) + "))";
        }

        [[nodiscard]] auto
        Program(const std::vector<Method> &methods,
                std::string_view helpers,
                std::string_view declarations) -> std::string
        {
            std::string program = "namespace Fuzz;\n";
            program += declarations;
            program += "class Program {\n"
                       "    public static int Id(_ int n) { return n > 0 ? 1 + "
                       "Id(n - 1) : 0; }\n";
            program += helpers;
            for (std::size_t method = 0U; method < methods.size(); ++method)
            {
                program += "    public static int Run" + std::to_string(method)
                           + "(_ bool flag, _ bool other, _ int left, _ int "
                             "right) {\n        ";
                program += methods[method].body;
                program += "\n    }\n";
            }
            program += "    public static int Evaluate() {\n"
                       "        int failed = 0;\n";
            std::size_t bit = 0U;
            for (std::size_t method = 0U; method < methods.size(); ++method)
                for (const auto *run : methods[method].runs)
                    program += "        if (" + Call(method, *run) + " \\= "
                               + Literal(run->expected) + ") { failed += "
                               + std::to_string(std::size_t{ 1U } << bit++)
                               + "; }\n";
            program += "        return failed;\n    }\n}\n";
            return program;
        }

        void
        Exercise(std::string_view label,
                 const std::vector<Method> &methods,
                 std::string_view helpers,
                 std::string_view declarations)
        {
            std::size_t bit = 0U;
            for (const auto &method : methods)
            {
                llvm::errs() << label << ": " << method.body << '\n';
                for (const auto *run : method.runs)
                    llvm::errs()
                        << "    run " << (std::size_t{ 1U } << bit++)
                        << ": flag " << (run->flag ? "true" : "false")
                        << ", other " << (run->other ? "true" : "false")
                        << ", left " << run->left << ", right " << run->right
                        << " -> " << run->expected << '\n';
            }
            // A result other than 0 is the sum of the run numbers printed
            // above whose value differed.
            ExerciseExpectedValue(Program(methods, helpers, declarations), 0);
        }
    } // namespace

    void
    ExerciseExecutionCases(std::string_view label,
                           std::span<const ExecutionCase> cases,
                           std::string_view helpers,
                           std::string_view declarations)
    {
        std::vector<bool> taken(cases.size(), false);
        std::vector<Method> methods;
        std::size_t runs = 0U;
        const auto flush = [&] {
            if (!methods.empty())
                Exercise(label, methods, helpers, declarations);
            methods.clear();
            runs = 0U;
        };
        for (std::size_t first = 0U; first < cases.size(); ++first)
        {
            if (taken[first])
                continue;
            // The runs of one body, in table order; a body with more runs
            // than a program holds continues in a later program.
            Method method{ cases[first].body, {} };
            for (std::size_t index = first;
                 index < cases.size()
                 && method.runs.size() < kMaximumRunsPerProgram;
                 ++index)
            {
                if (taken[index] || cases[index].body != method.body)
                    continue;
                taken[index] = true;
                method.runs.push_back(&cases[index]);
            }
            const auto large = method.body.size() > kMaximumSharedBodyBytes;
            if (large || methods.size() == kMaximumBodiesPerProgram
                || runs + method.runs.size() > kMaximumRunsPerProgram)
                flush();
            runs += method.runs.size();
            methods.push_back(std::move(method));
            if (large)
                flush();
        }
        flush();
    }
} // namespace Progmasoft::Tala::Fuzzing
