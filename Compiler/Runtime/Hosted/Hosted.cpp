// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

// The Visual X# runtime as it is linked into a native executable on Linux
// and macOS.
//
// There a native executable is linked with the C library of the system and
// with nothing of C++: the C library is what every such system has, and a
// C++ runtime is a choice between two that an executable should not have to
// make. This translation unit is the whole runtime such an executable gets:
// the ownership runtime and the text and console runtime, from the same
// sources that a process hosting generated code links, followed by the few
// things those sources take from a C++ runtime when there is one.
//
// The sources are included rather than compiled on their own so that the
// library is one object built with one set of options, as the Windows
// library in `Compiler/Runtime/Freestanding` is.
//
// What the executable takes from the system is `malloc` and `free` for
// memory and `write` for output.

#include <cstddef>
#include <cstdlib>
#include <new>

#include "Compiler/Runtime/AARC/Runtime.cpp"
#include "Compiler/Runtime/Text/Console.cpp"
#include "Compiler/Runtime/Text/Format.cpp"
#include "Compiler/Runtime/Text/Platform.cpp"
#include "Compiler/Runtime/Text/Text.cpp"

namespace std
{
    // The tag object of the non-throwing allocation functions, which a C++
    // runtime library defines.
    const nothrow_t nothrow{};
} // namespace std

// Memory comes from the C library. Only the non-throwing forms are defined:
// the runtime uses no other, and a use of a throwing form would fail to link
// rather than throw where nothing can catch.

auto
operator new(std::size_t bytes, const std::nothrow_t &) noexcept -> void *
{
    // The storage is released by the operator delete below.
    // NOLINTNEXTLINE(cppcoreguidelines-no-malloc,cppcoreguidelines-owning-memory)
    return std::malloc(bytes == 0U ? 1U : bytes);
}

auto
operator new[](std::size_t bytes, const std::nothrow_t &) noexcept -> void *
{
    // NOLINTNEXTLINE(cppcoreguidelines-no-malloc,cppcoreguidelines-owning-memory)
    return std::malloc(bytes == 0U ? 1U : bytes);
}

void
operator delete(void *block) noexcept
{
    // NOLINTNEXTLINE(cppcoreguidelines-no-malloc,cppcoreguidelines-owning-memory)
    std::free(block);
}

void
operator delete[](void *block) noexcept
{
    // NOLINTNEXTLINE(cppcoreguidelines-no-malloc,cppcoreguidelines-owning-memory)
    std::free(block);
}

void
operator delete(void *block, std::size_t) noexcept
{
    // NOLINTNEXTLINE(cppcoreguidelines-no-malloc,cppcoreguidelines-owning-memory)
    std::free(block);
}

void
operator delete[](void *block, std::size_t) noexcept
{
    // NOLINTNEXTLINE(cppcoreguidelines-no-malloc,cppcoreguidelines-owning-memory)
    std::free(block);
}
