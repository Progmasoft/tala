// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstdint>
#include <span>
#include <string_view>

namespace Progmasoft::Tala::Fuzzing
{
    /// One run of an executable regression: the body of
    /// `int Run(bool flag, bool other, int left, int right)`, the arguments
    /// it is called with, and the value it must return.
    struct ExecutionCase final
    {
        bool flag;
        bool other;
        int left;
        int right;
        std::int64_t expected;
        std::string_view body;
    };

    /**
     * @brief Compile every distinct body once and check all of its runs.
     *
     * A program holds up to eight bodies, each in a method of its own, and
     * up to twenty runs. Its `Evaluate` calls the method of each run,
     * compares the result with the expected value, and returns the sum of a
     * distinct power of two for every run that differed. The program must
     * return 0 from both native pipeline modes, so every run is checked
     * exactly as when each had a program of its own, and a nonzero result
     * names the runs that failed. What is saved is the fixed cost of
     * compiling a program, which dominates these cases under sanitizers. A
     * body of more than a kilobyte is not shared: its size is what it
     * tests.
     *
     * The arguments are passed through a recursive identity method, so the
     * optimizer cannot fold them and the bodies execute on run-time values.
     *
     * @param label Printed before each run, to name the table.
     * @param cases Runs in table order; equal bodies need not be adjacent.
     * @param helpers Source of additional methods of the class the body may
     * call.
     * @param declarations Source of declarations that stand before the
     * class, such as the enums the bodies use.
     */
    void
    ExerciseExecutionCases(std::string_view label,
                           std::span<const ExecutionCase> cases,
                           std::string_view helpers,
                           std::string_view declarations = {});
} // namespace Progmasoft::Tala::Fuzzing
