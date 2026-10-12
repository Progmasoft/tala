// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep.hpp"

namespace tala::xpp
{
    /// Resolved identifier shared with the verified CorePrep representation.
    using SymbolId = core::SymbolId;
    /// Identifier of a basic block within one Xpp function.
    using BlockId = core::BlockId;

    /// Typed operation encoded by an Xpp instruction.
    enum class Opcode : std::uint8_t
    {
        Copy,     ///< Copy an operand to the destination.
        Call,     ///< Invoke the function in the first operand.
        Add,      ///< Arithmetic addition.
        Subtract, ///< Arithmetic subtraction.
        Multiply, ///< Arithmetic multiplication.
        Divide,   ///< Truncating division.
        /// Rounded division `//`: nearest integer, halves away from zero.
        /// The enumerator keeps its historical name; it never floors.
        FloorDivide,
        Remainder,           ///< Arithmetic remainder.
        CompareLess,         ///< Ordered less-than comparison.
        CompareLessEqual,    ///< Ordered less-than-or-equal comparison.
        CompareGreater,      ///< Ordered greater-than comparison.
        CompareGreaterEqual, ///< Ordered greater-than-or-equal comparison.
        CompareEqual,        ///< Equality comparison.
        CompareNotEqual,     ///< Inequality comparison.
        LogicalAnd,          ///< Boolean conjunction.
        LogicalOr,           ///< Boolean disjunction.
        Negate,              ///< Arithmetic negation.
        LogicalNot,          ///< Boolean negation.
        MakeClosure, ///< Construct a closure with explicit capture modes.

        // Ownership is explicit from Xpp onward. Strong operations consume
        // object pointers; weak and unowned operations consume/produce control
        // handles while preserving the source language type in result_type.
        RetainStrong,   ///< Acquire a strong reference to an object.
        ReleaseStrong,  ///< Release a strong reference to an object.
        MakeWeak,       ///< Create a non-retaining weak handle.
        LockWeak,       ///< Upgrade a live weak handle to a strong value.
        ReleaseWeak,    ///< Release a weak handle.
        MakeUnowned,    ///< Create a non-retaining unowned handle.
        LoadUnowned,    ///< Load the value referenced by an unowned handle.
        ReleaseUnowned, ///< Release unowned-handle bookkeeping.
        Power,          ///< Exponentiation.
        ShiftLeft,      ///< Left bit shift.
        ShiftRight,     ///< Right bit shift.
        BitwiseAnd,     ///< Bitwise conjunction.
        BitwiseXor,     ///< Bitwise exclusive disjunction.
        BitwiseOr,      ///< Bitwise inclusive disjunction.
        BitwiseNot,     ///< Bitwise complement.
        TypeIs,         ///< Runtime type test.
        /// A callable that remembers its result. The operand is a callable
        /// without parameters; the result calls it at most once, at its
        /// own first call, and returns what it returned from then on.
        Memoize,
        /// A call of a function of the runtime. The first operand is an
        /// integer literal, the identity of the function in the catalog of
        /// `Tala/Core/RuntimeCall.hpp`; the operands after it are
        /// the arguments.
        RuntimeCall
    };

    /// Typed input to an Xpp instruction.
    struct Operand final
    {
        /// Selects a symbol reference or constant literal payload.
        enum class Kind : std::uint8_t
        {
            Symbol, ///< Read the value identified by symbol.
            Literal /**< Read the value stored in literal. */
        };
        /// Active operand category.
        Kind kind{ Kind::Literal };
        /// Static type used by verification and lowering.
        core::Type type{ core::Type::unit() };
        /// Referenced value identity when kind is Symbol.
        SymbolId symbol{};
        /// Constant payload when kind is Literal.
        core::Literal literal{};
        /// Compare operand kind, type, and active payload.
        /// @return true when both operands have equal semantic contents.
        [[nodiscard]] auto
        operator==(const Operand &) const -> bool = default;
    };
    /// Operation plus its data inputs and ownership metadata.
    struct Instruction final
    {
        /// Whether the instruction introduces, stores, or discards a result.
        enum class Effect : std::uint8_t
        {
            Define, ///< Create a new SSA-like symbol definition.
            Store,  ///< Assign to a previously defined mutable symbol.
            Discard /**< Preserve effects but discard the result value. */
        };
        /// Active instruction result effect.
        Effect effect{ Effect::Discard };
        /// Operation performed by this instruction.
        Opcode opcode{ Opcode::Copy };
        /// Destination symbol for Define and Store effects.
        SymbolId destination{};
        /// Result type retained even when the result is discarded.
        core::Type result_type{ core::Type::unit() };
        /// Ordered operation inputs.
        std::vector<Operand> operands;
        /// Lifted target function used by MakeClosure.
        SymbolId closure_function{};
        /// Ownership policy for each closure capture.
        std::vector<core::CaptureMode> capture_modes;
        /// Compare effect, operation, destination, inputs, and capture
        /// metadata.
        /// @return true when every instruction field matches.
        [[nodiscard]] auto
        operator==(const Instruction &) const -> bool = default;
    };
    /// Control-flow operation terminating an Xpp basic block.
    struct Terminator final
    {
        /// Selects the control-flow behavior.
        enum class Kind : std::uint8_t
        {
            Return,     ///< Return value to the caller.
            Branch,     ///< Select a successor using a Boolean operand.
            Jump,       ///< Transfer to the true_target unconditionally.
            Unreachable /**< Marks a block with no valid continuation. */
        };
        /// Active control-flow operation.
        Kind kind{ Kind::Unreachable };
        /// Returned value or Boolean branch condition.
        Operand value{};
        /// Branch target selected when value is true.
        BlockId true_target{};
        /// Branch target selected when value is false.
        BlockId false_target{};
        /// Compare the terminator category, value, and branch destinations.
        /// @return true when both control-flow operations match.
        [[nodiscard]] auto
        operator==(const Terminator &) const -> bool = default;
    };
    /// Ordered Xpp instructions ending in one control-flow terminator.
    struct Block final
    {
        /// Function-local block identity.
        BlockId id{};
        /// Operations executed before the terminator.
        std::vector<Instruction> instructions;
        /// Required final control-flow operation.
        Terminator terminator;
        /// Compare block identity and complete contents.
        /// @return true when both blocks are structurally equal.
        [[nodiscard]] auto
        operator==(const Block &) const -> bool = default;
    };
    /// Verified Xpp function with explicit CFG and source ownership.
    struct Function final
    {
        /// Resolved function identity and source spelling.
        core::SymbolName symbol{};
        /// Typed source parameters in declaration order.
        std::vector<core::Parameter> parameters;
        /// Declared result type.
        core::Type return_type{ core::Type::unit() };
        /// Entry block identifier.
        BlockId entry{};
        /// Function-local blocks in deterministic order.
        std::vector<Block> blocks;
        /// Project-relative path of the source defining this function.
        std::u32string source_file{};
        /// Compare signature, source ownership, and control-flow graph.
        /// @return true when all function fields match.
        [[nodiscard]] auto
        operator==(const Function &) const -> bool = default;
    };
    /// Xpp compilation unit with module identity and selected sources.
    struct Module final
    {
        /// Qualified module name as Unicode path segments.
        std::vector<std::u32string> name;
        /// Function definitions in deterministic order.
        std::vector<Function> functions;
        /// Project-relative sources, including declaration-free source files.
        std::vector<std::u32string> source_files{};
        /// Compare module identity, source set, and contained functions.
        /// @return true when all module fields match.
        [[nodiscard]] auto
        operator==(const Module &) const -> bool = default;
    };

    /// Lower verified CorePrep control flow and ownership into Xpp operations.
    /// @param module Verified CorePrep module to translate.
    /// @return Xpp module preserving the input source and ownership semantics.
    [[nodiscard]] auto
    lower(const core::CorePrepModule &module) -> Module;
    [[nodiscard]] auto
    optimize(Module module) -> Module;
} // namespace tala::xpp
  /// Apply semantics-preserving Xpp optimization passes.
  /// @param module Xpp module to optimize; consumed by value for rewriting.
  /// @return Optimized module with its verification invariants preserved.
