// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <lld/Common/Driver.h>
#include <llvm/ADT/StringRef.h>
#include <llvm/BinaryFormat/COFF.h>
#include <llvm/Object/COFFImportFile.h>
#include <llvm/Support/Error.h>
#include <llvm/Support/raw_ostream.h>

#include "Talac/Linker/Lld.hpp"

// LLD's linkers are linked into talac, so a link needs no linker on the
// host. Only the three formats talac writes are linked in.
LLD_HAS_DRIVER(coff)
LLD_HAS_DRIVER(elf)
LLD_HAS_DRIVER(macho)

namespace Progmasoft::Tala::Driver
{
    auto
    RunLld(const LldFlavor flavor, const std::vector<std::string> &arguments)
        -> LldOutcome
    {
        // LLD chooses the linker by the name of the program, as its single
        // executable does.
        const char *name = flavor == LldFlavor::Coff  ? "lld-link"
                           : flavor == LldFlavor::Elf ? "ld.lld"
                                                      : "ld64.lld";
        std::vector<const char *> argv;
        argv.reserve(arguments.size() + 1U);
        argv.push_back(name);
        for (const auto &argument : arguments)
            argv.push_back(argument.c_str());

        LldOutcome outcome;
        llvm::raw_string_ostream messages(outcome.messages);
        const auto result
            = lld::lldMain(argv,
                           messages,
                           messages,
                           { { lld::WinLink, &lld::coff::link },
                             { lld::Gnu, &lld::elf::link },
                             { lld::Darwin, &lld::macho::link } });
        messages.flush();
        outcome.exitCode = result.retCode;
        // A link that failed so badly that LLD's state cannot be reset
        // leaves talac unable to link again; it is one process per
        // compilation, so saying so is enough.
        if (!result.canRunAgain)
            outcome.messages += "LLD cannot link again in this process\n";
        return outcome;
    }

    auto
    WriteImportLibrary(const std::filesystem::path &library,
                       const std::string_view dll,
                       const std::vector<std::string> &functions,
                       const std::string_view machine) -> std::string
    {
        const auto type = machine == "arm64"
                              ? llvm::COFF::IMAGE_FILE_MACHINE_ARM64
                              : llvm::COFF::IMAGE_FILE_MACHINE_AMD64;
        std::vector<llvm::object::COFFShortExport> exports;
        exports.reserve(functions.size());
        for (const auto &function : functions)
        {
            llvm::object::COFFShortExport entry;
            entry.Name = function;
            exports.push_back(std::move(entry));
        }
        const auto text = library.u8string();
        const std::string path(reinterpret_cast<const char *>(text.data()),
                               text.size());
        if (auto error = llvm::object::writeImportLibrary(
                llvm::StringRef(dll.data(), dll.size()),
                path,
                exports,
                type,
                false))
            return "could not write the import library of " + std::string(dll)
                   + ": " + llvm::toString(std::move(error));
        return {};
    }
} // namespace Progmasoft::Tala::Driver
