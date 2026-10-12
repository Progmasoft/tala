// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <benchmark/benchmark.h>
#include <cstdint>
#include <llvm/ADT/Twine.h>
#include <llvm/Support/ErrorHandling.h>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Xmm/IR.hpp"
#include "Progmasoft/Tala/Xmm/Verifier.hpp"
#include "Progmasoft/Tala/Xmm/Wire.hpp"
#include "Progmasoft/Tala/Xpp/IR.hpp"

namespace
{
    namespace Core = tala::core;
    namespace IR = tala::xmm;
    namespace Xmm = Progmasoft::Tala::Xmm;
    namespace Xpp = tala::xpp;

    [[nodiscard]] auto
    Immediate(std::int64_t value) -> IR::Value
    {
        return { IR::Value::Kind::Immediate,
                 Core::Type::int64(),
                 0U,
                 0U,
                 Core::integer_from_signed(value) };
    }

    [[nodiscard]] auto
    Define(IR::VirtualRegister destination, std::int64_t value)
        -> IR::Instruction
    {
        return { IR::Opcode::LoadImmediate,
                 destination,
                 Core::Type::int64(),
                 { Immediate(value) },
                 true,
                 0U,
                 {} };
    }

    [[nodiscard]] auto
    MakeXmmModule(std::size_t blockCount, std::size_t instructionsPerBlock)
        -> IR::Module
    {
        std::vector<IR::Block> blocks;
        blocks.reserve(blockCount);
        IR::VirtualRegister nextRegister = 1U;
        for (std::size_t blockIndex = 0; blockIndex < blockCount; ++blockIndex)
        {
            std::vector<IR::Instruction> instructions;
            instructions.reserve(instructionsPerBlock);
            for (std::size_t instructionIndex = 0;
                 instructionIndex < instructionsPerBlock;
                 ++instructionIndex)
            {
                instructions.push_back(
                    Define(nextRegister++,
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
                terminator.value = { IR::Value::Kind::Immediate,
                                     Core::Type::unit(),
                                     0U,
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
        return { { U"Benchmark", U"Xmm" }, { std::move(function) } };
    }

    [[nodiscard]] auto
    MakeXppModule(std::size_t blockCount, std::size_t instructionsPerBlock)
        -> Xpp::Module
    {
        std::vector<Xpp::Block> blocks;
        blocks.reserve(blockCount);
        Xpp::SymbolId nextSymbol = 2U;
        for (std::size_t blockIndex = 0; blockIndex < blockCount; ++blockIndex)
        {
            std::vector<Xpp::Instruction> instructions;
            instructions.reserve(instructionsPerBlock);
            for (std::size_t instructionIndex = 0;
                 instructionIndex < instructionsPerBlock;
                 ++instructionIndex)
            {
                Xpp::Operand literal{ Xpp::Operand::Kind::Literal,
                                      Core::Type::int64(),
                                      0U,
                                      Core::integer_from_signed(
                                          static_cast<std::int64_t>(
                                              instructionIndex)) };
                instructions.push_back({ Xpp::Instruction::Effect::Define,
                                         Xpp::Opcode::Copy,
                                         nextSymbol++,
                                         Core::Type::int64(),
                                         { std::move(literal) },
                                         0U,
                                         {} });
            }
            Xpp::Terminator terminator;
            if (blockIndex + 1U < blockCount)
            {
                terminator.kind = Xpp::Terminator::Kind::Jump;
                terminator.true_target
                    = static_cast<Xpp::BlockId>(blockIndex + 1U);
            }
            else
            {
                terminator.kind = Xpp::Terminator::Kind::Return;
                terminator.value = { Xpp::Operand::Kind::Literal,
                                     Core::Type::unit(),
                                     0U,
                                     std::monostate{} };
            }
            blocks.push_back({ static_cast<Xpp::BlockId>(blockIndex),
                               std::move(instructions),
                               std::move(terminator) });
        }

        Xpp::Function function;
        function.symbol = { 1U, U"Benchmark" };
        function.return_type = Core::Type::unit();
        function.entry = 0U;
        function.blocks = std::move(blocks);
        return { { U"Benchmark", U"XppToXmm" }, { std::move(function) } };
    }

    void
    RequireValid(const IR::Module &module)
    {
        if (!Xmm::Verify(module).empty())
            llvm::report_fatal_error(
                llvm::Twine("Xmm benchmark fixture is not valid"));
    }

    void
    Verify(benchmark::State &state)
    {
        constexpr std::size_t kInstructionsPerBlock = 8U;
        const auto module
            = MakeXmmModule(static_cast<std::size_t>(state.range(0)),
                            kInstructionsPerBlock);
        RequireValid(module);
        for (auto _ : state)
        {
            const auto issues = Xmm::Verify(module);
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
            = MakeXmmModule(static_cast<std::size_t>(state.range(0)), 8U);
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
    Lower(benchmark::State &state)
    {
        const auto module
            = MakeXppModule(static_cast<std::size_t>(state.range(0)), 8U);
        RequireValid(IR::lower(module));
        for (auto _ : state)
        {
            const auto lowered = IR::lower(module);
            benchmark::DoNotOptimize(lowered.functions.data());
            benchmark::DoNotOptimize(lowered.functions.front().blocks.size());
        }
        state.SetItemsProcessed(state.iterations() * state.range(0));
        state.SetComplexityN(state.range(0));
    }

    void
    Encode(benchmark::State &state)
    {
        const auto module
            = MakeXmmModule(static_cast<std::size_t>(state.range(0)), 8U);
        RequireValid(module);
        for (auto _ : state)
        {
            const auto encoded = Xmm::Wire::Encode(module);
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
            = MakeXmmModule(static_cast<std::size_t>(state.range(0)), 8U);
        RequireValid(module);
        const auto encoded = Xmm::Wire::Encode(module);
        if (!encoded)
            llvm::report_fatal_error(
                llvm::Twine("Xmm benchmark fixture could not be encoded"));
        for (auto _ : state)
        {
            const auto decoded = Xmm::Wire::Decode(encoded.bytes);
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
BENCHMARK(Lower)
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
