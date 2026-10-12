// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <llvm/Support/ErrorHandling.h>

#include "Progmasoft/Tala/Support/CompilerStack.hpp"

#if defined(_WIN32)
#    ifndef WIN32_LEAN_AND_MEAN
#        define WIN32_LEAN_AND_MEAN
#    endif
#    ifndef NOMINMAX
#        define NOMINMAX
#    endif
#    include <process.h>
#    include <windows.h>
#else
#    include <pthread.h>
#    include <sys/mman.h>
#    include <unistd.h>
#    include <vector>
#endif

namespace Progmasoft::Tala::Support
{
    namespace
    {
        struct Start final
        {
            void (*function)(void *);
            void *argument;
        };

#if defined(_WIN32)
        unsigned __stdcall
        Enter(void *context)
        {
            const auto *start = static_cast<const Start *>(context);
            start->function(start->argument);
            return 0U;
        }
#else
        void *
        Enter(void *context)
        {
            const auto *start = static_cast<const Start *>(context);
            start->function(start->argument);
            return nullptr;
        }
#endif
    } // namespace

    void
    RunOnCompilerStackRaw(void (*function)(void *), void *argument)
    {
        RunOnStackRaw(kCompilerStackBytes, function, argument);
    }

    void
    RunOnStackRaw(std::size_t bytes, void (*function)(void *), void *argument)
    {
        Start start{ function, argument };
#if defined(_WIN32)
        // Without the reservation flag the size would be committed up
        // front: every run would charge the whole stack against the
        // system's commit limit and pay for mapping it.
        const auto handle = _beginthreadex(nullptr,
                                           static_cast<unsigned>(bytes),
                                           Enter,
                                           &start,
                                           STACK_SIZE_PARAM_IS_A_RESERVATION,
                                           nullptr);
        if (handle == 0U)
            llvm::report_fatal_error("could not start the compiler thread");
        // _beginthreadex returns the thread handle as an integer; this cast
        // is how its documentation says to recover the handle.
        // NOLINTNEXTLINE(performance-no-int-to-ptr)
        const auto thread = reinterpret_cast<HANDLE>(handle);
        if (WaitForSingleObject(thread, INFINITE) != WAIT_OBJECT_0)
            llvm::report_fatal_error("could not wait for the compiler thread");
        CloseHandle(thread);
#else
        // A pthread stack is mapped lazily, so the size is a reservation.
        pthread_attr_t attributes;
        if (pthread_attr_init(&attributes) != 0
            || pthread_attr_setstacksize(&attributes, bytes) != 0)
            llvm::report_fatal_error(
                "could not size the stack of the compiler thread");
        pthread_t thread;
        if (pthread_create(&thread, &attributes, Enter, &start) != 0)
            llvm::report_fatal_error("could not start the compiler thread");
        pthread_attr_destroy(&attributes);
        if (pthread_join(thread, nullptr) != 0)
            llvm::report_fatal_error("could not wait for the compiler thread");
#endif
    }

    auto
    CommittedStackBytes() -> std::size_t
    {
#if defined(_WIN32)
        MEMORY_BASIC_INFORMATION information{};
        const char here = 0;
        if (VirtualQuery(&here, &information, sizeof(information)) == 0U)
            return 0U;
        // A thread stack is one allocation: reserved pages at the bottom,
        // then the guard page, then the committed pages up to the top.
        const auto *const allocation = information.AllocationBase;
        std::size_t committed = 0U;
        // NOLINTBEGIN(cppcoreguidelines-pro-bounds-pointer-arithmetic)
        const auto *cursor = static_cast<const char *>(allocation);
        while (VirtualQuery(cursor, &information, sizeof(information)) != 0U
               && information.AllocationBase == allocation)
        {
            if (information.State == MEM_COMMIT)
                committed += information.RegionSize;
            cursor += information.RegionSize;
        }
        // NOLINTEND(cppcoreguidelines-pro-bounds-pointer-arithmetic)
        return committed;
#elif defined(__APPLE__) || defined(__linux__)
        // A thread stack is mapped lazily, so the pages that are resident
        // are the pages the thread has touched. The stack of the initial
        // thread is not one mapping; for it the query fails and nothing is
        // reported.
        void *low = nullptr;
        std::size_t size = 0U;
#    if defined(__APPLE__)
        const auto self = pthread_self();
        size = pthread_get_stacksize_np(self);
        // The address the system reports is the high end of the stack.
        // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
        low = static_cast<char *>(pthread_get_stackaddr_np(self)) - size;
        using PageState = char;
#    else
        pthread_attr_t attributes;
        if (pthread_getattr_np(pthread_self(), &attributes) != 0)
            return 0U;
        const auto found = pthread_attr_getstack(&attributes, &low, &size);
        pthread_attr_destroy(&attributes);
        if (found != 0)
            return 0U;
        using PageState = unsigned char;
#    endif
        const auto pageSize = sysconf(_SC_PAGESIZE);
        if (pageSize <= 0 || size == 0U || low == nullptr)
            return 0U;
        const auto page = static_cast<std::size_t>(pageSize);
        std::vector<PageState> states((size + page - 1U) / page);
        if (mincore(low, size, states.data()) != 0)
            return 0U;
        std::size_t committed = 0U;
        for (const auto state : states)
            if ((static_cast<unsigned char>(state) & 1U) != 0U)
                committed += page;
        return committed;
#else
        return 0U;
#endif
    }
} // namespace Progmasoft::Tala::Support
