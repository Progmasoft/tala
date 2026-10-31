// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <filesystem>
#include <llvm/ADT/SmallString.h>
#include <llvm/Support/FileSystem.h>
#include <string>
#include <system_error>

#include "Talac/Driver/IncrementalBuild.hpp"

namespace
{
    namespace Incremental = Progmasoft::Tala::Driver::Incremental;
    namespace Llvm = Progmasoft::Tala::Backend::LLVM;
    namespace core = tala::core;
    namespace xmm = tala::xmm;

    constexpr std::u32string_view kFirst = U"Sources/First.tala";
    constexpr std::u32string_view kSecond = U"Sources/Second.tala";
    constexpr std::u32string_view kThird = U"Sources/Third.tala";

    /// A function of [source] that returns nothing and, when [callee] is
    /// given, moves that function into a register first.
    [[nodiscard]] auto
    Function(const std::uint32_t id,
             std::u32string spelling,
             const std::u32string_view source,
             const tala::xpp::SymbolId callee = 0U) -> xmm::Function
    {
        xmm::Function function;
        function.symbol = { id, std::move(spelling) };
        function.source_file = std::u32string(source);
        xmm::Block block;
        block.terminator.kind = xmm::Terminator::Kind::Return;
        if (callee != 0U)
        {
            xmm::Instruction call;
            call.opcode = xmm::Opcode::Call;
            xmm::Value target;
            target.kind = xmm::Value::Kind::Function;
            target.symbol = callee;
            call.operands.push_back(target);
            block.instructions.push_back(std::move(call));
        }
        function.blocks.push_back(std::move(block));
        return function;
    }

    /// `Main` in the first source calls `Helper` in the second; the third
    /// has `Other`, which nobody calls.
    [[nodiscard]] auto
    Program() -> xmm::Module
    {
        xmm::Module module;
        module.name = { U"Demo" };
        module.source_files = { std::u32string(kFirst),
                                std::u32string(kSecond),
                                std::u32string(kThird) };
        module.functions = { Function(1U, U"Main", kFirst, 2U),
                             Function(2U, U"Helper", kSecond),
                             Function(3U, U"Other", kThird) };
        return module;
    }

    [[nodiscard]] auto
    Key(const xmm::Module &module, const std::u32string_view source)
        -> std::string
    {
        return Incremental::SourceKey(module, std::u32string(source), "context")
            .value();
    }

    /// A directory of its own for one test, removed afterwards.
    struct Directory final
    {
        std::filesystem::path path;

        Directory()
        {
            llvm::SmallString<128> created;
            if (!llvm::sys::fs::createUniqueDirectory("talac-incremental",
                                                      created))
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

    [[nodiscard]] auto
    Objects(const std::filesystem::path &directory) -> std::size_t
    {
        std::size_t count{};
        for (const auto &entry : std::filesystem::directory_iterator(directory))
            count += entry.path().extension() == ".o" ? 1U : 0U;
        return count;
    }
} // namespace

TEST_CASE("the key of a source follows its own functions")
{
    const auto before = Program();
    auto changed = Program();
    changed.functions[0].blocks[0].instructions.clear();
    CHECK(Key(before, kFirst) != Key(changed, kFirst));
    CHECK(Key(before, kFirst) == Key(Program(), kFirst));
    CHECK(Key(before, kSecond) == Key(changed, kSecond));
}

TEST_CASE("the key of a source sees the signature of what it calls, not its "
          "body")
{
    const auto before = Program();

    auto body = Program();
    xmm::Instruction added;
    body.functions[1].blocks[0].instructions.push_back(added);
    CHECK(Key(before, kFirst) == Key(body, kFirst));
    CHECK(Key(before, kSecond) != Key(body, kSecond));

    auto signature = Program();
    signature.functions[1].parameter_types.push_back(core::Type::boolean());
    CHECK(Key(before, kFirst) != Key(signature, kFirst));
}

TEST_CASE("the key of a source does not see what it does not call")
{
    const auto before = Program();
    auto other = Program();
    other.functions[2].parameter_types.push_back(core::Type::boolean());
    CHECK(Key(before, kFirst) == Key(other, kFirst));
}

TEST_CASE("the key of a source sees how the object is made")
{
    const auto module = Program();
    const auto source = std::u32string(kFirst);
    CHECK(Incremental::SourceKey(module, source, "O0")
          != Incremental::SourceKey(module, source, "O2"));
}

TEST_CASE("sources without a function have objects of their own")
{
    const Directory directory;
    xmm::Module program;
    program.name = { U"Demo" };
    program.source_files = { std::u32string(kFirst),
                             std::u32string(kSecond),
                             std::u32string(kThird) };
    program.functions = { Function(1U, U"Main", kFirst) };

    CHECK(Key(program, kSecond) != Key(program, kThird));

    const auto built = Incremental::BuildObjects(program,
                                                 Llvm::Options{},
                                                 directory.path,
                                                 "");
    REQUIRE_FALSE(built.error);
    CHECK(built.recompiled == 3U);
    CHECK(Objects(directory.path) == 4U);
}

TEST_CASE("only the sources whose key is new are lowered")
{
    const Directory directory;
    Llvm::Options options;

    auto program = Program();
    program.functions[0].blocks[0].instructions.clear();

    const auto first
        = Incremental::BuildObjects(program, options, directory.path, "");
    REQUIRE_FALSE(first.error);
    CHECK(first.sources == 3U);
    CHECK(first.recompiled == 3U);
    CHECK(first.objects.size() == 4U);
    CHECK(Objects(directory.path) == 4U);

    const auto again
        = Incremental::BuildObjects(program, options, directory.path, "");
    REQUIRE_FALSE(again.error);
    CHECK(again.recompiled == 0U);
    CHECK(again.objects == first.objects);

    program.functions[1].symbol.spelling = U"Renamed";
    const auto third
        = Incremental::BuildObjects(program, options, directory.path, "");
    REQUIRE_FALSE(third.error);
    CHECK(third.recompiled == 1U);
    // The object of the old body is gone, not kept for later.
    CHECK(Objects(directory.path) == 4U);
}
