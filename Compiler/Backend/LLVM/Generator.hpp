// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

// The generator that lowers verified Xmm to an LLVM module, as the sources of
// this directory share it. Nothing outside the LLVM backend includes this
// header: the public interface of the backend is
// `Visual/XSharp/Backend/LLVM.hpp`.

#include <cstdint>
#include <llvm/IR/DerivedTypes.h>
#include <llvm/IR/Function.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/IR/Instructions.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Module.h>
#include <llvm/TargetParser/Triple.h>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "Visual/XSharp/Backend/LLVM.hpp"
#include "Visual/XSharp/Core/Callable.hpp"
#include "Visual/XSharp/Core/Ownership.hpp"
#include "Visual/XSharp/Core/RuntimeCall.hpp"
#include "Visual/XSharp/Core/Scalar.hpp"

namespace Visual::XSharp::Backend::LLVM::Generation
{
    namespace core = ::visual_xsharp::core;
    namespace xmm = ::visual_xsharp::xmm;

    /// A result that holds the given error and no artifact.
    [[nodiscard]] auto
    Failure(ErrorKind kind, std::string code, std::string message) -> Result;

    /// The dotted name of a module in UTF-8, unless a part is not Unicode.
    [[nodiscard]] auto
    ModuleName(const xmm::Module &module) -> std::optional<std::string>;

    /// The LLVM symbol of a function: module, spelling and symbol identity.
    [[nodiscard]] auto
    SymbolName(const xmm::Module &module, const xmm::Function &function)
        -> std::optional<std::string>;

    struct TypeLowerer final
    {
        llvm::LLVMContext &context;

        explicit TypeLowerer(llvm::LLVMContext &llvmContext)
            : context(llvmContext)
        {}

        [[nodiscard]] auto
        Lower(const core::Type &type) const -> llvm::Type *
        {
            switch (type.kind)
            {
                case core::Type::Kind::Unit:
                    return llvm::Type::getVoidTy(context);
                case core::Type::Kind::Bool:
                    return llvm::Type::getInt1Ty(context);
                case core::Type::Kind::Character:
                    return llvm::Type::getInt32Ty(context);
                case core::Type::Kind::Int8:
                case core::Type::Kind::UInt8:
                    return llvm::Type::getInt8Ty(context);
                case core::Type::Kind::Int16:
                case core::Type::Kind::UInt16:
                    return llvm::Type::getInt16Ty(context);
                case core::Type::Kind::Int64:
                case core::Type::Kind::UInt64:
                    return llvm::Type::getInt64Ty(context);
                case core::Type::Kind::Int32:
                case core::Type::Kind::UInt32:
                    return llvm::Type::getInt32Ty(context);
                case core::Type::Kind::Int128:
                case core::Type::Kind::UInt128:
                    return llvm::IntegerType::get(context, 128U);
                case core::Type::Kind::Float16:
                    return llvm::Type::getHalfTy(context);
                case core::Type::Kind::Float32:
                    return llvm::Type::getFloatTy(context);
                case core::Type::Kind::Float64:
                    return llvm::Type::getDoubleTy(context);
                case core::Type::Kind::Float128:
                    return llvm::Type::getFP128Ty(context);
                case core::Type::Kind::String:
                case core::Type::Kind::Function:
                    // A function value is an AARC closure pointer. Direct
                    // function declarations build their LLVM FunctionType
                    // in FunctionType().
                case core::Type::Kind::Named:
                    // Nominal AARC values are opaque at this boundary.
                    // Concrete field layout belongs to the type metadata
                    // and allocation lowering.
                    return llvm::PointerType::get(context, 0);
                case core::Type::Kind::TypeVariable:
                    return nullptr;
            }
            return nullptr;
        }
    };

    struct FunctionState final
    {
        // Xmm virtual registers model typed mutable storage, not LLVM SSA
        // definitions. Slots preserve assignments across control-flow joins
        // without manufacturing phi nodes whose semantics have not yet been
        // established by an Xmm analysis pass.
        const xmm::Function *source{};
        llvm::Function *value{};
        llvm::FunctionType *type{};
        std::unordered_map<xmm::BlockId, llvm::BasicBlock *> blocks;
        std::unordered_map<xmm::VirtualRegister, llvm::AllocaInst *> slots;
        std::unordered_map<xmm::VirtualRegister, core::Type> register_types;
    };

    struct Generator final
    {
        llvm::LLVMContext &context;
        llvm::Module &module;
        TypeLowerer types;
        std::unordered_map<core::SymbolId, FunctionState> functions;
        std::uint64_t string_index{};
        std::uint64_t closure_index{};
        std::optional<Error> error;

        Generator(llvm::LLVMContext &llvmContext, llvm::Module &llvmModule)
            : context(llvmContext)
            , module(llvmModule)
            , types(context)
        {}

        void
        fail(ErrorKind kind, std::string code, std::string message);

        [[nodiscard]] auto
        FunctionType(const xmm::Function &function) const
            -> llvm::FunctionType *;

        [[nodiscard]] auto
        DeclareFunctions(const xmm::Module &source) -> bool;

        void
        DiscoverRegisters(FunctionState &state);

        [[nodiscard]] auto
        CreateBlocksAndSlots(FunctionState &state) -> bool;

        [[nodiscard]] auto
        StringLiteral(llvm::IRBuilder<> &builder, const std::u32string &text)
            -> llvm::Value *;

        [[nodiscard]] auto
        Immediate(llvm::IRBuilder<> &builder, const xmm::Value &value)
            -> llvm::Value *;

        [[nodiscard]] auto
        LoadValue(llvm::IRBuilder<> &builder,
                  FunctionState &state,
                  const xmm::Value &value) -> llvm::Value *;

        [[nodiscard]] auto
        LowerSignedRoundedDiv(llvm::IRBuilder<> &builder,
                              llvm::Value *left,
                              llvm::Value *right) -> llvm::Value *;

        [[nodiscard]] auto
        LowerUnsignedRoundedDiv(llvm::IRBuilder<> &builder,
                                llvm::Value *left,
                                llvm::Value *right) -> llvm::Value *;

        [[nodiscard]] auto
        LowerFloatingRoundedDiv(llvm::IRBuilder<> &builder,
                                llvm::Value *left,
                                llvm::Value *right) -> llvm::Value *;

        [[nodiscard]] auto
        IntegerPowerFunction(llvm::IntegerType *type) -> llvm::Function *;

        [[nodiscard]] auto
        LowerCall(llvm::IRBuilder<> &builder,
                  FunctionState &state,
                  const xmm::Instruction &instruction) -> llvm::Value *;

        [[nodiscard]] auto
        RuntimeFunction(std::string_view name,
                        llvm::Type *result,
                        std::initializer_list<llvm::Type *> arguments)
            -> llvm::FunctionCallee;

        [[nodiscard]] auto
        IsPointerAarcType(const core::Type &type) const -> bool;

        [[nodiscard]] auto
        LowerOwnership(llvm::IRBuilder<> &builder,
                       FunctionState &state,
                       const xmm::Instruction &instruction) -> bool;

        [[nodiscard]] auto
        CreateClosureThunk(llvm::StructType *payload,
                           const xmm::Instruction &instruction,
                           const std::vector<llvm::Type *> &captureTypes,
                           const FunctionState &target) -> llvm::Function *;

        /// Whether destroying a closure has anything to release: a strong
        /// capture of an object, or a weak or unowned handle. A closure over
        /// numbers and Booleans alone owns nothing.
        [[nodiscard]] static auto
        ClosureOwnsCaptures(const xmm::Instruction &instruction,
                            const std::vector<llvm::Type *> &captureTypes)
            -> bool;

        /// The destructor of a closure, or null for a closure that owns
        /// nothing. The runtime runs no destructor for an object whose metadata
        /// names none, so such a closure costs no function of its own.
        [[nodiscard]] auto
        CreateClosureDestructor(llvm::StructType *payload,
                                const xmm::Instruction &instruction,
                                const std::vector<llvm::Type *> &captureTypes)
            -> llvm::Function *;

        /// The LLVM type of the metadata record an allocation is described by;
        /// it mirrors `VxsAarcTypeMetadata` of the public runtime ABI.
        [[nodiscard]] auto
        ObjectMetadataType() -> llvm::StructType *;

        /// Allocates an AARC object with the given payload and destructor.
        ///
        /// TypeMetadata mirrors the public runtime ABI. Size is expressed as an
        /// LLVM constant expression so the target data layout, not the host
        /// compiler, determines the payload size. A null destructor describes
        /// an object that owns nothing. A metadata record that the module
        /// already holds under the given name is used again.
        [[nodiscard]] auto
        AllocateObject(llvm::IRBuilder<> &builder,
                       llvm::StructType *payload,
                       llvm::Function *destructor,
                       const std::string &metadataName,
                       const char *valueName) -> llvm::Value *;

        /// Lowers a callable that remembers its result.
        ///
        /// The value is an object of its own around the callable that computes
        /// the result. Like every closure it starts with its invoke entry, so a
        /// call site calls it as it calls any callable. Behind the entry it
        /// keeps whether it has a result, the result, and the callable. The
        /// entry calls the callable when there is no result yet, keeps what it
        /// returned, and returns the kept result from then on. Every holder of
        /// the object sees the same result, which is what lets a caller and the
        /// method it calls share one computation.
        ///
        /// The object owns the callable and releases it when it is destroyed.
        /// The result owns nothing: the verifiers admit only Bool and numeric
        /// results. A call that does not return leaves the object without a
        /// result.
        ///
        /// Nothing in the object's code depends on which computation it holds,
        /// so a module has one payload type, one entry, one destructor and one
        /// metadata record for each result type, however many values it
        /// suspends.
        [[nodiscard]] auto
        LowerMemoize(llvm::IRBuilder<> &builder,
                     FunctionState &state,
                     const xmm::Instruction &instruction) -> llvm::Value *;

        [[nodiscard]] auto
        LowerClosure(llvm::IRBuilder<> &builder,
                     FunctionState &state,
                     const xmm::Instruction &instruction) -> llvm::Value *;

        // Values that cannot be computed.
        //
        // An integer quotient or remainder by zero, and a shift by an amount
        // that is negative or not less than the width of the shifted value,
        // have no value. A program that needs one fails: it stops there. LLVM
        // gives the same instructions no meaning at all, so without a check an
        // optimizer may remove the computation, or the code after it, as if the
        // program had never needed the value. Each such instruction is
        // therefore preceded by a check that stops the program, and the
        // instruction itself only ever runs on operands it has a value for.

        /// The function that stops the program when its two operands are equal
        /// or, with `below` unset, when the first is not below the second as
        /// unsigned numbers. It is small and always inlined, so that the check
        /// costs a comparison where the operand is not known and nothing where
        /// it is.
        [[nodiscard]] auto
        ComputabilityCheck(llvm::IntegerType *type, bool below)
            -> llvm::Function *;

        /// Stops the program when an integer divisor is zero, and gives the
        /// divisor the division is carried out with.
        ///
        /// The least value of a signed type divided by minus one has a quotient
        /// one above the greatest value of the type. That is a result that does
        /// not fit, not a value that cannot be computed, and generated code
        /// lets every other integer result that does not fit wrap. Wrapped, the
        /// quotient is the least value again and the remainder is zero, which
        /// is what dividing by one gives; the division is carried out with one.
        /// The processor's own instruction would stop the program instead.
        [[nodiscard]] auto
        ComputableDivisor(llvm::IRBuilder<> &builder,
                          llvm::Value *dividend,
                          llvm::Value *divisor,
                          bool isSigned) -> llvm::Value *;

        /// Stops the program when a shift amount is negative or not less than
        /// the width of the shifted value.
        void
        RequireShiftAmount(llvm::IRBuilder<> &builder, llvm::Value *amount);

        /// Lowers a call of a function of the runtime.
        ///
        /// The verifiers have checked the call against its row of the catalog.
        /// An argument that the row gives a family of types is widened here to
        /// the one representation the runtime function is written for: a signed
        /// integer is sign-extended and an unsigned one zero-extended to
        /// sixty-four bits, and a floating-point number is extended to a
        /// `double`. None of these changes the value. A string result arrives
        /// with a reference the caller owns; when nothing takes it, it is
        /// released here. A Boolean result arrives as the byte the C ABI
        /// returns and is narrowed to the one bit a Bool is here.
        [[nodiscard]] auto
        LowerRuntimeCall(llvm::IRBuilder<> &builder,
                         FunctionState &state,
                         const xmm::Instruction &instruction) -> bool;

        [[nodiscard]] auto
        LowerInstruction(llvm::IRBuilder<> &builder,
                         FunctionState &state,
                         const xmm::Instruction &instruction) -> bool;

        [[nodiscard]] auto
        LowerTerminator(llvm::IRBuilder<> &builder,
                        FunctionState &state,
                        const xmm::Terminator &terminator) -> bool;

        // The ownership runtime an executable carries in its own module.
        [[nodiscard]] auto
        DefineFunction(FunctionState &state) -> bool;

        [[nodiscard]] auto
        CreateExecutableEntry(const llvm::Triple &triple) -> bool;
    };
} // namespace Visual::XSharp::Backend::LLVM::Generation
