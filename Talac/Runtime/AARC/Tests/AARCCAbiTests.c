// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <stddef.h>
#include <stdint.h>

#include "Progmasoft/Tala/Runtime/AARC.h"

_Static_assert(sizeof(((TalaAarcTypeMetadata *)0)->abiVersion) == sizeof(uint32_t), "ABI version must remain 32-bit");
_Static_assert(sizeof(((TalaAarcTypeMetadata *)0)->typeIdentity) == sizeof(uint64_t), "type identity must remain 64-bit");

typedef struct TestPayload
{
    uint64_t marker;
} TestPayload;

static uint32_t gDestructionCount;

static void
DestroyPayload(void *object)
{
    TestPayload *payload = (TestPayload *)object;
    payload->marker = 0U;
    ++gDestructionCount;
}

static const TalaAarcTypeMetadata kPayloadMetadata = {
    TALA_AARC_ABI_VERSION,
    0U,
    UINT64_C(0x51A7E001),
    sizeof(TestPayload),
    _Alignof(TestPayload),
    DestroyPayload,
    "C11.TestPayload",
};

static uint64_t
StringTypeIdentity(void)
{
    static const char kName[] = "String";
    uint64_t identity = UINT64_C(14695981039346656037);
    size_t index;
    for (index = 0U; index < sizeof(kName) - 1U; ++index)
        identity = (identity ^ (uint8_t)kName[index]) * UINT64_C(1099511628211);
    return identity;
}

static int
CheckOpaqueStrongWeakAndUnownedHandles(void)
{
    TestPayload *payload;
    TalaAarcWeakHandle *weak;
    TalaAarcWeakHandle *weakCopy;
    TalaAarcUnownedHandle *unowned;
    TalaAarcUnownedHandle *unownedCopy;
    void *loaded;

    gDestructionCount = 0U;
    payload = (TestPayload *)tala_aarc_allocate(&kPayloadMetadata);
    if (payload == NULL)
        return 1;
    payload->marker = UINT64_C(0xAACC55);
    if (tala_aarc_retain_strong(payload) != payload)
        return 2;
    tala_aarc_release_strong(payload);
    if (gDestructionCount != 0U)
        return 3;

    weak = tala_aarc_make_weak(payload);
    weakCopy = tala_aarc_copy_weak(weak);
    unowned = tala_aarc_make_unowned(payload);
    unownedCopy = tala_aarc_copy_unowned(unowned);
    if (weak == NULL || weakCopy == NULL || unowned == NULL || unownedCopy == NULL)
        return 4;
    loaded = tala_aarc_lock_weak(weak);
    if (loaded != payload)
        return 5;
    tala_aarc_release_strong(loaded);
    loaded = tala_aarc_load_unowned(unowned);
    if (loaded != payload)
        return 6;

    tala_aarc_release_strong(payload);
    if (gDestructionCount != 0U)
        return 7;
    tala_aarc_release_strong(loaded);
    if (gDestructionCount != 1U)
        return 8;
    if (tala_aarc_lock_weak(weak) != NULL || tala_aarc_load_unowned(unowned) != NULL)
        return 9;
    tala_aarc_release_weak(weakCopy);
    tala_aarc_release_weak(weak);
    tala_aarc_release_unowned(unownedCopy);
    tala_aarc_release_unowned(unowned);
    return 0;
}

static int
CheckStringFactoryRejectsInvalidScalars(void)
{
    static const uint32_t kValidScalars[] = { UINT32_C(0x56), UINT32_C(0x1F642) };
    static const uint32_t kSurrogate[] = { UINT32_C(0xD800) };
    static const uint32_t kOutOfRange[] = { UINT32_C(0x110000) };
    void *empty = tala_aarc_string_literal(NULL, 0U);
    void *text = tala_aarc_string_literal(kValidScalars, sizeof(kValidScalars) / sizeof(kValidScalars[0]));

    if (empty == NULL || text == NULL)
        return 10;
    if (!tala_aarc_is_exact_type(text, StringTypeIdentity()))
        return 11;
    tala_aarc_release_strong(text);
    tala_aarc_release_strong(empty);
    if (tala_aarc_string_literal(NULL, 1U) != NULL)
        return 12;
    if (tala_aarc_string_literal(kSurrogate, 1U) != NULL)
        return 13;
    if (tala_aarc_string_literal(kOutOfRange, 1U) != NULL)
        return 14;
    return 0;
}

static int
CheckMetadataValidation(void)
{
    TalaAarcTypeMetadata metadata = kPayloadMetadata;
    void *payload;

    metadata.abiVersion += 1U;
    if (tala_aarc_allocate(&metadata) != NULL)
        return 20;
    metadata = kPayloadMetadata;
    metadata.instanceSize = 0U;
    if (tala_aarc_allocate(&metadata) != NULL)
        return 21;
    metadata = kPayloadMetadata;
    metadata.instanceAlignment = 3U;
    if (tala_aarc_allocate(&metadata) != NULL)
        return 22;
    metadata = kPayloadMetadata;
    metadata.instanceAlignment = 64U;
    payload = tala_aarc_allocate(&metadata);
    if (payload == NULL || (uintptr_t)payload % 64U != 0U)
        return 23;
    tala_aarc_release_strong(payload);
    return 0;
}

int
main(void)
{
    int result;
    if (tala_aarc_abi_version() != TALA_AARC_ABI_VERSION)
        return 100;
    if (tala_aarc_allocate(NULL) != NULL || tala_aarc_retain_strong(NULL) != NULL)
        return 101;
    result = CheckOpaqueStrongWeakAndUnownedHandles();
    if (result != 0)
        return result;
    result = CheckMetadataValidation();
    if (result != 0)
        return result;
    return CheckStringFactoryRejectsInvalidScalars();
}
