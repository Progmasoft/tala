// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstdint>
#include <span>
#include <string_view>

namespace Progmasoft::Tala::Fuzzing
{
    // These routes deliberately share production Haskell entry points. The
    // syntax stages stop after the lexer or parser; source compilation goes
    // through verified Core, Xpp, Xmm and LLVM lowering. Every accepted
    // source is also lowered to CorePrep by both the frontend and the native
    // adapter, and the two results must be structurally equal.
    void
    ExerciseLexer(std::span<const std::uint8_t> input);
    void
    ExerciseParser(std::span<const std::uint8_t> input);
    void
    ExerciseSourceToLlvm(std::span<const std::uint8_t> input);
    void
    ExerciseDifferentialOracle(std::span<const std::uint8_t> input);
    /// Like ExerciseSourceToLlvm, but the source is known to be valid: a
    /// frontend rejection is a failure. Deterministic checks use this so a
    /// program that silently stopped compiling cannot pass as "rejected".
    void
    ExerciseAcceptedSource(std::span<const std::uint8_t> input);
    /// Compile a valid source whose `Evaluate()` in namespace `Fuzz` takes no
    /// arguments and returns `int`, run it through the unoptimized and the
    /// optimized native pipeline, and require both results to equal
    /// `expected`. The expected value comes from the caller, never from the
    /// compiler, so the check is an oracle and not a self-comparison.
    void
    ExerciseExpectedValue(std::string_view source, std::int64_t expected);
} // namespace Progmasoft::Tala::Fuzzing
