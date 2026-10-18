<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# LLVM backend contract

## Boundary

The LLVM backend consumes verified Xmm. It does not accept source syntax, AST, Core, CorePrep, or Xpp, and it does not infer
missing semantic information. Xmm therefore retains every item required for deterministic lowering:

- stable function symbols and spellings;
- parameter registers and parameter types;
- function result types;
- instruction result types;
- function operands distinct from ordinary virtual registers; and
- explicit basic-block terminators and targets.

CorePrep, Xpp, and Xmm verification happen before LLVM objects are constructed. Xmm owns the final native IR verifier; the
LLVM `Verify` entry remains as a source-compatible adapter and `Lower` repeats the check for direct clients. A failed check
produces structured `TAP` or `TAL` issues and no LLVM artifact.

The canonical C++ spelling is `Tala`, with PascalCase namespace segments, classes, and functions. Renewed and
existing C++ subsystems migrate toward that spelling without recreating the removed Rust naming or implementation layer.

## Sources

The lowering lives in `Talac/Backend/LLVM`, one source for each thing it lowers:

| Source | Holds |
| --- | --- |
| `Codegen.cpp` | `Lower`, the public entry: verification, the module, the order of the steps, the artifact |
| `Generator.hpp` | the generator the sources below share, with its type lowering and per-function state |
| `Generator.cpp` | declaring and defining functions, symbol names, the entry of an executable |
| `GeneratorValues.cpp` | literals, loads, calls and the ownership operations |
| `GeneratorArithmetic.cpp` | rounded division, integer powers and the checks that make an operation computable |
| `GeneratorObjects.cpp` | objects the runtime owns: closures, their thunks and destructors, memoized values |
| `GeneratorInstructions.cpp` | one Xmm instruction or terminator at a time, and runtime calls |
| `Emission.hpp`, `Emission.cpp` | optimization, the target machine and machine code |

`Generator.hpp` and `Emission.hpp` are private to the backend. Its public interface is
`Tala/Backend/LLVM.hpp`.

## Supported values

The connected slice lowers the scalar catalog, `String`, opaque nominal AARC pointers, direct calls, closure allocation,
and explicit strong/weak/unowned operations. Function types serve checked call signatures and callable values use an opaque
AARC pointer representation. Unresolved type variables remain rejected. Nominal field layout stays in type metadata; the
backend never guesses fields from a name.

Source scalar names do not inherit C widths. The frontend/Core contract selects the Tala width, and LLVM lowering
constructs the corresponding integer or floating type explicitly. Core wire
v7 transports the complete scalar catalog and source ownership. The backend
preserves each declared width, including 128-bit integer and floating types,
rather than narrowing values to host or C widths.

Source `void` is not a value. The frontend maps it once to the current resultless Core ABI marker. Tala has no source
`unit` type; the legacy native enum's unit-like spelling is private implementation vocabulary.

`String` is not a UTF-8 byte string. A constant uses an immutable LLVM array of 32-bit Unicode scalar values followed by a
zero sentinel, then calls `tala_aarc_string_literal` with the scalar count. The runtime creates an AARC `System.String` object;
the count excludes the sentinel. Invalid Unicode scalar values are rejected.

## Registers and control flow

Xmm virtual registers represent lower-level mutable storage, not LLVM SSA names. The backend allocates typed storage for each
virtual register in the function entry block, stores parameters into their assigned registers, and loads or stores values at
instruction boundaries. This preserves assignments across branches without inventing phi nodes before a dedicated SSA pass
exists.

Every branch and jump target must belong to the current function. Branch conditions must be `Bool`; returns must match the
declared function result. Calls resolve by stable symbol identity and must match their complete function signature.

Integer division uses signed LLVM division. Rounded division `//`, which the IR names `FloorDivide` for historical reasons,
rounds to the nearest integer with exact halves away from zero, as the specification requires: `7 // 2` is `4` and
`-7 // 2` is `-4`. The backend adjusts the truncated quotient by one, away from zero, when twice the remainder's magnitude
reaches the divisor's magnitude. It does not floor: `1 // 2` is `1`, not `0`.
`Talac/Backend/LLVM/Tests/ArithmeticExecutionTests.cpp` executes the specification examples and every sign
combination of small operands through both native optimizer settings.

Numeric boolean context is normalized before Xpp. A branch therefore receives a canonical boolean value rather than asking
LLVM to reinterpret every integer width differently. This keeps source semantics out of the backend and lets the Xmm
verifier require one condition shape.

## Calls and entry bridge

A function's LLVM symbol is its dotted module name, its source spelling, and
its symbol identity, for example `Demo.Main.7`. LLVM reserves every
global name that begins with `llvm.` for intrinsics and rejects a module that
defines one, while `llvm` is an ordinary namespace name in source. Such a
symbol is emitted with a leading `$`, which cannot occur in a source
identifier, for example `$llvm.Main.7`. Declarations in other
per-source objects use the same rule, so cross-object references still
resolve.

Direct calls resolve a stable function symbol to a declared function. Parameter count/types and result type are checked in
Xmm before LLVM call construction. A function symbol is not encoded as an integer or ordinary virtual register.

Project entry selection names a class whose parameterless `public static void Main()` method returns `void`. Binary emission
adds the platform bridge required by the target executable format; source code does not change to an integer-returning C
`main`. The bridge is an emission concern and does not appear in Core/Xpp/Xmm as a user declaration.

Closure allocation is connected and uses an AARC payload containing the lifted target and ordered environment slots.
Indirect invocation through that allocated value remains pending; it will use this object rather than a raw function pointer.

## Optimization and verification

The CLI optimization setting selects an LLVM new-pass-manager pipeline:

| Tala value | LLVM pipeline |
| --- | --- |
| `g` | `default<O0>` |
| `1` | `default<O1>` |
| `2` | `default<O2>` |
| `3` | `default<O3>` |

The generated module is verified before optimization. The backend builds LLVM's standard per-module optimization pipeline
with the C++ new pass manager and local analysis managers. LLVM contexts, modules, builders, printed IR streams, and bitcode
buffers have ordinary scoped C++ ownership and are released on every success or error path. The production backend does not
use the LLVM C API; the retired C backend was removed rather than retained as a compatibility implementation.

Optimization failure is an artifact failure. The backend does not serialize the pre-optimization module under the requested
output name after a selected pipeline fails. Tests should verify the module both before and after any custom pass additions.

## Target machine

`-Target` supplies a case-sensitive LLVM target triple. Without an explicit value, LLVM uses its host-dependent default.
Project target catalogs constrain an explicitly selected triple but do not implicitly select their first entry.

Target-machine creation owns:

- target lookup and diagnostic text;
- data layout and target triple on the module;
- the relocation model: position-independent code for ELF and Mach-O, whose linkers make position-independent
  executables by default and refuse an object that is not, and the default of the target for COFF;
- assembly/object file selection;
- COFF, ELF and Mach-O emission for the host target; and
- propagation of backend emission errors without leaving a plausible output.

Windows SDK and MSVC CRT/C++ development libraries are link inputs/toolchain resources. They do not make the Visual Studio
compiler or IDE part of the build architecture. ClangCL/LLD remain the native toolchain.

## Linking an executable

Talac links a native executable on every host. The entry of a program is a bridge the backend
adds for an executable and for nothing else: it calls the program's `Main` and returns zero.

| Host | Entry symbol | Linked by | Runtime library | Takes from the system |
| --- | --- | --- | --- | --- |
| Windows | `mainCRTStartup` | `lld-link`, started directly | `tala-runtime.lib` | seven functions of kernel32, through an import library made for the link |
| Linux | `main` | `cc`, the C compiler of the system, as the driver | `libtala-runtime.a` | the C library |
| macOS | `main` | `cc`, the C compiler of the system, as the driver | `libtala-runtime.a` | the system library |

On Windows an executable carries no C runtime. On Linux and macOS it is linked with the C library, which every such
system has, and with nothing of C++: the runtime library defines the allocation functions it uses over `malloc` and
`free`. The driver is used and not a linker started directly because it knows where the C library, its start-up
objects and, on macOS, the system libraries are, which differs between distributions and releases. The runtime
library stands beside the compiler under the name of the table; `develop build` puts it there.

A program that needs a value that cannot be computed stops at an instruction the processor refuses. Windows reports
the exception as the status of the process. Elsewhere the process is ended by a signal, and `tazel run` reports it the
way a shell does, 128 and the number of the signal.

## Artifacts

Ordinary pipeline execution keeps printed LLVM IR and serialized bitcode in memory. Disk access occurs only through explicit
artifact APIs:

- `WriteLlvmIr` accepts only a `.ll` path;
- `WriteBitcode` accepts only a `.bc` path;
- `WriteObject` accepts only a `.o` path; and
- `WriteAssembly` accepts only a `.asm` path.

`talac --emit=llvm-ir` writes the sibling `.ll` file and `talac --emit=llvm-bitcode` writes the sibling `.bc` file for either
`.tala` or `TACR` Core input. `talac --emit=object|assembly` writes target-machine output. Binary emission creates an
executable entry bridge, emits a temporary object, invokes LLD through a typed C++20 argument vector, verifies the executable,
and removes the temporary object. `--emit=metadata` generates no code. Xpp and Xmm artifact codecs are separate C++20 stage-owned
readers/writers; they are not LLVM-backend operations.

The Haskell frontend is the sole source owner. The backend remains responsible for target lowering and the driver remains
responsible for linking; no compatibility frontend, shell command construction, or DIMCLI route is used.

## Error discipline

The backend rejects rather than guesses when it encounters:

- an unverified Xmm module;
- duplicate function or register identity;
- a call whose symbol/signature does not match;
- a branch whose condition is not canonical `Bool`;
- a return inconsistent with the declared result;
- a named/type-variable value without a layout;
- an invalid Unicode scalar in a string constant;
- indirect invocation through an allocated closure value;
- an unsupported target or target-machine emission kind; or
- a requested file extension inconsistent with the writer API.

Errors include stage and relevant symbol/block/register context, but LLVM handles and internal object addresses are not part
of the public diagnostic contract.

## Backend extension checklist

Before adding a new value or instruction:

1. define its source/Core semantics in the owning frontend layer;
2. ensure the Core wire carries every required type/value without lossy reuse;
3. lower it through CorePrep, Xpp, and Xmm with verifier coverage at each boundary;
4. define target-independent representation before choosing LLVM layout;
5. specify ABI alignment, ownership, calling convention, and destruction where relevant;
6. add valid and malformed native tests;
7. verify textual IR and a target artifact where supported; and
8. update implementation status rather than presenting partial support as complete.

This sequence prevents an LLVM convenience type from becoming an accidental language or public ABI decision.
