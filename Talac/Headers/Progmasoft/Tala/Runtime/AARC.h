// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#ifndef TALA_RUNTIME_AARC_H
#define TALA_RUNTIME_AARC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define TALA_AARC_ABI_VERSION UINT32_C(2)

#ifdef __cplusplus
#    define TALA_AARC_NOEXCEPT noexcept
extern "C"
{
#else
#    define TALA_AARC_NOEXCEPT
#endif

    /** Destructor callbacks must not throw and must release only payload-owned
     * resources. */
    typedef void (*TalaAarcDestructor)(void *object);

    /** Opaque control-block handles; callers must never inspect or free them
     * directly. */
    typedef struct TalaAarcWeakHandle TalaAarcWeakHandle;
    typedef struct TalaAarcUnownedHandle TalaAarcUnownedHandle;

    /** Stable metadata layout shared by C11 callers and the C++20 runtime
     * implementation. */
    typedef struct TalaAarcTypeMetadata
    {
        uint32_t abiVersion; /**< Must equal TALA_AARC_ABI_VERSION. */
        uint32_t flags; /**< Reserved layout flags; pass zero unless defined by
                           this ABI. */
        uint64_t typeIdentity; /**< Stable identity used for exact runtime type
                                  tests. */
        size_t instanceSize;   /**< Payload size in bytes, excluding the control
                                  header. */
        size_t instanceAlignment; /**< Required power-of-two alignment of the
                                     payload. */
        TalaAarcDestructor destructor; /**< Runs exactly once after the final
                                         strong release. */
        const char *typeName; /**< NUL-terminated diagnostic name valid for
                                 metadata lifetime. */
    } TalaAarcTypeMetadata;

    /** Return the ABI version implemented by this runtime binary. */
    uint32_t
    tala_aarc_abi_version(void) TALA_AARC_NOEXCEPT;

    /** Allocate a payload with one strong owner; metadata must outlive every
     * allocated value. */
    void *
    tala_aarc_allocate(const TalaAarcTypeMetadata *metadata) TALA_AARC_NOEXCEPT;

    /** Retain a live object, returning null if the object is no longer
     * retainable. */
    void *
    tala_aarc_retain_strong(void *object) TALA_AARC_NOEXCEPT;

    /** Release one strong owner and destroy the payload after the final
     * release. */
    void
    tala_aarc_release_strong(void *object) TALA_AARC_NOEXCEPT;

    /** Create or copy an opaque weak handle; release each successful handle
     * exactly once. */
    TalaAarcWeakHandle *
    tala_aarc_make_weak(void *object) TALA_AARC_NOEXCEPT;
    TalaAarcWeakHandle *
    tala_aarc_copy_weak(TalaAarcWeakHandle *weakHandle) TALA_AARC_NOEXCEPT;
    void *
    tala_aarc_lock_weak(TalaAarcWeakHandle *weakHandle) TALA_AARC_NOEXCEPT;
    void
    tala_aarc_release_weak(TalaAarcWeakHandle *weakHandle) TALA_AARC_NOEXCEPT;

    /** Create or copy an opaque unowned handle; load upgrades it to a temporary
     * strong owner. */
    TalaAarcUnownedHandle *
    tala_aarc_make_unowned(void *object) TALA_AARC_NOEXCEPT;
    TalaAarcUnownedHandle *
    tala_aarc_copy_unowned(TalaAarcUnownedHandle *unownedHandle)
        TALA_AARC_NOEXCEPT;
    void *
    tala_aarc_load_unowned(TalaAarcUnownedHandle *unownedHandle)
        TALA_AARC_NOEXCEPT;
    void
    tala_aarc_release_unowned(TalaAarcUnownedHandle *unownedHandle)
        TALA_AARC_NOEXCEPT;

    /** Create an immutable UTF-32 scalar string; reject null input, surrogates,
     * and out-of-range values. */
    void *
    tala_aarc_string_literal(const uint32_t *scalars,
                             size_t count) TALA_AARC_NOEXCEPT;

    /** Compare the exact registered runtime identity without accepting
     * null/destroyed objects. */
    bool
    tala_aarc_is_exact_type(const void *object,
                            uint64_t typeIdentity) TALA_AARC_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#undef TALA_AARC_NOEXCEPT
#endif
