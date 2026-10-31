<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0 -->

# Project native artifacts

This document describes project-wide object and assembly emission from a
verified Core artifact. It is an implementation contract for the connected
compiler route; it does not add source syntax, a build setting, or a new
CLI option.

## Emission model

The compiler selects an output kind with `--emit` when several sources are
compiled as one program. An executable build still produces exactly one native executable. A project `object`
or `assembly` build instead produces one native artifact for every physical
source unit in the selected entry namespace's Core catalog:

| Build output | Per-source file | Container behavior |
| --- | --- | --- |
| `object` | `.o` | one target object per source unit |
| `assembly` | `.asm` | one target assembly file per source unit |
| `executable` | the executable | one executable for the selected entry |

The emitted `.o` suffix is intentionally stable across supported host systems.
The file contents are still target objects: for example, an object built for a
Windows target contains COFF rather than ELF or Mach-O. The name does not
promise that an arbitrary external linker can consume a mismatched target.

Project build mode chooses the destination root. With the default debug output,
`Sources/MyApp/Main.tala` becomes `build/debug/Main.o`; release mode uses the
configured release output root. The source directory hierarchy is not copied
under the output directory. This makes output placement independent of source
root spelling and matches the project's existing flat artifact layout.

An explicit single-file build is a separate route. It emits its selected
artifact beside the explicit `.tala` or intermediate input using the input's
basename; it does not enumerate sibling files and does not enter the project
batch transaction described below.

## Namespace boundary

The Haskell frontend currently builds one Core module per compiled namespace.
The selected entry namespace's module crosses the native boundary. Its source
catalog contains the physical files assigned to that namespace, not every file
in unrelated namespaces in the project. Other discovered namespaces are still
checked by the frontend, but cross-namespace native imports and a multi-module
link unit are separate compiler work.

Within the selected namespace, two files may declare different types or
methods and are merged before stable symbol identity is assigned. A source
file can also contribute no declaration; it remains in the source catalog and
receives an empty object or assembly artifact. The compiler does not infer file
ownership from namespace spelling, directory structure, function names, or
function ids.

Every lowered function keeps its source owner. Closure lifting inherits the
enclosing declaration's owner, so a generated closure function is emitted with
the source that caused its generation. A catalog entry without a function is
still meaningful and causes an output unit to be emitted.

## Source identity

The versioned Core, CorePrep, Xpp, and Xmm models carry source provenance:

```text
module source catalog: ordered, unique project-relative .tala paths
function source owner: exactly one catalog path for project modules
```

The path is slash-normalized, non-empty, relative, and ends in the exact
lowercase `.tala` extension. Verifiers reject, rather than repair, rooted
paths, drive syntax, backslashes, empty path segments, `.` and `..` segments,
embedded NUL, malformed Unicode scalars, and duplicate catalog entries. The
same utility validates these paths at each native IR boundary.

The wire catalog order follows deterministic frontend source order. That order
is preserved by the adapters, but output names are planned from each basename
and not from catalog order. Reordering a source catalog cannot select a
different function body for a file.

The physical path is provenance, not semantic identity. `SymbolId` remains the
identity of a declaration; moving a declaration to another file changes its
owner metadata but does not make name resolution depend on the path. An
explicit single-file module may omit project ownership metadata. A project
object/assembly build requires a complete, valid catalog and owners for every
function in the selected module.

Current wire versions are Core v10, CorePrep v8, Xpp v7, and Xmm v7. Older
versions are rejected by their owning reader. The new fields are part of the
schema and are not silently defaulted when reading an older project artifact.
See [Artifact wire contracts](ARTIFACT-WIRE.md) for field order, decoding
limits, and compatibility policy.

## Output name planning

For every catalog entry, the planner extracts the final path segment, removes
the `.tala` suffix, encodes the remaining Unicode scalars as UTF-8, and appends
the selected native extension. A few examples:

| Source identity | Object output | Assembly output |
| --- | --- | --- |
| `Sources/MyApp/Main.tala` | `Main.o` | `Main.asm` |
| `Library/JsonReader.tala` | `JsonReader.o` | `JsonReader.asm` |
| `Generated/Empty.tala` | `Empty.o` | `Empty.asm` |
| `Türkçe/Örnek.tala` | `Örnek.o` | `Örnek.asm` |

Flattening deliberately makes equal stems ambiguous. For example,
`Sources/Client/Main.tala` and `Sources/Tests/Main.tala` cannot both produce
`Main.o` in the same output directory. The planner rejects the whole set and
reports the colliding output basename before touching existing artifacts.

The planner rejects host-dependent output names. This includes control bytes,
path separators, `<`, `>`, `:`, `"`, `|`, `?`, `*`, trailing dot or space,
malformed UTF-8, and Win32 device basenames such as `CON`, `NUL`, `COM1`,
`LPT9`, and the reserved superscript-digit forms `COM¹`/`LPT³`, regardless of
the current host. Valid Unicode source stems are converted through the native
UTF-8 filesystem path constructor, not the machine's active narrow code page.
ASCII case-folded collisions are rejected during the side-effect-free
planning pass. A temporary probe on the destination filesystem catches
additional case- or normalization-equivalent names whose comparison rules
differ by filesystem.

Source paths remain case-sensitive Tala identities. The filesystem probe
does not change that language rule; it only prevents two distinct source
identities from mapping to one physical output name on a case-insensitive
volume.

## Per-source lowering

The driver reads and verifies the Core artifact, runs the Core-to-CorePrep
adapter, lowers through Xpp and Xmm, and validates all source metadata before
asking the backend for artifacts. It then performs a separate LLVM target
lowering for each planned source owner.

Every partition contains the declarations needed to type-check direct calls,
but only the functions owned by the selected source are emitted with bodies.
Functions owned by another source stay external declarations. This permits the
object files to reference one another without placing duplicate definitions in
every output. Target data layout, LLVM verification, optimization, and object
or assembly emission are still owned by the LLVM backend.

All requested LLVM modules are lowered successfully before output replacement
starts. Therefore a malformed Xmm module, unsupported target operation, LLVM
verification failure, or target-machine failure cannot leave half of the new
object set in place. The source catalog must be non-empty, and every source
must be usable as an output basename before LLVM emission begins.

Each source is emitted even if it owns no function. Its object may contain
target metadata but no definitions; its assembly may contain target directives
but no executable body. This is intentional. Omitting the file would make the
output list cease to represent the selected compilation-unit set and would
make adding a declaration later change the build's output topology.

## Replacement and failure behavior

Project outputs overwrite matching files without prompting. Only basenames in
the current plan are replaced. Unrelated files and outputs left by an older,
larger source catalog are not deleted; pruning stale build products belongs to
an explicit clean operation.

The native driver first keeps all generated bytes in memory, then asks the
artifact writer to commit the batch:

1. Validate every destination basename and reject duplicate names.
2. Create the output directory if it does not exist.
3. Reserve a unique `.tala-artifacts-*` directory beside the destinations so
   staging and final renames stay on the same filesystem.
4. For Unicode output names, probe the destination filesystem for equivalent
   names. ASCII batches rely on the earlier case-folded collision check.
5. Write and close every staged file under a short private transaction name
   before moving any old destination.
6. Inspect all existing destinations and reject a directory at any planned
   file path before replacing the first file.
7. Move old matching files or symlinks into private backups, then rename staged
   files into their final destinations.
8. Remove the private staging and backup tree after a successful commit.

If a later rename fails, the writer rolls back in reverse installation order:
newly installed outputs are removed, then saved originals are restored. If
rollback itself cannot remove or restore a destination, the writer retains the
staging directory and backups and includes its path in the diagnostic. This
keeps the only recovery copy from being silently deleted; the operator can
inspect that directory and restore the affected `old-N` backup entry.

The batch protocol provides error recovery while the compiler process is
running. It is not a crash-consistent database transaction: power loss or
process termination during the sequence of filesystem renames can expose a
partially replaced set and leave a staging directory. Each individual rename
is used only for a sibling path; the operating system does not provide one
atomic rename for a set of multiple files.

The writer uses `symlink_status` so an existing symlink is treated as the
destination entry, not followed and overwritten at its referent. Replacing a
symlink leaves the file it pointed to untouched. A directory at a planned
output path is an error; the writer does not recursively delete it.

## Diagnostics and user-visible behavior

The driver reports the source name that failed target lowering and names the
planned destination when an artifact is written. Planning and verification
errors are reported before publishing any output. A successful project object
build is therefore observable as one output per catalog entry, not one merged
object and not a single output named after the project.

`check` remains non-writing. `binary` remains a one-file executable route and
does not create one executable per source. The output kind is selected by the
existing CLI precedence rules; source partitioning is not persisted as a
setting.

## Current limits

- The native project route consumes the selected namespace module. Cross-
  namespace import binding, separate namespace objects, and a multi-module
  linker input are not implemented by this change.
- The format emits one object/assembly per source, but it does not add a new
  project-level link command or automatically link the objects independently.
- Output names are flat basenames. Directory-preserving output layouts and
  user-configurable collision renaming are not supported.
- The entire output set is buffered before commit. Very large projects can
  therefore use memory proportional to the combined emitted object or
  assembly sizes.
- Existing stale outputs are intentionally preserved. The compiler does not
  infer ownership of arbitrary neighboring files from a prior build; pruning
  is the responsibility of an explicit project clean operation.

These limits are explicit so the implementation does not imply a linker,
cross-namespace module model, or crash-recovery journal that it does not yet
provide.

## Test ownership

The relevant tests are kept with their owners:

- `Talac/Artifact/Tests/SourcePathTests.cpp` covers canonical source identity
  and portable path rejection.
- `Talac/Core/Tests/CorePipelineTests.cpp` covers the non-empty Haskell v10
  golden, metadata propagation through Xpp/Xmm, per-source object and assembly
  output, empty source units, and collision preservation.
- `Talac/Driver/Tests/ProjectArtifactTests.cpp` covers flattening,
  collisions, existing-file replacement, destination validation, symlinks,
  and preservation of unrelated outputs.
- `Talac/Haskell/Driver/test/SourceSetTests.hs` covers project source
  discovery, namespace ownership, deterministic paths, empty source retention,
  and Core wire round trips.

Run the focused native tests with:

```powershell
bazelisk build //Talac/Artifact/Tests:source_path_tests `
  //Talac/Core/Tests:core_pipeline_tests `
  //Talac/Driver/Tests:project_artifact_tests
.\bazel-bin\Talac\Artifact\Tests\source_path_tests.exe
.\bazel-bin\Talac\Core\Tests\core_pipeline_tests.exe
.\bazel-bin\Talac\Driver\Tests\project_artifact_tests.exe
```

The Haskell ownership and wire tests are part of `cabal test all` from the
`Talac/` directory. The repository-wide `go run ./helpers/cmd/develop test`
also builds and runs the native owner suites on supported hosts.
