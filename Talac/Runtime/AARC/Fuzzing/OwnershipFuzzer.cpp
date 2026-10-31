// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <llvm/Support/ErrorHandling.h>
#include <thread>
#include <vector>

#include "Progmasoft/Tala/Runtime/AARC.hpp"

namespace
{
    namespace Aarc = Progmasoft::Tala::Runtime::Aarc;
    constexpr std::uint64_t kMarker = 0xABCDEF123456ULL;
    struct Payload final
    {
        std::atomic_uint32_t *destructions{};
        std::uint64_t marker{};
    };
    void
    Destroy(void *object) noexcept
    {
        auto *payload = static_cast<Payload *>(object);
        payload->marker = 0U;
        payload->destructions->fetch_add(1U, std::memory_order_relaxed);
    }
    const Aarc::TypeMetadata kMetadata{ Aarc::kAbiVersion,
                                        0U,
                                        Aarc::TypeIdentity("Fuzz.Payload"),
                                        sizeof(Payload),
                                        alignof(Payload),
                                        Destroy,
                                        "Fuzz.Payload" };
} // namespace

extern "C" int
LLVMFuzzerTestOneInput(const std::uint8_t *data, std::size_t size)
{
    std::atomic_uint32_t destructions{};
    auto *payload = static_cast<Payload *>(Aarc::Allocate(kMetadata));
    if (payload == nullptr)
        llvm::report_fatal_error("ownership fuzz payload allocation failed");
    payload->destructions = &destructions;
    payload->marker = kMarker;
    const auto weak = Aarc::MakeWeak(payload);
    const auto unowned = Aarc::MakeUnowned(payload);
    std::atomic_bool start{};
    std::atomic_bool corrupt{};
    const auto workerCount
        = size == 0U ? 2U : 1U + static_cast<unsigned>(data[0] % 4U);
    const auto iterations
        = size < 2U ? 8U : 1U + static_cast<unsigned>(data[1] % 64U);
    // std::jthread is unavailable in Apple libc++; join explicitly below.
    std::vector<std::thread> workers;
    workers.reserve(workerCount);
    for (unsigned worker = 0U; worker < workerCount; ++worker)
    {
        const auto localWeak = Aarc::CopyWeak(weak);
        const auto localUnowned = Aarc::CopyUnowned(unowned);
        workers.emplace_back([&, localWeak, localUnowned, worker] {
            while (!start.load(std::memory_order_acquire))
                std::this_thread::yield();
            for (unsigned iteration = 0U; iteration < iterations; ++iteration)
            {
                auto *locked = static_cast<Payload *>(
                    (iteration + worker) % 2U == 0U
                        ? Aarc::LockWeak(localWeak)
                        : Aarc::LoadUnowned(localUnowned));
                if (locked != nullptr)
                {
                    // Reads occur only while a temporary strong owner protects
                    // the payload. Destructor writes must never overlap them.
                    if (locked->marker != kMarker)
                        corrupt.store(true, std::memory_order_relaxed);
                    Aarc::ReleaseStrong(locked);
                }
                const auto extra = Aarc::CopyWeak(localWeak);
                Aarc::ReleaseWeak(extra);
                std::this_thread::yield();
            }
            Aarc::ReleaseWeak(localWeak);
            Aarc::ReleaseUnowned(localUnowned);
        });
    }
    start.store(true, std::memory_order_release);
    Aarc::ReleaseStrong(payload);
    // Every worker finishes before the independent destructor oracle runs.
    for (auto &worker : workers)
        worker.join();
    if (corrupt.load() || destructions.load() != 1U
        || Aarc::LockWeak(weak) != nullptr
        || Aarc::LoadUnowned(unowned) != nullptr)
        llvm::report_fatal_error(
            "ownership race resurrected or multiply destroyed a payload");
    Aarc::ReleaseWeak(weak);
    Aarc::ReleaseUnowned(unowned);
    return 0;
}
