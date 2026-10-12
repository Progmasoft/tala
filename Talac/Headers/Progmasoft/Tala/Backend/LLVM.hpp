// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

#include "Progmasoft/Tala/Xmm/IR.hpp"
#include "Progmasoft/Tala/Xmm/Verifier.hpp"

namespace Progmasoft::Tala::Backend::LLVM
{
    /// Compiler Core namespace used by backend-facing IR declarations.
    namespace Core = ::tala::core;
    /// Register-based intermediate representation lowered to native code.
    namespace Xmm = ::tala::xmm;

    /// Requested optimization effort passed to LLVM's target pipeline.
    enum class OptimizationLevel : std::uint8_t
    {
        Debug,     ///< Prioritize debuggability and compilation speed.
        Less,      ///< Apply a small set of inexpensive optimizations.
        Default,   ///< Use LLVM's balanced optimization pipeline.
        Aggressive ///< Apply the target's strongest supported optimizations.
    };

    /// Native machine-code artifact kinds requested from the backend.
    enum class MachineCodeEmission : std::uint8_t
    {
        None,    ///< Emit LLVM IR and bitcode without target code generation.
        Object,  ///< Emit a relocatable native object file payload.
        Assembly ///< Emit target assembly text.
    };

    /// Object container format reported for emitted machine code.
    enum class ObjectFormat : std::uint8_t
    {
        Unknown, ///< Backend did not emit or identify an object format.
        Coff,    ///< Microsoft COFF object format.
        Elf,     ///< ELF object format.
        MachO,   ///< Apple Mach-O object format.
        Wasm     ///< WebAssembly object format.
    };

    /// Target selection, verification, and native artifact options.
    struct Options final
    {
        /// Optimization level used when creating LLVM code-generation passes.
        OptimizationLevel optimization{ OptimizationLevel::Default };
        /// LLVM target triple; empty selects the host target.
        std::string target_triple;
        /// Verify the generated module before returning it.
        bool verify_module{ true };
        /// Native output kind; None leaves check, IR, and bitcode
        /// target-neutral.
        MachineCodeEmission machineCode{ MachineCodeEmission::None };
        /// Emit the platform entry bridge for a final executable.
        bool executableEntry{};
        /// When set, define only functions owned by this project-relative file.
        /// Declarations for the other functions remain available for linking.
        std::optional<std::u32string> definition_source_file;
    };

    /// Xmm verifier diagnostic category reused by the backend.
    using IssueKind = ::Progmasoft::Tala::Xmm::IssueKind;
    /// Xmm verifier diagnostic record reused by the backend.
    using Issue = ::Progmasoft::Tala::Xmm::VerificationIssue;

    /// Failure stage when lowering Xmm or emitting a native artifact.
    enum class ErrorKind : std::uint8_t
    {
        InvalidXmm,       ///< Input Xmm failed structural or type validation.
        UnsupportedType,  ///< The backend cannot represent an X# type.
        InvalidUnicode,   ///< A name contains invalid target-facing text.
        LlvmConstruction, ///< LLVM refused to construct an IR value.
        LlvmVerification, ///< LLVM's verifier rejected the generated module.
        BitcodeEmission,  ///< LLVM could not serialize the module to bitcode.
        TargetMachine, ///< Target triple or machine configuration is invalid.
        MachineCodeEmission, ///< LLVM could not emit the requested native
                             ///< payload.
        InvalidEntryPoint,   ///< Requested executable entry does not meet its
                             ///< ABI.
        FileSystem           ///< Writing an artifact to disk failed.
    };

    /// Backend error with stable category and optional verifier issues.
    struct Error final
    {
        /// Failure category.
        ErrorKind kind{ ErrorKind::LlvmConstruction };
        /// Stable machine-readable error identifier.
        std::string code;
        /// Human-readable failure explanation.
        std::string message;
        /// Xmm verifier findings when the input module is invalid.
        std::vector<Issue> issues;
    };

    /// LLVM representations and optional native payloads owned by the caller.
    struct Artifact final
    {
        /// Human-readable LLVM IR independent of the temporary LLVM context.
        std::string llvm_ir;
        /// Serialized LLVM bitcode independent of the temporary LLVM context.
        std::vector<std::uint8_t> bitcode;
        /// Optional relocatable object bytes retained until explicitly written.
        std::vector<std::uint8_t> object;
        /// Optional target assembly text retained until explicitly written.
        std::string assembly;
        /// Resolved LLVM target triple used to produce this artifact.
        std::string target_triple;
        /// Container format of the emitted object payload, if any.
        ObjectFormat objectFormat{ ObjectFormat::Unknown };
        /// Number of function definitions lowered into the module.
        std::size_t function_count{};

        /// Check whether the required LLVM representations are missing.
        /// @return true when either LLVM IR or bitcode is empty.
        [[nodiscard]] auto
        empty() const noexcept -> bool
        {
            return llvm_ir.empty() || bitcode.empty();
        }
    };

    /// Backend output or the structured reason lowering could not complete.
    struct Result final
    {
        /// Completed LLVM artifact when lowering succeeds.
        std::optional<Artifact> artifact;
        /// Failure details when validation, lowering, or emission fails.
        std::optional<Error> error;

        /// Test whether a backend artifact was produced.
        /// @return true when artifact contains a value.
        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return artifact.has_value();
        }
    };

    /// Scalar result returned by a native ORC invocation.
    /// Only scalar alternatives with an explicitly supported host ABI are
    /// represented; type retains source signedness and width for REPL display.
    struct JitValue final
    {
        /// Exact Tala result type used for conversion and display.
        Core::Type type{ Core::Type::unit() };
        /// Host scalar payload; monostate indicates there is no scalar value.
        std::variant<std::monostate,
                     bool,
                     char32_t,
                     std::int64_t,
                     std::uint64_t,
                     double>
            payload;
    };

    /// Failure category for JIT setup, module loading, lookup, or invocation.
    enum class JitErrorKind : std::uint8_t
    {
        Initialization,
        InvalidBitcode,
        ModuleAddition,
        SymbolLookup,
        UnsupportedResult,
        Invocation,
        SignatureMismatch
    };

    /// Structured error returned by a JIT session operation.
    struct JitError final
    {
        /// Failure category.
        JitErrorKind kind{ JitErrorKind::Initialization };
        /// Stable machine-readable failure identifier.
        std::string code;
        /// Human-readable explanation of the JIT failure.
        std::string message;
    };

    /// Scalar JIT result or the error that prevented invocation.
    struct JitResult final
    {
        /// Returned scalar value when invocation succeeds.
        std::optional<JitValue> value;
        /// Structured failure when invocation is unsuccessful.
        std::optional<JitError> error;

        /// Test whether a scalar result was returned.
        /// @return true when value contains a result.
        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return value.has_value();
        }
    };

    /// Owns one process-local LLVM ORC LLJIT and every module added to it.
    ///
    /// Modules are verified before insertion. Mutation, lookup, and invocation
    /// are serialized. The callable ABI is zero-argument and scalar-result only
    /// until Tala defines an explicit ABI for richer signatures.
    class JitSession final
    {
    public:
        /// Create an empty process-local JIT session.
        JitSession();
        /// Release the JIT and every module registered in this session.
        ~JitSession();
        /// A session uniquely owns its LLVM execution state.
        JitSession(const JitSession &) = delete;
        /// Copy assignment would duplicate unique LLVM execution state.
        auto
        operator=(const JitSession &) -> JitSession & = delete;
        /// Transfer ownership of the JIT implementation.
        /// @param other Source session whose implementation is transferred.
        JitSession(JitSession &&other) noexcept;
        /// Replace this session with another session's implementation.
        /// @param other Session whose implementation is transferred.
        /// @return Reference to this session after transfer.
        auto
        operator=(JitSession &&other) noexcept -> JitSession &;

        /// Verify bitcode, add its module, and register a scalar entry point.
        /// @param bitcode Complete LLVM bitcode module to add.
        /// @param identifier Stable module identifier used by ORC.
        /// @param entrySymbol Zero-argument function registered for invocation.
        /// @param entryResultType Exact Tala result type of that function.
        /// @return Empty on success, otherwise the structured JIT error.
        [[nodiscard]] auto
        AddModule(std::span<const std::uint8_t> bitcode,
                  std::string_view identifier,
                  std::string_view entrySymbol,
                  const Core::Type &entryResultType) -> std::optional<JitError>;

        /// Remove every module and symbol previously registered in this
        /// session.
        /// @return Empty on success, otherwise the structured JIT error.
        [[nodiscard]] auto
        Reset() -> std::optional<JitError>;

        /// Find and invoke a zero-argument function using its Tala result
        /// type.
        /// @param symbol Registered function symbol to invoke.
        /// @param resultType Exact result type used for ABI-safe conversion.
        /// @return Scalar result or a structured lookup/invocation error.
        [[nodiscard]] auto
        InvokeScalar(std::string_view symbol, const Core::Type &resultType)
            -> JitResult;

    private:
        struct Impl;
        std::unique_ptr<Impl> impl_;
    };

    /// Validate Xmm without initializing LLVM state.
    /// Lower repeats verification before constructing IR, so this diagnostic
    /// helper cannot be used to bypass the backend safety boundary.
    /// @param module Xmm program to verify.
    /// @return Every structural and type-safety issue found in module.
    [[nodiscard]] auto
    Verify(const Xmm::Module &module) -> std::vector<Issue>;
    /// Lower verified Xmm to LLVM IR, bitcode, and requested native payloads.
    /// @param source Xmm program to lower.
    /// @param options Target, optimization, and emission settings.
    /// @return Backend artifact or a structured lowering/emission error.
    [[nodiscard]] auto
    Lower(const Xmm::Module &source, const Options &options = {}) -> Result;
    /// Write LLVM IR text to a file.
    /// @param path Destination file path.
    /// @param llvmIr IR text to write.
    /// @return Empty on success, otherwise a filesystem error.
    [[nodiscard]] auto
    WriteLlvmIr(const std::filesystem::path &path, std::string_view llvmIr)
        -> std::optional<Error>;
    /// Write LLVM bitcode to a file.
    /// @param path Destination file path.
    /// @param bitcode Serialized module bytes.
    /// @return Empty on success, otherwise a filesystem error.
    [[nodiscard]] auto
    WriteBitcode(const std::filesystem::path &path,
                 const std::vector<std::uint8_t> &bitcode)
        -> std::optional<Error>;
    /// Write a relocatable native object payload to a file.
    /// @param path Destination file path.
    /// @param object Object bytes emitted by LLVM.
    /// @return Empty on success, otherwise a filesystem error.
    [[nodiscard]] auto
    WriteObject(const std::filesystem::path &path,
                const std::vector<std::uint8_t> &object)
        -> std::optional<Error>;
    [[nodiscard]] auto
    WriteAssembly(const std::filesystem::path &path, std::string_view assembly)
        -> std::optional<Error>;
} // namespace Progmasoft::Tala::Backend::LLVM
  /// Write target assembly text to a file.
  /// @param path Destination file path.
  /// @param assembly Assembly text emitted by LLVM.
  /// @return Empty on success, otherwise a filesystem error.
