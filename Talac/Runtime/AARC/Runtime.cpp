// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <bit>
#include <limits>
#include <new>

#include "Internal.hpp"
#include "Progmasoft/Tala/Runtime/AARC.hpp"

namespace Progmasoft::Tala::Runtime::Aarc
{
    namespace
    {
        struct StringObject final
        {
            std::uint64_t count{};
            char32_t *scalars{};
        };

        void
        DestroyString(void *object) noexcept
        {
            auto *string = static_cast<StringObject *>(object);
            delete[] string->scalars;
            string->scalars = nullptr;
            string->count = 0U;
        }

        const TypeMetadata kStringMetadata{ kAbiVersion,
                                            0U,
                                            TypeIdentity("String"),
                                            sizeof(StringObject),
                                            alignof(StringObject),
                                            DestroyString,
                                            "System.String" };

        [[nodiscard]] auto
        ObjectHeaderOf(const void *object) noexcept -> ObjectHeader *
        {
            return object == nullptr
                       ? nullptr
                       : *(reinterpret_cast<ObjectHeader *const *>(object) - 1);
        }

        [[nodiscard]] auto
        ValidAlignment(std::size_t alignment) noexcept -> bool
        {
            return alignment != 0U && std::has_single_bit(alignment);
        }

        [[nodiscard]] auto
        RetainControl(ObjectHeader *header) noexcept -> bool
        {
            if (header == nullptr)
                return false;
            auto count = header->weakCount.load(std::memory_order_relaxed);
            while (count != 0U
                   && count != std::numeric_limits<std::uint64_t>::max())
                if (header->weakCount.compare_exchange_weak(
                        count,
                        count + 1U,
                        std::memory_order_relaxed,
                        std::memory_order_relaxed))
                    return true;
            return false;
        }

        // Allocations made and not yet reclaimed. The count orders nothing:
        // it is read only where no allocation is in flight.
        // NOLINTNEXTLINE(cppcoreguidelines-avoid-non-const-global-variables)
        std::atomic<std::uint64_t> liveAllocations{ 0U };

        void
        ReleaseControl(ObjectHeader *header) noexcept
        {
            if (header == nullptr
                || header->weakCount.fetch_sub(1U, std::memory_order_acq_rel)
                       != 1U)
                return;
            liveAllocations.fetch_sub(1U, std::memory_order_relaxed);

            // The acquire side of the final decrement observes the destructor
            // and all preceding handle releases before reclaiming the combined
            // allocation.
            auto *allocation = header->allocation;
            header->~ObjectHeader();
            ::operator delete(allocation);
        }

        [[nodiscard]] auto
        TryRetain(ObjectHeader *header) noexcept -> void *
        {
            if (header == nullptr)
                return nullptr;
            auto count = header->strongCount.load(std::memory_order_acquire);
            while (count != 0U)
            {
                if (count == std::numeric_limits<std::uint64_t>::max())
                    return nullptr;
                if (header->strongCount.compare_exchange_weak(
                        count,
                        count + 1U,
                        std::memory_order_acq_rel,
                        std::memory_order_acquire))
                    return header->object.load(std::memory_order_acquire);
            }
            return nullptr;
        }
    } // namespace

    auto
    LiveAllocations() noexcept -> std::uint64_t
    {
        return liveAllocations.load(std::memory_order_relaxed);
    }

    auto
    Allocate(const TypeMetadata &metadata) noexcept -> void *
    {
        if (metadata.abiVersion != kAbiVersion || metadata.instanceSize == 0U
            || !ValidAlignment(metadata.instanceAlignment))
            return nullptr;

        const auto alignment
            = std::max(metadata.instanceAlignment, alignof(ObjectHeader *));
        constexpr auto kPrefix = sizeof(ObjectHeader) + sizeof(ObjectHeader *);
        if (metadata.instanceSize
            > std::numeric_limits<std::size_t>::max() - kPrefix - alignment)
            return nullptr;

        const auto allocationSize
            = kPrefix + alignment - 1U + metadata.instanceSize;
        auto *allocation = static_cast<std::byte *>(
            ::operator new(allocationSize, std::nothrow));
        if (allocation == nullptr)
            return nullptr;

        auto *header = new (allocation) ObjectHeader{};
        header->metadata = &metadata;
        header->allocation = allocation;
        liveAllocations.fetch_add(1U, std::memory_order_relaxed);

        // Advance to the next multiple of the alignment without turning an
        // integer back into a pointer, which would discard provenance.
        auto *payload = allocation + kPrefix;
        const auto misalignment
            = reinterpret_cast<std::uintptr_t>(payload)
              & (static_cast<std::uintptr_t>(alignment) - 1U);
        if (misalignment != 0U)
            payload += alignment - misalignment;
        void *object = payload;
        *(reinterpret_cast<ObjectHeader **>(object) - 1) = header;
        header->object.store(object, std::memory_order_release);
        return object;
    }

    auto
    RetainStrong(void *object) noexcept -> void *
    {
        return TryRetain(ObjectHeaderOf(object));
    }

    void
    ReleaseStrong(void *object) noexcept
    {
        auto *header = ObjectHeaderOf(object);
        if (header == nullptr)
            return;
        if (header->strongCount.load(std::memory_order_relaxed)
            == std::numeric_limits<std::uint64_t>::max())
            return;
        if (header->strongCount.fetch_sub(1U, std::memory_order_acq_rel) != 1U)
            return;

        auto expected = ObjectState::Alive;
        if (header->state.compare_exchange_strong(expected,
                                                  ObjectState::Destroying,
                                                  std::memory_order_acq_rel))
        {
            if (header->metadata->destructor != nullptr)
                header->metadata->destructor(object);
            header->object.store(nullptr, std::memory_order_release);
            header->state.store(ObjectState::Destroyed,
                                std::memory_order_release);
        }
        ReleaseControl(header); // Drop the implicit weak reference.
    }

    auto
    MakeWeak(void *object) noexcept -> Weak
    {
        auto *header = ObjectHeaderOf(object);
        return RetainControl(header) ? Weak{ header } : Weak{};
    }

    auto
    CopyWeak(Weak value) noexcept -> Weak
    {
        return RetainControl(value.header) ? value : Weak{};
    }

    auto
    LockWeak(Weak value) noexcept -> void *
    {
        return TryRetain(value.header);
    }

    void
    ReleaseWeak(Weak value) noexcept
    {
        ReleaseControl(value.header);
    }

    auto
    MakeUnowned(void *object) noexcept -> Unowned
    {
        auto *header = ObjectHeaderOf(object);
        return RetainControl(header) ? Unowned{ header } : Unowned{};
    }

    auto
    CopyUnowned(Unowned value) noexcept -> Unowned
    {
        return RetainControl(value.header) ? value : Unowned{};
    }

    auto
    LoadUnowned(Unowned value) noexcept -> void *
    {
        // Loading upgrades to a temporary strong result. Merely reading object
        // after an Alive check would race the last release on another thread.
        // The generated owner pass balances this result like Weak::Lock.
        return TryRetain(value.header);
    }

    void
    ReleaseUnowned(Unowned value) noexcept
    {
        ReleaseControl(value.header);
    }

    auto
    IsExactType(const void *object, const std::uint64_t typeIdentity) noexcept
        -> bool
    {
        const auto *header = ObjectHeaderOf(object);
        return header != nullptr
               && header->state.load(std::memory_order_acquire)
                      == ObjectState::Alive
               && header->metadata != nullptr
               && header->metadata->typeIdentity == typeIdentity;
    }

    auto
    ViewString(const void *string) noexcept -> StringScalars
    {
        if (!IsExactType(string, kStringMetadata.typeIdentity))
            return {};
        const auto *object = static_cast<const StringObject *>(string);
        return { object->scalars, static_cast<std::size_t>(object->count) };
    }

    auto
    MakeString(const char32_t *scalars, const std::size_t count) noexcept
        -> void *
    {
        return MakeStringFrom(scalars, count);
    }

    // The C side of the ABI spells a scalar `uint32_t` and this side
    // `char32_t`. The two have one representation and are still two types,
    // so the scalars are copied through whichever was given.
    template<typename Scalar>
    auto
    MakeStringFrom(const Scalar *scalars, const std::size_t count) noexcept
        -> void *
    {
        if ((scalars == nullptr && count != 0U)
            || count == std::numeric_limits<std::size_t>::max())
            return nullptr;
        for (std::size_t index = 0; index < count; ++index)
            if (scalars[index] > 0x10ffffU
                || (scalars[index] >= 0xd800U && scalars[index] <= 0xdfffU))
                return nullptr;
        auto *object = static_cast<StringObject *>(Allocate(kStringMetadata));
        if (object == nullptr)
            return nullptr;
        object->scalars = new (std::nothrow) char32_t[count + 1U];
        if (object->scalars == nullptr)
        {
            ReleaseStrong(object);
            return nullptr;
        }
        object->count = count;
        for (std::size_t index = 0; index < count; ++index)
            object->scalars[index] = static_cast<char32_t>(scalars[index]);
        object->scalars[count] = U'\0';
        return object;
    }

    template auto
    MakeStringFrom<char32_t>(const char32_t *, std::size_t) noexcept -> void *;
    template auto
    MakeStringFrom<std::uint32_t>(const std::uint32_t *, std::size_t) noexcept
        -> void *;
} // namespace Progmasoft::Tala::Runtime::Aarc

extern "C"
{
    auto
    tala_aarc_abi_version() noexcept -> std::uint32_t
    {
        return Progmasoft::Tala::Runtime::Aarc::kAbiVersion;
    }

    auto
    tala_aarc_allocate(
        const Progmasoft::Tala::Runtime::Aarc::TypeMetadata *metadata) noexcept
        -> void *
    {
        return metadata == nullptr
                   ? nullptr
                   : Progmasoft::Tala::Runtime::Aarc::Allocate(*metadata);
    }

    auto
    tala_aarc_retain_strong(void *object) noexcept -> void *
    {
        return Progmasoft::Tala::Runtime::Aarc::RetainStrong(object);
    }

    void
    tala_aarc_release_strong(void *object) noexcept
    {
        Progmasoft::Tala::Runtime::Aarc::ReleaseStrong(object);
    }

    auto
    tala_aarc_make_weak(void *object) noexcept -> TalaAarcWeakHandle *
    {
        return reinterpret_cast<TalaAarcWeakHandle *>(
            Progmasoft::Tala::Runtime::Aarc::MakeWeak(object).header);
    }

    auto
    tala_aarc_copy_weak(TalaAarcWeakHandle *handle) noexcept
        -> TalaAarcWeakHandle *
    {
        using Progmasoft::Tala::Runtime::Aarc::ObjectHeader;
        return reinterpret_cast<TalaAarcWeakHandle *>(
            Progmasoft::Tala::Runtime::Aarc::CopyWeak(
                { reinterpret_cast<ObjectHeader *>(handle) })
                .header);
    }

    auto
    tala_aarc_lock_weak(TalaAarcWeakHandle *handle) noexcept -> void *
    {
        return Progmasoft::Tala::Runtime::Aarc::LockWeak(
            { reinterpret_cast<Progmasoft::Tala::Runtime::Aarc::ObjectHeader *>(
                handle) });
    }

    void
    tala_aarc_release_weak(TalaAarcWeakHandle *handle) noexcept
    {
        Progmasoft::Tala::Runtime::Aarc::ReleaseWeak(
            { reinterpret_cast<Progmasoft::Tala::Runtime::Aarc::ObjectHeader *>(
                handle) });
    }

    auto
    tala_aarc_make_unowned(void *object) noexcept -> TalaAarcUnownedHandle *
    {
        return reinterpret_cast<TalaAarcUnownedHandle *>(
            Progmasoft::Tala::Runtime::Aarc::MakeUnowned(object).header);
    }

    auto
    tala_aarc_copy_unowned(TalaAarcUnownedHandle *handle) noexcept
        -> TalaAarcUnownedHandle *
    {
        using Progmasoft::Tala::Runtime::Aarc::ObjectHeader;
        return reinterpret_cast<TalaAarcUnownedHandle *>(
            Progmasoft::Tala::Runtime::Aarc::CopyUnowned(
                { reinterpret_cast<ObjectHeader *>(handle) })
                .header);
    }

    auto
    tala_aarc_load_unowned(TalaAarcUnownedHandle *handle) noexcept -> void *
    {
        return Progmasoft::Tala::Runtime::Aarc::LoadUnowned(
            { reinterpret_cast<Progmasoft::Tala::Runtime::Aarc::ObjectHeader *>(
                handle) });
    }

    void
    tala_aarc_release_unowned(TalaAarcUnownedHandle *handle) noexcept
    {
        Progmasoft::Tala::Runtime::Aarc::ReleaseUnowned(
            { reinterpret_cast<Progmasoft::Tala::Runtime::Aarc::ObjectHeader *>(
                handle) });
    }

    auto
    tala_aarc_string_literal(const std::uint32_t *scalars,
                             std::size_t count) noexcept -> void *
    {
        return Progmasoft::Tala::Runtime::Aarc::MakeStringFrom(scalars, count);
    }

    auto
    tala_aarc_is_exact_type(const void *object,
                            const std::uint64_t typeIdentity) noexcept -> bool
    {
        return Progmasoft::Tala::Runtime::Aarc::IsExactType(object,
                                                            typeIdentity);
    }
}
