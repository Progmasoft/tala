// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

namespace Progmasoft::Tala::Fuzzing
{
    /// Compile and run every regression program for expressions that store
    /// into locals, and require the hand-written result from both native
    /// pipeline modes. A wrong result or a rejected program ends the process
    /// with a report.
    void
    ExerciseExpressionCases();
} // namespace Progmasoft::Tala::Fuzzing
