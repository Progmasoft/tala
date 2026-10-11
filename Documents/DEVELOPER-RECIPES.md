# Developer command shortcuts

The root `justfile` is optional. It delegates to the existing Go helper
commands with `go run`; it does not implement a second build graph or copy
the helpers' platform detection, installation, testing or cleanup logic.
Bazel, Cabal and Gradle remain the build owners.

```text
just                         # Go developer command reference
just --list                  # Available recipes
just prebuild-check          # Required host tools
just prebuild-install        # Install missing required host tools
just optional-check          # Optional packages and developer utilities
just optional-install        # Install missing optional packages
just build
just test
just benchmark
just fuzz
just fuzz-stress
just fuzz-thread             # TSan run of threaded fuzz targets on a supported host
just sanitize                # ASan + UBSan
just sanitize-thread         # Separate TSan run on a supported host
just verify-helpers
just verify-docs
just verify-examples
just verify-benchmarks
just repo-info
just incremental-clean-build
just cold-clean-build
just clean
```

`clean` and `cold-clean-build` remove generated build state; use them
deliberately. Installing packages changes the host. The `check` recipes and
`just --dry-run <recipe>` do not install packages.

To bootstrap just itself, run the optional-packages helper directly:

```text
go run ./helpers/cmd/optional-packages install
go run ./helpers/cmd/optional-packages check
```

It supports the hosts `prebuild` supports: Windows 10/11 with WinGet, macOS
15/26 with Homebrew, Ubuntu 26.04 LTS with apt, and Fedora 43 with dnf. On
Linux it runs the package manager through `sudo` unless it is root, and on
Ubuntu it refreshes the package lists once, before the first package it
installs. Its package-manager workflow includes just, ripgrep (`rg`)
and jq alongside the existing optional benchmark toolchains. Installed
packages are skipped; opening a new terminal may be necessary after an
installation changes PATH. A package being installed and its executable
being usable are separate checks. Rustup components still require a
previously selected toolchain; the helper does not install a Rust toolchain.

Advanced arguments go directly to the relevant Go command rather than being
interpolated through a second command parser in a recipe.
