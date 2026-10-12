// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <atomic>
#include <fstream>
#include <limits>
#include <ranges>
#include <string>
#include <unordered_set>

#include "Talac/Artifact/SourcePath.hpp"
#include "Talac/Driver/ProjectArtifacts.hpp"

namespace Progmasoft::Tala::Driver::ProjectArtifacts
{
    namespace
    {
        [[nodiscard]] auto
        IsUnicodeScalar(const char32_t value) -> bool
        {
            return value <= 0x10ffffU && (value < 0xd800U || value > 0xdfffU);
        }

        [[nodiscard]] auto
        IsPortableSourcePath(const std::u32string_view path) -> bool
        {
            return Artifact::IsNormalizedSourcePath(path);
        }

        [[nodiscard]] auto
        AppendUtf8(std::string &destination, const char32_t scalar) -> bool
        {
            if (!IsUnicodeScalar(scalar))
                return false;
            const auto value = static_cast<std::uint32_t>(scalar);
            if (value <= 0x7fU)
                destination.push_back(static_cast<char>(value));
            else if (value <= 0x7ffU)
            {
                destination.push_back(static_cast<char>(0xc0U | (value >> 6U)));
                destination.push_back(
                    static_cast<char>(0x80U | (value & 0x3fU)));
            }
            else if (value <= 0xffffU)
            {
                destination.push_back(
                    static_cast<char>(0xe0U | (value >> 12U)));
                destination.push_back(
                    static_cast<char>(0x80U | ((value >> 6U) & 0x3fU)));
                destination.push_back(
                    static_cast<char>(0x80U | (value & 0x3fU)));
            }
            else
            {
                destination.push_back(
                    static_cast<char>(0xf0U | (value >> 18U)));
                destination.push_back(
                    static_cast<char>(0x80U | ((value >> 12U) & 0x3fU)));
                destination.push_back(
                    static_cast<char>(0x80U | ((value >> 6U) & 0x3fU)));
                destination.push_back(
                    static_cast<char>(0x80U | (value & 0x3fU)));
            }
            return true;
        }

        [[nodiscard]] auto
        Utf8(const std::u32string_view text) -> std::optional<std::string>
        {
            std::string result;
            result.reserve(text.size());
            for (const auto scalar : text)
                if (!AppendUtf8(result, scalar))
                    return std::nullopt;
            return result;
        }

        [[nodiscard]] auto
        FoldAscii(std::string text) -> std::string
        {
            for (auto &character : text)
                if (character >= 'A' && character <= 'Z')
                    character = static_cast<char>(character - 'A' + 'a');
            return text;
        }

        [[nodiscard]] auto
        IsValidUtf8(const std::string_view text) -> bool
        {
            // Artifact names cross the UTF-32 IR boundary and become native
            // filesystem paths. Reject malformed byte strings here instead
            // of allowing the host locale to reinterpret them differently.
            for (std::size_t index = 0U; index < text.size();)
            {
                const auto first = static_cast<unsigned char>(text[index]);
                if (first <= 0x7fU)
                {
                    ++index;
                    continue;
                }

                std::size_t width{};
                std::uint32_t scalar{};
                if (first >= 0xc2U && first <= 0xdfU)
                {
                    width = 2U;
                    scalar = first & 0x1fU;
                }
                else if (first >= 0xe0U && first <= 0xefU)
                {
                    width = 3U;
                    scalar = first & 0x0fU;
                }
                else if (first >= 0xf0U && first <= 0xf4U)
                {
                    width = 4U;
                    scalar = first & 0x07U;
                }
                else
                    return false;

                if (width > text.size() - index)
                    return false;
                for (std::size_t continuation = 1U; continuation < width;
                     ++continuation)
                {
                    const auto byte = static_cast<unsigned char>(
                        text[index + continuation]);
                    if ((byte & 0xc0U) != 0x80U)
                        return false;
                    scalar = (scalar << 6U) | (byte & 0x3fU);
                }

                // Shortest-form encoding, scalar range, and surrogate checks
                // prevent multiple byte spellings for the same path name.
                if ((width == 2U && scalar < 0x80U)
                    || (width == 3U && scalar < 0x800U)
                    || (width == 4U && scalar < 0x10000U)
                    || !IsUnicodeScalar(static_cast<char32_t>(scalar)))
                    return false;
                index += width;
            }
            return true;
        }

        [[nodiscard]] auto
        Utf8Path(const std::string_view text) -> std::filesystem::path
        {
            const auto *begin = reinterpret_cast<const char8_t *>(text.data());
            return std::filesystem::path(
                std::u8string(begin, begin + text.size()));
        }

        [[nodiscard]] auto
        PathText(const std::filesystem::path &path) -> std::string
        {
            const auto text = path.u8string();
            return { reinterpret_cast<const char *>(text.data()), text.size() };
        }

        [[nodiscard]] auto
        IsSafeFileName(const std::string_view name) -> bool
        {
            if (name.empty() || !IsValidUtf8(name) || name == "."
                || name == ".." || name.back() == '.' || name.back() == ' ')
                return false;

            // Keep emitted basenames valid across the supported Windows and
            // Unix filesystems. A name accepted on one host must not fail only
            // after a clean checkout on another supported host.
            constexpr std::string_view kForbidden = "<>:\"/\\|?*";
            for (const auto character : name)
            {
                const auto byte = static_cast<unsigned char>(character);
                if (byte < 0x20U || byte == 0x7fU
                    || kForbidden.find(character) != std::string_view::npos)
                    return false;
            }

            // Device names are reserved by Win32 even when followed by an
            // extension. Only the ASCII device stem is case-insensitive.
            const auto firstDot = name.find('.');
            const auto device
                = FoldAscii(std::string(name.substr(0U, firstDot)));
            if (device == "con" || device == "prn" || device == "aux"
                || device == "nul" || device == "conin$" || device == "conout$"
                || device == "clock$")
                return false;
            if (device.size() == 4U
                && (device.starts_with("com") || device.starts_with("lpt"))
                && device.back() >= '1' && device.back() <= '9')
                return false;
            if (device.size() > 3U
                && (device.starts_with("com") || device.starts_with("lpt")))
            {
                constexpr std::string_view kSuperscriptNumbers[]{ "\xc2\xb9",
                                                                  "\xc2\xb2",
                                                                  "\xc2\xb3" };
                const auto suffix = std::string_view(device).substr(3U);
                if (std::ranges::find(kSuperscriptNumbers, suffix)
                    != std::ranges::end(kSuperscriptNumbers))
                    return false;
            }
            return true;
        }

        struct PendingReplacement final
        {
            std::filesystem::path destination;
            std::filesystem::path backup;
            bool had_original{};
            bool backed_up{};
            bool installed{};
        };

        class TransactionDirectory final
        {
        public:
            explicit TransactionDirectory(const std::filesystem::path &parent)
            {
                static std::atomic_uint64_t sequence{};
                for (std::size_t attempt = 0U; attempt < 128U; ++attempt)
                {
                    const auto nonce
                        = sequence.fetch_add(1U, std::memory_order_relaxed);
                    path_
                        = parent / (".tala-artifacts-" + std::to_string(nonce));
                    std::error_code error;
                    if (std::filesystem::create_directory(path_, error))
                    {
                        created_ = true;
                        return;
                    }
                    if (error && error != std::errc::file_exists)
                    {
                        diagnostic_ = error.message();
                        return;
                    }
                }
                diagnostic_ = "could not reserve a private staging directory";
            }

            TransactionDirectory(const TransactionDirectory &) = delete;
            auto
            operator=(const TransactionDirectory &)
                -> TransactionDirectory & = delete;

            ~TransactionDirectory()
            {
                if (!created_ || !cleanup_)
                    return;
                std::error_code ignored;
                std::filesystem::remove_all(path_, ignored);
            }

            [[nodiscard]] auto
            Path() const -> const std::filesystem::path &
            {
                return path_;
            }

            [[nodiscard]] auto
            Diagnostic() const -> const std::string &
            {
                return diagnostic_;
            }

            // Preserve the private staging tree if rollback cannot restore an
            // original artifact; its backup is the only safe recovery copy.
            void
            Preserve() noexcept
            {
                cleanup_ = false;
            }

            [[nodiscard]] explicit
            operator bool() const noexcept
            {
                return created_;
            }

        private:
            std::filesystem::path path_;
            std::string diagnostic_;
            bool created_{};
            bool cleanup_{ true };
        };

        [[nodiscard]] auto
        WriteStagedFile(const std::filesystem::path &path,
                        const std::span<const std::uint8_t> bytes)
            -> std::optional<std::string>
        {
            std::ofstream stream(path, std::ios::binary | std::ios::trunc);
            if (!stream)
                return "could not open staged artifact '" + PathText(path)
                       + "'";
            if (!bytes.empty())
                stream.write(reinterpret_cast<const char *>(bytes.data()),
                             static_cast<std::streamsize>(bytes.size()));
            stream.flush();
            if (!stream)
                return "could not finish staged artifact '" + PathText(path)
                       + "'";
            stream.close();
            if (stream.fail())
                return "could not close staged artifact '" + PathText(path)
                       + "'";
            return std::nullopt;
        }

        [[nodiscard]] auto
        RollBack(std::vector<PendingReplacement> &replacements)
            -> std::optional<std::string>
        {
            // Reverse order mirrors commit order. Each path is created or moved
            // only by this transaction, so rollback never erases unrelated
            // project output.
            std::string failures;
            for (auto &replacement : std::views::reverse(replacements))
            {
                std::error_code error;
                if (replacement.installed)
                {
                    std::filesystem::remove(replacement.destination, error);
                    if (error)
                    {
                        failures += " could not remove '";
                        failures += PathText(replacement.destination);
                        failures += "': ";
                        failures += error.message();
                        continue;
                    }
                    replacement.installed = false;
                }
                if (replacement.backed_up)
                {
                    error.clear();
                    std::filesystem::rename(replacement.backup,
                                            replacement.destination,
                                            error);
                    if (error)
                    {
                        failures += " could not restore '";
                        failures += PathText(replacement.destination);
                        failures += "' from '";
                        failures += PathText(replacement.backup);
                        failures += "': ";
                        failures += error.message();
                        continue;
                    }
                    replacement.backed_up = false;
                }
            }
            if (failures.empty())
                return std::nullopt;
            return failures;
        }

        [[nodiscard]] auto
        AbortReplacement(TransactionDirectory &transaction,
                         std::vector<PendingReplacement> &replacements,
                         std::string primary_error) -> std::string
        {
            if (const auto rollback_error = RollBack(replacements))
            {
                transaction.Preserve();
                primary_error += "; rollback was incomplete:";
                primary_error += *rollback_error;
                primary_error += "; recovery files retained at '";
                primary_error += PathText(transaction.Path());
                primary_error += "'";
            }
            return primary_error;
        }
    } // namespace

    auto
    PlanSourceOutputs(const std::span<const std::u32string> source_files,
                      const std::string_view extension) -> PlanResult
    {
        if (extension != ".o" && extension != ".asm")
            return { {}, "project source output supports only .o and .asm" };
        if (source_files.empty())
            return { {}, "project source catalog is empty" };

        PlanResult result;
        result.outputs.reserve(source_files.size());
        std::unordered_set<std::string> names;
        names.reserve(source_files.size());
        std::unordered_set<std::u32string> sources;
        sources.reserve(source_files.size());
        for (const auto &source : source_files)
        {
            if (!IsPortableSourcePath(source))
                return { {},
                         "project source path is not a normalized "
                         "relative .tala path" };
            if (!sources.insert(source).second)
                return { {}, "project source catalog repeats a source path" };

            const auto basenameStart = source.find_last_of(U'/');
            const auto basename = std::u32string_view(source).substr(
                basenameStart == std::u32string::npos ? 0U
                                                      : basenameStart + 1U);
            constexpr std::u32string_view kSourceExtension = U".tala";
            const auto stem
                = basename.substr(0U,
                                  basename.size() - kSourceExtension.size());
            const auto encodedStem = Utf8(stem);
            if (!encodedStem || !IsSafeFileName(*encodedStem))
                return { {},
                         "project source basename is not a valid "
                         "portable output name" };
            const auto fileName = *encodedStem + std::string(extension);
            if (!names.insert(FoldAscii(fileName)).second)
                return { {},
                         "project sources flatten to the same output "
                         "name: "
                             + fileName };
            result.outputs.push_back({ source, fileName });
        }
        return result;
    }

    auto
    CommitArtifactFiles(const std::filesystem::path &output_directory,
                        const std::span<const ArtifactFile> files)
        -> std::optional<std::string>
    {
        if (files.empty())
            return "project artifact batch is empty";
        std::unordered_set<std::string> names;
        names.reserve(files.size());
        for (const auto &file : files)
        {
            if (!IsSafeFileName(file.file_name))
                return "project artifact name is not a basename";
            if (!file.file_name.ends_with(".o")
                && !file.file_name.ends_with(".asm"))
                return "project artifact batch supports only .o and .asm";
            if (!names.insert(FoldAscii(file.file_name)).second)
                return "project artifact batch contains a colliding name: "
                       + file.file_name;
        }

        std::error_code filesystem_error;
        std::filesystem::create_directories(output_directory, filesystem_error);
        if (filesystem_error)
            return "could not create project output directory: "
                   + filesystem_error.message();
        if (!std::filesystem::is_directory(output_directory, filesystem_error)
            || filesystem_error)
            return "project output path is not a directory";

        TransactionDirectory transaction(output_directory);
        if (!transaction)
            return "could not create project staging directory: "
                   + transaction.Diagnostic();
        // ASCII folding above fully covers ASCII filesystem aliases. Probe the
        // destination volume only when Unicode names can have host-specific
        // case or normalization equivalence; ordinary ASCII batches avoid one
        // extra directory creation per output.
        const auto hasNonAsciiName
            = std::ranges::any_of(files, [](const auto &file) {
                  return std::ranges::any_of(
                      file.file_name,
                      [](const char character) {
                          return static_cast<unsigned char>(character) >= 0x80U;
                      });
              });
        if (hasNonAsciiName)
        {
            const auto probes = transaction.Path() / "name-probes";
            std::filesystem::create_directory(probes, filesystem_error);
            if (filesystem_error)
                return "could not initialize project name probes: "
                       + filesystem_error.message();
            for (const auto &file : files)
            {
                const auto probe = probes / Utf8Path(file.file_name);
                if (!std::filesystem::create_directory(probe, filesystem_error))
                    return "project output names collide on this filesystem: "
                           + file.file_name;
            }
        }

        for (std::size_t index = 0U; index < files.size(); ++index)
            if (const auto error = WriteStagedFile(
                    transaction.Path() / ("new-" + std::to_string(index)),
                    files[index].bytes))
                return error;

        std::vector<PendingReplacement> replacements;
        replacements.reserve(files.size());
        for (std::size_t index = 0U; index < files.size(); ++index)
        {
            const auto &file = files[index];
            PendingReplacement replacement{
                output_directory / Utf8Path(file.file_name),
                transaction.Path() / ("old-" + std::to_string(index)),
                false,
                false,
                false
            };
            const auto status
                = std::filesystem::symlink_status(replacement.destination,
                                                  filesystem_error);
            if (filesystem_error
                && filesystem_error != std::errc::no_such_file_or_directory)
            {
                return "could not inspect existing project artifact '"
                       + PathText(replacement.destination)
                       + "': " + filesystem_error.message();
            }
            filesystem_error.clear();
            if (std::filesystem::is_directory(status))
            {
                return "project artifact destination is a directory: "
                       + PathText(replacement.destination);
            }
            replacement.had_original
                = status.type() != std::filesystem::file_type::not_found;
            replacements.push_back(std::move(replacement));
        }

        for (std::size_t index = 0U; index < files.size(); ++index)
        {
            auto &replacement = replacements[index];
            if (replacement.had_original)
            {
                std::filesystem::rename(replacement.destination,
                                        replacement.backup,
                                        filesystem_error);
                if (filesystem_error)
                {
                    return AbortReplacement(
                        transaction,
                        replacements,
                        "could not preserve existing artifact '"
                            + PathText(replacement.destination)
                            + "': " + filesystem_error.message());
                }
                replacement.backed_up = true;
            }
            std::filesystem::rename(transaction.Path()
                                        / ("new-" + std::to_string(index)),
                                    replacement.destination,
                                    filesystem_error);
            if (filesystem_error)
            {
                return AbortReplacement(transaction,
                                        replacements,
                                        "could not install project artifact '"
                                            + PathText(replacement.destination)
                                            + "': "
                                            + filesystem_error.message());
            }
            replacement.installed = true;
        }
        return std::nullopt;
    }
} // namespace Progmasoft::Tala::Driver::ProjectArtifacts
