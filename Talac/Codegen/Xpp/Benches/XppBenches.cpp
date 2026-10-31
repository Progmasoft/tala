// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <benchmark/benchmark.h>
#include <cstdint>
#include <llvm/ADT/Twine.h>
#include <llvm/Support/ErrorHandling.h>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Xpp/IR.hpp"
#include "Progmasoft/Tala/Xpp/Verifier.hpp"
#include "Progmasoft/Tala/Xpp/Wire.hpp"

namespace
{
    namespace Core = tala::core;
    namespace IR = tala::xpp;
    namespace Xpp = Progmasoft::Tala::Xpp;

    [[nodiscard]] auto
    Integer(std::int64_t value) -> IR::Operand
    {
        return { IR::Operand::Kind::Literal,
                 Core::Type::int64(),
                 0U,
                 Core::integer_from_signed(value) };
    }

    [[nodiscard]] auto
    Copy(IR::SymbolId destination, std::int64_t value) -> IR::Instruction
    {
        return {
            IR::Instruction::Effect::Define,
            IR::Opcode::Copy,
            destination,
            Core::Type::int64(),
            { Integer(value) },
            0U,
            {},
        };
    }

    [[nodiscard]] auto
    MakeModule(std::size_t blockCount, std::size_t instructionsPerBlock)
        -> IR::Module
    {
        std::vector<IR::Block> blocks;
        blocks.reserve(blockCount);
        IR::SymbolId nextSymbol = 2U;
        for (std::size_t blockIndex = 0; blockIndex < blockCount; ++blockIndex)
        {
            std::vector<IR::Instruction> instructions;
            instructions.reserve(instructionsPerBlock);
            for (std::size_t instructionIndex = 0;
                 instructionIndex < instructionsPerBlock;
                 ++instructionIndex)
            {
                instructions.push_back(
                    Copy(nextSymbol++,
                         static_cast<std::int64_t>(instructionIndex)));
            }

            IR::Terminator terminator;
            if (blockIndex + 1U < blockCount)
            {
                terminator.kind = IR::Terminator::Kind::Jump;
                terminator.true_target
                    = static_cast<IR::BlockId>(blockIndex + 1U);
            }
            else
            {
                terminator.kind = IR::Terminator::Kind::Return;
                terminator.value = { IR::Operand::Kind::Literal,
                                     Core::Type::unit(),
                                     0U,
                                     std::monostate{} };
            }
            blocks.push_back({ static_cast<IR::BlockId>(blockIndex),
                               std::move(instructions),
                               std::move(terminator) });
        }

        IR::Function function;
        function.symbol = { 1U, U"Benchmark" };
        function.return_type = Core::Type::unit();
        function.entry = 0U;
        function.blocks = std::move(blocks);
        return { { U"Benchmark", U"Xpp" }, { std::move(function) } };
    }

    void
    RequireValid(const IR::Module &module)
    {
        if (!Xpp::Verify(module).empty())
            llvm::report_fatal_error(
                llvm::Twine("Xpp benchmark fixture is not valid"));
    }

    void
    Verify(benchmark::State &state)
    {
        constexpr std::size_t kInstructionsPerBlock = 8U;
        const auto module = MakeModule(static_cast<std::size_t>(state.range(0)),
                                       kInstructionsPerBlock);
        RequireValid(module);
        for (auto _ : state)
        {
            const auto issues = Xpp::Verify(module);
            benchmark::DoNotOptimize(issues.data());
            benchmark::DoNotOptimize(issues.size());
        }
        state.SetItemsProcessed(state.iterations() * state.range(0)
                                * kInstructionsPerBlock);
        state.SetComplexityN(state.range(0));
    }

    void
    Optimize(benchmark::State &state)
    {
        const auto module
            = MakeModule(static_cast<std::size_t>(state.range(0)), 8U);
        RequireValid(module);
        for (auto _ : state)
        {
            const auto optimized = IR::optimize(module);
            benchmark::DoNotOptimize(optimized.functions.data());
            benchmark::DoNotOptimize(optimized.functions.front().blocks.size());
        }
        state.SetItemsProcessed(state.iterations() * state.range(0));
        state.SetComplexityN(state.range(0));
    }

    void
    Encode(benchmark::State &state)
    {
        const auto module
            = MakeModule(static_cast<std::size_t>(state.range(0)), 8U);
        RequireValid(module);
        for (auto _ : state)
        {
            const auto encoded = Xpp::Wire::Encode(module);
            benchmark::DoNotOptimize(encoded.bytes.data());
            benchmark::DoNotOptimize(encoded.bytes.size());
        }
        state.SetItemsProcessed(state.iterations() * state.range(0));
        state.SetComplexityN(state.range(0));
    }

    void
    Decode(benchmark::State &state)
    {
        const auto module
            = MakeModule(static_cast<std::size_t>(state.range(0)), 8U);
        RequireValid(module);
        const auto encoded = Xpp::Wire::Encode(module);
        if (!encoded)
            llvm::report_fatal_error(
                llvm::Twine("Xpp benchmark fixture could not be encoded"));
        for (auto _ : state)
        {
            const auto decoded = Xpp::Wire::Decode(encoded.bytes);
            benchmark::DoNotOptimize(decoded.module.has_value());
            benchmark::DoNotOptimize(
                decoded.module ? decoded.module->functions.data() : nullptr);
        }
        state.SetBytesProcessed(
            state.iterations()
            * static_cast<std::int64_t>(encoded.bytes.size()));
        state.SetItemsProcessed(state.iterations() * state.range(0));
        state.SetComplexityN(state.range(0));
    }

    constexpr auto kMinimumBlocks = 4;
    constexpr auto kMaximumBlocks = 256;
} // namespace

BENCHMARK(Verify)
    ->RangeMultiplier(4)
    ->Range(kMinimumBlocks, kMaximumBlocks)
    ->Complexity();
BENCHMARK(Optimize)
    ->RangeMultiplier(4)
    ->Range(kMinimumBlocks, kMaximumBlocks)
    ->Complexity();
BENCHMARK(Encode)
    ->RangeMultiplier(4)
    ->Range(kMinimumBlocks, kMaximumBlocks)
    ->Complexity();
BENCHMARK(Decode)
    ->RangeMultiplier(4)
    ->Range(kMinimumBlocks, kMaximumBlocks)
    ->Complexity();
