// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <cstdint>
#include <limits>
#include <llvm/Bitcode/BitcodeReader.h>
#include <llvm/ExecutionEngine/Orc/ExecutionUtils.h>
#include <llvm/ExecutionEngine/Orc/LLJIT.h>
#include <llvm/ExecutionEngine/Orc/ThreadSafeModule.h>
#include <llvm/IR/Function.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Module.h>
#include <llvm/IR/Verifier.h>
#include <llvm/Support/Error.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/TargetSelect.h>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#ifdef _WIN32
// Only the Windows linking layer below needs these. Other hosts build against
// distribution LLVM releases whose memory manager has no reservation mode.
#    include <llvm/ExecutionEngine/Orc/RTDyldObjectLinkingLayer.h>
#    include <llvm/ExecutionEngine/SectionMemoryManager.h>
#endif

#include "Progmasoft/Tala/Backend/LLVM.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"

namespace Progmasoft::Tala::Backend::LLVM
{
    namespace
    {
        constexpr std::size_t kMaximumJitBitcodeBytes
            = std::size_t{ 256U } * 1024U * 1024U;

        [[nodiscard]] auto
        IsSupportedInvocationType(const Core::Type &type) -> bool
        {
            if (type.kind == Core::Type::Kind::Unit)
                return true;
            const auto scalar = tala::core::describe_scalar(type);
            if (!scalar)
                return false;
            using tala::core::ScalarFamily;
            switch (scalar->family)
            {
                case ScalarFamily::Boolean:
                case ScalarFamily::Character:
                    return true;
                case ScalarFamily::SignedInteger:
                case ScalarFamily::UnsignedInteger:
                    return scalar->bit_width == 8U || scalar->bit_width == 16U
                           || scalar->bit_width == 32U
                           || scalar->bit_width == 64U;
                case ScalarFamily::Floating:
                    return scalar->bit_width == 32U || scalar->bit_width == 64U;
                case ScalarFamily::None:
                    return false;
            }
            return false;
        }

        [[nodiscard]] auto
        MatchesInvocationType(const llvm::Function &function,
                              const Core::Type &type) -> bool
        {
            if (function.getCallingConv() != llvm::CallingConv::C
                || function.isVarArg() || !function.arg_empty())
                return false;
            const auto *llvmResult = function.getReturnType();
            if (type.kind == Core::Type::Kind::Unit)
                return llvmResult->isVoidTy();
            const auto scalar = tala::core::describe_scalar(type);
            if (!scalar)
                return false;
            using tala::core::ScalarFamily;
            switch (scalar->family)
            {
                case ScalarFamily::Boolean:
                    return llvmResult->isIntegerTy(1U);
                case ScalarFamily::Character:
                    return llvmResult->isIntegerTy(32U);
                case ScalarFamily::SignedInteger:
                case ScalarFamily::UnsignedInteger:
                    return llvmResult->isIntegerTy(scalar->bit_width);
                case ScalarFamily::Floating:
                    return scalar->bit_width == 32U   ? llvmResult->isFloatTy()
                           : scalar->bit_width == 64U ? llvmResult->isDoubleTy()
                                                      : false;
                case ScalarFamily::None:
                    return false;
            }
            return false;
        }

        [[nodiscard]] auto
        MakeJitError(JitErrorKind kind, std::string code, std::string message)
            -> JitError
        {
            return JitError{ kind, std::move(code), std::move(message) };
        }

        // ORC machine code has no Clang function-sanitizer metadata prefix.
        // That checker reads before the entry address, potentially outside the
        // executable mapping. Only this foreign-code call skips that checker;
        // ASan and all other UBSan checks remain enabled. InvokeScalar
        // validates the LLVM signature and host calling convention before
        // reaching here.
        template<typename Native>
#if defined(__clang__)
        __attribute__((no_sanitize("function")))
#endif
        auto
        InvokeMachineCode(llvm::orc::ExecutorAddr address) -> Native
        {
            using Function = Native (*)();
            return address.toPtr<Function>()();
        }

        [[nodiscard]] auto
        InvokeAddress(llvm::orc::ExecutorAddr address, const Core::Type &type)
            -> JitResult
        {
            // The generated functions use LLVM's host C calling convention.
            // Keep every C++ function-pointer type exact; calling a function
            // through a wider or signedness-incompatible type would be
            // undefined behavior.
            const auto invoke = [&]<typename Native>() -> Native {
                return InvokeMachineCode<Native>(address);
            };
            const auto integerResult = [&](auto value) {
                return JitResult{ JitValue{ type,
                                            static_cast<std::int64_t>(value) },
                                  std::nullopt };
            };
            const auto unsignedResult = [&](auto value) {
                return JitResult{ JitValue{ type,
                                            static_cast<std::uint64_t>(value) },
                                  std::nullopt };
            };
            const auto unsupported = [&] {
                return JitResult{ std::nullopt,
                                  MakeJitError(
                                      JitErrorKind::UnsupportedResult,
                                      "TAL4010",
                                      "this Tala scalar width has no "
                                      "portable host invocation ABI yet") };
            };

            if (type.kind == Core::Type::Kind::Unit)
            {
                invoke.template operator()<void>();
                return JitResult{ JitValue{ type, std::monostate{} },
                                  std::nullopt };
            }
            const auto scalar = tala::core::describe_scalar(type);
            if (!scalar)
                return { std::nullopt,
                         MakeJitError(JitErrorKind::UnsupportedResult,
                                      "TAL4009",
                                      "ORC invocation currently requires a "
                                      "scalar or void expression result") };

            using tala::core::ScalarFamily;
            switch (scalar->family)
            {
                case ScalarFamily::Boolean:
                    return { JitValue{ type,
                                       invoke.template operator()<bool>() },
                             std::nullopt };
                case ScalarFamily::Character:
                    return { JitValue{ type,
                                       invoke.template operator()<char32_t>() },
                             std::nullopt };
                case ScalarFamily::SignedInteger:
                    switch (scalar->bit_width)
                    {
                        case 8:
                            return integerResult(
                                invoke.template operator()<std::int8_t>());
                        case 16:
                            return integerResult(
                                invoke.template operator()<std::int16_t>());
                        case 32:
                            return integerResult(
                                invoke.template operator()<std::int32_t>());
                        case 64:
                            return integerResult(
                                invoke.template operator()<std::int64_t>());
                        default:
                            return unsupported();
                    }
                case ScalarFamily::UnsignedInteger:
                    switch (scalar->bit_width)
                    {
                        case 8:
                            return unsignedResult(
                                invoke.template operator()<std::uint8_t>());
                        case 16:
                            return unsignedResult(
                                invoke.template operator()<std::uint16_t>());
                        case 32:
                            return unsignedResult(
                                invoke.template operator()<std::uint32_t>());
                        case 64:
                            return unsignedResult(
                                invoke.template operator()<std::uint64_t>());
                        default:
                            return unsupported();
                    }
                case ScalarFamily::Floating:
                    switch (scalar->bit_width)
                    {
                        case 32:
                            return {
                                JitValue{
                                    type,
                                    static_cast<double>(
                                        invoke.template operator()<float>()) },
                                std::nullopt
                            };
                        case 64:
                            return { JitValue{
                                         type,
                                         invoke.template operator()<double>() },
                                     std::nullopt };
                        default:
                            return unsupported();
                    }
                case ScalarFamily::None:
                    break;
            }
            return unsupported();
        }
    } // namespace

    struct JitSession::Impl final
    {
        struct LoadedModule final
        {
            llvm::orc::ResourceTrackerSP tracker;
            std::string entrySymbol;
            Core::Type entryResultType;
        };

        std::unique_ptr<llvm::orc::LLJIT> jit;
        std::optional<JitError> initializationError;
        std::vector<LoadedModule> modules;
        std::unordered_map<std::string, Core::Type> entries;
        std::mutex mutex;

        Impl()
        {
            // Native target registration is process-wide, but the actual JIT
            // and its resource trackers remain owned by this session instance.
            if (llvm::InitializeNativeTarget()
                || llvm::InitializeNativeTargetAsmPrinter())
            {
                initializationError = MakeJitError(
                    JitErrorKind::Initialization,
                    "TAL4001",
                    "LLVM could not initialize the host execution target");
                return;
            }

            llvm::orc::LLJITBuilder builder;
#ifdef _WIN32
            // Win64 unwind tables use image-relative relocations, which
            // RuntimeDyld can only apply when no section of an object
            // lies below the lowest one it has already seen. The default
            // memory manager maps code and data sections separately, so
            // the host decides their order and some address layouts
            // abort linking with "relocation requires an ordered section
            // layout". Reserving one contiguous block per object fixes
            // the order: every section is carved from that reservation.
            builder.setObjectLinkingLayerCreator(
                [](llvm::orc::ExecutionSession &session)
                    -> llvm::Expected<std::unique_ptr<llvm::orc::ObjectLayer>> {
                    auto layer
                        = std::make_unique<llvm::orc::RTDyldObjectLinkingLayer>(
                            session,
                            [](const llvm::MemoryBuffer &) {
                                return std::make_unique<
                                    llvm::SectionMemoryManager>(nullptr, true);
                            });
                    // Same COFF symbol-flag handling as LLJIT's default
                    // linking layer.
                    layer->setOverrideObjectFlagsWithResponsibilityFlags(true);
                    layer->setAutoClaimResponsibilityForObjectSymbols(true);
                    return layer;
                });
#endif
            auto created = builder.create();
            if (!created)
            {
                initializationError
                    = MakeJitError(JitErrorKind::Initialization,
                                   "TAL4002",
                                   llvm::toString(created.takeError()));
                return;
            }
            jit = std::move(*created);

            // The process generator is the bridge for runtime symbols that are
            // intentionally linked into a hosting executable. Modules that only
            // use language intrinsics do not need to resolve one.
            auto processSymbols = llvm::orc::DynamicLibrarySearchGenerator::
                GetForCurrentProcess(jit->getDataLayout().getGlobalPrefix());
            if (!processSymbols)
            {
                initializationError
                    = MakeJitError(JitErrorKind::Initialization,
                                   "TAL4003",
                                   llvm::toString(processSymbols.takeError()));
                jit.reset();
                return;
            }
            jit->getMainJITDylib().addGenerator(std::move(*processSymbols));
        }
    };

    JitSession::JitSession()
        : impl_(std::make_unique<Impl>())
    {}

    JitSession::~JitSession() = default;

    JitSession::JitSession(JitSession &&) noexcept = default;

    auto
    JitSession::operator=(JitSession &&) noexcept -> JitSession & = default;

    auto
    JitSession::AddModule(std::span<const std::uint8_t> bitcode,
                          std::string_view identifier,
                          std::string_view entrySymbol,
                          const Core::Type &entryResultType)
        -> std::optional<JitError>
    {
        if (!impl_)
            return MakeJitError(JitErrorKind::Initialization,
                                "TAL4004",
                                "the moved-from ORC session is not usable");
        std::scoped_lock lock(impl_->mutex);
        if (impl_->initializationError)
            return impl_->initializationError;
        if (!impl_->jit)
            return MakeJitError(JitErrorKind::Initialization,
                                "TAL4005",
                                "LLVM ORC is not initialized");
        if (bitcode.empty())
            return MakeJitError(JitErrorKind::InvalidBitcode,
                                "TAL4006",
                                "cannot add an empty LLVM bitcode module");
        if (bitcode.size() > kMaximumJitBitcodeBytes)
            return MakeJitError(
                JitErrorKind::InvalidBitcode,
                "TAL4007",
                "LLVM bitcode exceeds the 256 MiB session limit");
        if (identifier.empty())
            return MakeJitError(JitErrorKind::InvalidBitcode,
                                "TAL4008",
                                "LLVM JIT module identifier cannot be empty");
        if (entrySymbol.empty())
            return MakeJitError(JitErrorKind::SignatureMismatch,
                                "TAL4020",
                                "LLVM JIT entry symbol cannot be empty");
        if (impl_->entries.contains(std::string(entrySymbol)))
            return MakeJitError(
                JitErrorKind::SignatureMismatch,
                "TAL4021",
                "LLVM JIT entry symbol is already registered in this session");
        if (!IsSupportedInvocationType(entryResultType))
            return MakeJitError(JitErrorKind::UnsupportedResult,
                                "TAL4010",
                                "this Tala scalar width has no portable "
                                "host invocation ABI yet");

        auto context = std::make_unique<llvm::LLVMContext>();
        const auto *data = reinterpret_cast<const char *>(bitcode.data());
        auto buffer = llvm::MemoryBuffer::getMemBufferCopy(
            llvm::StringRef(data, bitcode.size()),
            identifier);
        auto parsed
            = llvm::parseBitcodeFile(buffer->getMemBufferRef(), *context);
        if (!parsed)
            return MakeJitError(JitErrorKind::InvalidBitcode,
                                "TAL4011",
                                llvm::toString(parsed.takeError()));

        auto *entry = (**parsed).getFunction(
            llvm::StringRef(entrySymbol.data(), entrySymbol.size()));
        if (entry == nullptr || entry->isDeclaration()
            || !MatchesInvocationType(*entry, entryResultType))
            return MakeJitError(
                JitErrorKind::SignatureMismatch,
                "TAL4022",
                "LLVM JIT entry must be a defined zero-argument function with "
                "the declared X# result ABI");

        std::string verification;
        llvm::raw_string_ostream diagnostics(verification);
        if (llvm::verifyModule(**parsed, &diagnostics))
        {
            diagnostics.flush();
            return MakeJitError(JitErrorKind::InvalidBitcode,
                                "TAL4012",
                                verification.empty()
                                    ? "LLVM rejected the JIT module"
                                    : std::move(verification));
        }

        auto tracker = impl_->jit->getMainJITDylib().createResourceTracker();
        llvm::orc::ThreadSafeModule threadSafeModule(std::move(*parsed),
                                                     std::move(context));
        if (auto addError
            = impl_->jit->addIRModule(tracker, std::move(threadSafeModule)))
        {
            const auto message = llvm::toString(std::move(addError));
            if (auto removeError = tracker->remove())
                llvm::consumeError(std::move(removeError));
            return MakeJitError(JitErrorKind::ModuleAddition,
                                "TAL4013",
                                message);
        }
        impl_->modules.push_back(Impl::LoadedModule{ std::move(tracker),
                                                     std::string(entrySymbol),
                                                     entryResultType });
        impl_->entries.emplace(std::string(entrySymbol), entryResultType);
        return std::nullopt;
    }

    auto
    JitSession::Reset() -> std::optional<JitError>
    {
        if (!impl_)
            return MakeJitError(JitErrorKind::Initialization,
                                "TAL4018",
                                "the moved-from ORC session is not usable");
        std::scoped_lock lock(impl_->mutex);
        while (!impl_->modules.empty())
        {
            if (auto removeError = impl_->modules.back().tracker->remove())
                return MakeJitError(JitErrorKind::ModuleAddition,
                                    "TAL4019",
                                    llvm::toString(std::move(removeError)));
            impl_->entries.erase(impl_->modules.back().entrySymbol);
            impl_->modules.pop_back();
        }
        return std::nullopt;
    }

    auto
    JitSession::InvokeScalar(std::string_view symbol,
                             const Core::Type &resultType) -> JitResult
    {
        if (!impl_)
            return { std::nullopt,
                     MakeJitError(JitErrorKind::Initialization,
                                  "TAL4014",
                                  "the moved-from ORC session is not usable") };
        std::scoped_lock lock(impl_->mutex);
        if (impl_->initializationError)
            return { std::nullopt, impl_->initializationError };
        if (!impl_->jit)
            return { std::nullopt,
                     MakeJitError(JitErrorKind::Initialization,
                                  "TAL4015",
                                  "LLVM ORC is not initialized") };
        if (symbol.empty())
            return { std::nullopt,
                     MakeJitError(JitErrorKind::SymbolLookup,
                                  "TAL4016",
                                  "LLVM JIT symbol name cannot be empty") };

        const auto registered = impl_->entries.find(std::string(symbol));
        if (registered == impl_->entries.end())
            return { std::nullopt,
                     MakeJitError(JitErrorKind::SymbolLookup,
                                  "TAL4017",
                                  "LLVM JIT symbol was not registered as a "
                                  "callable module entry") };
        if (registered->second != resultType)
            return { std::nullopt,
                     MakeJitError(JitErrorKind::SignatureMismatch,
                                  "TAL4023",
                                  "requested Tala result type does not "
                                  "match the registered entry type") };

        if (resultType.kind != Core::Type::Kind::Unit)
        {
            const auto scalar = tala::core::describe_scalar(resultType);
            if (!scalar)
                return { std::nullopt,
                         MakeJitError(JitErrorKind::UnsupportedResult,
                                      "TAL4009",
                                      "ORC invocation currently requires a "
                                      "scalar or void expression result") };
            const bool supportedWidth
                = scalar->family == tala::core::ScalarFamily::Boolean
                  || scalar->family == tala::core::ScalarFamily::Character
                  || ((scalar->family == tala::core::ScalarFamily::SignedInteger
                       || scalar->family
                              == tala::core::ScalarFamily::UnsignedInteger)
                      && scalar->bit_width <= 64U)
                  || (scalar->family == tala::core::ScalarFamily::Floating
                      && (scalar->bit_width == 32U
                          || scalar->bit_width == 64U));
            if (!supportedWidth)
                return { std::nullopt,
                         MakeJitError(JitErrorKind::UnsupportedResult,
                                      "TAL4010",
                                      "this Tala scalar width has no "
                                      "portable host invocation ABI yet") };
        }

        auto found
            = impl_->jit->lookup(llvm::StringRef(symbol.data(), symbol.size()));
        if (!found)
            return { std::nullopt,
                     MakeJitError(JitErrorKind::SymbolLookup,
                                  "TAL4017",
                                  llvm::toString(found.takeError())) };
        return InvokeAddress(*found, resultType);
    }
} // namespace Progmasoft::Tala::Backend::LLVM
