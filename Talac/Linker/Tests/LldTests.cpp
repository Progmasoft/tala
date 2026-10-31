// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/TestMacros.hpp>
#include <cstdlib>
#include <filesystem>
#include <llvm/ADT/SmallString.h>
#include <llvm/IR/BasicBlock.h>
#include <llvm/IR/Constants.h>
#include <llvm/IR/Function.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/LegacyPassManager.h>
#include <llvm/IR/Module.h>
#include <llvm/MC/TargetRegistry.h>
#include <llvm/Support/CodeGen.h>
#include <llvm/Support/FileSystem.h>
#include <llvm/Support/TargetSelect.h>
#include <llvm/Support/raw_ostream.h>
#include <llvm/Target/TargetMachine.h>
#include <llvm/Target/TargetOptions.h>
#include <llvm/TargetParser/Triple.h>
#include <memory>
#include <string>
#include <system_error>
#include <vector>

#include "Talac/Linker/Lld.hpp"

// LLD is linked into talac: these tests run it inside the test process. The
// object a Windows link reads is generated here by LLVM, so the link needs
// nothing from the host but the test itself.

namespace
{
    namespace Driver = Progmasoft::Tala::Driver;

    /// A directory of its own for one test, removed afterwards.
    struct Directory final
    {
        std::filesystem::path path;

        Directory()
        {
            llvm::SmallString<128> created;
            if (!llvm::sys::fs::createUniqueDirectory("talac-lld", created))
                path = created.str().str();
        }
        Directory(const Directory &) = delete;
        Directory(Directory &&) = delete;
        auto
        operator=(const Directory &) -> Directory & = delete;
        auto
        operator=(Directory &&) -> Directory & = delete;
        ~Directory()
        {
            std::error_code ignored;
            std::filesystem::remove_all(path, ignored);
        }
    };

    /// A COFF object for x86-64 Windows whose `mainCRTStartup` returns 42.
    [[nodiscard]] auto
    WriteEntryObject(const std::filesystem::path &object) -> bool
    {
        LLVMInitializeX86TargetInfo();
        LLVMInitializeX86Target();
        LLVMInitializeX86TargetMC();
        LLVMInitializeX86AsmPrinter();
        const llvm::Triple triple("x86_64-pc-windows-msvc");
        std::string error;
        const auto *target = llvm::TargetRegistry::lookupTarget(triple, error);
        if (target == nullptr)
            return false;
        std::unique_ptr<llvm::TargetMachine> machine(
            target->createTargetMachine(triple,
                                        "x86-64",
                                        "",
                                        llvm::TargetOptions{},
                                        std::nullopt));
        llvm::LLVMContext context;
        llvm::Module module("entry", context);
        module.setTargetTriple(triple);
        module.setDataLayout(machine->createDataLayout());
        auto *int32 = llvm::Type::getInt32Ty(context);
        auto *entry
            = llvm::Function::Create(llvm::FunctionType::get(int32, false),
                                     llvm::GlobalValue::ExternalLinkage,
                                     "mainCRTStartup",
                                     module);
        llvm::IRBuilder<> builder(
            llvm::BasicBlock::Create(context, "entry", entry));
        builder.CreateRet(llvm::ConstantInt::get(int32, 42));

        std::error_code openError;
        llvm::raw_fd_ostream stream(object.string(), openError);
        if (openError)
            return false;
        llvm::legacy::PassManager passes;
        if (machine->addPassesToEmitFile(passes,
                                         stream,
                                         nullptr,
                                         llvm::CodeGenFileType::ObjectFile))
            return false;
        passes.run(module);
        stream.flush();
        return true;
    }
} // namespace

TEST_CASE("an import library is written for the functions of a DLL")
{
    const Directory directory;
    const auto library = directory.path / "talart.dll.lib";
    for (const auto *machine : { "x64", "arm64" })
    {
        CHECK(Driver::WriteImportLibrary(library,
                                         "talart.dll",
                                         { "tala_console_write", "memset" },
                                         machine)
                  .empty());
        std::error_code error;
        CHECK(std::filesystem::file_size(library, error) > 0U);
    }
}

TEST_CASE("a link LLD refuses fails with what LLD said")
{
    const Directory directory;
    const auto outcome
        = Driver::RunLld(Driver::LldFlavor::Coff,
                         { "/nologo",
                           "/out:" + (directory.path / "a.exe").string(),
                           (directory.path / "missing.obj").string() });
    CHECK(outcome.exitCode != 0);
    CHECK(outcome.messages.find("missing.obj") != std::string::npos);
    // LLD can run again after a refused link.
    const auto again = Driver::RunLld(Driver::LldFlavor::Elf, { "--version" });
    CHECK(again.exitCode == 0);
    CHECK(again.messages.find("LLD") != std::string::npos);
}

TEST_CASE("LLD inside the process links a Windows executable")
{
    const Directory directory;
    const auto object = directory.path / "entry.obj";
    REQUIRE(WriteEntryObject(object));
    const auto executable = directory.path / "entry.exe";
    const auto outcome = Driver::RunLld(Driver::LldFlavor::Coff,
                                        { "/nologo",
                                          "/entry:mainCRTStartup",
                                          "/subsystem:console",
                                          "/nodefaultlib",
                                          "/machine:x64",
                                          "/out:" + executable.string(),
                                          object.string() });
    INFO(outcome.messages);
    REQUIRE(outcome.exitCode == 0);
    std::error_code error;
    CHECK(std::filesystem::file_size(executable, error) > 0U);
#if defined(_WIN32) && defined(_M_X64)
    // The program runs, and the exit code is the one its entry returns.
    CHECK(std::system(("\"" + executable.string() + "\"").c_str()) == 42);
#endif
}
