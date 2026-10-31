// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/raw_ostream.h>

#include "Progmasoft/Tala/Support/CompilerStack.hpp"
#include "SourceFuzz.hpp"

// Measures the stack a whole compilation uses.
//
//     source_stack_probe <file> <stack-kibibytes>
//
// compiles a source file through the frontend and the native pipeline on a
// thread whose stack has the given size, as `talac` does on the compiler
// stack, and prints the stack that thread committed. That is an upper bound
// on what it used, to the page and with the guard page, not the exact number
// of bytes in use; frames a sanitizer keeps on a heap-allocated fake stack
// are not in it. The size on the command line is only reserved. A source of at
// most 64 KiB that the frontend rejects is a completed run as well; a larger
// one must be accepted. The process is terminated by the operating system when
// the stack is too small. The program is a measuring instrument, not a test.

int
main(int argc, char **argv)
{
    if (argc != 3)
    {
        llvm::errs() << "usage: source_stack_probe <file> <stack-kibibytes>\n";
        return 2;
    }
    // The arguments of a measuring tool, read once at the start.
    // NOLINTBEGIN(cppcoreguidelines-pro-bounds-pointer-arithmetic)
    const char *const path = argv[1];
    const auto stack
        = static_cast<std::size_t>(std::strtoull(argv[2], nullptr, 10)) * 1024U;
    // NOLINTEND(cppcoreguidelines-pro-bounds-pointer-arithmetic)
    auto buffer = llvm::MemoryBuffer::getFile(path);
    if (!buffer || stack == 0U)
    {
        llvm::errs() << "source_stack_probe: cannot read " << path << '\n';
        return 3;
    }
    const auto text = (*buffer)->getBuffer();
    std::size_t committed = 0U;
    Progmasoft::Tala::Support::RunOnStack(stack, [&] {
        // The bytes of the file are the input, as a fuzz target receives it.
        // NOLINTNEXTLINE(cppcoreguidelines-pro-type-reinterpret-cast)
        const auto *const bytes
            = reinterpret_cast<const std::uint8_t *>(text.data());
        // The entry that tolerates a rejection ignores input above the
        // size limit of the fuzz targets; a larger file must be accepted.
        constexpr std::size_t kFuzzInputLimit = std::size_t{ 64U } * 1024U;
        if (text.size() <= kFuzzInputLimit)
            Progmasoft::Tala::Fuzzing::ExerciseSourceToLlvm(
                { bytes, text.size() });
        else
            Progmasoft::Tala::Fuzzing::ExerciseAcceptedSource(
                { bytes, text.size() });
        committed = Progmasoft::Tala::Support::CommittedStackBytes();
    });
    llvm::outs() << "ok committed-kib " << committed / 1024U << '\n';
    return 0;
}
