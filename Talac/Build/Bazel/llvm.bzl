"""Discovers an installed LLVM development tree for the C++20 backend and LLD."""

# The components of LLVM that LLD's COFF, ELF and Mach-O linkers use, beside
# those of the backend. They are linked into talac with LLD.
_LLD_COMPONENTS = [
    # LLD initializes every target LLVM was built for, for link-time
    # optimization.
    "all-targets",
    "debuginfocodeview",
    "debuginfodwarf",
    "debuginfomsf",
    "debuginfopdb",
    "demangle",
    "libdriver",
    "lto",
    "objcarcopts",
    "option",
    "textapi",
    "windowsdriver",
    "windowsmanifest",
]

# LLD's libraries, in the order a static link needs them: the linkers before
# what they share.
_LLD_LIBRARIES = ["lldCOFF", "lldELF", "lldMachO", "lldCommon"]

_COMPONENTS = [
    "core",
    "bitwriter",
    "passes",
    "support",
    "targetparser",
    "nativecodegen",
    "bitreader",
    "orcjit",
    "executionengine",
    "runtimedyld",
    "object",
]

def _quote(value):
    return "\"{}\"".format(value.replace("\\", "/"))

def _sanitizer_support_archive(repository_ctx, config, library_dir, library_names):
    """Exclude an optional CRT allocator override from a generated import copy.

    No upstream source, compiler flags or installed archives are changed.
    Removing this member is allowed only when no imported component references
    its private rpmalloc API; otherwise selecting a compatible LLVM is required.
    """
    tool_dir = repository_ctx.path(config).dirname
    ar = tool_dir.get_child("llvm-ar.exe")
    lib = tool_dir.get_child("llvm-lib.exe")
    nm = tool_dir.get_child("llvm-nm.exe")
    for tool in [ar, lib, nm]:
        if not tool.exists:
            fail("Windows sanitizer import requires the LLVM archive tools: {}".format(tool))
    support = library_dir.get_child("LLVMSupport.lib")
    members = repository_ctx.execute([ar, "t", support], quiet = True)
    if members.return_code != 0:
        fail("Could not inspect LLVM's allocator members:\n{}".format(members.stderr))
    overrides = [
        member.strip()
        for member in members.stdout.splitlines()
        if member.strip().replace("\\", "/").split("/")[-1] == "rpmalloc.c.obj"
    ]
    if not overrides:
        return "lib/LLVMSupport.lib"
    if len(overrides) != 1:
        fail("Expected at most one optional LLVM CRT allocator override")

    undefined = repository_ctx.execute(
        [nm, "--undefined-only", "--format=posix"] + [library_dir.get_child(name) for name in library_names],
        quiet = True,
    )
    if undefined.return_code != 0:
        fail("Could not verify LLVM allocator references:\n{}".format(undefined.stderr))
    for line in undefined.stdout.splitlines():
        fields = [field for field in line.replace("\t", " ").split(" ") if field]
        if len(fields) >= 2 and fields[1] == "U" and fields[0].startswith("rp"):
            fail("LLVM directly references rpmalloc; use an ASan-compatible development package: {}".format(fields[0]))

    repository_ctx.file("sanitizer-import/README.txt", "Generated sanitizer-only import; the installed LLVM archive is unchanged.\n")
    destination = repository_ctx.path("sanitizer-import/LLVMSupport.lib")
    copied = repository_ctx.execute([lib, "/out:{}".format(destination), support], quiet = True)
    if copied.return_code != 0:
        fail("Could not create a sanitizer-compatible LLVM import copy:\n{}".format(copied.stderr))
    removed = repository_ctx.execute([ar, "dP", destination, overrides[0]], quiet = True)
    checked = repository_ctx.execute([ar, "t", destination], quiet = True)
    remaining = [member for member in checked.stdout.splitlines() if member.strip().replace("\\", "/").split("/")[-1] == "rpmalloc.c.obj"]
    if removed.return_code != 0 or checked.return_code != 0 or remaining:
        fail("Could not exclude the optional allocator override from the generated import")
    return "sanitizer-import/LLVMSupport.lib"

def _llvm_repository_impl(repository_ctx):
    root = repository_ctx.os.environ.get("LLVM_ROOT")
    is_windows = repository_ctx.os.name.lower().startswith("windows")
    config = None
    if root:
        executable = "llvm-config.exe" if is_windows else "llvm-config"
        candidate = repository_ctx.path(root).get_child("bin").get_child(executable)
        if candidate.exists:
            config = candidate
    if config == None:
        config = repository_ctx.which("llvm-config") or repository_ctx.which("llvm-config.exe")
    if config == None:
        fail("LLVM was not found. Set LLVM_ROOT to the LLVM development tree or put llvm-config on PATH.")

    # Distribution packages do not have to put headers and archives directly
    # below --prefix. Fedora, for example, uses a versioned lib64 LLVM tree.
    # Query the selected llvm-config for each location so its headers and
    # libraries always belong to the same installation.
    include_location = repository_ctx.execute([config, "--includedir"], quiet = True)
    library_location = repository_ctx.execute([config, "--libdir"], quiet = True)
    if include_location.return_code != 0 or library_location.return_code != 0:
        fail("llvm-config could not resolve its include/library directories:\n{}\n{}".format(
            include_location.stderr,
            library_location.stderr,
        ))
    include_dir = repository_ctx.path(include_location.stdout.strip())
    library_dir = repository_ctx.path(library_location.stdout.strip())
    if not include_dir.exists or not library_dir.exists:
        fail("llvm-config reported missing include/library directories: {} and {}".format(
            include_dir,
            library_dir,
        ))

    # Distributed ThinLTO is a component of its own since LLVM 21; LLD uses
    # it where LLVM has it.
    available = repository_ctx.execute([config, "--components"], quiet = True)
    lld_components = list(_LLD_COMPONENTS)
    if available.return_code == 0 and "dtlto" in available.stdout.split(" "):
        lld_components.append("dtlto")

    libraries = repository_ctx.execute(
        [config, "--link-static", "--libnames"] + _COMPONENTS + lld_components,
        quiet = True,
    )
    if libraries.return_code != 0:
        fail("llvm-config could not resolve backend components:\n{}".format(libraries.stderr))

    library_suffix = ".lib" if is_windows else ".a"
    library_names = [
        name
        for name in libraries.stdout.replace("\r", " ").replace("\n", " ").split(" ")
        if name.endswith(library_suffix)
    ]
    if not library_names:
        fail("llvm-config returned no static libraries for the native backend")

    # Query non-LLVM dependencies from the chosen development package. LLVM's
    # compression, terminal, and XML dependencies differ between installations,
    # so a checked-in macOS library list would be brittle.
    if is_windows:
        system_linkopts = [
            "/DEFAULTLIB:advapi32.lib",
            "/DEFAULTLIB:ntdll.lib",
            "/DEFAULTLIB:ole32.lib",
            "/DEFAULTLIB:psapi.lib",
            "/DEFAULTLIB:shell32.lib",
            "/DEFAULTLIB:uuid.lib",
            "/DEFAULTLIB:ws2_32.lib",
        ]
    else:
        system_libraries = repository_ctx.execute(
            [config, "--link-static", "--system-libs"] + _COMPONENTS + lld_components,
            quiet = True,
        )
        if system_libraries.return_code != 0:
            fail("llvm-config could not resolve platform libraries:\n{}".format(system_libraries.stderr))
        system_linkopts = [
            option
            for option in system_libraries.stdout.replace("\r", " ").replace("\n", " ").split(" ")
            if option
        ]

        # Homebrew keeps zstd keg-only on Apple Silicon and Intel hosts. LLVM's
        # system library list therefore names -lzstd without making its cellar
        # visible to Apple's linker. Discover that prefix at repository analysis
        # time instead of committing an architecture-specific /opt path.
        if "-lzstd" in system_linkopts:
            brew = repository_ctx.which("brew")
            if brew:
                zstd_prefix = repository_ctx.execute(
                    [brew, "--prefix", "zstd"],
                    quiet = True,
                )
                if zstd_prefix.return_code == 0:
                    zstd_library = repository_ctx.path(zstd_prefix.stdout.strip()).get_child("lib")
                    if zstd_library.exists:
                        system_linkopts.insert(0, "-L{}".format(zstd_library))

    repository_ctx.symlink(include_dir, "include")
    repository_ctx.symlink(library_dir, "lib")

    lld_imports = _lld_imports(repository_ctx, include_dir, library_dir, library_suffix, is_windows)

    support_archive = "lib/LLVMSupport.lib"
    if is_windows and repository_ctx.os.environ.get("TALA_LLVM_SYSTEM_ALLOCATOR") == "1":
        support_archive = _sanitizer_support_archive(repository_ctx, config, library_dir, library_names)

    imports = []
    dependencies = [":headers"]
    for index, library_name in enumerate(library_names):
        target = "component_{}".format(index)
        imports.append("cc_import(name = {}, static_library = {})".format(
            _quote(target),
            _quote(support_archive if library_name == "LLVMSupport.lib" else "lib/{}".format(library_name)),
        ))
        dependencies.append(":{}".format(target))

    build = """load(\"@rules_cc//cc:cc_import.bzl\", \"cc_import\")
load(\"@rules_cc//cc:cc_library.bzl\", \"cc_library\")

package(default_visibility = [\"//visibility:public\"])

cc_library(
    name = \"headers\",
    hdrs = glob([\"include/**/*.def\", \"include/**/*.h\", \"include/**/*.inc\"]),
    includes = [\"include\"],
)

{}

cc_library(
    name = \"llvm\",
    deps = {},
    linkopts = {},
)

{}
""".format("\n".join(imports), repr(dependencies), repr(system_linkopts), lld_imports)
    repository_ctx.file("BUILD.bazel", build)

def _lld_imports(repository_ctx, include_dir, library_dir, library_suffix, is_windows):
    """The BUILD text of the `lld` target: LLD's linkers and their headers.

    The Windows release of LLVM and the libc++ toolchain of the Linux hosts
    keep LLD beside LLVM. Homebrew keeps it in a formula of its own, which
    LLD_ROOT names or `brew --prefix lld` finds.
    """
    prefix = "" if is_windows else "lib"

    def has_lld(include, library):
        return include.get_child("lld").get_child("Common").get_child("Driver.h").exists and all([
            library.get_child("{}{}{}".format(prefix, name, library_suffix)).exists
            for name in _LLD_LIBRARIES
        ])

    lld_include = include_dir
    lld_library = library_dir
    if not has_lld(lld_include, lld_library):
        root = repository_ctx.os.environ.get("LLD_ROOT")
        if not root:
            brew = repository_ctx.which("brew")
            if brew:
                found = repository_ctx.execute([brew, "--prefix", "lld"], quiet = True)
                if found.return_code == 0:
                    root = found.stdout.strip()
        if root:
            lld_include = repository_ctx.path(root).get_child("include")
            lld_library = repository_ctx.path(root).get_child("lib")
        if not root or not has_lld(lld_include, lld_library):
            fail("LLD's static libraries and headers were not found beside LLVM. Set LLD_ROOT to a tree " +
                 "with lib/ and include/lld built for this LLVM; Homebrew's lld formula has only shared libraries.")
        repository_ctx.symlink(lld_include, "lld-include")
        repository_ctx.symlink(lld_library, "lld-lib")
        header_root = "lld-include"
        library_root = "lld-lib"
    else:
        header_root = "include"
        library_root = "lib"

    text = ["""cc_library(
    name = \"lld_headers\",
    hdrs = glob([\"{root}/lld/**/*.h\"]),
    includes = [\"{root}\"],
)""".format(root = header_root)]
    previous = ":llvm"
    for name in reversed(_LLD_LIBRARIES):
        text.append("""cc_import(
    name = {target},
    static_library = {library},
    deps = [{previous}, \":lld_headers\"],
)""".format(
            target = _quote(name),
            library = _quote("{}/{}{}{}".format(library_root, prefix, name, library_suffix)),
            previous = _quote(previous),
        ))
        previous = ":" + name
    text.append("""cc_library(
    name = \"lld\",
    deps = [{}],
)""".format(", ".join([_quote(":" + name) for name in _LLD_LIBRARIES[:-1]])))
    return "\n\n".join(text)

_llvm_repository = repository_rule(
    implementation = _llvm_repository_impl,
    environ = ["LLD_ROOT", "LLVM_ROOT", "PATH", "TALA_LLVM_SYSTEM_ALLOCATOR"],
    local = True,
)

def _llvm_extension_impl(module_ctx):
    _llvm_repository(name = "llvm")

llvm = module_extension(implementation = _llvm_extension_impl)
