// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <catch2/catch_test_macros.hpp>
#include <string>
#include <string_view>
#include <vector>

#include "Talac/Linker/LinkPlan.hpp"

// The plan of a link depends on the target and, only to tell a cross link
// from a native one, on the host. Both are triples here, so every pair of
// target and host is planned on whichever host runs the tests.

namespace
{
    using Progmasoft::Tala::Driver::Linker;
    using Progmasoft::Tala::Driver::LinkPlanRequest;
    namespace Driver = Progmasoft::Tala::Driver;
    using ObjectFormat = Progmasoft::Tala::Backend::LLVM::ObjectFormat;

    constexpr std::string_view kLinux = "x86_64-unknown-linux-gnu";
    constexpr std::string_view kLinuxArm = "aarch64-unknown-linux-gnu";
    constexpr std::string_view kMusl = "x86_64-unknown-linux-musl";
    constexpr std::string_view kWindows = "x86_64-pc-windows-msvc";
    constexpr std::string_view kWindowsArm = "aarch64-pc-windows-msvc";
    constexpr std::string_view kMac = "arm64-apple-macosx15.0.0";
    constexpr std::string_view kDarwin = "arm64-apple-darwin25.0.0";

    [[nodiscard]] auto
    Request(std::string_view target, std::string_view host) -> LinkPlanRequest
    {
        return { "out/Program",     { "out/Program.o" }, std::string(target),
                 std::string(host), std::nullopt,        true,
                 std::nullopt,      std::nullopt };
    }

    [[nodiscard]] auto
    Has(const std::vector<std::string> &arguments, std::string_view argument)
        -> bool
    {
        return std::ranges::find(arguments, argument) != arguments.end();
    }
} // namespace

TEST_CASE("a target names its object format")
{
    CHECK(Driver::TargetObjectFormat(kWindows) == ObjectFormat::Coff);
    CHECK(Driver::TargetObjectFormat(kLinux) == ObjectFormat::Elf);
    CHECK(Driver::TargetObjectFormat(kMac) == ObjectFormat::MachO);
    CHECK(Driver::RuntimeLibraryName(kWindows, false) == "talart.lib");
    CHECK(Driver::RuntimeLibraryName(kWindows, true) == "talart.dll");
    CHECK(Driver::RuntimeLibraryName(kLinux, false) == "libtalart.a");
    CHECK(Driver::RuntimeLibraryName(kLinux, true) == "libtalart.so");
    CHECK(Driver::RuntimeLibraryName(kMac, false) == "libtalart.a");
    CHECK(Driver::RuntimeLibraryName(kMac, true) == "libtalart.dylib");
    CHECK(Driver::CrossRuntimeDirectory(kLinuxArm)
          == std::filesystem::path("runtimes") / "aarch64-unknown-linux-gnu");
}

TEST_CASE("a target is cross when its architecture, system or C library "
          "differs")
{
    CHECK_FALSE(Driver::IsCrossTarget(kLinux, kLinux));
    CHECK(Driver::IsCrossTarget(kLinuxArm, kLinux));
    CHECK(Driver::IsCrossTarget(kMusl, kLinux));
    CHECK(Driver::IsCrossTarget(kLinux, kWindows));
    // Every Darwin spelling is one system.
    CHECK_FALSE(Driver::IsCrossTarget(kMac, kDarwin));
}

TEST_CASE("a target of the host is linked by the host's C compiler")
{
    const auto result = Driver::PlanLink(Request(kLinux, kLinux));
    REQUIRE(result.plan);
    CHECK(result.plan->linker == Linker::HostDriver);
    CHECK(result.plan->program == "cc");
    CHECK(result.plan->arguments
          == std::vector<std::string>{ "-o", "out/Program", "out/Program.o" });
}

TEST_CASE("another Linux, macOS or BSD target is linked by clang with LLD")
{
    for (const auto &[target, host] : { std::pair{ kLinuxArm, kLinux },
                                        std::pair{ kLinux, kWindows },
                                        std::pair{ kMac, kLinux } })
    {
        auto request = Request(target, host);
        request.sysroot = "/sysroots/target";
        request.sharedRuntime = false;
        request.runtimeLibrary = "runtimes/target/libtalart.a";
        const auto result = Driver::PlanLink(request);
        REQUIRE(result.plan);
        CHECK(result.plan->linker == Linker::CrossDriver);
        CHECK(result.plan->program == "clang");
        const auto &arguments = result.plan->arguments;
        CHECK(arguments.front().starts_with("--target="));
        CHECK(Has(arguments, "-fuse-ld=lld"));
        CHECK(Has(arguments, "--sysroot=/sysroots/target"));
        CHECK(arguments.back() == "runtimes/target/libtalart.a");
        CHECK_FALSE(result.plan->besideExecutable);
    }
}

TEST_CASE("a Windows executable is linked by lld-link from every host")
{
    for (const auto host : { kWindows, kLinux, kMac })
    {
        auto request = Request(kWindows, host);
        request.sharedRuntime = false;
        request.runtimeLibrary = "talart.lib";
        request.systemImports = "out/Program.imports.lib";
        const auto result = Driver::PlanLink(request);
        REQUIRE(result.plan);
        CHECK(result.plan->linker == Linker::LldLink);
        CHECK(result.plan->program == "lld-link");
        CHECK(result.plan->machine == "x64");
        const auto &arguments = result.plan->arguments;
        CHECK(Has(arguments, "/entry:mainCRTStartup"));
        CHECK(Has(arguments, "/nodefaultlib"));
        CHECK(Has(arguments, "/machine:x64"));
        CHECK(Has(arguments, "/out:out/Program"));
        CHECK(arguments.back() == "out/Program.imports.lib");
    }
}

TEST_CASE("TalaRT is taken from its archive or from beside the executable")
{
    // The archive goes into the executable and nothing goes beside it.
    auto archive = Request(kLinux, kLinux);
    archive.sharedRuntime = false;
    archive.runtimeLibrary = "libtalart.a";
    const auto linkedIn = Driver::PlanLink(archive);
    REQUIRE(linkedIn.plan);
    CHECK(linkedIn.plan->arguments.back() == "libtalart.a");
    CHECK_FALSE(Has(linkedIn.plan->arguments, "-Wl,-rpath,$ORIGIN"));
    CHECK_FALSE(linkedIn.plan->besideExecutable);

    // The shared library is linked against, found through the run path,
    // and copied beside the executable.
    auto elfRequest = Request(kLinux, kLinux);
    elfRequest.runtimeLibrary = "libtalart.so";
    const auto elf = Driver::PlanLink(elfRequest);
    REQUIRE(elf.plan);
    CHECK(Has(elf.plan->arguments, "libtalart.so"));
    CHECK(Has(elf.plan->arguments, "-Wl,-rpath,$ORIGIN"));
    CHECK(elf.plan->besideExecutable
          == std::optional<std::filesystem::path>("libtalart.so"));

    auto mac = Request(kMac, kMac);
    mac.runtimeLibrary = "libtalart.dylib";
    const auto macho = Driver::PlanLink(mac);
    REQUIRE(macho.plan);
    CHECK(Has(macho.plan->arguments, "-Wl,-rpath,@executable_path"));

    // A Windows executable imports talart.dll through the import library
    // talac writes; the DLL itself is not an input of the link.
    auto windows = Request(kWindows, kLinux);
    windows.runtimeLibrary = "talart.dll";
    windows.systemImports = "out/Program.imports.lib";
    const auto pe = Driver::PlanLink(windows);
    REQUIRE(pe.plan);
    CHECK_FALSE(Has(pe.plan->arguments, "talart.dll"));
    CHECK(pe.plan->arguments.back() == "out/Program.imports.lib");
    CHECK(pe.plan->besideExecutable
          == std::optional<std::filesystem::path>("talart.dll"));
}

TEST_CASE("the machine of a Windows link is the target's, not the host's")
{
    const auto arm = Driver::PlanLink(Request(kWindowsArm, kWindows));
    REQUIRE(arm.plan);
    CHECK(arm.plan->machine == "arm64");
    CHECK(Has(arm.plan->arguments, "/machine:arm64"));
}

TEST_CASE("a link that cannot be planned says why")
{
    auto windows = Request(kWindows, kLinux);
    windows.sysroot = "/sysroots/windows";
    CHECK(Driver::PlanLink(windows).diagnostic.find("--sysroot")
          != std::string::npos);
    CHECK_FALSE(
        Driver::PlanLink(Request("i686-pc-windows-msvc", kWindows)).plan);
    CHECK_FALSE(
        Driver::PlanLink(Request("wasm32-unknown-unknown", kLinux)).plan);
}
