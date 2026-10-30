// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

// The Tala runtime as it is linked into a native executable.
//
// A native executable is linked without a C runtime. This translation unit
// is the whole runtime such an executable gets: the ownership runtime and
// the text and console runtime, from the same sources that a process
// hosting generated code links, followed by the few things those sources
// take from a C runtime when there is one.
//
// The sources are included rather than compiled on their own so that the
// library is one object built with one set of options. Those options turn
// off what needs runtime support the executable does not have: stack
// cookies, and instrumentation of any kind. A sanitizer build of the
// compiler therefore still produces this object uninstrumented, because the
// programs it is linked into are not sanitizer builds.
//
// What the executable imports from the system is kernel32 and nothing else:
// the process heap for memory and the standard handles for output.

#include <cstddef>
#include <new>

#include "Talac/Runtime/AARC/Runtime.cpp"
#include "Talac/Runtime/Text/Console.cpp"
#include "Talac/Runtime/Text/Format.cpp"
#include "Talac/Runtime/Text/Platform.cpp"
#include "Talac/Runtime/Text/Testing.cpp"
#include "Talac/Runtime/Text/Text.cpp"

extern "C"
{
    __declspec(dllimport) void *__stdcall
    GetProcessHeap();
    __declspec(dllimport) void *__stdcall
    HeapAlloc(void *heap, unsigned long flags, std::size_t bytes);
    __declspec(dllimport) int __stdcall
    HeapFree(void *heap, unsigned long flags, void *block);

    // The linker looks for this symbol in any program that uses
    // floating-point arithmetic; a C runtime defines it. The process entry of
    // every executable defines it too, because an executable that takes
    // TalaRT from talart.dll carries none of this file; any one of the
    // definitions may be kept.
    // NOLINTNEXTLINE(bugprone-reserved-identifier,cppcoreguidelines-avoid-non-const-global-variables)
    __declspec(selectany) int _fltused = 0x9875;

    // The compiler may turn a loop or an initialization into a call of
    // these, and each is told not to turn its own loop into a call of
    // itself.
    __attribute__((no_builtin("memset"))) auto
    memset(void *destination, int value, std::size_t count) -> void *
    {
        auto *bytes = static_cast<unsigned char *>(destination);
        for (std::size_t index = 0U; index < count; ++index)
            bytes[index] = static_cast<unsigned char>(value);
        return destination;
    }

    __attribute__((no_builtin("memcpy"))) auto
    memcpy(void *destination, const void *source, std::size_t count) -> void *
    {
        auto *to = static_cast<unsigned char *>(destination);
        const auto *from = static_cast<const unsigned char *>(source);
        for (std::size_t index = 0U; index < count; ++index)
            to[index] = from[index];
        return destination;
    }

    __attribute__((no_builtin("memmove", "memcpy"))) auto
    memmove(void *destination, const void *source, std::size_t count) -> void *
    {
        auto *to = static_cast<unsigned char *>(destination);
        const auto *from = static_cast<const unsigned char *>(source);
        if (to < from)
            for (std::size_t index = 0U; index < count; ++index)
                to[index] = from[index];
        else
            for (std::size_t index = count; index-- > 0U;)
                to[index] = from[index];
        return destination;
    }
}

namespace std
{
    // The tag object of the non-throwing allocation functions, which a C++
    // runtime library defines.
    const nothrow_t nothrow{};
} // namespace std

// Memory comes from the heap of the process. Only the non-throwing forms
// are defined: the runtime uses no other, and a use of a throwing form would
// fail to link rather than throw where nothing can catch.

auto
operator new(std::size_t bytes, const std::nothrow_t &) noexcept -> void *
{
    return HeapAlloc(GetProcessHeap(), 0UL, bytes == 0U ? 1U : bytes);
}

auto
operator new[](std::size_t bytes, const std::nothrow_t &) noexcept -> void *
{
    return HeapAlloc(GetProcessHeap(), 0UL, bytes == 0U ? 1U : bytes);
}

void
operator delete(void *block) noexcept
{
    if (block != nullptr)
        HeapFree(GetProcessHeap(), 0UL, block);
}

void
operator delete[](void *block) noexcept
{
    if (block != nullptr)
        HeapFree(GetProcessHeap(), 0UL, block);
}

void
operator delete(void *block, std::size_t) noexcept
{
    if (block != nullptr)
        HeapFree(GetProcessHeap(), 0UL, block);
}

void
operator delete[](void *block, std::size_t) noexcept
{
    if (block != nullptr)
        HeapFree(GetProcessHeap(), 0UL, block);
}
