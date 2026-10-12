// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <array>
#include <limits>
#include <string_view>
#include <unordered_set>
#include <utility>

#include "Progmasoft/Tala/Diagnostic/Protocol.hpp"

namespace Progmasoft::Tala::Diagnostic
{
    namespace Wire = Artifact::Wire;

    namespace
    {
        constexpr std::array<std::uint8_t, 4U> kMagic{ 'T', 'A', 'D', 'G' };

        [[nodiscard]] auto
        WireLimits(const Limits &limits) -> Wire::Limits
        {
            Wire::Limits result;
            result.maximumWireBytes = limits.maximumWireBytes;
            result.maximumTextScalars = limits.maximumTextScalars;
            result.maximumFunctions = limits.maximumRecords;
            result.maximumParameters
                = std::max({ limits.maximumArguments,
                             limits.maximumRelatedLocations,
                             limits.maximumFixes,
                             limits.maximumEditsPerFix });
            return result;
        }

        [[nodiscard]] auto
        Failure(ErrorKind kind,
                std::size_t offset,
                std::string context,
                std::string message) -> Error
        {
            return Error{ kind,
                          offset,
                          std::move(context),
                          std::move(message) };
        }

        [[nodiscard]] auto
        PositionPrecedes(const Position &left, const Position &right) noexcept
            -> bool
        {
            return left.line < right.line
                   || (left.line == right.line && left.column <= right.column);
        }

        [[nodiscard]] auto
        ValidStage(Stage stage) noexcept -> bool
        {
            return static_cast<std::uint8_t>(stage)
                   <= static_cast<std::uint8_t>(Stage::LlvmBackend);
        }

        [[nodiscard]] auto
        ValidSeverity(Severity severity) noexcept -> bool
        {
            return static_cast<std::uint8_t>(severity)
                   <= static_cast<std::uint8_t>(Severity::Hint);
        }

        [[nodiscard]] auto
        ValidCode(std::u32string_view code) noexcept -> bool
        {
            if (code.empty() || code.size() > 64U)
                return false;
            return std::ranges::all_of(code, [](char32_t character) {
                return (character >= U'A' && character <= U'Z')
                       || (character >= U'0' && character <= U'9')
                       || character == U'-';
            });
        }

        [[nodiscard]] auto
        ValidateLocation(const Location &location, std::string_view context)
            -> std::optional<Error>
        {
            if (location.source.empty())
                return Failure(ErrorKind::InvalidModel,
                               0U,
                               std::string(context),
                               "diagnostic source identity is empty");
            if (!PositionPrecedes(location.range.start, location.range.end))
                return Failure(ErrorKind::InvalidModel,
                               0U,
                               std::string(context),
                               "diagnostic range end precedes its start");
            return std::nullopt;
        }

        [[nodiscard]] auto
        ValidateRecord(const Record &record, const Limits &limits)
            -> std::optional<Error>
        {
            if (!ValidStage(record.stage))
                return Failure(ErrorKind::InvalidTag,
                               0U,
                               "diagnostic stage",
                               "diagnostic stage is outside the v1 catalog");
            if (!ValidSeverity(record.severity))
                return Failure(ErrorKind::InvalidTag,
                               0U,
                               "diagnostic severity",
                               "diagnostic severity is outside the v1 catalog");
            if (!ValidCode(record.code))
                return Failure(ErrorKind::InvalidModel,
                               0U,
                               "diagnostic code",
                               "diagnostic code must be 1-64 ASCII uppercase, "
                               "digit, or hyphen scalars");
            if (record.message.empty())
                return Failure(ErrorKind::InvalidModel,
                               0U,
                               "diagnostic message",
                               "diagnostic message is empty");
            if (record.arguments.size() > limits.maximumArguments)
                return Failure(
                    ErrorKind::LimitExceeded,
                    0U,
                    "diagnostic argument count",
                    "diagnostic argument count exceeds configured limit");
            if (record.related.size() > limits.maximumRelatedLocations)
                return Failure(
                    ErrorKind::LimitExceeded,
                    0U,
                    "related location count",
                    "related location count exceeds configured limit");
            if (record.fixes.size() > limits.maximumFixes)
                return Failure(ErrorKind::LimitExceeded,
                               0U,
                               "diagnostic fix count",
                               "diagnostic fix count exceeds configured limit");

            std::unordered_set<std::u32string> argumentNames;
            argumentNames.reserve(record.arguments.size());
            for (const auto &argument : record.arguments)
            {
                if (argument.name.empty())
                    return Failure(ErrorKind::InvalidModel,
                                   0U,
                                   "diagnostic argument name",
                                   "diagnostic argument name is empty");
                if (!argumentNames.insert(argument.name).second)
                    return Failure(ErrorKind::InvalidModel,
                                   0U,
                                   "diagnostic argument name",
                                   "diagnostic argument names must be unique "
                                   "within one record");
            }
            if (record.primary)
                if (auto error
                    = ValidateLocation(*record.primary, "primary location"))
                    return error;
            for (const auto &related : record.related)
            {
                if (related.message.empty())
                    return Failure(ErrorKind::InvalidModel,
                                   0U,
                                   "related location message",
                                   "related location message is empty");
                if (auto error
                    = ValidateLocation(related.location, "related location"))
                    return error;
            }
            for (const auto &fix : record.fixes)
            {
                if (fix.title.empty())
                    return Failure(ErrorKind::InvalidModel,
                                   0U,
                                   "diagnostic fix title",
                                   "diagnostic fix title is empty");
                if (fix.edits.empty())
                    return Failure(
                        ErrorKind::InvalidModel,
                        0U,
                        "diagnostic fix edits",
                        "diagnostic fix must contain at least one edit");
                if (fix.edits.size() > limits.maximumEditsPerFix)
                    return Failure(
                        ErrorKind::LimitExceeded,
                        0U,
                        "diagnostic edit count",
                        "diagnostic edit count exceeds configured limit");
                for (const auto &edit : fix.edits)
                    if (auto error
                        = ValidateLocation(edit.location, "diagnostic edit"))
                        return error;
            }
            return std::nullopt;
        }

        void
        WriteLocation(Wire::Writer &writer, const Location &location)
        {
            writer.Text(location.source, "diagnostic source");
            writer.U32(location.range.start.line);
            writer.U32(location.range.start.column);
            writer.U32(location.range.end.line);
            writer.U32(location.range.end.column);
        }

        void
        WriteRecord(Wire::Writer &writer,
                    const Record &record,
                    const Limits &limits)
        {
            writer.Byte(static_cast<std::uint8_t>(record.stage));
            writer.Byte(static_cast<std::uint8_t>(record.severity));
            writer.Text(record.code, "diagnostic code");
            writer.Text(record.message, "diagnostic message");

            writer.Count(record.arguments.size(),
                         limits.maximumArguments,
                         "diagnostic argument count");
            for (const auto &argument : record.arguments)
            {
                writer.Text(argument.name, "diagnostic argument name");
                writer.Text(argument.value, "diagnostic argument value");
            }

            writer.Boolean(record.primary.has_value());
            if (record.primary)
                WriteLocation(writer, *record.primary);

            writer.Count(record.related.size(),
                         limits.maximumRelatedLocations,
                         "related location count");
            for (const auto &related : record.related)
            {
                WriteLocation(writer, related.location);
                writer.Text(related.message, "related location message");
            }

            writer.Count(record.fixes.size(),
                         limits.maximumFixes,
                         "diagnostic fix count");
            for (const auto &fix : record.fixes)
            {
                writer.Text(fix.title, "diagnostic fix title");
                writer.Count(fix.edits.size(),
                             limits.maximumEditsPerFix,
                             "diagnostic edit count");
                for (const auto &edit : fix.edits)
                {
                    WriteLocation(writer, edit.location);
                    writer.Text(edit.replacement,
                                "diagnostic edit replacement");
                }
            }
        }

        [[nodiscard]] auto
        ReadLocation(Wire::Reader &reader) -> Location
        {
            Location location;
            location.source = reader.Text("diagnostic source");
            location.range.start.line = reader.U32("diagnostic start line");
            location.range.start.column = reader.U32("diagnostic start column");
            location.range.end.line = reader.U32("diagnostic end line");
            location.range.end.column = reader.U32("diagnostic end column");
            return location;
        }

        [[nodiscard]] auto
        ReadStage(Wire::Reader &reader) -> Stage
        {
            const auto tag = reader.Byte("diagnostic stage");
            if (tag > static_cast<std::uint8_t>(Stage::LlvmBackend))
            {
                reader.Fail(ErrorKind::InvalidTag,
                            "diagnostic stage",
                            "unknown diagnostic stage tag");
                return Stage::Parser;
            }
            return static_cast<Stage>(tag);
        }

        [[nodiscard]] auto
        ReadSeverity(Wire::Reader &reader) -> Severity
        {
            const auto tag = reader.Byte("diagnostic severity");
            if (tag > static_cast<std::uint8_t>(Severity::Hint))
            {
                reader.Fail(ErrorKind::InvalidTag,
                            "diagnostic severity",
                            "unknown diagnostic severity tag");
                return Severity::Error;
            }
            return static_cast<Severity>(tag);
        }

        [[nodiscard]] auto
        ReadRecord(Wire::Reader &reader, const Limits &limits) -> Record
        {
            Record record;
            record.stage = ReadStage(reader);
            record.severity = ReadSeverity(reader);
            record.code = reader.Text("diagnostic code");
            record.message = reader.Text("diagnostic message");

            const auto argumentCount
                = reader.Count(limits.maximumArguments,
                               "diagnostic argument count");
            record.arguments.reserve(argumentCount);
            for (std::size_t index = 0U;
                 index < argumentCount && !reader.Failure();
                 ++index)
                record.arguments.push_back(
                    { reader.Text("diagnostic argument name"),
                      reader.Text("diagnostic argument value") });

            if (reader.Boolean("primary location presence"))
                record.primary = ReadLocation(reader);

            const auto relatedCount
                = reader.Count(limits.maximumRelatedLocations,
                               "related location count");
            record.related.reserve(relatedCount);
            for (std::size_t index = 0U;
                 index < relatedCount && !reader.Failure();
                 ++index)
            {
                auto location = ReadLocation(reader);
                record.related.push_back(
                    { std::move(location),
                      reader.Text("related location message") });
            }

            const auto fixCount
                = reader.Count(limits.maximumFixes, "diagnostic fix count");
            record.fixes.reserve(fixCount);
            for (std::size_t fixIndex = 0U;
                 fixIndex < fixCount && !reader.Failure();
                 ++fixIndex)
            {
                Fix fix;
                fix.title = reader.Text("diagnostic fix title");
                const auto editCount = reader.Count(limits.maximumEditsPerFix,
                                                    "diagnostic edit count");
                fix.edits.reserve(editCount);
                for (std::size_t editIndex = 0U;
                     editIndex < editCount && !reader.Failure();
                     ++editIndex)
                {
                    auto location = ReadLocation(reader);
                    fix.edits.push_back(
                        { std::move(location),
                          reader.Text("diagnostic edit replacement") });
                }
                record.fixes.push_back(std::move(fix));
            }
            return record;
        }
    } // namespace

    auto
    Encode(const Document &document, const Limits &limits) -> EncodeResult
    {
        if (document.records.size() > limits.maximumRecords)
            return { {},
                     Failure(ErrorKind::LimitExceeded,
                             0U,
                             "diagnostic count",
                             "diagnostic count exceeds configured limit") };
        for (const auto &record : document.records)
            if (auto error = ValidateRecord(record, limits))
                return { {}, std::move(error) };

        auto wireLimits = WireLimits(limits);
        Wire::Writer writer(wireLimits);
        for (const auto byte : kMagic)
            writer.Byte(byte);
        writer.U16(kProtocolVersion);
        writer.U16(0U);
        writer.Count(document.records.size(),
                     limits.maximumRecords,
                     "diagnostic count");
        for (const auto &record : document.records)
            WriteRecord(writer, record, limits);
        if (writer.Failure())
            return { {}, writer.Failure() };
        return { writer.TakeBytes(), std::nullopt };
    }

    auto
    Decode(const std::vector<std::uint8_t> &bytes, const Limits &limits)
        -> DecodeResult
    {
        if (bytes.size() > limits.maximumWireBytes)
            return { std::nullopt,
                     Failure(
                         ErrorKind::LimitExceeded,
                         0U,
                         "wire byte length",
                         "diagnostic document exceeds configured byte limit") };

        auto wireLimits = WireLimits(limits);
        Wire::Reader reader(bytes, wireLimits);
        for (const auto expected : kMagic)
            if (reader.Byte("magic") != expected)
            {
                reader.Fail(ErrorKind::InvalidMagic,
                            "magic",
                            "input is not a Tala diagnostic document");
                break;
            }
        const auto version = reader.U16("version");
        if (!reader.Failure() && version != kProtocolVersion)
            reader.Fail(ErrorKind::UnsupportedVersion,
                        "version",
                        "unsupported diagnostic protocol version");
        const auto flags = reader.U16("flags");
        if (!reader.Failure() && flags != 0U)
            reader.Fail(ErrorKind::InvalidTag,
                        "flags",
                        "reserved diagnostic flags must be zero");

        Document document;
        const auto count
            = reader.Count(limits.maximumRecords, "diagnostic count");
        document.records.reserve(count);
        for (std::size_t index = 0U; index < count && !reader.Failure();
             ++index)
        {
            auto record = ReadRecord(reader, limits);
            if (!reader.Failure())
            {
                if (auto error = ValidateRecord(record, limits))
                    reader.Fail(error->kind,
                                std::move(error->context),
                                std::move(error->message));
            }
            document.records.push_back(std::move(record));
        }
        if (!reader.Failure() && !reader.AtEnd())
            reader.Fail(ErrorKind::TrailingInput,
                        "document",
                        "bytes remain after diagnostic document");
        if (reader.Failure())
            return { std::nullopt, reader.Failure() };
        return { std::move(document), std::nullopt };
    }
} // namespace Progmasoft::Tala::Diagnostic
