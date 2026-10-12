// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "Progmasoft/Tala/Xpp/IR.hpp"

namespace tala::xmm
{
    /// Register identifier assigned by Xmm lowering.
    using VirtualRegister = std::uint32_t;
    /// Identifier of a basic block within one Xmm function.
    using BlockId = xpp::BlockId;

    /// Typed operation encoded by an Xmm instruction.
    enum class Opcode : std::uint8_t
    {
        LoadImmediate, ///< Materialize a constant into a virtual register.
        Move,          ///< Copy a value into the destination register.
        Call,          ///< Invoke a function value or direct function.
        Add,           ///< Arithmetic addition.
        Subtract,      ///< Arithmetic subtraction.
        Multiply,      ///< Arithmetic multiplication.
        Divide,        ///< Truncating arithmetic division.
        /// Rounded division `//`: nearest integer, halves away from zero.
        /// The enumerator keeps its historical name; it never floors.
        FloorDivide,
        Remainder,           ///< Arithmetic remainder.
        CompareLess,         ///< Ordered less-than comparison.
        CompareLessEqual,    ///< Ordered less-than-or-equal comparison.
        CompareGreater,      ///< Ordered greater-than comparison.
        CompareGreaterEqual, ///< Ordered greater-than-or-equal comparison.
        CompareEqual,        ///< Value equality comparison.
        CompareNotEqual,     ///< Value inequality comparison.
        AndBool,             ///< Boolean conjunction.
        OrBool,              ///< Boolean disjunction.
        Negate,              ///< Arithmetic negation.
        NotBool,             ///< Boolean negation.
        MakeClosure,         ///< Construct a closure with explicit captures.
        RetainStrong,        ///< Acquire a strong object reference.
        ReleaseStrong,       ///< Release a strong object reference.
        MakeWeak,            ///< Create a non-retaining weak handle.
        LockWeak,            ///< Upgrade a live weak handle to a strong value.
        ReleaseWeak,         ///< Release a weak handle.
        MakeUnowned,         ///< Create a non-retaining unowned handle.
        LoadUnowned,         ///< Load a value through an unowned handle.
        ReleaseUnowned,      ///< Release unowned-handle bookkeeping.
        Power,               ///< Exponentiation.
        ShiftLeft,           ///< Left bit shift.
        ShiftRight,          ///< Right bit shift.
        BitwiseAnd,          ///< Bitwise conjunction.
        BitwiseXor,          ///< Bitwise exclusive disjunction.
        BitwiseOr,           ///< Bitwise inclusive disjunction.
        BitwiseNot,          ///< Bitwise complement.
        TypeIs,              ///< Runtime type test.
        /// A callable that remembers its result. The operand is a callable
        /// without parameters; the result calls it at most once, at its
        /// own first call, and returns what it returned from then on.
        Memoize,
        /// A call of a function of the runtime. The first operand is an
        /// integer literal, the identity of the function in the catalog of
        /// `Tala/Core/RuntimeCall.hpp`; the operands after it are
        /// the arguments.
        RuntimeCall,

        // Source-compatible names for pre-v3 native clients. They intentionally
        // alias the typed operations; width and signedness now come from
        // Instruction::result_type.
        AddI64 = Add, ///< Legacy alias; the instruction result type selects
                      ///< width.
        SubI64 = Subtract, ///< Legacy alias; retained for source compatibility.
        MulI64 = Multiply, ///< Legacy alias; retained for source compatibility.
        DivI64 = Divide,   ///< Legacy alias; retained for source compatibility.
        FloorDivI64 = FloorDivide,    ///< Legacy alias; retained for source
                                      ///< compatibility.
        RemI64 = Remainder,           ///< Legacy alias; retained for source
                                      ///< compatibility.
        CompareLessI64 = CompareLess, ///< Legacy alias for typed comparison.
        CompareLessEqualI64 = CompareLessEqual, ///< Legacy alias for typed
                                                ///< comparison.
        CompareGreaterI64 = CompareGreater,     ///< Legacy alias for typed
                                                ///< comparison.
        CompareGreaterEqualI64 = CompareGreaterEqual, ///< Legacy alias for
                                                      ///< typed comparison.
        NegateI64 = Negate ///< Legacy alias; retained for source compatibility.
    };

    /// Typed value consumed or produced by an Xmm instruction.
    struct Value final
    {
        /// Selects a register, literal, or direct callable value.
        enum class Kind : std::uint8_t
        {
            Register,  ///< Value currently held in reg.
            Immediate, ///< Literal payload held in immediate.
            Function ///< Callable identity held in symbol, not a data register.
        };
        /// Active value category.
        Kind kind{ Kind::Immediate };
        /// Static type consumed by verification and native lowering.
        core::Type type{ core::Type::unit() };
        /// Selected register when kind is Register.
        VirtualRegister reg{};
        /// Function symbol when kind is Function.
        xpp::SymbolId symbol{};
        /// Constant payload when kind is Immediate.
        core::Literal immediate{};
        /// Compare the active payload and its static type.
        /// @return true when both values are structurally equal.
        [[nodiscard]] auto
        operator==(const Value &) const -> bool = default;
    };
    /// Typed operation, virtual destination, and explicit capture semantics.
    struct Instruction final
    {
        /// Operation performed by this instruction.
        Opcode opcode{ Opcode::Move };
        /// Destination register when has_result is true.
        VirtualRegister destination{};
        /// Semantic result type retained even when the value is discarded.
        core::Type result_type{ core::Type::unit() };
        /// Ordered input values consumed by the operation.
        std::vector<Value> operands;
        /// Whether the operation writes a value to destination.
        bool has_result{};
        /// Lifted function identity used by MakeClosure.
        xpp::SymbolId closure_function{};
        /// Ownership mode for each closure capture.
        std::vector<core::CaptureMode> capture_modes;
        /// Compare operation, destination, inputs, and closure metadata.
        /// @return true when the full instruction contents match.
        [[nodiscard]] auto
        operator==(const Instruction &) const -> bool = default;
    };
    /// Control-flow operation that ends an Xmm basic block.
    struct Terminator final
    {
        /// Selects the control-flow behavior.
        enum class Kind : std::uint8_t
        {
            Return,     ///< Return value to the caller.
            Branch,     ///< Select a successor using a Boolean value.
            Jump,       ///< Transfer to true_target unconditionally.
            Unreachable /**< Marks a block with no valid continuation. */
        };
        /// Active control-flow operation.
        Kind kind{ Kind::Unreachable };
        /// Returned value or Boolean branch condition.
        Value value{};
        /// Branch successor selected when the condition is true.
        BlockId true_target{};
        /// Branch successor selected when the condition is false.
        BlockId false_target{};
        /// Compare the terminator category, value, and successors.
        /// @return true when both control-flow operations match.
        [[nodiscard]] auto
        operator==(const Terminator &) const -> bool = default;
    };
    /// Ordered Xmm instructions and their required block terminator.
    struct Block final
    {
        /// Function-local basic-block identity.
        BlockId id{};
        /// Operations executed before the block terminator.
        std::vector<Instruction> instructions;
        /// Required final control-flow operation.
        Terminator terminator;
        /// Compare block identity and complete contents.
        /// @return true when both blocks are structurally equal.
        [[nodiscard]] auto
        operator==(const Block &) const -> bool = default;
    };
    /// Xmm function with its register assignment and native-call signature.
    struct Function final
    {
        /// Resolved function identity and source spelling.
        core::SymbolName symbol{};
        /// Virtual registers assigned to incoming parameters in declaration
        /// order.
        std::vector<VirtualRegister> parameter_registers;
        /// Parameter types in declaration order; required to form the ABI.
        std::vector<core::Type> parameter_types;
        /// Declared result type.
        core::Type return_type{ core::Type::unit() };
        /// Entry block identifier.
        BlockId entry{};
        /// Function-local blocks in deterministic order.
        std::vector<Block> blocks;
        /// Project-relative source path that owns the emitted definition.
        std::u32string source_file{};
        /// Compare identity, signature, source ownership, and block graph.
        /// @return true when all function fields match.
        [[nodiscard]] auto
        operator==(const Function &) const -> bool = default;
    };
    /// Xmm compilation unit with module identity and selected sources.
    struct Module final
    {
        /// Qualified module name as Unicode path segments.
        std::vector<std::u32string> name;
        /// Function definitions in deterministic declaration order.
        std::vector<Function> functions;
        /// Project-relative sources, including files with no declarations.
        std::vector<std::u32string> source_files{};
        /// Compare module identity, source set, and contained functions.
        /// @return true when all module fields match.
        [[nodiscard]] auto
        operator==(const Module &) const -> bool = default;
    };

    /// Lower verified Xpp instructions and control flow into Xmm registers.
    /// @param module Verified Xpp module to translate.
    /// @return Xmm module preserving source ownership and operand types.
    [[nodiscard]] auto
    lower(const xpp::Module &module) -> Module;
    [[nodiscard]] auto
    optimize(Module module) -> Module;
} // namespace tala::xmm
  /// Apply semantics-preserving Xmm optimization passes.
  /// @param module Xmm module to optimize; consumed by value for rewriting.
  /// @return Optimized module with verification invariants preserved.
