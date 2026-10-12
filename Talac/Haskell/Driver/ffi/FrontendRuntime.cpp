// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <HsFFI.h>
#include <cstdint>

#ifdef _WIN32
#    define WIN32_LEAN_AND_MEAN
#    include <windows.h>
#else
#    include <atomic>
#endif

namespace
{
    // 0=uninitialized, 1=initializing, 2=ready, 3=shutting down, 4=stopped.
    // The atomic state keeps the tiny host shim independent of the C++ runtime
    // (which Cabal's standalone Windows foreign library intentionally omits).
#ifdef _WIN32
    volatile LONG runtimeState = 0;

    [[nodiscard]] auto
    LoadRuntimeState() noexcept -> LONG
    {
        return InterlockedCompareExchange(&runtimeState, 0, 0);
    }

    [[nodiscard]] auto
    CompareRuntimeState(LONG expected, LONG desired) noexcept -> bool
    {
        return InterlockedCompareExchange(&runtimeState, desired, expected)
               == expected;
    }

    void
    StoreRuntimeState(LONG desired) noexcept
    {
        InterlockedExchange(&runtimeState, desired);
    }
#else
    std::atomic<std::int32_t> runtimeState{ 0 };

    [[nodiscard]] auto
    LoadRuntimeState() noexcept -> std::int32_t
    {
        return runtimeState.load();
    }

    [[nodiscard]] auto
    CompareRuntimeState(std::int32_t expected, std::int32_t desired) noexcept
        -> bool
    {
        return runtimeState.compare_exchange_strong(expected, desired);
    }

    void
    StoreRuntimeState(std::int32_t desired) noexcept
    {
        runtimeState.store(desired);
    }
#endif
} // namespace

// GHC requires the host to start its RTS before a foreign-exported Haskell
// function runs. This explicit C++20 entry point is intentionally never called
// from DllMain, where GHC documents that hs_init can deadlock the loader.
extern "C" std::int32_t
tala_frontend_initialize() noexcept
{
    if (CompareRuntimeState(0, 1))
    {
        int argumentCount = 1;
        char executableName[] = "talac";
        char *arguments[] = { executableName, nullptr };
        char **argumentPointer = arguments;
        hs_init(&argumentCount, &argumentPointer);
        StoreRuntimeState(2);
    }
    else
    {
        while (LoadRuntimeState() == 1)
        {
            // Initialization is a one-time startup operation and callers are
            // never allowed into Haskell until the RTS reaches the ready state.
        }
    }
    return LoadRuntimeState() == 2 ? 0 : -1;
}

// The native driver owns one process-wide frontend runtime. Shutdown is
// idempotent and occurs at normal process teardown, never while a callback is
// executing or while a result buffer is borrowed.
extern "C" void
tala_frontend_shutdown() noexcept
{
    if (!CompareRuntimeState(2, 3))
        return;
    hs_exit();
    StoreRuntimeState(4);
}
