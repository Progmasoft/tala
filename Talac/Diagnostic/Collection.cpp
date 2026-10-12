// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <string>
#include <utility>

#include "Progmasoft/Tala/Diagnostic/Collection.hpp"

namespace Progmasoft::Tala::Diagnostic
{
    Collection::Collection(Limits limits)
        : limits_(limits)
    {
        records_.reserve(std::min<std::size_t>(limits_.maximumRecords, 256U));
        identities_.reserve(
            std::min<std::size_t>(limits_.maximumRecords, 256U));
    }

    auto
    Collection::Append(Record record) -> AppendResult
    {
        auto encoded = Identity(record);
        if (encoded.error)
        {
            const auto status = encoded.error->kind == ErrorKind::LimitExceeded
                                    ? AppendStatus::LimitExceeded
                                    : AppendStatus::Invalid;
            return { status, std::move(encoded.error) };
        }

        // Binary identity avoids maintaining a second, subtly different notion
        // of equality as the structured record grows new optional fields.
        std::string identity(
            reinterpret_cast<const char *>(encoded.bytes.data()),
            encoded.bytes.size());
        if (identities_.contains(identity))
            return { AppendStatus::Duplicate, std::nullopt };
        if (records_.size() >= limits_.maximumRecords)
            return {
                AppendStatus::LimitExceeded,
                Error{
                    ErrorKind::LimitExceeded,
                    0U,
                    "diagnostic count",
                    "diagnostic collection exceeds configured record limit" }
            };

        identities_.insert(std::move(identity));
        if (record.severity == Severity::Error)
            ++errorCount_;
        if (record.severity == Severity::Warning)
            ++warningCount_;
        records_.push_back(std::move(record));
        return { AppendStatus::Added, std::nullopt };
    }

    auto
    Collection::Merge(const Document &document) -> AppendResult
    {
        // Copying here is intentional. It makes a multi-stage merge atomic and
        // keeps rollback logic out of every caller; diagnostic batches are
        // small.
        Collection candidate = *this;
        AppendStatus aggregate = AppendStatus::Duplicate;
        for (const auto &record : document.records)
        {
            auto result = candidate.Append(record);
            if (!result)
                return result;
            if (result.status == AppendStatus::Added)
                aggregate = AppendStatus::Added;
        }
        *this = std::move(candidate);
        return { aggregate, std::nullopt };
    }

    auto
    Collection::Size() const noexcept -> std::size_t
    {
        return records_.size();
    }

    auto
    Collection::Empty() const noexcept -> bool
    {
        return records_.empty();
    }

    auto
    Collection::ErrorCount() const noexcept -> std::size_t
    {
        return errorCount_;
    }

    auto
    Collection::WarningCount() const noexcept -> std::size_t
    {
        return warningCount_;
    }

    auto
    Collection::Snapshot() const -> Document
    {
        return Document{ records_ };
    }

    auto
    Collection::Take() -> Document
    {
        Document document{ std::move(records_) };
        records_.clear();
        identities_.clear();
        errorCount_ = 0U;
        warningCount_ = 0U;
        return document;
    }

    void
    Collection::Clear() noexcept
    {
        records_.clear();
        identities_.clear();
        errorCount_ = 0U;
        warningCount_ = 0U;
    }

    auto
    Collection::Identity(const Record &record) const -> EncodeResult
    {
        return Encode(Document{ { record } }, limits_);
    }
} // namespace Progmasoft::Tala::Diagnostic
