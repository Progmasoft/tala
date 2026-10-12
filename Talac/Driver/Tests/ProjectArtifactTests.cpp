// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "Talac/Driver/ProjectArtifacts.hpp"

namespace
{
    namespace Artifacts = Progmasoft::Tala::Driver::ProjectArtifacts;

    class TemporaryDirectory final
    {
    public:
        TemporaryDirectory()
        {
            static std::atomic_uint64_t sequence{};
            const auto clock
                = std::chrono::steady_clock::now().time_since_epoch().count();
            const auto serial
                = sequence.fetch_add(1U, std::memory_order_relaxed);
            path_ = std::filesystem::temp_directory_path()
                    / ("tala-project-artifact-tests-" + std::to_string(clock)
                       + "-" + std::to_string(serial));
            created_ = std::filesystem::create_directory(path_);
        }

        TemporaryDirectory(const TemporaryDirectory &) = delete;
        auto
        operator=(const TemporaryDirectory &) -> TemporaryDirectory & = delete;

        ~TemporaryDirectory()
        {
            if (created_)
            {
                std::error_code ignored;
                std::filesystem::remove_all(path_, ignored);
            }
        }

        [[nodiscard]] auto
        Path() const -> const std::filesystem::path &
        {
            return path_;
        }

        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return created_;
        }

    private:
        std::filesystem::path path_;
        bool created_{};
    };

    [[nodiscard]] auto
    ReadText(const std::filesystem::path &path) -> std::string
    {
        std::ifstream stream(path, std::ios::binary);
        return { std::istreambuf_iterator<char>(stream),
                 std::istreambuf_iterator<char>() };
    }

    [[nodiscard]] auto
    Bytes(const std::string_view text) -> std::vector<std::uint8_t>
    {
        std::vector<std::uint8_t> bytes;
        bytes.reserve(text.size());
        for (const auto character : text)
            bytes.push_back(static_cast<std::uint8_t>(character));
        return bytes;
    }
} // namespace

TEST_CASE("project output flattens source paths to stable basenames")
{
    const std::vector<std::u32string> sources{
        U"Sources/Client/Main.tala",
        U"Sources/Library/Codec.tala",
        U"Generated/Empty.tala",
    };

    const auto objects = Artifacts::PlanSourceOutputs(sources, ".o");
    REQUIRE(objects);
    REQUIRE(objects.outputs.size() == sources.size());
    CHECK(objects.outputs[0].source_file == sources[0]);
    CHECK(objects.outputs[0].file_name == "Main.o");
    CHECK(objects.outputs[1].file_name == "Codec.o");
    CHECK(objects.outputs[2].file_name == "Empty.o");

    const auto assembly = Artifacts::PlanSourceOutputs(sources, ".asm");
    REQUIRE(assembly);
    CHECK(assembly.outputs[0].file_name == "Main.asm");
    CHECK(assembly.outputs[1].file_name == "Codec.asm");
}

TEST_CASE("project output rejects flattened collisions before any writes")
{
    const std::vector<std::u32string> sources{
        U"Sources/App/Main.tala",
        U"Sources/Shared/Main.tala",
    };

    const auto plan = Artifacts::PlanSourceOutputs(sources, ".o");
    REQUIRE_FALSE(plan);
    CHECK(plan.outputs.empty());
    CHECK(plan.diagnostic.find("same output name") != std::string::npos);
}

TEST_CASE("project output collision checking follows Windows case rules")
{
    const std::vector<std::u32string> sources{
        U"Sources/Main.tala",
        U"Sources/main.tala",
    };

    const auto plan = Artifacts::PlanSourceOutputs(sources, ".asm");
    REQUIRE_FALSE(plan);
    CHECK(plan.diagnostic.find("same output name") != std::string::npos);
}

TEST_CASE("source output planning rejects roots traversal and non-source paths")
{
    const std::vector<std::vector<std::u32string>> invalid_catalogs{
        { U"/outside/Main.tala" },       { U"C:/outside/Main.tala" },
        { U"Sources/../Main.tala" },     { U"Sources/./Main.tala" },
        { U"Sources\\Main.tala" },       { U"Sources//Main.tala" },
        { U"Sources/Main.cpp" },         { U"Sources/.tala" },
        { U"Sources/Broken\U0001f600" },
    };

    for (const auto &sources : invalid_catalogs)
    {
        const auto plan = Artifacts::PlanSourceOutputs(sources, ".o");
        CHECK_FALSE(plan);
        CHECK(plan.outputs.empty());
    }
}

TEST_CASE("source output planning rejects malformed Unicode scalars")
{
    std::u32string malformed = U"Sources/";
    malformed.push_back(static_cast<char32_t>(0xd800U));
    malformed += U".tala";
    const std::vector<std::u32string> sources{ malformed };

    const auto plan = Artifacts::PlanSourceOutputs(sources, ".o");
    REQUIRE_FALSE(plan);
    CHECK(plan.diagnostic.find("normalized relative") != std::string::npos);
}

TEST_CASE("source catalog rejects duplicate physical paths")
{
    const std::vector<std::u32string> sources{
        U"Sources/Main.tala",
        U"Sources/Main.tala",
    };

    const auto plan = Artifacts::PlanSourceOutputs(sources, ".o");
    REQUIRE_FALSE(plan);
    CHECK(plan.outputs.empty());
    CHECK(plan.diagnostic.find("repeats a source path") != std::string::npos);
}

TEST_CASE("source catalog rejects Windows device names before output planning")
{
    const std::vector<std::u32string> reserved_stems{
        U"CON.tala",  U"conin$.tala", U"PRN.tala",  U"AUX.tala",
        U"NUL.tala",  U"COM1.tala",   U"COM9.tala", U"LPT1.tala",
        U"LPT9.tala", U"COM¹.tala",   U"COM².tala", U"COM³.tala",
        U"LPT¹.tala", U"LPT².tala",   U"LPT³.tala", U"Sources/CON.debug.tala",
    };

    for (const auto &source : reserved_stems)
    {
        const std::vector<std::u32string> sources{ source };
        const auto plan = Artifacts::PlanSourceOutputs(sources, ".o");
        CHECK_FALSE(plan);
        CHECK(plan.diagnostic.find("portable output name")
              != std::string::npos);
    }
}

TEST_CASE("source output names reject characters not portable to Windows")
{
    const std::vector<std::u32string> invalid_stems{
        U"bad<name.tala",  U"bad>name.tala",  U"bad\"name.tala",
        U"bad|name.tala",  U"bad?name.tala",  U"bad*name.tala",
        U"bad\nname.tala", U"bad\tname.tala", U"bad\u007Fname.tala",
    };

    for (const auto &source : invalid_stems)
    {
        CAPTURE(source);
        const std::vector<std::u32string> sources{ source };
        const auto plan = Artifacts::PlanSourceOutputs(sources, ".asm");
        CAPTURE(plan.diagnostic);
        CHECK_FALSE(plan);
        CHECK(plan.diagnostic.find("portable output name")
              != std::string::npos);
    }
}

TEST_CASE("source output planning is a stable bijection over large catalogs")
{
    for (const std::size_t count : { 1U, 2U, 7U, 64U, 257U })
    {
        std::vector<std::u32string> sources;
        sources.reserve(count);
        for (std::size_t index = 0U; index < count; ++index)
        {
            const auto number = std::to_string(index);
            std::u32string source = U"Packages/Example/Source";
            for (const auto digit : number)
                source.push_back(static_cast<char32_t>(digit));
            source += U".tala";
            sources.push_back(std::move(source));
        }

        const auto objectPlan = Artifacts::PlanSourceOutputs(sources, ".o");
        const auto assemblyPlan = Artifacts::PlanSourceOutputs(sources, ".asm");
        REQUIRE(objectPlan);
        REQUIRE(assemblyPlan);
        REQUIRE(objectPlan.outputs.size() == count);
        REQUIRE(assemblyPlan.outputs.size() == count);
        for (std::size_t index = 0U; index < count; ++index)
        {
            const auto number = std::to_string(index);
            const auto expectedStem = "Source" + number;
            CHECK(objectPlan.outputs[index].source_file == sources[index]);
            CHECK(assemblyPlan.outputs[index].source_file == sources[index]);
            CHECK(objectPlan.outputs[index].file_name == expectedStem + ".o");
            CHECK(assemblyPlan.outputs[index].file_name
                  == expectedStem + ".asm");
        }

        const auto repeated = Artifacts::PlanSourceOutputs(sources, ".o");
        REQUIRE(repeated);
        CHECK(repeated.outputs == objectPlan.outputs);
    }
}

TEST_CASE("source output planning retains valid non-ASCII basenames as UTF-8")
{
    const std::vector<std::u32string> sources{ U"Sources/Пример.tala" };

    const auto plan = Artifacts::PlanSourceOutputs(sources, ".o");
    REQUIRE(plan);
    REQUIRE(plan.outputs.size() == 1U);
    CHECK(plan.outputs.front().file_name
          == "\xd0\x9f\xd1\x80\xd0\xb8\xd0\xbc\xd0\xb5\xd1\x80.o");
}

TEST_CASE("source output planning only accepts supported native formats")
{
    const std::vector<std::u32string> sources{ U"Main.tala" };

    for (const auto extension : { std::string_view{ ".ll" },
                                  std::string_view{ ".bc" },
                                  std::string_view{ ".obj" },
                                  std::string_view{} })
    {
        const auto plan = Artifacts::PlanSourceOutputs(sources, extension);
        CHECK_FALSE(plan);
    }
    CHECK_FALSE(Artifacts::PlanSourceOutputs({}, ".o"));
}

TEST_CASE("project artifact batches replace only named files and keep siblings")
{
    TemporaryDirectory directory;
    REQUIRE(directory);
    const auto output = directory.Path() / "build" / "debug";
    std::filesystem::create_directories(output);
    std::ofstream(output / "Main.o", std::ios::binary) << "old object";
    std::ofstream(output / "notes.txt", std::ios::binary) << "keep";
    const std::vector<Artifacts::ArtifactFile> files{
        { "Main.o", Bytes("new main") },
        { "Helper.o", Bytes("new helper") },
    };

    const auto error = Artifacts::CommitArtifactFiles(output, files);
    REQUIRE_FALSE(error.has_value());
    CHECK(ReadText(output / "Main.o") == "new main");
    CHECK(ReadText(output / "Helper.o") == "new helper");
    CHECK(ReadText(output / "notes.txt") == "keep");
}

TEST_CASE("project artifact batch accepts an intentionally empty source object")
{
    TemporaryDirectory directory;
    REQUIRE(directory);
    const std::vector<Artifacts::ArtifactFile> files{
        { "Empty.o", {} },
        { "OnlyComments.asm", {} },
    };

    const auto error = Artifacts::CommitArtifactFiles(directory.Path(), files);
    REQUIRE_FALSE(error.has_value());
    CHECK(std::filesystem::exists(directory.Path() / "Empty.o"));
    CHECK(std::filesystem::file_size(directory.Path() / "Empty.o") == 0U);
    CHECK(std::filesystem::file_size(directory.Path() / "OnlyComments.asm")
          == 0U);
}

TEST_CASE("project artifact preflight preserves old files if any target is a "
          "directory")
{
    TemporaryDirectory directory;
    REQUIRE(directory);
    std::ofstream(directory.Path() / "Main.o", std::ios::binary)
        << "must survive";
    std::filesystem::create_directory(directory.Path() / "Helper.o");
    const std::vector<Artifacts::ArtifactFile> files{
        { "Main.o", Bytes("replacement") },
        { "Helper.o", Bytes("not a directory") },
    };

    const auto error = Artifacts::CommitArtifactFiles(directory.Path(), files);
    REQUIRE(error.has_value());
    CHECK(error->find("is a directory") != std::string::npos);
    CHECK(ReadText(directory.Path() / "Main.o") == "must survive");
    CHECK(std::filesystem::is_directory(directory.Path() / "Helper.o"));
}

TEST_CASE("project artifact preflight rejects duplicate names without mutation")
{
    TemporaryDirectory directory;
    REQUIRE(directory);
    std::ofstream(directory.Path() / "Main.o", std::ios::binary) << "stable";
    const std::vector<Artifacts::ArtifactFile> files{
        { "Main.o", Bytes("first") },
        { "main.o", Bytes("second") },
    };

    const auto error = Artifacts::CommitArtifactFiles(directory.Path(), files);
    REQUIRE(error.has_value());
    CHECK(error->find("colliding name") != std::string::npos);
    CHECK(ReadText(directory.Path() / "Main.o") == "stable");
}

TEST_CASE(
    "project artifact validation never treats nested names as destinations")
{
    TemporaryDirectory directory;
    REQUIRE(directory);
    const std::vector<Artifacts::ArtifactFile> files{
        { "../outside.o", Bytes("unsafe") },
    };

    const auto error = Artifacts::CommitArtifactFiles(directory.Path(), files);
    REQUIRE(error.has_value());
    CHECK_FALSE(
        std::filesystem::exists(directory.Path().parent_path() / "outside.o"));
}

TEST_CASE("project artifact validation rejects drive and device path syntax")
{
    TemporaryDirectory directory;
    REQUIRE(directory);
    const std::vector<std::string> unsafe_names{
        "C:outside.o", "CON.o",  "COM1.o",    "LPT9.asm",  "bad?.o",
        "bad*.o",      "bad|.o", "trailing.", "trailing ",
    };

    for (const auto &name : unsafe_names)
    {
        const std::vector<Artifacts::ArtifactFile> files{
            { name, Bytes("must not be created") },
        };
        const auto error
            = Artifacts::CommitArtifactFiles(directory.Path() / "out", files);
        CAPTURE(name);
        CHECK(error.has_value());
        CHECK_FALSE(std::filesystem::exists(directory.Path() / "out"));
    }
}

TEST_CASE("project artifact validation rejects malformed UTF-8 names")
{
    TemporaryDirectory directory;
    REQUIRE(directory);

    std::vector<std::string> invalid_names;
    for (const auto &malformed : {
             std::string{ "\xc0\xaf" },         // overlong two-byte encoding
             std::string{ "\xe0\x80\xaf" },     // overlong three-byte encoding
             std::string{ "\xed\xa0\x80" },     // UTF-16 surrogate
             std::string{ "\xf4\x90\x80\x80" }, // above U+10FFFF
             std::string{ "\xe2\x28\xa1" },     // invalid continuation byte
             std::string{ "\xf0\x9f\x8c" },     // truncated scalar
             std::string{ "\x80" },             // stray continuation byte
         })
    {
        invalid_names.push_back(malformed + ".o");
    }

    for (const auto &name : invalid_names)
    {
        const std::vector<Artifacts::ArtifactFile> files{
            { name, Bytes("not committed") },
        };
        const auto error
            = Artifacts::CommitArtifactFiles(directory.Path() / "out", files);
        CAPTURE(name.size());
        REQUIRE(error.has_value());
        CHECK(error->find("basename") != std::string::npos);
        CHECK_FALSE(std::filesystem::exists(directory.Path() / "out"));
    }
}

TEST_CASE("project artifact batches accept only compiler native suffixes")
{
    TemporaryDirectory directory;
    REQUIRE(directory);

    for (const auto name : { "Main.obj", "Main.exe", "Main.ll", "Main.O" })
    {
        const std::vector<Artifacts::ArtifactFile> files{
            { name, Bytes("unsupported format") },
        };
        const auto error
            = Artifacts::CommitArtifactFiles(directory.Path() / "out", files);
        CAPTURE(name);
        REQUIRE(error.has_value());
        CHECK(error->find("only .o and .asm") != std::string::npos);
        CHECK_FALSE(std::filesystem::exists(directory.Path() / "out"));
    }
}

TEST_CASE("UTF-8 object basenames are written as native filesystem paths")
{
    TemporaryDirectory directory;
    REQUIRE(directory);
    const std::vector<Artifacts::ArtifactFile> files{
        { "Örnek.o", Bytes("utf8 object") },
    };

    const auto error = Artifacts::CommitArtifactFiles(directory.Path(), files);
    REQUIRE_FALSE(error.has_value());
    const auto output = directory.Path() / std::filesystem::path(u8"Örnek.o");
    CHECK(std::filesystem::is_regular_file(output));
    CHECK(ReadText(output) == "utf8 object");
}

TEST_CASE("binary artifact replacement preserves exact bytes for every unit")
{
    TemporaryDirectory directory;
    REQUIRE(directory);
    const auto output = directory.Path() / "build" / "debug";
    std::filesystem::create_directories(output);
    std::ofstream(output / "Unit0.o", std::ios::binary) << "old";

    const std::vector<Artifacts::ArtifactFile> files{
        { "Unit0.o", { 0U, 1U, 0U, 127U, 128U, 255U } },
        { "Unit1.o", {} },
        { "Unit2.asm", Bytes("line one\r\nline two\r\n") },
    };
    const auto error = Artifacts::CommitArtifactFiles(output, files);

    REQUIRE_FALSE(error.has_value());
    std::ifstream binary(output / "Unit0.o", std::ios::binary);
    const std::vector<std::uint8_t> actual{ std::istreambuf_iterator<char>(
                                                binary),
                                            std::istreambuf_iterator<char>() };
    CHECK(actual == files.front().bytes);
    CHECK(std::filesystem::file_size(output / "Unit1.o") == 0U);
    CHECK(ReadText(output / "Unit2.asm") == "line one\r\nline two\r\n");
    for (const auto &entry : std::filesystem::directory_iterator(output))
        CHECK(entry.path().filename().string().find(".tala-artifacts-")
              == std::string::npos);
}

TEST_CASE("project artifact batches reject an empty commit")
{
    TemporaryDirectory directory;
    REQUIRE(directory);

    const auto error = Artifacts::CommitArtifactFiles(directory.Path(), {});
    REQUIRE(error.has_value());
    CHECK(error->find("batch is empty") != std::string::npos);
    CHECK(std::filesystem::is_empty(directory.Path()));
}

TEST_CASE("project artifact output must be a directory, not an existing file")
{
    TemporaryDirectory directory;
    REQUIRE(directory);
    const auto output = directory.Path() / "build";
    std::ofstream(output, std::ios::binary) << "keep as a file";
    const std::vector<Artifacts::ArtifactFile> files{
        { "Main.o", Bytes("object") },
    };

    const auto error = Artifacts::CommitArtifactFiles(output, files);
    REQUIRE(error.has_value());
    CHECK(error->find("create project output directory") != std::string::npos);
    CHECK(ReadText(output) == "keep as a file");
}

TEST_CASE("replacing a symlink artifact does not overwrite its referent")
{
    TemporaryDirectory directory;
    REQUIRE(directory);
    const auto referent = directory.Path() / "original.bin";
    const auto destination = directory.Path() / "Main.o";
    std::ofstream(referent, std::ios::binary) << "outside artifact";
    std::error_code link_error;
    std::filesystem::create_symlink(referent, destination, link_error);
    if (link_error)
        SKIP("the current host account cannot create a symbolic link");

    const std::vector<Artifacts::ArtifactFile> files{
        { "Main.o", Bytes("new object") },
    };
    const auto error = Artifacts::CommitArtifactFiles(directory.Path(), files);
    REQUIRE_FALSE(error.has_value());
    CHECK(ReadText(destination) == "new object");
    CHECK_FALSE(std::filesystem::is_symlink(destination));
    CHECK(ReadText(referent) == "outside artifact");
}

TEST_CASE("project artifact transaction removes only its own staging directory")
{
    TemporaryDirectory directory;
    REQUIRE(directory);
    std::ofstream(directory.Path() / "user-data.txt", std::ios::binary)
        << "preserve";
    const std::vector<Artifacts::ArtifactFile> files{
        { "Main.o", Bytes("compiled") },
    };

    const auto error = Artifacts::CommitArtifactFiles(directory.Path(), files);
    REQUIRE_FALSE(error.has_value());
    CHECK(ReadText(directory.Path() / "user-data.txt") == "preserve");
    for (const auto &entry :
         std::filesystem::directory_iterator(directory.Path()))
        CHECK(entry.path().filename().string().find(".tala-artifacts-")
              == std::string::npos);
}

TEST_CASE("project artifact writer creates a missing output tree safely")
{
    TemporaryDirectory directory;
    REQUIRE(directory);
    const auto output = directory.Path() / "build" / "release";
    const std::vector<Artifacts::ArtifactFile> files{
        { "Program.asm", Bytes(".text\n") },
    };

    const auto error = Artifacts::CommitArtifactFiles(output, files);
    REQUIRE_FALSE(error.has_value());
    CHECK(ReadText(output / "Program.asm") == ".text\n");
}
