// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <cstdint>
#include <cstdlib>
#include <llvm/ADT/Twine.h>
#include <llvm/Support/ErrorHandling.h>
#include <llvm/Support/raw_ostream.h>
#include <span>
#include <string>
#include <utility>

#include "CorePrepParity.hpp"
#include "Progmasoft/Tala/Backend/LLVM.hpp"
#include "Progmasoft/Tala/Pipeline.hpp"
#include "Progmasoft/Tala/Runtime/AARC.hpp"
#include "SourceFuzz.hpp"
#include "Talac/Cli/Commands/Frontend.hpp"

namespace Progmasoft::Tala::Fuzzing
{
    namespace
    {
        namespace Frontend = ::Progmasoft::Tala::Cli::Frontend;
        namespace Llvm = ::Progmasoft::Tala::Backend::LLVM;
        namespace Core = ::Progmasoft::Tala::Core;

        constexpr std::size_t kMaximumFuzzInput = std::size_t{ 64U } * 1024U;
        constexpr std::size_t kMaximumGeneratedDepth = 4U;

        struct Expression final
        {
            std::string source;
            std::int64_t value{};
        };

        [[nodiscard]] auto
        NextByte(std::span<const std::uint8_t> bytes, std::size_t &cursor)
            -> std::uint8_t
        {
            // Cycle a short seed deterministically; an empty corpus still has
            // a defined path and never reads outside the supplied span.
            if (bytes.empty())
                return 0U;
            const auto value = bytes[cursor % bytes.size()];
            ++cursor;
            return value;
        }

        [[nodiscard]] auto
        GenerateExpression(std::span<const std::uint8_t> bytes,
                           std::size_t &cursor,
                           std::size_t depth) -> Expression
        {
            // The fixed depth bounds both source growth and the independent
            // oracle's arithmetic range regardless of adversarial seed bytes.
            const auto selector = NextByte(bytes, cursor);
            if (depth == 0U || selector % 4U == 0U)
            {
                const auto value = static_cast<std::int64_t>(selector % 6U);
                return { std::to_string(value), value };
            }

            auto left = GenerateExpression(bytes, cursor, depth - 1U);
            auto right = GenerateExpression(bytes, cursor, depth - 1U);
            const char operation = selector % 3U == 1U   ? '+'
                                   : selector % 3U == 2U ? '-'
                                                         : '*';
            const auto value = operation == '+'   ? left.value + right.value
                               : operation == '-' ? left.value - right.value
                                                  : left.value * right.value;
            return { "(" + left.source + " " + operation + " " + right.source
                         + ")",
                     value };
        }

        [[nodiscard]] auto
        GeneratedProgram(std::span<const std::uint8_t> bytes,
                         std::int64_t &expected) -> std::string
        {
            std::size_t cursor{};
            const auto expression
                = GenerateExpression(bytes, cursor, kMaximumGeneratedDepth);
            expected = expression.value;
            std::string body = "return " + expression.source + ";";
            std::string members;
            const auto mode = NextByte(bytes, cursor) % 14U;
            const auto limit
                = static_cast<std::int64_t>(NextByte(bytes, cursor) % 12U);
            if (mode == 1U)
            {
                // Independent host execution models for/continue/break rather
                // than comparing two copies of the compiler's CFG algorithm.
                expected = 0;
                for (std::int64_t index = 0; index < limit; ++index)
                {
                    if (index == 2)
                        continue;
                    if (index == 9)
                        break;
                    expected += index;
                }
                body = "int total = 0; for (int index = 0; index < "
                       + std::to_string(limit)
                       + "; index++) { if (index == 2) { continue; } "
                         "if (index == 9) { break; } total = total + index; } "
                         "return total;";
            }
            else if (mode == 2U)
            {
                expected = limit == 0 ? 1 : limit;
                body = "int total = 0; do { total++; } while (total < "
                       + std::to_string(limit) + "); return total;";
            }
            else if (mode == 3U)
            {
                expected = limit < 6 ? expression.value : -expression.value;
                body = "if (" + std::to_string(limit) + " < 6) { return "
                       + expression.source + "; } else { return -("
                       + expression.source + "); }";
            }
            else if (mode == 4U)
            {
                // Statements before a pre-test loop run exactly once. The
                // initializers and the loop share one source block, so a
                // back-edge that re-enters that block resets the counter.
                expected = 0;
                std::int64_t index = 0;
                while (index < limit)
                {
                    if (index == 1)
                    {
                        ++index;
                        continue;
                    }
                    if (index == 7)
                        break;
                    expected += index;
                    ++index;
                }
                body = "int total = 0; int index = 0; while (index < "
                       + std::to_string(limit)
                       + ") { if (index == 1) { index++; continue; } "
                         "if (index == 7) { break; } total = total + index; "
                         "index++; } return total;";
            }
            else if (mode == 5U)
            {
                // The recursion ends only because `||` skips its right
                // operand at zero, and the comparison after `&&` is reached
                // only when the call returned. Evaluating either right
                // operand eagerly recurses without bound.
                expected = limit < 6 ? limit : -1;
                members
                    = "    public static bool Down(_ int n) { return n == 0 "
                      "|| Down(n - 1); }\n";
                body = "if (Down(" + std::to_string(limit) + ") && "
                       + std::to_string(limit) + " < 6) { return "
                       + std::to_string(limit) + "; } return 0 - 1;";
            }
            else if (mode == 6U)
            {
                // Both conditionals are correct only when the unselected
                // result is not evaluated: the recursion ends at the first
                // result, and the division is defined only in the second.
                const auto sum = limit * (limit + 1) / 2;
                expected = sum + (limit == 0 ? 100 : 60 / limit);
                members = "    public static int Sum(_ int n) { return n == 0 "
                          "? 0 : n + Sum(n - 1); }\n";
                body = "int value = " + std::to_string(limit)
                       + "; return Sum(value) + (value == 0 ? 100 : 60 / "
                         "value);";
            }
            else if (mode == 7U)
            {
                // Truthy coalescing keeps a nonzero left value and evaluates
                // the fallback otherwise; every compound operator reads the
                // target it writes. The host loop is the reference.
                std::int64_t total
                    = expression.value != 0 ? expression.value : 7;
                for (std::int64_t index = 0; index < limit; index += 2)
                {
                    total += index != 0 ? index : 3;
                    total ^= index;
                }
                total *= 2;
                total -= limit;
                total %= 1000003;
                expected = total;
                body = "int total = " + expression.source
                       + " ?: 7; for (int index = 0; index < "
                       + std::to_string(limit)
                       + "; index += 2) { total += index ?: 3; total ^= "
                         "index; } total *= 2; total -= "
                       + std::to_string(limit)
                       + "; total %= 1000003; return total;";
            }
            else if (mode == 8U)
            {
                // Chained conditionals group to the right and nest in a
                // first result without parentheses; each trip count selects
                // a different leaf of the same expression.
                const auto value = limit - 5;
                expected = value < 0    ? (value < -3 ? 1 : 2)
                           : value == 0 ? expression.value
                           : value > 3  ? 4
                                        : 5;
                body = "int value = " + std::to_string(limit)
                       + "; value -= 5; return value < 0 ? value < 0 - 3 ? 1 "
                         ": 2 : value == 0 ? "
                       + expression.source + " : value > 3 ? 4 : 5 ?: 6;";
            }
            else if (mode == 9U)
            {
                // Assignments and increments used as values. Operands are
                // evaluated left to right, so a read written before a store
                // sees the value from before it. The host model performs
                // each read and store as its own statement, in that order.
                std::int64_t a = limit;
                std::int64_t b = expression.value;
                // int r = a + (a = b) * 2;
                const auto firstRead = a;
                a = b;
                std::int64_t r = firstRead + a * 2;
                // r += a++ - (b += a);
                const auto targetRead = r;
                const auto previous = a;
                a += 1;
                b += a;
                r = targetRead + (previous - b);
                // return r - (a -= 2) + a + (b = a++) + a;
                a -= 2;
                const auto reduced = a;
                const auto second = a;
                b = a;
                a += 1;
                expected = r - reduced + second + b + a;
                body = "int a = " + std::to_string(limit)
                       + "; int b = " + expression.source
                       + "; int r = a + (a = b) * 2; r += a++ - (b += a); "
                         "return r - (a -= 2) + a + (b = a++) + a;";
            }
            else if (mode == 10U)
            {
                // Loop conditions that store. The stores run on every test
                // of the condition, including the test after `continue`,
                // and a do/while body still runs before its first test.
                std::int64_t n = 0;
                std::int64_t sum = 0;
                std::int64_t v = 0;
                for (;;)
                {
                    v = n;
                    n += 1;
                    if (v >= limit)
                        break;
                    if (v == 3)
                        continue;
                    if (v == 9)
                        break;
                    sum += v;
                }
                std::int64_t m = limit;
                for (;;)
                {
                    sum += 100;
                    m -= 4;
                    if (m <= 0)
                        break;
                }
                for (std::int64_t index = 0;; ++index)
                {
                    v = index * 3;
                    if (v >= limit)
                        break;
                    sum += v;
                }
                expected = sum * 10 + n + v;
                const auto bound = std::to_string(limit);
                body = "int n = 0; int sum = 0; int v = 0; while ((v = n++) < "
                       + bound
                       + ") { if (v == 3) { continue; } if (v == 9) { break; } "
                         "sum += v; } int m = "
                       + bound
                       + "; do { sum += 100; } while ((m -= 4) > 0); "
                         "for (int index = 0; (v = index * 3) < "
                       + bound
                       + "; index++) { sum += v; } return sum * 10 + n + v;";
            }
            else if (mode == 11U)
            {
                // Stores in operands that are evaluated lazily. Each store
                // must happen only when its operand is selected: in one
                // conditional result, on the right of `&&` and `||`, and in
                // a coalescing fallback.
                std::int64_t a = limit;
                std::int64_t b = expression.value;
                std::int64_t hits = 0;
                std::int64_t r = 0;
                if (a > 5)
                {
                    a -= 5;
                    r = a;
                }
                else
                {
                    b += 1;
                    r = b;
                }
                bool both = false;
                if (a > 2)
                {
                    hits += 1;
                    both = hits > 0;
                }
                bool either = b != 0;
                if (!either)
                {
                    hits += 10;
                    either = hits > 0;
                }
                std::int64_t c = b;
                if (b == 0)
                {
                    hits += 100;
                    c = hits;
                }
                expected = r + a * 3 + b * 5 + hits * 7 + c + (both ? 1000 : 0)
                           + (either ? 2000 : 0);
                body = "int a = " + std::to_string(limit)
                       + "; int b = " + expression.source
                       + "; int hits = 0; int r = a > 5 ? (a -= 5) : (b += 1); "
                         "bool both = a > 2 && (hits += 1) > 0; "
                         "bool either = b \\= 0 || (hits += 10) > 0; "
                         "int c = b ?: (hits += 100); "
                         "return r + a * 3 + b * 5 + hits * 7 + c + "
                         "(both ? 1000 : 0) + (either ? 2000 : 0);";
            }
            else if (mode == 12U)
            {
                // Loops used as expressions. Each loop leaves only through
                // a break that carries its value; the nested loop statement
                // has a bare break of its own, and the second loop reads a
                // local the first one stored.
                // The start value is reduced so that a seed cannot make the
                // first loop run for an unbounded number of iterations.
                std::int64_t n = expression.value % 7;
                std::int64_t first = 0;
                for (;;)
                {
                    n += 2;
                    if (n > limit)
                    {
                        first = n;
                        break;
                    }
                }
                std::int64_t second = 0;
                for (std::int64_t index = 0;; ++index)
                {
                    if (index == 1)
                        continue;
                    std::int64_t inner = 0;
                    for (;;)
                    {
                        inner += 1;
                        if (inner == 3)
                            break;
                    }
                    if (index * inner >= limit)
                    {
                        second = index + first;
                        break;
                    }
                }
                // return first * 100 + second + (n > 4 ? <loop> : 0 - n);
                std::int64_t tail = 0;
                if (n > 4)
                {
                    n -= 4;
                    tail = n;
                }
                else
                {
                    tail = 0 - n;
                }
                expected = first * 100 + second + tail;
                const auto bound = std::to_string(limit);
                body = "int n = (" + expression.source
                       + ") % 7; int first = while (true) { n += 2; if (n > "
                       + bound
                       + ") { break n; } }; int second = for (int index = 0; ; "
                         "index++) { if (index == 1) { continue; } int inner = "
                         "0; while (true) { inner += 1; if (inner == 3) { "
                         "break; } } if (index * inner >= "
                       + bound
                       + ") { break index + first; } }; return first * 100 + "
                         "second + (n > 4 ? while (true) { n -= 4; break n; } "
                         ": 0 - n);";
            }
            else if (mode == 13U)
            {
                // match, guard and if used as an expression. The host model
                // below is written with plain C++ conditions, so it shares
                // no decision structure with the compiler's lowering of the
                // arms. The subject is shifted by the limit so that the
                // literal arms, the guarded arm, the binding arm and the
                // catch-all are all selected across the limits of one seed.
                const std::int64_t n = (expression.value + limit) % 7 - 2;
                std::int64_t kind = 0;
                if (n == 0)
                    kind = 10;
                else if (n == 1 && limit > 5)
                    kind = 20;
                else if (n < 0)
                    kind = 0 - n;
                else
                    kind = n + 30;
                // A statement match with two subjects inside a loop: one
                // arm continues the loop, and a guard after the match
                // leaves it.
                std::int64_t total = 0;
                for (std::int64_t index = 0; index < limit; ++index)
                {
                    const auto remainder = index % 3;
                    if (remainder == 0)
                        continue;
                    if (remainder == 1 && index > 4)
                        total += 10;
                    else
                        total += index;
                    if (!(total < 12))
                        break;
                }
                std::int64_t picked = 0;
                if (kind > total)
                {
                    const auto distance = kind - total;
                    picked = distance * 2;
                }
                else
                {
                    picked = total - kind;
                }
                expected = kind * 1000 + total * 10 + picked;
                const auto bound = std::to_string(limit);
                body = "int n = ((" + expression.source + ") + " + bound
                       + ") % 7 - 2; int kind = match (n) { 0 -> 10, 1 if "
                       + bound
                       + " > 5 -> 20, int below if below < 0 -> 0 - below, _ "
                         "-> n + 30 }; int total = 0; for (int index = 0; "
                         "index < "
                       + bound
                       + "; index++) { match (index % 3), (index > 4) { (0), "
                         "(_) -> { continue; }, (1), (true) -> { total += 10; "
                         "}, (_), (_) -> { total += index; } } guard (total < "
                         "12) else { break; } } int picked = if (kind > total) "
                         "{ int distance = kind - total; distance * 2 } else { "
                         "total - kind }; return kind * 1000 + total * 10 + "
                         "picked;";
            }
            return "namespace Fuzz;\n"
                   "class Program {\n"
                   + members
                   + "    public static int Evaluate() {\n"
                     "        "
                   + body
                   + "\n"
                     "    }\n"
                     "}\n";
        }

        /**
         * @brief Compile once and require both CorePrep lowerings to agree.
         *
         * The frontend lowers its optimized Core to CorePrep, and the native
         * pipeline lowers the same Core again with its own adapter. Only
         * the native result reaches Xpp, so a divergence is a miscompile
         * that no later verifier can see: both lowerings are well formed.
         * This check decodes the Core and CorePrep buffers of one
         * compilation, runs the native adapter, and fails on the first
         * structural difference.
         */
        [[nodiscard]] auto
        CompileSource(std::span<const std::uint8_t> source) -> Frontend::Result
        {
            if (source.size() > kMaximumFuzzInput)
                return { Frontend::Status::InvalidRequest,
                         Frontend::OutputKind::ErrorText,
                         {},
                         "source fuzz input exceeds 64 KiB",
                         {} };
            auto stages = Frontend::FuzzCompileStages(source);
            if (!stages.core.succeeded()
                || stages.core.kind != Frontend::OutputKind::CoreWire)
                return std::move(stages.core);

            const auto core = Core::Wire::Decode(stages.core.bytes);
            if (!core.module)
                llvm::report_fatal_error(llvm::Twine(
                    "native Core reader rejected frontend Core wire"));
            // Unverified Core is rejected by the pipeline with its own
            // report; lowering it here would compare undefined shapes.
            if (!Core::Verify(*core.module).empty())
                return std::move(stages.core);
            const auto frontendCorePrep
                = ::tala::core::wire::decode(stages.corePrep);
            if (!frontendCorePrep.module)
                llvm::report_fatal_error(llvm::Twine(
                    "native CorePrep reader rejected frontend CorePrep wire"));
            const auto difference
                = CompareCorePrep(*frontendCorePrep.module,
                                  Core::CorePrep::Prepare(*core.module));
            if (difference)
                llvm::report_fatal_error(llvm::Twine(
                    "frontend and native CorePrep lowerings differ: "
                    + *difference + "; source:\n"
                    + std::string(reinterpret_cast<const char *>(source.data()),
                                  source.size())));
            return std::move(stages.core);
        }

        [[nodiscard]] auto
        PipelineFailure(const Progmasoft::Tala::Pipeline::Result &pipeline)
            -> std::string
        {
            std::string details;
            const auto append
                = [&details](std::string_view stage, const auto &issues) {
                      for (const auto &issue : issues)
                      {
                          if (!details.empty())
                              details.append("; ");
                          details.append(stage);
                          details.push_back(' ');
                          details.append(issue.code);
                          details.append(": ");
                          details.append(issue.message);
                      }
                  };
            if (pipeline.coreWireError)
                details = "Core wire: " + pipeline.coreWireError->message;
            append("Core", pipeline.coreVerificationIssues);
            append("CorePrep", pipeline.verification_issues);
            append("Xpp", pipeline.xppVerificationIssues);
            append("Xmm", pipeline.xmmVerificationIssues);
            if (pipeline.llvm_error)
            {
                if (!details.empty())
                    details.append("; ");
                details.append("LLVM ");
                details.append(pipeline.llvm_error->code);
                details.append(": ");
                details.append(pipeline.llvm_error->message);
            }
            if (details.empty())
                details = "pipeline returned without an LLVM artifact";
            return details;
        }

        [[nodiscard]] auto
        IsExpectedEmptyModule(
            const Progmasoft::Tala::Pipeline::Result &pipeline) -> bool
        {
            // The parser deliberately accepts an empty source unit, while the
            // native Xpp IR requires at least one function. That known
            // front-end-only module is a normal boundary result, not a
            // compiler crash or a source-to-code miscompile.
            return pipeline.xppVerificationIssues.size() == 1U
                   && pipeline.xppVerificationIssues.front().code == "TAP1002";
        }

        [[nodiscard]] auto
        ConsumeVerifiedCore(const Frontend::Result &compiled,
                            std::string_view sourceDescription)
            -> Progmasoft::Tala::Pipeline::Result
        {
            if (!compiled.succeeded()
                || compiled.kind != Frontend::OutputKind::CoreWire)
                llvm::report_fatal_error(
                    llvm::Twine("valid fuzz source was rejected: "
                                + std::string(sourceDescription)));
            auto pipeline
                = Progmasoft::Tala::Pipeline::ConsumeCore(compiled.bytes);
            if (!pipeline || !pipeline.llvm)
            {
                if (IsExpectedEmptyModule(pipeline))
                    return pipeline;
                llvm::report_fatal_error(
                    llvm::Twine("verified Core failed Xpp/Xmm/LLVM lowering ("
                                + PipelineFailure(pipeline) + ") for "
                                + std::string(sourceDescription)));
            }
            return pipeline;
        }

        [[nodiscard]] auto
        CompileVariant(std::span<const std::uint8_t> coreBytes,
                       bool optimizeXpp,
                       bool optimizeXmm) -> Llvm::Artifact
        {
            Progmasoft::Tala::Pipeline::Options options;
            options.optimize_xpp = optimizeXpp;
            options.optimize_xmm = optimizeXmm;
            options.llvm.optimization = optimizeXmm
                                            ? Llvm::OptimizationLevel::Default
                                            : Llvm::OptimizationLevel::Debug;
            const auto pipeline
                = Progmasoft::Tala::Pipeline::ConsumeCore(coreBytes, options);
            if (!pipeline || !pipeline.llvm)
                llvm::report_fatal_error(llvm::Twine(
                    "differential source failed a verified compiler pipeline: "
                    + PipelineFailure(pipeline)));
            return *pipeline.llvm;
        }

        [[nodiscard]] auto
        EntrySymbol(const Llvm::Artifact &artifact) -> std::string
        {
            // Names are assigned by the compiler's symbol pass. Discover the
            // one generated evaluator from LLVM IR instead of duplicating its
            // private symbol-ID/mangling rules in this test harness.
            const auto definition = artifact.llvm_ir.find("define ");
            const auto symbol
                = artifact.llvm_ir.find("@Fuzz.Evaluate.", definition);
            if (definition == std::string::npos || symbol == std::string::npos)
                llvm::report_fatal_error(llvm::Twine(
                    "generated fuzz module has no Evaluate definition"));
            const auto end = artifact.llvm_ir.find('(', symbol);
            if (end == std::string::npos)
                llvm::report_fatal_error(
                    llvm::Twine("generated fuzz Evaluate symbol has no "
                                "function signature"));
            return artifact.llvm_ir.substr(symbol + 1U, end - symbol - 1U);
        }

        [[nodiscard]] auto
        Invoke(const Llvm::Artifact &artifact, std::string_view identifier)
            -> std::int64_t
        {
            // A compiled program may call the AARC runtime: a closure does,
            // and so does an argument that is passed by need. The JIT finds
            // the runtime in this process. The call also keeps the runtime
            // in the program where the linker would otherwise leave an
            // unreferenced library out.
            if (tala_aarc_abi_version() != TALA_AARC_ABI_VERSION)
                llvm::report_fatal_error(llvm::Twine(
                    "the linked AARC runtime has another ABI version"));
            // Each oracle variant owns an isolated ORC session so equal source
            // symbols in optimized and reference modules cannot collide.
            Llvm::JitSession session;
            const auto entrySymbol = EntrySymbol(artifact);
            if (const auto error = session.AddModule(artifact.bitcode,
                                                     identifier,
                                                     entrySymbol,
                                                     Core::Type::int64()))
                llvm::report_fatal_error(
                    llvm::Twine("ORC rejected verified bitcode: " + error->code
                                + ": " + error->message));
            const auto result
                = session.InvokeScalar(entrySymbol, Core::Type::int64());
            if (!result.value)
                llvm::report_fatal_error(llvm::Twine(
                    "ORC could not invoke the verified "
                    "fuzz expression: "
                    + (result.error ? result.error->message
                                    : std::string("no error "
                                                  "was reported"))));
            return std::get<std::int64_t>(result.value->payload);
        }
    } // namespace

    void
    ExerciseLexer(std::span<const std::uint8_t> input)
    {
        if (input.size() <= kMaximumFuzzInput
            && !Frontend::FuzzSyntax(0U, input))
            llvm::report_fatal_error(
                llvm::Twine("Haskell lexer fuzz ABI is unavailable"));
    }

    void
    ExerciseParser(std::span<const std::uint8_t> input)
    {
        if (input.size() <= kMaximumFuzzInput
            && !Frontend::FuzzSyntax(1U, input))
            llvm::report_fatal_error(
                llvm::Twine("Haskell parser fuzz ABI is unavailable"));
    }

    void
    ExerciseSourceToLlvm(std::span<const std::uint8_t> input)
    {
        if (input.size() > kMaximumFuzzInput)
            return;
        const auto compiled = CompileSource(input);
        if (compiled.status == Frontend::Status::InternalError
            || compiled.status == Frontend::Status::OutputRejected)
            llvm::report_fatal_error(
                llvm::Twine("frontend failed internally while "
                            "compiling a source fuzz input"));
        if (!compiled.succeeded())
            return; // Lexical, syntax, and semantic diagnostics are normal.
        (void)ConsumeVerifiedCore(compiled, "arbitrary source fuzz input");
    }

    void
    ExerciseAcceptedSource(std::span<const std::uint8_t> input)
    {
        const auto compiled = CompileSource(input);
        (void)ConsumeVerifiedCore(compiled, "source that must be accepted");
    }

    void
    ExerciseDifferentialOracle(std::span<const std::uint8_t> input)
    {
        if (input.size() > kMaximumFuzzInput)
            return;
        std::int64_t expected{};
        const auto source = GeneratedProgram(input, expected);
        ExerciseExpectedValue(source, expected);
    }

    void
    ExerciseExpectedValue(std::string_view source, std::int64_t expected)
    {
        const auto bytes = std::span<const std::uint8_t>(
            reinterpret_cast<const std::uint8_t *>(source.data()),
            source.size());
        const auto compiled = CompileSource(bytes);
        if (!compiled.succeeded()
            || compiled.kind != Frontend::OutputKind::CoreWire)
            llvm::report_fatal_error(llvm::Twine(
                "source with a known result was rejected by the frontend:\n"
                + std::string(source)));
        // The comparison varies native optimizers, so both paths start from
        // the same frontend result. Recompiling identical source adds no
        // independent evidence and repeats work in the expensive oracle.
        const auto unoptimized = CompileVariant(compiled.bytes, false, false);
        const auto optimized = CompileVariant(compiled.bytes, true, true);
        // The harness never modifies its environment.
        // NOLINTNEXTLINE(concurrency-mt-unsafe)
        if (std::getenv("TALA_FUZZ_TRACE") != nullptr)
            llvm::errs() << source << "\nReference LLVM:\n"
                         << unoptimized.llvm_ir << "\nOptimized LLVM:\n"
                         << optimized.llvm_ir;
        constexpr std::string_view kReferenceModule = "tala-fuzz-reference";
        constexpr std::string_view kOptimizedModule = "tala-fuzz-optimized";
        const auto referenceValue = Invoke(unoptimized, kReferenceModule);
        const auto optimizedValue = Invoke(optimized, kOptimizedModule);
        // Compare both compiler modes with a small independent evaluator; a
        // shared optimizer/codegen defect cannot validate itself.
        if (referenceValue != expected || optimizedValue != expected
            || referenceValue != optimizedValue)
            llvm::report_fatal_error(llvm::Twine(
                "compiler differential oracle found a miscompile: expected "
                + std::to_string(expected) + ", baseline "
                + std::to_string(referenceValue) + ", optimized "
                + std::to_string(optimizedValue) + "; source:\n"
                + std::string(source)));
    }
} // namespace Progmasoft::Tala::Fuzzing
