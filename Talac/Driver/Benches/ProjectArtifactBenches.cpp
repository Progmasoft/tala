// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <atomic>
#include <benchmark/benchmark.h>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

#include "Talac/Driver/ProjectArtifacts.hpp"

namespace
{
    namespace Artifacts = Progmasoft::Tala::Driver::ProjectArtifacts;

    class ScratchDirectory final
    {
    public:
        ScratchDirectory()
        {
            static std::atomic_uint64_t sequence{};
            const auto tick
                = std::chrono::steady_clock::now().time_since_epoch().count();
            const auto serial
                = sequence.fetch_add(1U, std::memory_order_relaxed);
            path_ = std::filesystem::temp_directory_path()
                    / ("tala-project-artifact-bench-" + std::to_string(tick)
                       + "-" + std::to_string(serial));
            created_ = std::filesystem::create_directory(path_);
        }

        ScratchDirectory(const ScratchDirectory &) = delete;
        auto
        operator=(const ScratchDirectory &) -> ScratchDirectory & = delete;

        ~ScratchDirectory()
        {
            if (!created_)
                return;
            std::error_code ignored;
            std::filesystem::remove_all(path_, ignored);
        }

        [[nodiscard]] auto
        Path() const noexcept -> const std::filesystem::path &
        {
            return path_;
        }

        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return created_;
        }

    private:
        std::filesystem::path path_;
        bool created_{};
    };

    [[nodiscard]] auto
    MakeSourceCatalog(const std::size_t count) -> std::vector<std::u32string>
    {
        std::vector<std::u32string> sources;
        sources.reserve(count);
        for (std::size_t index = 0U; index < count; ++index)
        {
            const auto ordinal = std::to_string(index);
            std::u32string source = U"Sources/Module";
            for (const auto character : ordinal)
                source.push_back(static_cast<char32_t>(character));
            source += U"/Unit";
            for (const auto character : ordinal)
                source.push_back(static_cast<char32_t>(character));
            source += U".tala";
            sources.push_back(std::move(source));
        }
        return sources;
    }

    [[nodiscard]] auto
    MakeArtifactBatch(const std::size_t count, const std::size_t bytes_per_file)
        -> std::vector<Artifacts::ArtifactFile>
    {
        std::vector<Artifacts::ArtifactFile> files;
        files.reserve(count);
        for (std::size_t index = 0U; index < count; ++index)
        {
            const auto ordinal = std::to_string(index);
            auto name = std::string("Unit") + ordinal + ".o";
            std::vector<std::uint8_t> bytes(bytes_per_file, 0x5aU);
            files.push_back({ std::move(name), std::move(bytes) });
        }
        return files;
    }

    void
    PlanProjectSourceOutputs(benchmark::State &state)
    {
        const auto count = static_cast<std::size_t>(state.range(0));
        const auto sources = MakeSourceCatalog(count);
        for (auto _ : state)
        {
            const auto plan = Artifacts::PlanSourceOutputs(sources, ".o");
            if (!plan)
            {
                state.SkipWithError(plan.diagnostic.c_str());
                return;
            }
            benchmark::DoNotOptimize(plan.outputs.data());
            benchmark::DoNotOptimize(plan.outputs.size());
        }
        state.SetItemsProcessed(state.iterations() * state.range(0));
        state.SetComplexityN(state.range(0));
    }

    void
    CommitProjectArtifactBatch(benchmark::State &state)
    {
        constexpr std::size_t kBytesPerObject = 4096U;
        const auto count = static_cast<std::size_t>(state.range(0));
        ScratchDirectory scratch;
        if (!scratch)
        {
            state.SkipWithError("could not create benchmark scratch output");
            return;
        }

        const auto output = scratch.Path() / "build" / "debug";
        const auto files = MakeArtifactBatch(count, kBytesPerObject);
        for (auto _ : state)
        {
            if (const auto error
                = Artifacts::CommitArtifactFiles(output, files))
            {
                state.SkipWithError(error->c_str());
                return;
            }
            benchmark::ClobberMemory();
        }

        state.SetItemsProcessed(state.iterations() * state.range(0));
        state.SetBytesProcessed(state.iterations() * state.range(0)
                                * static_cast<std::int64_t>(kBytesPerObject));
        state.SetComplexityN(state.range(0));
    }
} // namespace

BENCHMARK(PlanProjectSourceOutputs)
    ->Arg(1)
    ->Arg(4)
    ->Arg(16)
    ->Arg(64)
    ->Complexity();
BENCHMARK(CommitProjectArtifactBatch)
    ->Arg(1)
    ->Arg(4)
    ->Arg(16)
    ->Arg(64)
    ->Complexity();
