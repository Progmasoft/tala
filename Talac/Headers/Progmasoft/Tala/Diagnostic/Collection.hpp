// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <unordered_set>
#include <vector>

#include "Progmasoft/Tala/Diagnostic/Protocol.hpp"

namespace Progmasoft::Tala::Diagnostic
{
    /// Outcome of inserting or merging a validated diagnostic record.
    enum class AppendStatus : std::uint8_t
    {
        Added,         ///< A new record was appended.
        Duplicate,     ///< An identical record already existed.
        LimitExceeded, ///< A configured document ceiling would be exceeded.
        Invalid        ///< The record failed protocol validation.
    };

    /// Insertion status together with a structured failure, when present.
    struct AppendResult final
    {
        /// Whether the record was added, duplicated, rejected, or too large.
        AppendStatus status{ AppendStatus::Invalid };
        /// Validation or capacity error for rejected input.
        std::optional<Error> error;

        /// Test whether the operation was accepted as a valid append.
        /// @return true for Added and Duplicate; false for all rejections.
        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return status == AppendStatus::Added
                   || status == AppendStatus::Duplicate;
        }
    };

    /// Bounded diagnostic accumulator shared by compiler stages.
    /// It preserves first-emission order, removes byte-identical duplicates,
    /// and applies the same validation and resource limits as the wire format.
    class Collection final
    {
    public:
        /// Create an empty accumulator with protocol resource ceilings.
        /// @param limits Maximum records, bytes, and nesting accepted.
        explicit Collection(Limits limits = {});

        /// Validate and append a record, coalescing identical prior records.
        /// @param record Diagnostic to append.
        /// @return Append status and a structured rejection reason.
        [[nodiscard]] auto
        Append(Record record) -> AppendResult;

        /// Merge a diagnostic document atomically.
        /// An invalid record or capacity overflow leaves this collection
        /// unchanged; duplicate records are accepted without re-emission.
        /// @param document Document to merge.
        /// @return Append status and a structured rejection reason.
        [[nodiscard]] auto
        Merge(const Document &document) -> AppendResult;

        /// Return the number of unique records retained.
        /// @return Record count.
        [[nodiscard]] auto
        Size() const noexcept -> std::size_t;

        /// Test whether no unique diagnostic records are retained.
        /// @return true when Size() is zero.
        [[nodiscard]] auto
        Empty() const noexcept -> bool;

        /// Count retained records whose severity is error.
        /// @return Error record count.
        [[nodiscard]] auto
        ErrorCount() const noexcept -> std::size_t;

        /// Count retained records whose severity is warning.
        /// @return Warning record count.
        [[nodiscard]] auto
        WarningCount() const noexcept -> std::size_t;

        /// Copy the accumulated records into a protocol document.
        /// @return Snapshot preserving first-emission order.
        [[nodiscard]] auto
        Snapshot() const -> Document;

        /// Transfer accumulated records and reset the reusable collection.
        /// @return Owned document; this collection is empty afterward.
        [[nodiscard]] auto
        Take() -> Document;

        /// Remove records and reset counters while retaining configured limits.
        void
        Clear() noexcept;

    private:
        Limits limits_;
        std::vector<Record> records_;
        std::unordered_set<std::string> identities_;
        std::size_t errorCount_{};
        std::size_t warningCount_{};

        [[nodiscard]] auto
        Identity(const Record &record) const -> EncodeResult;
    };
} // namespace Progmasoft::Tala::Diagnostic
