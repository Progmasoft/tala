// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstddef>
#include <llvm/ADT/BitVector.h>
#include <llvm/Support/Error.h>
#include <vector>

namespace Progmasoft::Tala::Analysis
{
    /// Bounds-safe dense set used by finite compiler dataflow universes.
    /// LLVM supplies the packed storage and bit iteration; this wrapper makes
    /// out-of-range queries false and mutations no-ops, while set algebra
    /// requires equal-sized universes.
    class DenseBitSet final
    {
    public:
        /// Construct an empty set with a zero-bit universe.
        DenseBitSet() = default;
        /// Construct a set with every bit initialized to the requested value.
        /// @param bitCount Number of valid bit indices in the universe.
        /// @param value Initial state assigned to every bit.
        explicit DenseBitSet(std::size_t bitCount, bool value = false);

        /// Validate an externally supplied universe before allocating storage.
        /// @param bitCount Number of valid bit indices in the universe.
        /// @param value Initial state assigned to every bit.
        /// @return A set, or an error when LLVM cannot represent the size.
        [[nodiscard]] static auto
        Create(std::size_t bitCount, bool value = false)
            -> llvm::Expected<DenseBitSet>;

        /// Return the number of bit positions in the universe.
        /// @return The fixed universe size.
        [[nodiscard]] auto
        Size() const noexcept -> std::size_t;

        /// Test whether the universe contains no bit positions.
        /// @return true when the universe size is zero.
        [[nodiscard]] auto
        Empty() const noexcept -> bool;

        /// Test whether no bit in the set is present.
        /// @return true when the set has zero members.
        [[nodiscard]] auto
        None() const noexcept -> bool;

        /// Test whether at least one bit in the set is present.
        /// @return true when the set has at least one member.
        [[nodiscard]] auto
        Any() const noexcept -> bool;

        /// Count the set bits in the universe.
        /// @return Number of set bits.
        [[nodiscard]] auto
        Count() const noexcept -> std::size_t;

        /// Query one bit; an index outside the universe is treated as clear.
        /// @param index Bit index to inspect.
        /// @return Whether the requested in-range bit is set.
        [[nodiscard]] auto
        Test(std::size_t index) const noexcept -> bool;

        /// Set one in-range bit; an out-of-range index is ignored.
        /// @param index Bit index to set.
        void
        Set(std::size_t index) noexcept;

        /// Clear one in-range bit; an out-of-range index is ignored.
        /// @param index Bit index to clear.
        void
        Reset(std::size_t index) noexcept;

        /// Assign one in-range bit; an out-of-range index is ignored.
        /// @param index Bit index to update.
        /// @param value New bit value.
        void
        Assign(std::size_t index, bool value) noexcept;

        /// Clear all bits without changing the universe size.
        void
        Clear() noexcept;

        /// Set all bits in the universe.
        void
        Fill() noexcept;

        /// Add every bit set in another equal-sized set.
        /// @param other Set whose bits are unioned into this set.
        /// @return Success, or an error without mutation for unequal sizes.
        [[nodiscard]] auto
        UnionWith(const DenseBitSet &other) -> llvm::Error;

        /// Retain only bits also present in another equal-sized set.
        /// @param other Set whose bits form the intersection mask.
        /// @return Success, or an error without mutation for unequal sizes.
        [[nodiscard]] auto
        IntersectWith(const DenseBitSet &other) -> llvm::Error;

        /// Remove bits present in another equal-sized set.
        /// @param other Set whose bits are subtracted from this set.
        /// @return Success, or an error without mutation for unequal sizes.
        [[nodiscard]] auto
        Subtract(const DenseBitSet &other) -> llvm::Error;

        /// Return set-bit indices in ascending order.
        /// @return Vector containing every set index exactly once.
        [[nodiscard]] auto
        SetIndices() const -> std::vector<std::size_t>;

        /// Compare universe size and all bit values.
        /// @return true when both sets denote the same finite set.
        [[nodiscard]] auto
        operator==(const DenseBitSet &) const -> bool = default;

    private:
        [[nodiscard]] auto
        Compatible(const DenseBitSet &other) const noexcept -> bool;

        // LLVM owns word packing, popcount and set-bit iteration. The wrapper
        // keeps Tala's bounds-safe and equal-universe semantics stable for
        // dataflow clients instead of exposing BitVector's assertion surface.
        llvm::BitVector bits_;
    };
} // namespace Progmasoft::Tala::Analysis
