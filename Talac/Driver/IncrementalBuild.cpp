// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <array>
#include <atomic>
#include <fmt/format.h>
#include <llvm/ADT/StringExtras.h>
#include <llvm/ADT/StringRef.h>
#include <llvm/Support/SHA256.h>
#include <llvm/Support/thread.h>
#include <mutex>
#include <set>
#include <system_error>
#include <thread>
#include <utility>

#include "Progmasoft/Tala/Xmm/Wire.hpp"
#include "Talac/Driver/IncrementalBuild.hpp"

namespace Progmasoft::Tala::Driver::Incremental
{
    namespace
    {
        namespace Llvm = Progmasoft::Tala::Backend::LLVM;

        constexpr std::string_view kEntryObject = "entry.o";
        constexpr std::string_view kKeyFormat = "tala object key 1";
        /// What a main thread usually has: LLVM recurses over the code it
        /// lowers, and the default of a thread is far less on some hosts.
        constexpr unsigned kWorkerStackBytes = 8U * 1024U * 1024U;

        /// The symbols a function refers to, itself not excluded.
        void
        CollectReferences(const tala::xmm::Function &function,
                          std::set<tala::xpp::SymbolId> &references)
        {
            using Value = tala::xmm::Value;
            const auto collect = [&](const Value &value) {
                if (value.kind == Value::Kind::Function)
                    references.insert(value.symbol);
            };
            for (const auto &block : function.blocks)
            {
                for (const auto &instruction : block.instructions)
                {
                    std::ranges::for_each(instruction.operands, collect);
                    if (instruction.opcode == tala::xmm::Opcode::MakeClosure)
                        references.insert(instruction.closure_function);
                }
                collect(block.terminator.value);
            }
        }

        /// The sources of [module]. A program made from one source through
        /// the single-file pipeline has no catalog: its functions own the
        /// empty name.
        [[nodiscard]] auto
        Sources(const tala::xmm::Module &module) -> std::vector<std::u32string>
        {
            if (module.source_files.empty())
                return { std::u32string{} };
            return module.source_files;
        }

        [[nodiscard]] auto
        IsObjectOfKey(const std::filesystem::path &file) -> bool
        {
            return file.extension() == ".o"
                   && file.filename() != std::filesystem::path(kEntryObject);
        }

        /// Writes [bytes] under [path] whole or not at all, so that a build
        /// that stops halfway leaves no object a later one would believe.
        [[nodiscard]] auto
        Publish(const std::filesystem::path &path,
                const std::vector<std::uint8_t> &bytes)
            -> std::optional<std::string>
        {
            auto staged = path;
            staged.replace_extension(".staged.o");
            if (const auto error = Llvm::WriteObject(staged, bytes))
                return error->message;
            std::error_code renamed;
            std::filesystem::rename(staged, path, renamed);
            if (renamed)
                return renamed.message();
            return std::nullopt;
        }

        [[nodiscard]] auto
        LowerSource(const tala::xmm::Module &module,
                    Llvm::Options options,
                    const std::u32string &source,
                    const std::filesystem::path &object)
            -> std::optional<std::string>
        {
            options.executableEntry = false;
            options.machineCode = Llvm::MachineCodeEmission::Object;
            options.definition_source_file = source;
            const auto lowered = Llvm::Lower(module, options);
            if (!lowered.artifact)
                return lowered.error ? lowered.error->message
                                     : "the backend returned neither an "
                                       "artifact nor an error";
            return Publish(object, lowered.artifact->object);
        }

        void
        RemoveStale(const std::filesystem::path &directory,
                    const std::vector<std::filesystem::path> &objects)
        {
            const std::set<std::filesystem::path> kept(objects.begin(),
                                                       objects.end());
            std::error_code error;
            std::vector<std::filesystem::path> stale;
            for (const auto &entry :
                 std::filesystem::directory_iterator(directory, error))
                if (IsObjectOfKey(entry.path()) && !kept.contains(entry.path()))
                    stale.push_back(entry.path());
            // An object left behind costs disk and nothing else.
            for (const auto &file : stale)
                std::filesystem::remove(file, error);
        }
    } // namespace

    auto
    SourceKey(const tala::xmm::Module &module,
              const std::u32string &source,
              const std::string_view context) -> std::optional<std::string>
    {
        std::vector<tala::xmm::Function> owned;
        std::set<tala::xpp::SymbolId> references;
        for (const auto &function : module.functions)
            if (function.source_file == source)
            {
                owned.push_back(function);
                CollectReferences(function, references);
            }
        // The functions of other sources count by their signature: their
        // bodies are in other objects.
        std::vector<tala::xmm::Function> called;
        for (const auto &function : module.functions)
            if (function.source_file != source
                && references.contains(function.symbol.id))
            {
                auto signature = function;
                signature.blocks.clear();
                signature.source_file.clear();
                called.push_back(std::move(signature));
            }
        namespace Wire = Progmasoft::Tala::Xmm::Wire;
        const auto ownedBytes = Wire::EncodeFunctions(owned);
        const auto calledBytes = Wire::EncodeFunctions(called);
        if (!ownedBytes || !calledBytes)
            return std::nullopt;

        llvm::SHA256 hash;
        hash.update(kKeyFormat);
        hash.update(context);
        const auto text = [&](const std::u32string &value) {
            hash.update(llvm::ArrayRef<std::uint8_t>(
                reinterpret_cast<const std::uint8_t *>(value.data()),
                value.size() * sizeof(char32_t)));
        };
        // Sources without a function must not share an object, and the
        // module names the symbols of its functions.
        text(source);
        std::ranges::for_each(module.name, text);
        hash.update(llvm::ArrayRef<std::uint8_t>(ownedBytes.bytes));
        hash.update(llvm::ArrayRef<std::uint8_t>(calledBytes.bytes));
        const auto digest = hash.final();
        return llvm::toHex(
            llvm::ArrayRef<std::uint8_t>(digest.data(), digest.size()),
            true);
    }

    auto
    BuildObjects(const tala::xmm::Module &module,
                 const Llvm::Options &options,
                 const std::filesystem::path &directory,
                 const std::string_view context) -> Outcome
    {
        Outcome outcome;
        std::error_code created;
        std::filesystem::create_directories(directory, created);
        if (created)
        {
            outcome.error = fmt::format("cannot create '{}': {}",
                                        directory.string(),
                                        created.message());
            return outcome;
        }

        const auto sources = Sources(module);
        outcome.sources = sources.size();

        std::vector<std::pair<const std::u32string *, std::filesystem::path>>
            missing;
        for (const auto &source : sources)
        {
            const auto key = SourceKey(module, source, context);
            if (!key)
            {
                outcome.error = "the Xmm of a source could not be encoded";
                return outcome;
            }
            auto object = directory / (*key + ".o");
            outcome.objects.push_back(object);
            std::error_code ignored;
            if (!std::filesystem::is_regular_file(object, ignored))
                missing.emplace_back(&source, std::move(object));
        }
        outcome.recompiled = missing.size();

        // The entry goes first, on this thread: it is what sets up the
        // target, and it says which format the objects have. It depends on
        // little and takes no time, so it is always made.
        auto entryOptions = options;
        entryOptions.executableEntry = true;
        entryOptions.entry_only = true;
        entryOptions.machineCode = Llvm::MachineCodeEmission::Object;
        const auto entry = Llvm::Lower(module, entryOptions);
        if (!entry.artifact)
        {
            outcome.error = entry.error ? entry.error->message
                                        : "the entry could not be lowered";
            return outcome;
        }
        auto entryObject = directory / std::filesystem::path(kEntryObject);
        if (auto error = Publish(entryObject, entry.artifact->object))
        {
            outcome.error = std::move(error);
            return outcome;
        }
        outcome.objectFormat = entry.artifact->objectFormat;
        outcome.targetTriple = entry.artifact->target_triple;

        // Every source has an LLVM context of its own, so the sources need
        // nothing from each other.
        std::atomic<std::size_t> next{};
        std::mutex failure;
        const auto work = [&] {
            for (auto index = next.fetch_add(1U); index < missing.size();
                 index = next.fetch_add(1U))
            {
                const auto &[source, object] = missing[index];
                if (auto error = LowerSource(module, options, *source, object))
                {
                    const std::scoped_lock lock(failure);
                    if (!outcome.error)
                        outcome.error = std::move(error);
                }
            }
        };
        const auto threads = std::min<std::size_t>(
            missing.size(),
            std::max(1U, std::thread::hardware_concurrency()));
        std::vector<llvm::thread> workers;
        workers.reserve(threads);
        for (std::size_t index = 0U; index < threads; ++index)
            workers.emplace_back(std::optional{ kWorkerStackBytes }, work);
        for (auto &worker : workers)
            worker.join();
        if (outcome.error)
            return outcome;

        RemoveStale(directory, outcome.objects);
        outcome.objects.push_back(std::move(entryObject));
        return outcome;
    }
} // namespace Progmasoft::Tala::Driver::Incremental
