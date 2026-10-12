// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <array>
#include <atomic>
#include <cstdint>
#include <thread>
#include <vector>

#include "Progmasoft/Tala/Core/Ownership.hpp"
#include "Progmasoft/Tala/Runtime/AARC.hpp"

namespace
{
    namespace Aarc = Progmasoft::Tala::Runtime::Aarc;
    namespace Core = tala::core;

    struct Payload final
    {
        std::uint64_t marker{};
    };

    std::atomic_uint32_t destructions{};

    void
    DestroyPayload(void *value) noexcept
    {
        auto *payload = static_cast<Payload *>(value);
        payload->marker = 0U;
        destructions.fetch_add(1U, std::memory_order_relaxed);
    }

    const Aarc::TypeMetadata kMetadata{ Aarc::kAbiVersion,
                                        0U,
                                        Aarc::TypeIdentity("Tests.Payload"),
                                        sizeof(Payload),
                                        alignof(Payload),
                                        DestroyPayload,
                                        "Tests.Payload" };
} // namespace

TEST_CASE("type storage classes follow the language declaration families")
{
    CHECK(Core::ClassifyType(Core::Type::int64())
          == Core::StorageClass::TrivialValue);
    CHECK(Core::ClassifyType(Core::Type::string())
          == Core::StorageClass::AarcReference);
    CHECK(Core::ClassifyType(Core::Type::function({}, Core::Type::unit()))
          == Core::StorageClass::AarcReference);
    CHECK(Core::ClassifyNominal(Core::NominalKind::Data)
          == Core::StorageClass::CopyOnWriteValue);
    CHECK(Core::ClassifyNominal(Core::NominalKind::Type)
          == Core::StorageClass::CopyOnWriteValue);
    CHECK(Core::ClassifyNominal(Core::NominalKind::ClassicEnum)
          == Core::StorageClass::CopyOnWriteValue);
    CHECK(Core::ClassifyNominal(Core::NominalKind::Class)
          == Core::StorageClass::AarcReference);
    CHECK(Core::ClassifyNominal(Core::NominalKind::DataClass)
          == Core::StorageClass::AarcReference);
    CHECK(Core::ClassifyNominal(Core::NominalKind::EnumClass)
          == Core::StorageClass::AarcReference);
    CHECK(Core::ClassifyNominal(Core::NominalKind::Object)
          == Core::StorageClass::AarcReference);
    CHECK(Core::ClassifyNominal(Core::NominalKind::Interface)
          == Core::StorageClass::AarcReference);
    CHECK(Core::ClassifyType(Core::Type::named({ U"Unknown" }))
          == Core::StorageClass::Unresolved);
}

TEST_CASE("constructed value types inherit reference classification from every "
          "nested type argument")
{
    Core::NominalTypeCatalog catalog;
    REQUIRE(catalog.Register({ U"ValueCell" }, Core::NominalKind::Data));
    REQUIRE(catalog.Register({ U"ReferenceCell" }, Core::NominalKind::Class));

    const auto scalar
        = Core::Type::named({ U"ValueCell" }, { Core::Type::int64() });
    const auto allValues = Core::Type::named({ U"ValueCell" }, { scalar });
    const auto directReference
        = Core::Type::named({ U"ValueCell" }, { Core::Type::string() });
    const auto nestedReference
        = Core::Type::named({ U"ValueCell" }, { directReference });
    const auto deepReference = Core::Type::named(
        { U"ValueCell" },
        { Core::Type::named({ U"ValueCell" }, { nestedReference }) });
    const auto nominalReference
        = Core::Type::named({ U"ReferenceCell" }, { Core::Type::int64() });
    const auto containedReference
        = Core::Type::named({ U"ValueCell" }, { nominalReference });

    CHECK(Core::ClassifyType(scalar, catalog)
          == Core::StorageClass::CopyOnWriteValue);
    CHECK(Core::ClassifyType(allValues, catalog)
          == Core::StorageClass::CopyOnWriteValue);
    CHECK(Core::ClassifyType(directReference, catalog)
          == Core::StorageClass::AarcReference);
    CHECK(Core::ClassifyType(nestedReference, catalog)
          == Core::StorageClass::AarcReference);
    CHECK(Core::ClassifyType(deepReference, catalog)
          == Core::StorageClass::AarcReference);
    CHECK(Core::ClassifyType(nominalReference, catalog)
          == Core::StorageClass::AarcReference);
    CHECK(Core::ClassifyType(containedReference, catalog)
          == Core::StorageClass::AarcReference);
    CHECK(Core::UsesCopyOnWrite(allValues, catalog));
    CHECK(Core::UsesAarc(containedReference, catalog));
}

TEST_CASE("constructed type classification preserves unresolved and non-type "
          "argument boundaries")
{
    Core::NominalTypeCatalog catalog;
    REQUIRE(catalog.Register({ U"Buffer" }, Core::NominalKind::Data));
    REQUIRE(catalog.Register({ U"ReferenceCell" }, Core::NominalKind::Class));

    const auto valueArgument = Core::TemplateArgument::value_argument(
        Core::TemplateValue::boolean_value(true));
    const auto concreteBuffer = Core::Type::named_template(
        { U"Buffer" },
        { Core::TemplateArgument::type_argument(Core::Type::int64()),
          valueArgument });
    const auto openBuffer
        = Core::Type::named({ U"Buffer" },
                            { Core::Type::type_variable({ 91U, U"T" }) });
    const auto missingDeclaration
        = Core::Type::named({ U"Missing" }, { Core::Type::int64() });
    const auto referenceWithOpenArgument
        = Core::Type::named({ U"ReferenceCell" },
                            { Core::Type::type_variable({ 92U, U"U" }) });
    const auto malformedBuffer
        = Core::Type::named_template({ U"Buffer" },
                                     { Core::TemplateArgument{} });
    const auto unresolvedThenReference = Core::Type::named(
        { U"Buffer" },
        { Core::Type::type_variable({ 93U, U"V" }), Core::Type::string() });
    const auto referenceThenUnresolved = Core::Type::named(
        { U"Buffer" },
        { Core::Type::string(), Core::Type::type_variable({ 94U, U"W" }) });

    CHECK(Core::ClassifyType(concreteBuffer, catalog)
          == Core::StorageClass::CopyOnWriteValue);
    CHECK(Core::ClassifyType(openBuffer, catalog)
          == Core::StorageClass::Unresolved);
    CHECK(Core::ClassifyType(missingDeclaration, catalog)
          == Core::StorageClass::Unresolved);
    CHECK(Core::ClassifyType(referenceWithOpenArgument, catalog)
          == Core::StorageClass::AarcReference);
    CHECK(Core::ClassifyType(malformedBuffer, catalog)
          == Core::StorageClass::Unresolved);
    CHECK(Core::ClassifyType(unresolvedThenReference, catalog)
          == Core::StorageClass::AarcReference);
    CHECK(Core::ClassifyType(referenceThenUnresolved, catalog)
          == Core::StorageClass::AarcReference);
}

TEST_CASE("nominal type catalog rejects ambiguous declarations and compares "
          "qualified names case-sensitively")
{
    Core::NominalTypeCatalog catalog;
    CHECK(catalog.Empty());
    CHECK_FALSE(catalog.Register({}, Core::NominalKind::Data));
    CHECK_FALSE(catalog.Register({ U"Example", U"" }, Core::NominalKind::Data));
    REQUIRE(
        catalog.Register({ U"Example", U"Value" }, Core::NominalKind::Data));
    CHECK_FALSE(
        catalog.Register({ U"Example", U"Value" }, Core::NominalKind::Class));
    REQUIRE(
        catalog.Register({ U"Example", U"value" }, Core::NominalKind::Class));

    CHECK(catalog.Size() == 2U);
    CHECK(catalog.Lookup(std::array{ std::u32string(U"Example"),
                                     std::u32string(U"Value") })
          == Core::NominalKind::Data);
    CHECK(catalog.Lookup(std::array{ std::u32string(U"Example"),
                                     std::u32string(U"value") })
          == Core::NominalKind::Class);
    CHECK_FALSE(catalog
                    .Lookup(std::array{ std::u32string(U"example"),
                                        std::u32string(U"Value") })
                    .has_value());
}

TEST_CASE("strong references destroy the payload exactly once")
{
    destructions.store(0U);
    auto *payload = static_cast<Payload *>(Aarc::Allocate(kMetadata));
    REQUIRE(payload != nullptr);
    payload->marker = 0xAACC55U;

    CHECK(Aarc::RetainStrong(payload) == payload);
    Aarc::ReleaseStrong(payload);
    CHECK(destructions.load() == 0U);
    Aarc::ReleaseStrong(payload);
    CHECK(destructions.load() == 1U);
}

TEST_CASE("the live allocation count follows storage, not strong lifetime")
{
    const auto before = Aarc::LiveAllocations();
    auto *first = static_cast<Payload *>(Aarc::Allocate(kMetadata));
    auto *second = static_cast<Payload *>(Aarc::Allocate(kMetadata));
    REQUIRE(first != nullptr);
    REQUIRE(second != nullptr);
    CHECK(Aarc::LiveAllocations() == before + 2U);

    // A retained object stays one allocation.
    CHECK(Aarc::RetainStrong(first) == first);
    CHECK(Aarc::LiveAllocations() == before + 2U);
    Aarc::ReleaseStrong(first);
    CHECK(Aarc::LiveAllocations() == before + 2U);
    Aarc::ReleaseStrong(first);
    CHECK(Aarc::LiveAllocations() == before + 1U);

    // A weak handle keeps the storage after the payload is destroyed.
    const auto weak = Aarc::MakeWeak(second);
    Aarc::ReleaseStrong(second);
    CHECK(Aarc::LiveAllocations() == before + 1U);
    Aarc::ReleaseWeak(weak);
    CHECK(Aarc::LiveAllocations() == before);

    // A failed allocation and a null release count nothing.
    auto invalid = kMetadata;
    invalid.instanceSize = 0U;
    CHECK(Aarc::Allocate(invalid) == nullptr);
    Aarc::ReleaseStrong(nullptr);
    CHECK(Aarc::LiveAllocations() == before);
}

TEST_CASE("exact type tests use stable metadata identity and reject null")
{
    auto *payload = static_cast<Payload *>(Aarc::Allocate(kMetadata));
    REQUIRE(payload != nullptr);

    CHECK(Aarc::IsExactType(payload, kMetadata.typeIdentity));
    CHECK(tala_aarc_is_exact_type(payload, kMetadata.typeIdentity));
    CHECK_FALSE(
        Aarc::IsExactType(payload, Aarc::TypeIdentity("Tests.OtherPayload")));
    CHECK_FALSE(
        Aarc::IsExactType(payload, Aarc::TypeIdentity("tests.payload")));
    CHECK_FALSE(Aarc::IsExactType(nullptr, kMetadata.typeIdentity));
    Aarc::ReleaseStrong(payload);
}

TEST_CASE("allocation validates ABI version size and alignment")
{
    auto metadata = kMetadata;
    metadata.abiVersion = Aarc::kAbiVersion + 1U;
    CHECK(Aarc::Allocate(metadata) == nullptr);
    metadata = kMetadata;
    metadata.instanceSize = 0U;
    CHECK(Aarc::Allocate(metadata) == nullptr);
    metadata = kMetadata;
    metadata.instanceAlignment = 3U;
    CHECK(Aarc::Allocate(metadata) == nullptr);

    metadata = kMetadata;
    metadata.instanceAlignment = 64U;
    auto *payload = Aarc::Allocate(metadata);
    REQUIRE(payload != nullptr);
    CHECK(reinterpret_cast<std::uintptr_t>(payload) % 64U == 0U);
    Aarc::ReleaseStrong(payload);
}

TEST_CASE("weak lock retains a live object and expires after destruction")
{
    destructions.store(0U);
    auto *payload = static_cast<Payload *>(Aarc::Allocate(kMetadata));
    REQUIRE(payload != nullptr);
    const auto weak = Aarc::MakeWeak(payload);
    REQUIRE(weak.header != nullptr);
    const auto copied = Aarc::CopyWeak(weak);
    CHECK(copied.header == weak.header);

    auto *locked = Aarc::LockWeak(weak);
    REQUIRE(locked == payload);
    Aarc::ReleaseStrong(locked);
    Aarc::ReleaseStrong(payload);
    CHECK(destructions.load() == 1U);
    CHECK(Aarc::LockWeak(weak) == nullptr);
    Aarc::ReleaseWeak(copied);
    Aarc::ReleaseWeak(weak);
}

TEST_CASE("unowned handles retain only the control header")
{
    destructions.store(0U);
    auto *payload = static_cast<Payload *>(Aarc::Allocate(kMetadata));
    REQUIRE(payload != nullptr);
    const auto unowned = Aarc::MakeUnowned(payload);
    const auto copied = Aarc::CopyUnowned(unowned);
    CHECK(copied.header == unowned.header);
    auto *loaded = Aarc::LoadUnowned(unowned);
    REQUIRE(loaded == payload);
    Aarc::ReleaseStrong(loaded);

    Aarc::ReleaseStrong(payload);
    CHECK(destructions.load() == 1U);
    CHECK(Aarc::LoadUnowned(unowned) == nullptr);
    Aarc::ReleaseUnowned(copied);
    Aarc::ReleaseUnowned(unowned);
}

TEST_CASE("empty control handles and null object operations are inert")
{
    CHECK(Aarc::RetainStrong(nullptr) == nullptr);
    Aarc::ReleaseStrong(nullptr);
    CHECK_FALSE(Aarc::IsExactType(nullptr, kMetadata.typeIdentity));

    const auto emptyWeak = Aarc::MakeWeak(nullptr);
    CHECK(emptyWeak.header == nullptr);
    CHECK(Aarc::CopyWeak(emptyWeak).header == nullptr);
    CHECK(Aarc::LockWeak(emptyWeak) == nullptr);
    Aarc::ReleaseWeak(emptyWeak);

    const auto emptyUnowned = Aarc::MakeUnowned(nullptr);
    CHECK(emptyUnowned.header == nullptr);
    CHECK(Aarc::CopyUnowned(emptyUnowned).header == nullptr);
    CHECK(Aarc::LoadUnowned(emptyUnowned) == nullptr);
    Aarc::ReleaseUnowned(emptyUnowned);
}

TEST_CASE("control-handle copies outlive their source handles independently")
{
    destructions.store(0U);
    auto *payload = static_cast<Payload *>(Aarc::Allocate(kMetadata));
    REQUIRE(payload != nullptr);

    const auto weakSource = Aarc::MakeWeak(payload);
    const auto weakCopy = Aarc::CopyWeak(weakSource);
    REQUIRE(weakSource.header != nullptr);
    REQUIRE(weakCopy.header == weakSource.header);
    Aarc::ReleaseWeak(weakSource);
    auto *weakLoaded = Aarc::LockWeak(weakCopy);
    REQUIRE(weakLoaded == payload);
    Aarc::ReleaseStrong(weakLoaded);

    const auto unownedSource = Aarc::MakeUnowned(payload);
    const auto unownedCopy = Aarc::CopyUnowned(unownedSource);
    REQUIRE(unownedSource.header != nullptr);
    REQUIRE(unownedCopy.header == unownedSource.header);
    Aarc::ReleaseUnowned(unownedSource);
    auto *loaded = Aarc::LoadUnowned(unownedCopy);
    REQUIRE(loaded == payload);
    Aarc::ReleaseStrong(loaded);

    Aarc::ReleaseStrong(payload);
    CHECK(destructions.load() == 1U);
    CHECK(Aarc::LockWeak(weakCopy) == nullptr);
    CHECK(Aarc::LoadUnowned(unownedCopy) == nullptr);
    Aarc::ReleaseWeak(weakCopy);
    Aarc::ReleaseUnowned(unownedCopy);
}

TEST_CASE(
    "weak upgrades racing the last owner never resurrect a destroyed object",
    "[aarc][concurrency]")
{
    destructions.store(0U);
    auto *payload = static_cast<Payload *>(Aarc::Allocate(kMetadata));
    REQUIRE(payload != nullptr);
    const auto weak = Aarc::MakeWeak(payload);
    REQUIRE(weak.header != nullptr);

    constexpr std::size_t kThreadCount = 6U;
    constexpr std::size_t kAttemptsPerThread = 1500U;
    std::atomic_size_t ready{};
    std::atomic_bool start{};
    std::atomic_bool raceStart{};
    std::atomic_bool failedToUpgradeLiveObject{};
    std::atomic_size_t primed{};
    std::vector<std::thread> workers;
    workers.reserve(kThreadCount);
    for (std::size_t worker = 0U; worker < kThreadCount; ++worker)
    {
        workers.emplace_back([weak,
                              &ready,
                              &start,
                              &raceStart,
                              &failedToUpgradeLiveObject,
                              &primed] {
            ready.fetch_add(1U, std::memory_order_release);
            while (!start.load(std::memory_order_acquire))
                std::this_thread::yield();

            // Prove that every worker can upgrade the same control handle while
            // the original strong owner is known to remain live.
            auto *live = Aarc::LockWeak(weak);
            if (live == nullptr)
                failedToUpgradeLiveObject.store(true,
                                                std::memory_order_relaxed);
            else
                Aarc::ReleaseStrong(live);
            primed.fetch_add(1U, std::memory_order_release);
            while (!raceStart.load(std::memory_order_acquire))
                std::this_thread::yield();

            for (std::size_t attempt = 0U; attempt < kAttemptsPerThread;
                 ++attempt)
            {
                auto *locked = Aarc::LockWeak(weak);
                if (locked == nullptr)
                    continue;
                Aarc::ReleaseStrong(locked);
            }
        });
    }

    while (ready.load(std::memory_order_acquire) != kThreadCount)
        std::this_thread::yield();
    start.store(true, std::memory_order_release);
    while (primed.load(std::memory_order_acquire) != kThreadCount)
        std::this_thread::yield();
    CHECK_FALSE(failedToUpgradeLiveObject.load(std::memory_order_relaxed));
    raceStart.store(true, std::memory_order_release);
    Aarc::ReleaseStrong(payload);
    for (auto &worker : workers)
        worker.join();

    CHECK(destructions.load() == 1U);
    CHECK(Aarc::LockWeak(weak) == nullptr);
    Aarc::ReleaseWeak(weak);
}

TEST_CASE("concurrent strong retain and release preserves one owner")
{
    destructions.store(0U);
    auto *payload = static_cast<Payload *>(Aarc::Allocate(kMetadata));
    REQUIRE(payload != nullptr);

    constexpr std::size_t kThreadCount = 8U;
    constexpr std::size_t kIterations = 2000U;
    std::atomic_bool retainedEveryTime{ true };
    std::vector<std::thread> workers;
    workers.reserve(kThreadCount);
    for (std::size_t thread = 0; thread < kThreadCount; ++thread)
        workers.emplace_back([payload, &retainedEveryTime] {
            for (std::size_t index = 0; index < kIterations; ++index)
            {
                if (Aarc::RetainStrong(payload) != payload)
                    retainedEveryTime.store(false, std::memory_order_relaxed);
                Aarc::ReleaseStrong(payload);
            }
        });
    for (auto &worker : workers)
        worker.join();

    CHECK(retainedEveryTime.load(std::memory_order_relaxed));
    CHECK(destructions.load() == 0U);
    Aarc::ReleaseStrong(payload);
    CHECK(destructions.load() == 1U);
}

TEST_CASE("Unicode scalar string factory creates an AARC object")
{
    const std::uint32_t scalars[]{ 0x56U, 0x69U, 0x73U, 0x75U, 0x61U,
                                   0x6cU, 0x20U, 0x58U, 0x23U };
    auto *string = tala_aarc_string_literal(scalars, std::size(scalars));
    REQUIRE(string != nullptr);
    CHECK(Aarc::IsExactType(string, Aarc::TypeIdentity("String")));
    Aarc::ReleaseStrong(string);
    const std::uint32_t surrogate[]{ 0xd800U };
    CHECK(tala_aarc_string_literal(surrogate, 1U) == nullptr);
    const std::uint32_t outsideUnicode[]{ 0x110000U };
    CHECK(tala_aarc_string_literal(outsideUnicode, 1U) == nullptr);
}
