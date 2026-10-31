// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <array>
#include <cstdint>
#include <llvm/Support/raw_ostream.h>
#include <string_view>

#include "Progmasoft/Tala/Support/CompilerStack.hpp"
#include "SourceFuzz.hpp"

namespace
{
    int
    Smoke();
} // namespace

int
main()
{
    // The compiler runs here on the stack it runs on in `talac`.
    return Progmasoft::Tala::Support::RunOnCompilerStack([] {
        return Smoke();
    });
}

namespace
{
    int
    Smoke()
    {
        constexpr std::string_view sourceText
            = "namespace Demo; public class Program { public static long "
              "Evaluate() { return 5; } }";
        const auto source = std::span<const std::uint8_t>(
            reinterpret_cast<const std::uint8_t *>(sourceText.data()),
            sourceText.size());
        constexpr std::array<std::uint8_t, 8U> expressionSeed{ 1U, 2U, 3U, 4U,
                                                               5U, 6U, 7U, 8U };
        Progmasoft::Tala::Fuzzing::ExerciseLexer(source);
        Progmasoft::Tala::Fuzzing::ExerciseParser(source);
        const std::span<const std::uint8_t> emptySource;
        Progmasoft::Tala::Fuzzing::ExerciseSourceToLlvm(emptySource);
        Progmasoft::Tala::Fuzzing::ExerciseSourceToLlvm(source);
        // Control-flow shapes whose frontend and native CorePrep lowerings must
        // agree. They combine forms the generated programs below keep separate:
        // loops inside loops, short-circuit operators as loop conditions, and
        // several functions sharing one module-wide symbol numbering.
        constexpr std::array<std::string_view, 15U> accepted{
            "namespace Parity; class Program { public static int Evaluate() { "
            "int total = 0; for (int outer = 0; outer < 4; outer++) { "
            "if (outer == 2) { continue; } int inner = 0; "
            "while (inner < 3) { if (inner == 1) { inner++; continue; } "
            "total = total + outer + inner; inner++; } } return total; } }",
            "namespace Parity; class Program { public static int Evaluate() { "
            "int index = 0; int total = 0; "
            "while (index < 9 && (index < 4 || total < 20)) { "
            "total = total + index; index++; } "
            "do { total++; } while (total < 40 && index \\= 0); "
            "return total; } }",
            "namespace Parity; class Program { "
            "public static bool Down(_ int n) { return n == 0 || Down(n - 1); "
            "} "
            "public static int Pick(_ int n) { if (Down(n) && n < 6) { "
            "return n; } return 0 - 1; } "
            "public static int Evaluate() { return Pick(3) + Pick(8); } }",
            "namespace Parity; class First { public static long Evaluate() { "
            "long result = 8; if (result > 4) { result = result - 2; } "
            "return result; } } class Second { public static long Other() { "
            "long value = 3; for (int step = 0; step < 2; step++) { "
            "value = value * 2; } return value; } }",
            // Conditional expressions: Boolean and numeric tests, nesting in
            // either result and in the test, and a recursion the first result
            // terminates.
            "namespace Parity; class Program { "
            "public static int Sum(_ int n) { return n == 0 ? 0 : n + Sum(n - "
            "1); "
            "} public static int Pick(_ bool flag, _ int left, _ int right) { "
            "return flag ? left > right ? left : right : left ? 0 - left : "
            "right; } public static int Evaluate() { return (Sum(4) > 5 ? "
            "Pick(true, 3, 9) > 4 : false) ? Pick(false, 0, 7) : Sum(2); } }",
            // Truthy coalescing binds its left operand once. A call on the left
            // is the case where an adapter that copies the bound value through
            // an extra temporary disagrees with one that binds the call itself.
            "namespace Parity; class Program { "
            "public static int Next(_ int n) { return n > 2 ? Next(n - 3) : n; "
            "} "
            "public static int Evaluate() { int value = Next(7) ?: Next(5); "
            "return value + (Next(9) ?: 4) + (value ?: Next(8) ?: 6); } }",
            // Compound assignments in statement and loop-update position, with
            // a conditional and a coalescing operand.
            "namespace Parity; class Program { public static int Evaluate() { "
            "int total = 3; total += 4; total -= 1; total *= 5; total /= 2; "
            "total //= 2; total %= 7; total <<= 3; total >>= 1; total &= 127; "
            "total ^= 9; total |= 64; for (int index = 0; index < 6; index += "
            "2) "
            "{ total += index ? index : 1; total -= index ?: 2; } "
            "return total; } }",
            // Discarded values: a call keeps its result-dropping instruction;
            // an operator, a conditional and a division are computed into
            // temporaries.
            "namespace Parity; class Program { "
            "public static int Down(_ int n) { return n > 0 ? Down(n - 1) : 0; "
            "} "
            "public static int Evaluate() { int value = 5; _ = Down(value); "
            "_ = !Down(2); _ = 12 / value; _ = value > 3 ? Down(1) : value; "
            "value > 4 ? Down(3) : 0; _ = Down(value) ?: 7; return value; } }",
            // Conditional forms as loop conditions and as the operands of
            // short-circuit operators, in a module with several functions.
            "namespace Parity; class Program { "
            "public static bool Small(_ int n) { return n < 3 ? true : n == 9; "
            "} "
            "public static int Evaluate() { int index = 0; int total = 0; "
            "while (index < 4 ? Small(index) || total < 9 : false) { "
            "total += index ?: 5; index += 1; } "
            "do { total -= 1; } while (total > 3 && (total ?: 1) \\= 2); "
            "return Small(total) && total > 0 ? total : 0 - total; } }",
            // Assignments and increments used as values: an earlier operand
            // held across a later store, chained and compound forms, and
            // arguments evaluated in order.
            "namespace Parity; class Program { "
            "public static int Pick(_ int a, _ int b, _ int c) { return a * "
            "100 "
            "+ b * 10 + c; } public static int Next(_ int n) { return n > 2 ? "
            "Next(n - 3) : n; } public static int Evaluate() { int a = "
            "Next(7); "
            "int b = 0; int c = 0; a = b = c = a + 1; int r = a + (a = b + 2) "
            "* "
            "(a += 1) - a++ + ++b; r += Pick(a, a = r, a++) + Pick(c++, c++, "
            "c); "
            "return r - (b -= a) + Next(a = 8) + a; } }",
            // Loop conditions that store: the stores run before every test,
            // after `continue` too, and a do/while body runs before its first.
            "namespace Parity; class Program { public static int Evaluate() { "
            "int n = 0; int sum = 0; int v = 0; "
            "while ((v = n++) < 9) { if (v == 3) { continue; } "
            "if (v == 5) { n += 2; continue; } sum += v; } "
            "do { sum += 100; if (sum > 400) { break; } } while ((n -= 3) > "
            "4); "
            "for (int i = 0; (v = i * 3) < 11; i++) { if (v == 6) { continue; "
            "} "
            "sum += v; } int j = 0; while (j++ < 3) { int k = 0; "
            "do { sum += j; } while (++k < j); } return sum * 10 + n + v; } }",
            // Stores in lazily evaluated operands: conditional results, the
            // right side of short-circuit operators and a coalescing fallback.
            "namespace Parity; class Program { "
            "public static int Step(_ int n) { return n > 0 ? 1 + Step(n - 1) "
            ": "
            "0; } public static int Evaluate() { int a = Step(7); int b = "
            "Step(0); int hits = 0; int r = a > 5 ? (a -= 5) : (b += 1); "
            "bool both = a > 2 && (hits += 1) > 0; "
            "bool either = b \\= 0 || (hits += 10) > 0; "
            "int c = b ?: (hits += 100); "
            "int d = (a = Step(3)) ? (b = a) ?: (hits += 1000) : (hits = 0); "
            "bool chain = both && (a = 1) > 0 && (b = 2) > 0 || (c = 0) == 0; "
            "return r + a * 3 + b * 5 + hits * 7 + c + d + (both ? 1000 : 0) + "
            "(either ? 2000 : 0) + (chain ? 4000 : 0); } }",
            // Stores as statements of their own and inside closures, which
            // capture by value and store into their own copies.
            "namespace Parity; class Program { public static int Evaluate() { "
            "int a = 4; (a = 6); _ = (a += 1); _ = a++; _ = a++ > 0 ? 1 : 0; "
            "auto bump = \\(int value) -> { int local = value; "
            "return (local += 1) + local++; }; "
            "auto held = [kept = a++] \\ -> kept; "
            "return bump(a) + held() + a; } }",
            // Loops used as expressions: `while` and `for` forms, a nested loop
            // expression, a loop statement with its own bare break inside one,
            // and loop expressions as operands and as a loop condition.
            "namespace Parity; class Program { "
            "public static int Step(_ int n) { return n > 0 ? 1 + Step(n - 1) "
            ": "
            "0; } public static int Evaluate() { int n = Step(2); "
            "int first = while (true) { n += 1; if (n * n > 30) { break n; } "
            "}; "
            "int second = for (int i = 0; ; i++) { if (i == 2) { continue; } "
            "int inner = while (true) { int k = 0; while (true) { k++; "
            "if (k == 3) { break; } } break k + i; }; "
            "if (inner > 6) { break inner * 2; } }; "
            "int third = first + while (true) { first += 1; break first; } + "
            "first; int sum = 0; while (for (int j = sum; ; j++) { "
            "if (j >= sum) { break j; } } < 4) { sum += 1; } "
            "bool big = second > 9 && while (true) { n -= 1; break n > 0; }; "
            "return first + second + third + sum + n + (big ? 100 : 0); } }",
            // Floating values in Boolean contexts. Both lowerings must compare
            // them with a floating zero, not an integer one.
            "namespace Parity; class Program { public static int Evaluate() { "
            "double zero = 0.0; double half = 0.5; float small = 0.25; "
            "bool both = half && small; bool either = zero || half; "
            "double kept = zero ?: half; int picked = half ? 1 : 2; "
            "return (both ? 1 : 0) + (either ? 2 : 0) + (kept ? 4 : 0) + "
            "picked * 8 + (not zero ? 32 : 0); } }",
        };
        for (const auto text : accepted)
            Progmasoft::Tala::Fuzzing::ExerciseAcceptedSource(
                std::span<const std::uint8_t>(
                    reinterpret_cast<const std::uint8_t *>(text.data()),
                    text.size()));
        // The programs with hand-written results run in
        // `source_execution_smoke`, a program of its own.
        llvm::errs() << "Differential smoke: mixed seed\n";
        Progmasoft::Tala::Fuzzing::ExerciseDifferentialOracle(expressionSeed);
        llvm::errs() << "Differential smoke: empty seed\n";
        Progmasoft::Tala::Fuzzing::ExerciseDifferentialOracle(emptySource);
        // Constant seeds force leaves, full-depth addition, subtraction and
        // multiplication. Exercise the independent oracle before a mutation
        // campaign so a missing generated-code route cannot appear as success.
        constexpr std::array<std::uint8_t, 4U> selectors{ 252U,
                                                          253U,
                                                          254U,
                                                          255U };
        for (const auto selector : selectors)
        {
            const std::array<std::uint8_t, 1U> seed{ selector };
            llvm::errs() << "Differential smoke: selector "
                         << static_cast<unsigned>(selector) << '\n';
            Progmasoft::Tala::Fuzzing::ExerciseDifferentialOracle(seed);
        }
        // A leaf selector followed by an explicit mode and limit byte reaches
        // every generated control-flow shape at every trip count, including the
        // zero-trip, continue and break paths, instead of only the shapes the
        // four cycling selectors above happen to select. The two leaves are the
        // literals 0 and 4, so a form that tests its generated expression sees
        // both a false and a true value.
        constexpr std::uint8_t kModes = 14U;
        constexpr std::uint8_t kLimits = 12U;
        constexpr std::array<std::uint8_t, 2U> leaves{ 0U, 4U };
        for (const auto leaf : leaves)
        {
            for (std::uint8_t mode = 0U; mode < kModes; ++mode)
            {
                for (std::uint8_t limit = 0U; limit < kLimits; ++limit)
                {
                    const std::array<std::uint8_t, 3U> seed{ leaf,
                                                             mode,
                                                             limit };
                    llvm::errs() << "Differential smoke: leaf "
                                 << static_cast<unsigned>(leaf) << " mode "
                                 << static_cast<unsigned>(mode) << " limit "
                                 << static_cast<unsigned>(limit) << '\n';
                    Progmasoft::Tala::Fuzzing::ExerciseDifferentialOracle(seed);
                }
            }
        }
        return 0;
    }
} // namespace
