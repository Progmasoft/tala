// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <atomic>
#include <climits>
#include <cstdlib>
#include <llvm/Support/raw_ostream.h>
#include <string_view>
#include <thread>

#if defined(__cpp_exceptions) || defined(_CPPUNWIND)
#    error "owned compiler translation units must have C++ exceptions disabled"
#endif

namespace
{
    volatile int sink{};
    volatile int raceValue{};

    void
    ExerciseAddress()
    {
        auto *allocation = static_cast<int *>(std::malloc(64U));
        if (allocation == nullptr)
            std::abort();
        allocation[0] = 37;
        volatile int *borrowed = allocation;
        std::free(allocation);
        // Intentional lifetime violation, isolated in a never-shipped probe.
        // Volatile consumption prevents optimization from removing the load.
        sink = *borrowed;
    }

    void
    ExerciseUndefined()
    {
        volatile int maximum = INT_MAX;
        sink = maximum + 1;
    }

    void
    ExerciseThread()
    {
        raceValue = 0;
        std::atomic<bool> start{ false };
        auto writer = [&]() {
            while (!start.load(std::memory_order_acquire))
                std::this_thread::yield();
            for (int iteration = 0; iteration < 10000; ++iteration)
                raceValue = iteration;
        };
        std::thread first(writer);
        std::thread second(writer);
        start.store(true, std::memory_order_release);
        first.join();
        second.join();
        sink = raceValue;
    }
} // namespace

int
main(int count, char **arguments)
{
    // Exercise the real LLVM Support link boundary too: a bare CRT-only probe
    // would miss allocator overrides introduced by a development package.
    llvm::outs().flush();
    if (count != 2)
        return 2;
    const std::string_view mode(arguments[1]);
    if (mode == "clean")
        return 0;
    if (mode == "address")
        ExerciseAddress();
    else if (mode == "undefined")
        ExerciseUndefined();
    else if (mode == "thread")
        ExerciseThread();
    else
        return 2;
    // Returning successfully is deliberately a failure of the helper gate.
    return 0;
}
