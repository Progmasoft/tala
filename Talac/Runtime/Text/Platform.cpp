// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include "Platform.hpp"

#ifdef _WIN32

// The four functions of kernel32 the runtime needs are declared here rather
// than through <windows.h>: a native executable links against an import
// library that the compiler generates for exactly the functions the runtime
// names, and this list is that contract. `TalaKernel32.def.inc` repeats it
// for the linker.
extern "C"
{
    __declspec(dllimport) void *__stdcall
    GetStdHandle(unsigned long standardHandle);
    __declspec(dllimport) int __stdcall
    GetConsoleMode(void *handle, unsigned long *mode);
    __declspec(dllimport) int __stdcall
    WriteConsoleW(void *handle,
                  const wchar_t *text,
                  unsigned long count,
                  unsigned long *written,
                  void *reserved);
    __declspec(dllimport) int __stdcall
    WriteFile(void *handle,
              const void *bytes,
              unsigned long count,
              unsigned long *written,
              void *overlapped);
}

namespace Progmasoft::Tala::Runtime::Platform
{
    namespace
    {
        constexpr unsigned long kStandardOutput = 0xfffffff5UL; // -11
        constexpr unsigned long kStandardError = 0xfffffff4UL;  // -12
        constexpr std::size_t kChunk = 512U;

        /// Write whole UTF-8 characters to a console as UTF-16. A console
        /// shows what it is given as text in its own code page, so bytes
        /// of UTF-8 written to it would show as the wrong characters.
        void
        WriteConsole(void *handle,
                     const char *bytes,
                     const std::size_t count) noexcept
        {
            wchar_t units[kChunk];
            std::size_t used = 0U;
            std::size_t index = 0U;
            while (index < count)
            {
                const auto lead = static_cast<unsigned char>(bytes[index]);
                const std::size_t length = lead < 0x80U   ? 1U
                                           : lead < 0xe0U ? 2U
                                           : lead < 0xf0U ? 3U
                                                          : 4U;
                if (index + length > count)
                    break;
                std::uint32_t scalar = length == 1U   ? lead
                                       : length == 2U ? (lead & 0x1fU)
                                       : length == 3U ? (lead & 0x0fU)
                                                      : (lead & 0x07U);
                for (std::size_t offset = 1U; offset < length; ++offset)
                    scalar
                        = (scalar << 6U)
                          | (static_cast<unsigned char>(bytes[index + offset])
                             & 0x3fU);
                index += length;
                if (used + 2U > kChunk)
                {
                    unsigned long written = 0UL;
                    WriteConsoleW(handle,
                                  units,
                                  static_cast<unsigned long>(used),
                                  &written,
                                  nullptr);
                    used = 0U;
                }
                if (scalar < 0x10000U)
                {
                    units[used++] = static_cast<wchar_t>(scalar);
                }
                else
                {
                    scalar -= 0x10000U;
                    units[used++]
                        = static_cast<wchar_t>(0xd800U + (scalar >> 10U));
                    units[used++]
                        = static_cast<wchar_t>(0xdc00U + (scalar & 0x3ffU));
                }
            }
            if (used != 0U)
            {
                unsigned long written = 0UL;
                WriteConsoleW(handle,
                              units,
                              static_cast<unsigned long>(used),
                              &written,
                              nullptr);
            }
        }
    } // namespace

    void
    Fail() noexcept
    {
        __builtin_trap();
    }

    void
    Write(const bool error, const char *bytes, const std::size_t count) noexcept
    {
        auto *handle = GetStdHandle(error ? kStandardError : kStandardOutput);
        // A process without the stream has a null or an invalid handle.
        if (handle == nullptr || reinterpret_cast<std::intptr_t>(handle) == -1)
            return;
        unsigned long mode = 0UL;
        if (GetConsoleMode(handle, &mode) != 0)
        {
            WriteConsole(handle, bytes, count);
            return;
        }
        std::size_t done = 0U;
        while (done < count)
        {
            unsigned long written = 0UL;
            const auto part
                = count - done > 0x40000000U ? 0x40000000U : count - done;
            if (WriteFile(handle,
                          bytes + done,
                          static_cast<unsigned long>(part),
                          &written,
                          nullptr)
                    == 0
                || written == 0UL)
                return;
            done += written;
        }
    }
} // namespace Progmasoft::Tala::Runtime::Platform

#else

#    include <cerrno>
#    include <unistd.h>

namespace Progmasoft::Tala::Runtime::Platform
{
    void
    Fail() noexcept
    {
        __builtin_trap();
    }

    void
    Write(const bool error, const char *bytes, const std::size_t count) noexcept
    {
        const int descriptor = error ? 2 : 1;
        std::size_t done = 0U;
        while (done < count)
        {
            const auto written
                = ::write(descriptor, bytes + done, count - done);
            if (written < 0)
            {
                if (errno == EINTR)
                    continue;
                return;
            }
            if (written == 0)
                return;
            done += static_cast<std::size_t>(written);
        }
    }
} // namespace Progmasoft::Tala::Runtime::Platform

#endif
