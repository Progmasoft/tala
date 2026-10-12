# Native error handling

Tala's owned C++20 compiler, Interactive, test, benchmark and fuzz
translation units are compiled with `-fno-exceptions`. Windows passes the
same Clang option through `clang-cl`. This policy does not change a
dependency's compiler options or require dependencies to disable exceptions.

## Recoverable failures

Use `llvm::Expected<T>` when an operation either produces a value or fails,
and `llvm::Error` when it has no value to return. Existing explicit compiler
result/diagnostic models remain valid; a new exception layer must not replace
them. Inspect each result and propagate or consume its error exactly once.
Do not discard an error just to keep a command running.

`DenseBitSet::Create` validates a caller-supplied universe size before
allocation. Its set-algebra operations return an error for incompatible
universes and leave the destination unchanged. Their callers can print,
propagate or attach context to that error without stack unwinding.

The direct `DenseBitSet` constructor is for representable, internally known
sizes. An oversized size violates its precondition and terminates with an
invariant diagnostic. Use `Create` for external sizes. Allocation failure is
not converted into a recoverable size-validation error.

For filesystem operations, prefer overloads accepting `std::error_code` and
convert failures using `llvm::errorCodeToError`. A compiler built without
exceptions must not rely on catching errors from throwing filesystem APIs.
Disabling exceptions is not, by itself, an audit of every standard-library or
dependency call; those API boundaries still need individual review.

## Invariants and fuzz oracles

`llvm::cantFail` is appropriate only where the caller establishes an invariant,
such as equal finite universes created by one analysis. It is not an input
validation mechanism and must not wrap arbitrary user-controlled failures.

A fuzz oracle detecting an inconsistent verified wire round trip or a
miscompile terminates with `llvm::report_fatal_error`. That is an unexpected
compiler defect, not a normal invalid-source diagnostic. LibFuzzer can retain
the input that caused the crash without an exception crossing its C ABI.
Benchmark fixture corruption is likewise fatal rather than a timed workload.
Corpus creation failures instead produce a normal command error and nonzero
exit status.

## Dependency boundaries

Owned warning, exception, sanitizer and coverage compile options use Bazel's
per-file filters. Dependency translation units keep their own flags. System
header adapters separate upstream-header diagnostics from owned-code warnings;
they contain no owned implementation logic.

Linking sanitizer runtimes is still necessary for instrumented executables.
On Windows, `/MT` requires Clang's static-CRT ASan thunk. The ordinary dynamic
thunk can initialize ASan without intercepting the executable's static CRT
allocations; the negative runtime probe must diagnose a real use-after-free.

Some Windows LLVM development archives also contain an optional rpmalloc CRT
override. The ASan profile selects a generated import copy of `LLVMSupport.lib`
without that override member. The original installed archive, dependency source
and dependency compiler options remain unchanged. Before excluding the member,
the importer checks that none of the imported LLVM components directly references
its private allocator API; an incompatible package fails instead of silently
dropping required functions. Normal, non-ASan imports are unchanged.

Uninstrumented dependency code and prebuilt LLVM libraries are not covered by
the same native instrumentation. GHC-generated frontend code is not covered
by Clang's branch-coverage instrumentation either. Neither exception-free
compilation nor passing sanitizer tests proves complete memory safety.

## Generated code calls

ORC entry points do not carry Clang's function-sanitizer metadata before their
machine-code address. Reading that prefix can itself access an unmapped page.
Only the typed `InvokeMachineCode` bridge disables the `function` checker;
ASan and the remaining UBSan checks stay enabled. Before invoking the bridge,
the session verifies the LLVM return type, parameter count, varargs status and
host calling convention. A mismatch is rejected, never coerced into a call.
