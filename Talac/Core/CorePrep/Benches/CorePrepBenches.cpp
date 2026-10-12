// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <benchmark/benchmark.h>
#include <cstdint>
#include <llvm/ADT/Twine.h>
#include <llvm/Support/ErrorHandling.h>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Wire.hpp"

namespace
{
    namespace Core = tala::core;

    [[nodiscard]] auto
    Symbol(std::uint64_t id) -> Core::SymbolName
    {
        return { id, U"symbol" };
    }

    [[nodiscard]] auto
    MakeModule(std::size_t blockCount, std::size_t instructionsPerBlock)
        -> Core::CorePrepModule
    {
        std::vector<Core::Block> blocks;
        blocks.reserve(blockCount);
        std::uint64_t nextSymbol = 2U;
        for (std::size_t blockIndex = 0; blockIndex < blockCount; ++blockIndex)
        {
            std::vector<Core::Instruction> instructions;
            instructions.reserve(instructionsPerBlock);
            for (std::size_t instructionIndex = 0;
                 instructionIndex < instructionsPerBlock;
                 ++instructionIndex)
            {
                const auto destination = Symbol(nextSymbol++);
                instructions.push_back({
                    Core::Instruction::Kind::Bind,
                    destination,
                    Core::Type::int64(),
                    false,
                    Core::Operation::Copy,
                    { Core::Atom::constant(
                        static_cast<std::int64_t>(instructionIndex),
                        Core::Type::int64()) },
                    {},
                    {},
                });
            }
            Core::Terminator terminator;
            if (blockIndex + 1U < blockCount)
            {
                terminator.kind = Core::Terminator::Kind::Jump;
                terminator.true_target
                    = static_cast<Core::BlockId>(blockIndex + 1U);
            }
            else
            {
                terminator.kind = Core::Terminator::Kind::Return;
                terminator.value = Core::Atom::constant(std::int64_t{ 0 },
                                                        Core::Type::int64());
            }
            blocks.push_back({ static_cast<Core::BlockId>(blockIndex),
                               std::move(instructions),
                               std::move(terminator) });
        }
        Core::Function function{ Symbol(1U),
                                 {},
                                 Core::Type::int64(),
                                 0U,
                                 std::move(blocks) };
        return { { U"Benchmark" }, { std::move(function) } };
    }

    // A module of the given number of functions, each of which returns a
    // constant. What a function sees of the functions around it is part of
    // verifying it, so the cost of that view shows as the count grows.
    [[nodiscard]] auto
    MakeFunctions(std::size_t functionCount) -> Core::CorePrepModule
    {
        std::vector<Core::Function> functions;
        functions.reserve(functionCount);
        for (std::size_t index = 0; index < functionCount; ++index)
        {
            Core::Terminator terminator;
            terminator.kind = Core::Terminator::Kind::Return;
            terminator.value
                = Core::Atom::constant(std::int64_t{ 0 }, Core::Type::int64());
            functions.push_back({ Symbol(index + 1U),
                                  {},
                                  Core::Type::int64(),
                                  0U,
                                  { { 0U, {}, std::move(terminator) } } });
        }
        return { { U"Benchmark" }, std::move(functions) };
    }

    void
    RequireValid(const Core::CorePrepModule &module)
    {
        if (!Core::verify(module).empty())
            llvm::report_fatal_error(
                llvm::Twine("CorePrep benchmark fixture is not valid"));
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
            const auto issues = Core::verify(module);
            benchmark::DoNotOptimize(issues.data());
            benchmark::DoNotOptimize(issues.size());
        }
        state.SetItemsProcessed(state.iterations() * state.range(0)
                                * kInstructionsPerBlock);
        state.SetComplexityN(state.range(0));
    }

    void
    VerifyFunctions(benchmark::State &state)
    {
        const auto module
            = MakeFunctions(static_cast<std::size_t>(state.range(0)));
        RequireValid(module);
        for (auto _ : state)
        {
            const auto issues = Core::verify(module);
            benchmark::DoNotOptimize(issues.data());
            benchmark::DoNotOptimize(issues.size());
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
            const auto encoded = Core::wire::encode(module);
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
        const auto encoded = Core::wire::encode(module);
        if (!encoded)
            llvm::report_fatal_error(
                llvm::Twine("benchmark fixture could not be encoded"));
        for (auto _ : state)
        {
            const auto decoded = Core::wire::decode(encoded.bytes);
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
    constexpr auto kMinimumFunctions = 64;
    constexpr auto kMaximumFunctions = 4096;
} // namespace

BENCHMARK(Verify)
    ->RangeMultiplier(4)
    ->Range(kMinimumBlocks, kMaximumBlocks)
    ->Complexity();
BENCHMARK(VerifyFunctions)
    ->RangeMultiplier(4)
    ->Range(kMinimumFunctions, kMaximumFunctions)
    ->Complexity();
BENCHMARK(Encode)
    ->RangeMultiplier(4)
    ->Range(kMinimumBlocks, kMaximumBlocks)
    ->Complexity();
BENCHMARK(Decode)
    ->RangeMultiplier(4)
    ->Range(kMinimumBlocks, kMaximumBlocks)
    ->Complexity();
