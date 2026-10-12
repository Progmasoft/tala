// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <fstream>
#include <system_error>

#include "Progmasoft/Tala/Backend/LLVM.hpp"

namespace Progmasoft::Tala::Backend::LLVM
{
    namespace
    {
        [[nodiscard]] auto
        FileError(const std::filesystem::path &path, std::string_view action)
            -> Error
        {
            return Error{ ErrorKind::FileSystem,
                          "TAL3001",
                          "could not " + std::string(action)
                              + " LLVM artifact '" + path.string() + "'",
                          {} };
        }

        [[nodiscard]] auto
        ExtensionError(const std::filesystem::path &path,
                       std::string_view expected) -> Error
        {
            return Error{ ErrorKind::FileSystem,
                          "TAL3002",
                          "LLVM artifact '" + path.string() + "' must use the "
                              + std::string(expected) + " extension",
                          {} };
        }

        [[nodiscard]] auto
        WriteBytes(const std::filesystem::path &path,
                   const char *bytes,
                   std::size_t size) -> std::optional<Error>
        {
            // Truncation implements `talac build` replacement semantics: a new
            // artifact supersedes an older one instead of appending or
            // requiring manual cleanup.
            std::ofstream stream(path, std::ios::binary | std::ios::trunc);
            if (!stream)
                return FileError(path, "open");
            stream.write(bytes, static_cast<std::streamsize>(size));
            if (!stream)
                return FileError(path, "write");
            // Explicit close catches delayed Windows filesystem errors while
            // the path is still available for a useful diagnostic. Relying only
            // on the destructor would discard that failure and could report a
            // truncated artifact as successful.
            stream.close();
            if (!stream)
                return FileError(path, "close");
            return std::nullopt;
        }
    } // namespace

    auto
    WriteLlvmIr(const std::filesystem::path &path, std::string_view llvmIr)
        -> std::optional<Error>
    {
        // The extension check is part of the public writer contract, not
        // cosmetic naming. It prevents a caller from labelling textual IR as
        // bitcode (or an object file) and handing a misleading artifact to
        // later toolchain stages.
        if (path.extension() != ".ll")
            return ExtensionError(path, ".ll");
        return WriteBytes(path, llvmIr.data(), llvmIr.size());
    }

    auto
    WriteBitcode(const std::filesystem::path &path,
                 const std::vector<std::uint8_t> &bitcode)
        -> std::optional<Error>
    {
        if (path.extension() != ".bc")
            return ExtensionError(path, ".bc");
        return WriteBytes(path,
                          reinterpret_cast<const char *>(bitcode.data()),
                          bitcode.size());
    }

    auto
    WriteObject(const std::filesystem::path &path,
                const std::vector<std::uint8_t> &object) -> std::optional<Error>
    {
        // Tala uses one portable source-oriented spelling for native
        // objects even on COFF hosts. The bytes still follow the selected
        // target's object format.
        if (path.extension() != ".o")
            return ExtensionError(path, ".o");
        return WriteBytes(path,
                          reinterpret_cast<const char *>(object.data()),
                          object.size());
    }

    auto
    WriteAssembly(const std::filesystem::path &path, std::string_view assembly)
        -> std::optional<Error>
    {
        if (path.extension() != ".asm")
            return ExtensionError(path, ".asm");
        return WriteBytes(path, assembly.data(), assembly.size());
    }
} // namespace Progmasoft::Tala::Backend::LLVM
