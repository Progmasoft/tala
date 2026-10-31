// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "Progmasoft/Tala/Artifact/WireSupport.hpp"

namespace Progmasoft::Tala::Diagnostic
{
    /// Current binary diagnostic side-channel format version.
    inline constexpr std::uint16_t kProtocolVersion = 1U;

    /// Compiler pipeline phase that produced a diagnostic.
    enum class Stage : std::uint8_t
    {
        /// Project source discovery and loading.
        SourceLoader,
        /// Tokenization of source text.
        Lexer,
        /// Syntactic analysis and AST construction.
        Parser,
        /// Declaration identity assignment.
        Renamer,
        /// Name and member lookup.
        NameResolution,
        /// Static type checking.
        TypeChecker,
        /// High-level semantic lowering.
        Desugarer,
        /// Construction of typed Core IR.
        Core,
        /// Core optimization passes.
        CoreOptimizer,
        /// CorePrep lowering and verification.
        CorePrep,
        /// CorePrep-to-Xpp lowering.
        XppLowering,
        /// Xpp optimization passes.
        XppOptimizer,
        /// Xpp-to-Xmm lowering.
        XmmLowering,
        /// Xmm optimization passes.
        XmmOptimizer,
        /// LLVM IR generation and native code emission.
        LlvmBackend
    };

    /// User-facing urgency associated with a diagnostic record.
    enum class Severity : std::uint8_t
    {
        /// The reported issue prevents the requested operation from succeeding.
        Error,
        /// The operation may succeed, but the source has a likely problem.
        Warning,
        /// Contextual information that does not request a source change.
        Information,
        /// A low-priority suggestion for the editor.
        Hint
    };

    /// Zero-based source coordinate encoded by the diagnostic protocol.
    struct Position final
    {
        /// Zero-based line index in the source document.
        std::uint32_t line{};
        /// Zero-based column measured in Unicode scalar values.
        std::uint32_t column{};

        /// Compare line and column coordinates.
        /// @return true when both coordinates are equal.
        [[nodiscard]] auto
        operator==(const Position &) const -> bool = default;
    };

    /// Half-open source interval from start through, but not including, end.
    struct Range final
    {
        /// Inclusive beginning position of the diagnostic span.
        Position start{};
        /// Exclusive end position of the diagnostic span.
        Position end{};

        /// Compare both range endpoints.
        /// @return true when start and end are equal.
        [[nodiscard]] auto
        operator==(const Range &) const -> bool = default;
    };

    /// Compiler-owned source identity and range for one document location.
    struct Location final
    {
        /// Source identity, usually a project-relative or absolute path.
        /// The wire format preserves it as text instead of imposing URI rules.
        std::u32string source;
        /// Range within source, using zero-based scalar coordinates.
        Range range{};

        /// Compare source identity and source range.
        /// @return true when source and range match.
        [[nodiscard]] auto
        operator==(const Location &) const -> bool = default;
    };

    /// Named interpolation value attached to a diagnostic message.
    struct MessageArgument final
    {
        /// Placeholder name referenced by the localized message template.
        std::u32string name;
        /// Textual value supplied for that placeholder.
        std::u32string value;

        /// Compare the placeholder name and value.
        /// @return true when both fields match.
        [[nodiscard]] auto
        operator==(const MessageArgument &) const -> bool = default;
    };

    /// Additional source location that explains a diagnostic's context.
    struct RelatedLocation final
    {
        /// Related declaration, use site, or other relevant source span.
        Location location;
        /// Human-readable explanation of the relationship.
        std::u32string message;

        /// Compare the related span and its explanation.
        /// @return true when both fields match.
        [[nodiscard]] auto
        operator==(const RelatedLocation &) const -> bool = default;
    };

    /// Replacement of one source range proposed as a diagnostic fix.
    struct TextEdit final
    {
        /// Source span that the edit replaces.
        Location location;
        /// Unicode text to insert in place of location.range.
        std::u32string replacement;

        /// Compare the target span and replacement text.
        /// @return true when both fields match.
        [[nodiscard]] auto
        operator==(const TextEdit &) const -> bool = default;
    };

    /// Atomic quick-fix candidate containing one or more edits.
    struct Fix final
    {
        /// Short action label shown by the consuming editor.
        std::u32string title;
        /// Edits applied together when the user selects this fix.
        std::vector<TextEdit> edits;

        /// Compare the user-visible title and edit set.
        /// @return true when both fields match.
        [[nodiscard]] auto
        operator==(const Fix &) const -> bool = default;
    };

    /// Structured diagnostic exchanged between compiler and editor clients.
    struct Record final
    {
        /// Pipeline phase responsible for detecting the issue.
        Stage stage{ Stage::Parser };
        /// Urgency presented to the user.
        Severity severity{ Severity::Error };
        /// Stable machine-readable diagnostic identifier.
        std::u32string code;
        /// Default human-readable message text.
        std::u32string message;
        /// Named values used to format a localized message.
        std::vector<MessageArgument> arguments;
        /// Primary source span, absent for diagnostics without source text.
        std::optional<Location> primary;
        /// Secondary spans that provide context for the primary issue.
        std::vector<RelatedLocation> related;
        /// Suggested edits that may resolve the issue.
        std::vector<Fix> fixes;

        /// Compare all user-visible and machine-readable diagnostic data.
        /// @return true when every record field matches.
        [[nodiscard]] auto
        operator==(const Record &) const -> bool = default;
    };

    /// Complete diagnostic document returned for one compiler operation.
    struct Document final
    {
        /// Diagnostics in deterministic reporting order.
        std::vector<Record> records;

        /// Compare diagnostic sequences and their records.
        /// @return true when records are equal and in the same order.
        [[nodiscard]] auto
        operator==(const Document &) const -> bool = default;
    };

    /// Resource limits applied before allocating from untrusted wire data.
    struct Limits final
    {
        /// Maximum encoded or decoded payload size, in bytes.
        std::size_t maximumWireBytes{ std::size_t{ 16U } * 1024U * 1024U };
        /// Maximum number of diagnostic records in one document.
        std::size_t maximumRecords{ 65535U };
        /// Maximum scalar count for any encoded text value.
        std::size_t maximumTextScalars{ std::size_t{ 1024U } * 1024U };
        /// Maximum named formatting arguments per record.
        std::size_t maximumArguments{ 256U };
        /// Maximum related source locations per record.
        std::size_t maximumRelatedLocations{ 256U };
        /// Maximum quick fixes attached to one record.
        std::size_t maximumFixes{ 128U };
        /// Maximum edits bundled into one quick fix.
        std::size_t maximumEditsPerFix{ 4096U };
    };

    /// Wire-format error details shared with the artifact protocol.
    using Error = Artifact::Wire::Error;
    /// Wire-format error category shared with the artifact protocol.
    using ErrorKind = Artifact::Wire::ErrorKind;

    /// Result of serializing a diagnostic document.
    struct EncodeResult final
    {
        /// Encoded protocol bytes when encoding succeeds.
        std::vector<std::uint8_t> bytes;
        /// Failure details when limits or validation reject the document.
        std::optional<Error> error;

        /// Test whether encoding completed without an error.
        /// @return true when error is empty.
        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return !error.has_value();
        }
    };

    /// Result of parsing a diagnostic document from protocol bytes.
    struct DecodeResult final
    {
        /// Parsed document when the payload is valid.
        std::optional<Document> document;
        /// Failure details when decoding rejects the payload.
        std::optional<Error> error;

        /// Test whether a valid document was decoded.
        /// @return true when document exists and error is empty.
        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return document.has_value() && !error.has_value();
        }
    };

    /// Serialize a structured diagnostic document into the versioned wire
    /// format.
    ///
    /// The protocol is an IDE/compiler side channel; command-line stderr
    /// wording may evolve independently while editor integrations consume this
    /// record.
    /// @param document Diagnostic records to encode.
    /// @param limits Resource ceilings enforced before and during
    /// serialization.
    /// @return Encoded bytes on success, otherwise a structured wire error.
    [[nodiscard]] auto
    Encode(const Document &document, const Limits &limits = {}) -> EncodeResult;

    /// Parse and validate one versioned diagnostic document.
    /// @param bytes Complete serialized document; trailing or malformed data is
    /// rejected.
    /// @param limits Resource ceilings enforced before allocating decoded data.
    /// @return Parsed document on success, otherwise a structured wire error.
    [[nodiscard]] auto
    Decode(const std::vector<std::uint8_t> &bytes, const Limits &limits = {})
        -> DecodeResult;
} // namespace Progmasoft::Tala::Diagnostic
