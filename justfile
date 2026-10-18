# SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
# SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

# Recipes only delegate to Go helpers. Bazel and Cabal keep ownership
# of their build graphs; this file is an optional command shortcut layer.
set windows-shell := ["powershell.exe", "-NoLogo", "-NoProfile", "-Command"]

# Show the developer helper's command reference.
default:
    @go run ./helpers/cmd/develop --help

# Check the development host without installing packages.
doctor:
    go run ./helpers/cmd/develop doctor

prebuild-check:
    go run ./helpers/cmd/prebuild check

prebuild-install:
    go run ./helpers/cmd/prebuild install

optional-check:
    go run ./helpers/cmd/optional-packages check

optional-install:
    go run ./helpers/cmd/optional-packages install

build:
    go run ./helpers/cmd/develop build

test:
    go run ./helpers/cmd/develop test

benchmark:
    go run ./helpers/cmd/develop benchmark

fuzz:
    go run ./helpers/cmd/develop fuzz

# Threaded fuzz targets under ThreadSanitizer; macOS and native Linux only.
fuzz-thread:
    go run ./helpers/cmd/develop fuzz-thread

fuzz-stress:
    go run ./helpers/cmd/develop fuzz-stress

sanitize:
    go run ./helpers/cmd/develop sanitize address-undefined

# clang-tidy over every first-party C++ translation unit.
tidy:
    go run ./helpers/cmd/develop tidy

sanitize-thread:
    go run ./helpers/cmd/develop sanitize thread

incremental-clean-build:
    go run ./helpers/cmd/develop incremental-clean-build

cold-clean-build:
    go run ./helpers/cmd/develop cold-clean-build

verify-helpers:
    go run ./helpers/cmd/verify-helpers

verify-docs:
    go run ./helpers/cmd/verify-docs

verify-examples:
    go run ./helpers/cmd/verify-examples

verify-benchmarks:
    go run ./helpers/cmd/verify-benchmarks

repo-info:
    go run ./helpers/cmd/repo-info

clean:
    go run ./helpers/cmd/develop clean
