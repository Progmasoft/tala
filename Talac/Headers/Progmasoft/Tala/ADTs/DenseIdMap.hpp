// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <concepts>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <llvm/ADT/DenseMap.h>
#include <llvm/ADT/Hashing.h>
#include <llvm/Support/ErrorHandling.h>
#include <utility>

namespace Progmasoft::Tala::ADTs
{
    /// LLVM DenseMap wrapper that stores every unsigned identifier value.
    ///
    /// LLVM's integral key traits reserve two integer sentinels. The tagged
    /// internal key keeps those states separate from compiler IDs, preserving
    /// the full unsigned domain including zero and the maximum values.
    /// @tparam Id Unsigned identifier type used as the map key.
    /// @tparam Value Stored mapped-value type.
    template<std::unsigned_integral Id, typename Value>
    class DenseIdMap final
    {
        enum class Slot : std::uint8_t
        {
            Normal,
            Empty,
            Tombstone
        };

        struct Key final
        {
            Id value{};
            Slot slot{ Slot::Normal };

            [[nodiscard]] static auto
            Normal(const Id value) noexcept -> Key
            {
                return { value, Slot::Normal };
            }

            [[nodiscard]] auto
            operator==(const Key &other) const noexcept -> bool
            {
                return slot == other.slot
                       && (slot != Slot::Normal || value == other.value);
            }
        };

        struct KeyInfo final
        {
            [[nodiscard]] static auto
            getEmptyKey() noexcept -> Key
            {
                return { Id{}, Slot::Empty };
            }

            [[nodiscard]] static auto
            getTombstoneKey() noexcept -> Key
            {
                return { Id{}, Slot::Tombstone };
            }

            [[nodiscard]] static auto
            getHashValue(const Key &key) noexcept -> unsigned
            {
                return static_cast<unsigned>(llvm::hash_value(key.value));
            }

            [[nodiscard]] static auto
            isEqual(const Key &left, const Key &right) noexcept -> bool
            {
                return left == right;
            }
        };

        using Storage = llvm::DenseMap<Key, Value, KeyInfo>;

    public:
        /// Value pointer and insertion status returned by TryEmplace.
        struct InsertResult final
        {
            /// Pointer to the stored value, whether it was new or pre-existing.
            Value *value{};
            /// Whether TryEmplace created a new entry.
            bool inserted{};
        };

        /// Check whether the map contains no entries.
        /// @return true when the map is empty.
        [[nodiscard]] auto
        Empty() const noexcept -> bool
        {
            return values_.empty();
        }

        /// Report the number of stored identifier/value pairs.
        /// @return Current number of entries.
        [[nodiscard]] auto
        Size() const noexcept -> std::size_t
        {
            return values_.size();
        }

        /// Ensure storage capacity for at least count entries.
        /// @param count Minimum capacity requested.
        void
        Reserve(const std::size_t count)
        {
            // Reserve remains the programmer-contract API; untrusted sizes
            // use TryReserve so rejecting a limit never needs an exception.
            if (!TryReserve(count))
                llvm::report_fatal_error(
                    "DenseIdMap reserve exceeds its index domain");
        }

        /// Reserve capacity only if LLVM's bucket domain can represent it.
        /// @param count Requested minimum capacity.
        /// @return false before mutation/allocation for an excessive count.
        [[nodiscard]] auto
        TryReserve(const std::size_t count) -> bool
        {
            // DenseMap's bucket arithmetic uses a narrower unsigned count.
            // Leave headroom for its load factor/power-of-two growth instead
            // of truncating a caller's size_t or overflowing bucket arithmetic.
            constexpr auto kMaximumEntries
                = static_cast<std::size_t>(std::numeric_limits<unsigned>::max())
                  / 4U;
            if (count > kMaximumEntries)
                return false;
            values_.reserve(static_cast<unsigned>(count));
            return true;
        }

        /// Test whether an identifier is present.
        /// @param id Identifier to search for.
        /// @return true when id has a mapped value.
        [[nodiscard]] auto
        Contains(const Id id) const -> bool
        {
            return values_.contains(Key::Normal(id));
        }

        /// Find a mutable mapped value by identifier.
        /// @param id Identifier to search for.
        /// @return Pointer to the value, or null when id is absent.
        [[nodiscard]] auto
        Find(const Id id) -> Value *
        {
            const auto found = values_.find(Key::Normal(id));
            return found == values_.end() ? nullptr : &found->second;
        }

        /// Find a read-only mapped value by identifier.
        /// @param id Identifier to search for.
        /// @return Pointer to the value, or null when id is absent.
        [[nodiscard]] auto
        Find(const Id id) const -> const Value *
        {
            const auto found = values_.find(Key::Normal(id));
            return found == values_.end() ? nullptr : &found->second;
        }

        /// Insert a value only when the identifier is currently absent.
        /// @tparam Arguments Constructor-argument types forwarded to Value.
        /// @param id Identifier to insert.
        /// @param arguments Arguments used to construct Value in-place.
        /// @return Pointer to the stored value and whether insertion occurred.
        template<typename... Arguments>
        auto
        TryEmplace(const Id id, Arguments &&...arguments) -> InsertResult
        {
            auto [found, inserted]
                = values_.try_emplace(Key::Normal(id),
                                      std::forward<Arguments>(arguments)...);
            return { &found->second, inserted };
        }

        /// Insert a mapping or replace its existing value.
        /// @param id Identifier whose mapping is updated.
        /// @param value New value to store.
        void
        InsertOrAssign(const Id id, Value value)
        {
            if (auto *stored = Find(id))
            {
                *stored = std::move(value);
                return;
            }
            static_cast<void>(TryEmplace(id, std::move(value)));
        }

        /// Visit each mapping with mutable access to its value.
        /// @tparam Visitor Callable accepting (Id, Value&).
        /// @param visitor Callback invoked once for each mapping.
        template<typename Visitor>
        void
        ForEach(Visitor &&visitor)
        {
            for (auto &[key, value] : values_)
                visitor(key.value, value);
        }

        /// Visit each mapping through const access to its value.
        /// @tparam Visitor Callable accepting (Id, const Value&).
        /// @param visitor Callback invoked once for each mapping.
        template<typename Visitor>
        void
        ForEach(Visitor &&visitor) const
        {
            for (const auto &[key, value] : values_)
                visitor(key.value, value);
        }

    private:
        Storage values_;
    };

    /// Dense identifier set preserving the full unsigned identifier domain.
    /// @tparam Id Unsigned identifier type stored in the set.
    template<std::unsigned_integral Id>
    class DenseIdSet final
    {
    public:
        /// Check whether the set contains no identifiers.
        /// @return true when the set is empty.
        [[nodiscard]] auto
        Empty() const noexcept -> bool
        {
            return values_.Empty();
        }

        /// Report the number of distinct identifiers stored.
        /// @return Current number of identifiers.
        [[nodiscard]] auto
        Size() const noexcept -> std::size_t
        {
            return values_.Size();
        }

        /// Ensure storage capacity for at least count identifiers.
        /// @param count Minimum capacity requested.
        void
        Reserve(const std::size_t count)
        {
            values_.Reserve(count);
        }

        /// Test whether an identifier is present.
        /// @param id Identifier to search for.
        /// @return true when id is in the set.
        [[nodiscard]] auto
        Contains(const Id id) const -> bool
        {
            return values_.Contains(id);
        }

        /// Add an identifier if it is not already present.
        /// @param id Identifier to insert.
        /// @return true only when a new identifier was added.
        [[nodiscard]] auto
        Insert(const Id id) -> bool
        {
            return values_.TryEmplace(id, std::uint8_t{}).inserted;
        }

        /// Visit each distinct identifier in the set.
        /// @tparam Visitor Callable accepting an Id value.
        /// @param visitor Callback invoked once for each identifier.
        template<typename Visitor>
        void
        ForEach(Visitor &&visitor) const
        {
            values_.ForEach([&visitor](const Id id, const std::uint8_t) {
                visitor(id);
            });
        }

    private:
        DenseIdMap<Id, std::uint8_t> values_;
    };
} // namespace Progmasoft::Tala::ADTs
