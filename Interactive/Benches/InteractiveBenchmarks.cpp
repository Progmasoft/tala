// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <benchmark/benchmark.h>
#include <cstdint>
#include <string>
#include <utility>

#include "Progmasoft/Tala/Backend/LLVM.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Wire.hpp"
#include "Progmasoft/Tala/Pipeline.hpp"

namespace
{
    namespace Llvm = Progmasoft::Tala::Backend::LLVM;
    namespace Core = Llvm::Core;

    [[nodiscard]] auto
    LowerCell(std::uint64_t identity) -> Llvm::Result
    {
        Core::Function cell{
            { identity, U"Evaluate" },
            {},
            Core::Type::int64(),
            0,
            { Core::Block{
                0,
                {},
                Core::Terminator{
                    Core::Terminator::Kind::Return,
                    Core::Atom::constant(static_cast<std::int64_t>(identity),
                                         Core::Type::int64()),
                    0,
                    0 } } },
        };
        const Core::CorePrepModule module{ { U"TALI", U"Benchmark" },
                                           { std::move(cell) } };
        const auto xpp = tala::xpp::lower(module);
        const auto xmm = tala::xmm::lower(xpp);
        return Llvm::Lower(xmm);
    }

    void
    BenchmarkCellLowerAddInvokeReset(benchmark::State &state)
    {
        Llvm::JitSession session;
        std::uint64_t identity = 1U;
        for (auto _ : state)
        {
            const auto cell = identity++;
            auto result = LowerCell(cell);
            if (!result)
            {
                state.SkipWithError("Xmm-to-LLVM cell lowering failed");
                return;
            }
            const auto name = "TALI.Benchmark.Evaluate." + std::to_string(cell);
            if (auto issue = session.AddModule(result.artifact->bitcode,
                                               name,
                                               name,
                                               Core::Type::int64()))
            {
                state.SkipWithError(issue->message.c_str());
                return;
            }
            auto value = session.InvokeScalar(name, Core::Type::int64());
            if (!value)
            {
                state.SkipWithError(value.error->message.c_str());
                return;
            }
            benchmark::DoNotOptimize(value.value->payload);
            if (auto issue = session.Reset())
            {
                state.SkipWithError(issue->message.c_str());
                return;
            }
            state.SetItemsProcessed(state.iterations());
        }
    }

    void
    BenchmarkEmptyJitSession(benchmark::State &state)
    {
        for (auto _ : state)
        {
            Llvm::JitSession session;
            benchmark::DoNotOptimize(session);
        }
        state.SetItemsProcessed(state.iterations());
    }
} // namespace

BENCHMARK(BenchmarkCellLowerAddInvokeReset)->Unit(benchmark::kMicrosecond);
BENCHMARK(BenchmarkEmptyJitSession)->Unit(benchmark::kMicrosecond);
BENCHMARK_MAIN();
