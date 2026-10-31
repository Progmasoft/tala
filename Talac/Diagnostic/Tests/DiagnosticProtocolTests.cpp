// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <array>
#include <cstdint>
#include <string>
#include <vector>

#include "Progmasoft/Tala/Diagnostic/Collection.hpp"
#include "Progmasoft/Tala/Diagnostic/Protocol.hpp"

namespace
{
    namespace Diagnostic = ::Progmasoft::Tala::Diagnostic;
    using Diagnostic::AppendStatus;
    using Diagnostic::Collection;
    using Diagnostic::Document;
    using Diagnostic::ErrorKind;
    using Diagnostic::Limits;
    using Diagnostic::Record;
    using Diagnostic::Severity;

    [[nodiscard]] auto
    Point(std::uint32_t line, std::uint32_t column) -> Diagnostic::Position
    {
        return { line, column };
    }

    [[nodiscard]] auto
    Source(std::u32string name = U"Sources/App/Main.tala",
           Diagnostic::Position start = Point(3U, 8U),
           Diagnostic::Position end = Point(3U, 13U)) -> Diagnostic::Location
    {
        return { std::move(name), { start, end } };
    }

    [[nodiscard]] auto
    RichDocument() -> Diagnostic::Document
    {
        Diagnostic::Record record;
        record.stage = Diagnostic::Stage::TypeChecker;
        record.severity = Diagnostic::Severity::Error;
        record.code = U"TAT1042";
        record.message = U"cannot convert argument '🐺' to System.String";
        record.arguments = {
            { U"argument", U"🐺" },
            { U"expected", U"System.String" },
        };
        record.primary = Source();
        record.related = {
            { Source(U"Sources/App/Api.tala", Point(11U, 4U), Point(11U, 22U)),
              U"parameter is declared here" },
        };
        record.fixes = {
            { U"Convert the value to String",
              { { Source(), U"value.ToString()" } } },
            { U"Change the parameter type",
              { { Source(U"Sources/App/Api.tala",
                         Point(11U, 4U),
                         Point(11U, 17U)),
                  U"System.Object" } } },
        };
        return { { std::move(record) } };
    }

    [[nodiscard]] auto
    SampleRecord() -> Record
    {
        auto document = RichDocument();
        auto record = std::move(document.records.front());
        // Keep collection fixtures compact while retaining a valid identity.
        record.arguments.clear();
        record.related.clear();
        record.fixes.clear();
        return record;
    }

    void
    RequireError(const Diagnostic::DecodeResult &result,
                 ErrorKind kind,
                 std::string_view context)
    {
        REQUIRE_FALSE(result);
        REQUIRE_FALSE(result.document.has_value());
        REQUIRE(result.error.has_value());
        CHECK(result.error->kind == kind);
        CHECK(result.error->context == context);
        CHECK_FALSE(result.error->message.empty());
    }

    void
    RequireError(const Diagnostic::EncodeResult &result,
                 ErrorKind kind,
                 std::string_view context)
    {
        REQUIRE_FALSE(result);
        REQUIRE(result.bytes.empty());
        REQUIRE(result.error.has_value());
        CHECK(result.error->kind == kind);
        CHECK(result.error->context == context);
        CHECK_FALSE(result.error->message.empty());
    }

    [[nodiscard]] auto
    Encoded(const Diagnostic::Document &document,
            const Diagnostic::Limits &limits = {}) -> std::vector<std::uint8_t>
    {
        const auto result = Diagnostic::Encode(document, limits);
        REQUIRE(result);
        REQUIRE_FALSE(result.bytes.empty());
        return result.bytes;
    }

    void
    StoreU32(std::vector<std::uint8_t> &bytes,
             std::size_t offset,
             std::uint32_t value)
    {
        REQUIRE(offset + 4U <= bytes.size());
        for (std::size_t index = 0U; index < 4U; ++index)
            bytes[offset + index]
                = static_cast<std::uint8_t>(value >> (index * 8U));
    }
} // namespace

TEST_CASE("diagnostic protocol round-trips the complete v1 model")
{
    const auto original = RichDocument();
    const auto bytes = Encoded(original);
    const auto decoded = Diagnostic::Decode(bytes);

    REQUIRE(decoded);
    REQUIRE(decoded.document == original);
    const auto &record = decoded.document->records.front();
    CHECK(record.stage == Diagnostic::Stage::TypeChecker);
    CHECK(record.severity == Diagnostic::Severity::Error);
    CHECK(record.arguments.size() == 2U);
    CHECK(record.related.size() == 1U);
    CHECK(record.fixes.size() == 2U);
    CHECK(record.fixes.front().edits.front().replacement
          == U"value.ToString()");
}

TEST_CASE(
    "diagnostic collection preserves order and coalesces exact duplicates")
{
    Collection collection;
    auto first = SampleRecord();
    auto second = SampleRecord();
    second.code = U"TAT205";

    REQUIRE(collection.Append(first).status == AppendStatus::Added);
    REQUIRE(collection.Append(first).status == AppendStatus::Duplicate);
    REQUIRE(collection.Append(second).status == AppendStatus::Added);
    REQUIRE(collection.Size() == 2U);
    REQUIRE(collection.Snapshot().records
            == std::vector<Record>{ first, second });
}

TEST_CASE("diagnostic collection counts only error and warning severities")
{
    Collection collection;
    auto error = SampleRecord();
    auto warning = SampleRecord();
    warning.code = U"TAT205";
    warning.severity = Severity::Warning;
    auto information = SampleRecord();
    information.code = U"TAT206";
    information.severity = Severity::Information;
    auto hint = SampleRecord();
    hint.code = U"TAT207";
    hint.severity = Severity::Hint;

    REQUIRE(
        collection.Merge(Document{ { error, warning, information, hint } }));
    REQUIRE(collection.ErrorCount() == 1U);
    REQUIRE(collection.WarningCount() == 1U);
}

TEST_CASE("diagnostic collection rejects invalid records without mutation")
{
    Collection collection;
    REQUIRE(collection.Append(SampleRecord()));
    auto invalid = SampleRecord();
    invalid.code = U"lowercase";

    const auto result = collection.Append(std::move(invalid));

    REQUIRE(result.status == AppendStatus::Invalid);
    REQUIRE(result.error.has_value());
    REQUIRE(collection.Size() == 1U);
}

TEST_CASE("diagnostic collection enforces its configured capacity")
{
    Limits limits;
    limits.maximumRecords = 1U;
    Collection collection(limits);
    auto second = SampleRecord();
    second.code = U"TAT205";

    REQUIRE(collection.Append(SampleRecord()));
    const auto result = collection.Append(std::move(second));

    REQUIRE(result.status == AppendStatus::LimitExceeded);
    REQUIRE(result.error->kind == ErrorKind::LimitExceeded);
    REQUIRE(collection.Size() == 1U);
}

TEST_CASE("diagnostic collection merge rolls back the complete batch")
{
    Limits limits;
    limits.maximumRecords = 2U;
    Collection collection(limits);
    const auto original = SampleRecord();
    REQUIRE(collection.Append(original));
    auto second = SampleRecord();
    second.code = U"TAT205";
    auto third = SampleRecord();
    third.code = U"TAT206";

    const auto result = collection.Merge(Document{ { second, third } });

    REQUIRE(result.status == AppendStatus::LimitExceeded);
    REQUIRE(collection.Snapshot() == Document{ { original } });
}

TEST_CASE(
    "diagnostic collection merge treats an all-duplicate batch as duplicate")
{
    Collection collection;
    const auto record = SampleRecord();
    REQUIRE(collection.Append(record));

    const auto result = collection.Merge(Document{ { record, record } });

    REQUIRE(result.status == AppendStatus::Duplicate);
    REQUIRE(collection.Size() == 1U);
}

TEST_CASE("diagnostic collection take resets all reusable state")
{
    Collection collection;
    auto warning = SampleRecord();
    warning.severity = Severity::Warning;
    REQUIRE(collection.Append(warning));

    const auto taken = collection.Take();

    REQUIRE(taken == Document{ { warning } });
    REQUIRE(collection.Empty());
    REQUIRE(collection.ErrorCount() == 0U);
    REQUIRE(collection.WarningCount() == 0U);
    REQUIRE(collection.Append(warning).status == AppendStatus::Added);
}

TEST_CASE("diagnostic collection clear discards identities as well as records")
{
    Collection collection;
    const auto record = SampleRecord();
    REQUIRE(collection.Append(record));

    collection.Clear();

    REQUIRE(collection.Empty());
    REQUIRE(collection.Append(record).status == AppendStatus::Added);
}

TEST_CASE("empty diagnostic documents have a stable compact header")
{
    const auto bytes = Encoded({});
    const std::vector<std::uint8_t> expected{
        'T', 'A', 'D', 'G', 1U, 0U, 0U, 0U, 0U, 0U, 0U, 0U,
    };
    REQUIRE(bytes == expected);
    const auto decoded = Diagnostic::Decode(bytes);
    REQUIRE(decoded);
    REQUIRE(decoded.document->records.empty());
}

TEST_CASE("diagnostic source positions are zero-based and lossless")
{
    auto document = RichDocument();
    document.records.front().primary
        = Source(U"Main.tala", Point(0U, 0U), Point(4294967295U, 4294967295U));

    const auto decoded = Diagnostic::Decode(Encoded(document));
    REQUIRE(decoded);
    REQUIRE(decoded.document->records.front().primary.has_value());
    CHECK(decoded.document->records.front().primary->range.start
          == Point(0U, 0U));
    CHECK(decoded.document->records.front().primary->range.end
          == Point(4294967295U, 4294967295U));
}

TEST_CASE("diagnostic document preserves every stage tag")
{
    Diagnostic::Document document;
    for (std::uint8_t tag = 0U;
         tag <= static_cast<std::uint8_t>(Diagnostic::Stage::LlvmBackend);
         ++tag)
    {
        Diagnostic::Record record;
        record.stage = static_cast<Diagnostic::Stage>(tag);
        record.code = U"TAD0001";
        record.message = U"stage";
        document.records.push_back(std::move(record));
    }
    const auto decoded = Diagnostic::Decode(Encoded(document));
    REQUIRE(decoded);
    REQUIRE(decoded.document->records.size() == document.records.size());
    for (std::size_t index = 0U; index < document.records.size(); ++index)
        CHECK(decoded.document->records[index].stage
              == document.records[index].stage);
}

TEST_CASE("diagnostic document preserves every severity tag")
{
    Diagnostic::Document document;
    for (std::uint8_t tag = 0U;
         tag <= static_cast<std::uint8_t>(Diagnostic::Severity::Hint);
         ++tag)
    {
        Diagnostic::Record record;
        record.severity = static_cast<Diagnostic::Severity>(tag);
        record.code = U"TAD0002";
        record.message = U"severity";
        document.records.push_back(std::move(record));
    }
    const auto decoded = Diagnostic::Decode(Encoded(document));
    REQUIRE(decoded);
    REQUIRE(decoded.document->records.size() == document.records.size());
    for (std::size_t index = 0U; index < document.records.size(); ++index)
        CHECK(decoded.document->records[index].severity
              == document.records[index].severity);
}

TEST_CASE("diagnostic protocol rejects invalid framing")
{
    SECTION("wrong magic")
    {
        auto bytes = Encoded({});
        bytes.front() = 'N';
        RequireError(Diagnostic::Decode(bytes),
                     ErrorKind::InvalidMagic,
                     "magic");
    }
    SECTION("old version")
    {
        auto bytes = Encoded({});
        bytes[4] = 0U;
        RequireError(Diagnostic::Decode(bytes),
                     ErrorKind::UnsupportedVersion,
                     "version");
    }
    SECTION("future version")
    {
        auto bytes = Encoded({});
        bytes[4] = 2U;
        RequireError(Diagnostic::Decode(bytes),
                     ErrorKind::UnsupportedVersion,
                     "version");
    }
    SECTION("reserved flags")
    {
        auto bytes = Encoded({});
        bytes[6] = 1U;
        RequireError(Diagnostic::Decode(bytes), ErrorKind::InvalidTag, "flags");
    }
    SECTION("truncated header")
    {
        auto bytes = Encoded({});
        bytes.pop_back();
        RequireError(Diagnostic::Decode(bytes),
                     ErrorKind::TruncatedInput,
                     "diagnostic count");
    }
    SECTION("trailing input")
    {
        auto bytes = Encoded({});
        bytes.push_back(0U);
        RequireError(Diagnostic::Decode(bytes),
                     ErrorKind::TrailingInput,
                     "document");
    }
}

TEST_CASE("diagnostic decoder rejects unknown semantic tags")
{
    auto bytes = Encoded(RichDocument());
    REQUIRE(bytes.size() > 13U);

    SECTION("stage")
    {
        bytes[12] = 0xffU;
        RequireError(Diagnostic::Decode(bytes),
                     ErrorKind::InvalidTag,
                     "diagnostic stage");
    }
    SECTION("severity")
    {
        bytes[13] = 0xffU;
        RequireError(Diagnostic::Decode(bytes),
                     ErrorKind::InvalidTag,
                     "diagnostic severity");
    }
}

TEST_CASE("diagnostic encoder validates record identity")
{
    SECTION("invalid stage")
    {
        auto document = RichDocument();
        // The out-of-catalog value is the input under test.
        // NOLINTNEXTLINE(clang-analyzer-optin.core.EnumCastOutOfRange)
        document.records.front().stage = static_cast<Diagnostic::Stage>(255U);
        RequireError(Diagnostic::Encode(document),
                     ErrorKind::InvalidTag,
                     "diagnostic stage");
    }
    SECTION("invalid severity")
    {
        auto document = RichDocument();
        // The out-of-catalog value is the input under test.
        document.records.front().severity
            // NOLINTNEXTLINE(clang-analyzer-optin.core.EnumCastOutOfRange)
            = static_cast<Diagnostic::Severity>(255U);
        RequireError(Diagnostic::Encode(document),
                     ErrorKind::InvalidTag,
                     "diagnostic severity");
    }
    SECTION("empty code")
    {
        auto document = RichDocument();
        document.records.front().code.clear();
        RequireError(Diagnostic::Encode(document),
                     ErrorKind::InvalidModel,
                     "diagnostic code");
    }
    SECTION("lowercase code")
    {
        auto document = RichDocument();
        document.records.front().code = U"Vxt1042";
        RequireError(Diagnostic::Encode(document),
                     ErrorKind::InvalidModel,
                     "diagnostic code");
    }
    SECTION("empty message")
    {
        auto document = RichDocument();
        document.records.front().message.clear();
        RequireError(Diagnostic::Encode(document),
                     ErrorKind::InvalidModel,
                     "diagnostic message");
    }
}

TEST_CASE("diagnostic locations require an identity and ordered range")
{
    SECTION("empty source")
    {
        auto document = RichDocument();
        document.records.front().primary->source.clear();
        RequireError(Diagnostic::Encode(document),
                     ErrorKind::InvalidModel,
                     "primary location");
    }
    SECTION("reversed line")
    {
        auto document = RichDocument();
        document.records.front().primary->range
            = { Point(9U, 0U), Point(8U, 99U) };
        RequireError(Diagnostic::Encode(document),
                     ErrorKind::InvalidModel,
                     "primary location");
    }
    SECTION("reversed column")
    {
        auto document = RichDocument();
        document.records.front().primary->range
            = { Point(9U, 7U), Point(9U, 6U) };
        RequireError(Diagnostic::Encode(document),
                     ErrorKind::InvalidModel,
                     "primary location");
    }
    SECTION("multi-line range")
    {
        auto document = RichDocument();
        document.records.front().primary->range
            = { Point(9U, 700U), Point(10U, 0U) };
        REQUIRE(Diagnostic::Encode(document));
    }
}

TEST_CASE("diagnostic message arguments have unique nonempty names")
{
    SECTION("empty name")
    {
        auto document = RichDocument();
        document.records.front().arguments.front().name.clear();
        RequireError(Diagnostic::Encode(document),
                     ErrorKind::InvalidModel,
                     "diagnostic argument name");
    }
    SECTION("duplicate name")
    {
        auto document = RichDocument();
        document.records.front().arguments.push_back(
            document.records.front().arguments.front());
        RequireError(Diagnostic::Encode(document),
                     ErrorKind::InvalidModel,
                     "diagnostic argument name");
    }
    SECTION("empty value is meaningful")
    {
        auto document = RichDocument();
        document.records.front().arguments.front().value.clear();
        REQUIRE(Diagnostic::Decode(Encoded(document)));
    }
}

TEST_CASE("diagnostic related locations require explanatory messages")
{
    auto document = RichDocument();
    document.records.front().related.front().message.clear();
    RequireError(Diagnostic::Encode(document),
                 ErrorKind::InvalidModel,
                 "related location message");
}

TEST_CASE("diagnostic fixes are named nonempty edit transactions")
{
    SECTION("empty title")
    {
        auto document = RichDocument();
        document.records.front().fixes.front().title.clear();
        RequireError(Diagnostic::Encode(document),
                     ErrorKind::InvalidModel,
                     "diagnostic fix title");
    }
    SECTION("no edits")
    {
        auto document = RichDocument();
        document.records.front().fixes.front().edits.clear();
        RequireError(Diagnostic::Encode(document),
                     ErrorKind::InvalidModel,
                     "diagnostic fix edits");
    }
    SECTION("empty replacement deletes text")
    {
        auto document = RichDocument();
        document.records.front()
            .fixes.front()
            .edits.front()
            .replacement.clear();
        const auto decoded = Diagnostic::Decode(Encoded(document));
        REQUIRE(decoded);
        CHECK(decoded.document->records.front()
                  .fixes.front()
                  .edits.front()
                  .replacement.empty());
    }
}

TEST_CASE("diagnostic encoder applies every collection limit")
{
    SECTION("record count")
    {
        auto document = RichDocument();
        Diagnostic::Limits limits;
        limits.maximumRecords = 0U;
        RequireError(Diagnostic::Encode(document, limits),
                     ErrorKind::LimitExceeded,
                     "diagnostic count");
    }
    SECTION("arguments")
    {
        auto document = RichDocument();
        Diagnostic::Limits limits;
        limits.maximumArguments = 1U;
        RequireError(Diagnostic::Encode(document, limits),
                     ErrorKind::LimitExceeded,
                     "diagnostic argument count");
    }
    SECTION("related locations")
    {
        auto document = RichDocument();
        Diagnostic::Limits limits;
        limits.maximumRelatedLocations = 0U;
        RequireError(Diagnostic::Encode(document, limits),
                     ErrorKind::LimitExceeded,
                     "related location count");
    }
    SECTION("fixes")
    {
        auto document = RichDocument();
        Diagnostic::Limits limits;
        limits.maximumFixes = 1U;
        RequireError(Diagnostic::Encode(document, limits),
                     ErrorKind::LimitExceeded,
                     "diagnostic fix count");
    }
    SECTION("edits")
    {
        auto document = RichDocument();
        Diagnostic::Limits limits;
        limits.maximumEditsPerFix = 0U;
        RequireError(Diagnostic::Encode(document, limits),
                     ErrorKind::LimitExceeded,
                     "diagnostic edit count");
    }
}

TEST_CASE(
    "diagnostic decoder applies record and wire byte limits before allocation")
{
    const auto bytes = Encoded(RichDocument());

    SECTION("wire bytes")
    {
        Diagnostic::Limits limits;
        limits.maximumWireBytes = bytes.size() - 1U;
        RequireError(Diagnostic::Decode(bytes, limits),
                     ErrorKind::LimitExceeded,
                     "wire byte length");
    }
    SECTION("record count")
    {
        Diagnostic::Limits limits;
        limits.maximumRecords = 0U;
        RequireError(Diagnostic::Decode(bytes, limits),
                     ErrorKind::LimitExceeded,
                     "diagnostic count");
    }
}

TEST_CASE("diagnostic text scalar limits cover nested payloads")
{
    auto document = RichDocument();
    Diagnostic::Limits limits;
    limits.maximumTextScalars = 4U;
    const auto encoded = Diagnostic::Encode(document, limits);
    REQUIRE_FALSE(encoded);
    REQUIRE(encoded.error.has_value());
    CHECK(encoded.error->kind == ErrorKind::LimitExceeded);
}

TEST_CASE("diagnostic decoder rejects malformed presence booleans")
{
    Diagnostic::Record record;
    record.code = U"TAD0003";
    record.message = U"x";
    auto bytes = Encoded({ { record } });

    // Header (12), stage (1), severity (1), code scalar vector (4 + 7*4),
    // message scalar vector (4 + 1*4), and empty argument count (4).
    const std::size_t primaryPresence = 12U + 2U + 4U + 7U * 4U + 4U + 4U + 4U;
    REQUIRE(primaryPresence < bytes.size());
    bytes[primaryPresence] = 2U;
    RequireError(Diagnostic::Decode(bytes),
                 ErrorKind::InvalidBoolean,
                 "primary location presence");
}

TEST_CASE(
    "diagnostic decoder rejects invalid model data from untrusted producers")
{
    Diagnostic::Record record;
    record.code = U"TAD0004";
    record.message = U"valid";
    record.primary = Source(U"A.tala", Point(4U, 2U), Point(4U, 9U));
    auto bytes = Encoded({ { record } });

    // Locate the four final u32 position fields by decoding the known source
    // length from this intentionally small fixture. Reversing the end column
    // exercises post-decode model validation, not framing validation.
    const auto sourceScalars = record.primary->source.size();
    const std::size_t locationStart = 12U + 2U + (4U + record.code.size() * 4U)
                                      + (4U + record.message.size() * 4U) + 4U
                                      + 1U;
    const std::size_t endColumn = locationStart + 4U + sourceScalars * 4U + 12U;
    StoreU32(bytes, endColumn, 1U);
    RequireError(Diagnostic::Decode(bytes),
                 ErrorKind::InvalidModel,
                 "primary location");
}
