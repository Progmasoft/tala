// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>

#include "Progmasoft/Tala/Runtime/AARC.h"

namespace Progmasoft::Tala::Runtime::Aarc
{
    /// C ABI version shared by runtime implementation and clients.
    inline constexpr std::uint32_t kAbiVersion = TALA_AARC_ABI_VERSION;

    /** Hash a canonical, case-sensitive runtime type name into its stable
     * identity. */
    [[nodiscard]] consteval auto
    TypeIdentity(std::string_view canonicalName) noexcept -> std::uint64_t
    {
        std::uint64_t value = 14695981039346656037ULL;
        for (const auto byte : canonicalName)
            value
                = (value ^ static_cast<unsigned char>(byte)) * 1099511628211ULL;
        return value;
    }

    /// Payload destructor callback used by the stable runtime ABI.
    using Destructor = TalaAarcDestructor;
    /// Stable C ABI layout describing an AARC-managed payload type.
    using TypeMetadata = TalaAarcTypeMetadata;

    /// Opaque runtime control block shared by strong, weak, and unowned
    /// handles.
    struct ObjectHeader;

    /// C++ wrapper for one retained weak control-block reference.
    struct Weak final
    {
        /// Opaque block pointer; copy with CopyWeak and release exactly once.
        ObjectHeader *header{};
    };

    /// C++ wrapper for one retained unowned control-block reference.
    struct Unowned final
    {
        /// Opaque block pointer; copy with CopyUnowned and release exactly
        /// once.
        ObjectHeader *header{};
    };

    /** Allocate aligned payload storage and return its initial strong owner. */
    [[nodiscard]] auto
    Allocate(const TypeMetadata &metadata) noexcept -> void *;

    /** Count the allocations whose storage has not been reclaimed.
     *
     * An allocation is reclaimed when its last strong, weak and unowned
     * handle is gone. A program that balances its references returns this
     * count to the value it had before the program ran, which is how tests
     * observe a missing release on every platform. The count is not part of
     * the C ABI.
     */
    [[nodiscard]] auto
    LiveAllocations() noexcept -> std::uint64_t;

    /** Retain the live object, returning null if its strong lifetime has ended.
     */
    auto
    RetainStrong(void *object) noexcept -> void *;

    /** Release one strong owner and run the payload destructor exactly once at
     * zero. */
    void
    ReleaseStrong(void *object) noexcept;

    /** Create one weak control reference without retaining the payload. */
    [[nodiscard]] auto
    MakeWeak(void *object) noexcept -> Weak;

    /** Retain the control reference represented by an existing weak value. */
    [[nodiscard]] auto
    CopyWeak(Weak value) noexcept -> Weak;

    /** Upgrade a live weak target to one strong owner, or return null after
     * destruction. */
    [[nodiscard]] auto
    LockWeak(Weak value) noexcept -> void *;

    /** Release one weak control reference. */
    void
    ReleaseWeak(Weak value) noexcept;

    /** Create one unowned control reference without retaining the payload. */
    [[nodiscard]] auto
    MakeUnowned(void *object) noexcept -> Unowned;

    /** Retain the control reference represented by an existing unowned value.
     */
    [[nodiscard]] auto
    CopyUnowned(Unowned value) noexcept -> Unowned;

    /** Load an unowned target as a temporary strong owner, or return null when
     * dead. */
    [[nodiscard]] auto
    LoadUnowned(Unowned value) noexcept -> void *;

    /** Release one unowned control reference. */
    void
    ReleaseUnowned(Unowned value) noexcept;

    /** Check exact runtime identity for a live payload; null never matches. */
    [[nodiscard]] auto
    IsExactType(const void *object, std::uint64_t typeIdentity) noexcept
        -> bool;

    /** The scalars of a string object, borrowed for as long as the string
     * is alive. */
    struct StringScalars final
    {
        /** The first scalar, or null for the empty string. */
        const char32_t *scalars{};
        /** How many scalars the string holds. */
        std::size_t count{};
    };

    /** Read the scalars of a live `System.String`.
     *
     * A null reference, and an object that is not a string, read as the
     * empty string: the text routines of the runtime treat a string that is
     * not there as one without characters.
     */
    [[nodiscard]] auto
    ViewString(const void *string) noexcept -> StringScalars;

    /** Create a `System.String` that holds a copy of the given scalars and
     * return its initial strong owner, or null when the scalars are not
     * Unicode scalar values or memory is exhausted. */
    [[nodiscard]] auto
    MakeString(const char32_t *scalars, std::size_t count) noexcept -> void *;
} // namespace Progmasoft::Tala::Runtime::Aarc
