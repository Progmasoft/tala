// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "Progmasoft/Tala/Xmm/IR.hpp"

namespace Progmasoft::Tala::Xmm
{
    /// Category of structural, typing, control-flow, or ownership violation.
    enum class IssueKind : std::uint8_t
    {
        EmptyModule,          ///< No module declaration was supplied.
        InvalidModuleName,    ///< The qualified module name is malformed.
        DuplicateFunction,    ///< Function identity is declared twice.
        InvalidFunction,      ///< Function signature or body is malformed.
        UnsupportedType,      ///< A type cannot be represented by Xmm.
        ParameterShape,       ///< Entry parameters disagree with the signature.
        DuplicateBlock,       ///< Two blocks have the same identity.
        MissingEntry,         ///< The declared entry block is absent.
        InvalidTarget,        ///< A branch targets an undefined block.
        RegisterRedefinition, ///< A virtual register receives two definitions.
        UndefinedRegister,    ///< An operand reads a register without a
                              ///< definition.
        OperandCount,         ///< An operation has the wrong operand count.
        OperandType,          ///< An operand violates the opcode type contract.
        ResultType,    ///< A result register violates the opcode type contract.
        InvalidCall,   ///< A call target or argument list is invalid.
        InvalidReturn, ///< Return value disagrees with the function result.
        InvalidBranch, ///< Branch arguments disagree with target parameters.
        InvalidLiteral, ///< Literal payload is invalid for its declared type.
        UninitializedRegister,    ///< A path reads a register before
                                  ///< initialization.
        OwnershipUseAfterRelease, ///< A released handle is used again.
        OwnershipKindMismatch, ///< An operation expects another ownership kind.
        OwnershipPathMismatch  ///< Paths disagree on the handle's ownership
                               ///< state.
    };

    /// One verifier finding with function, block, and instruction coordinates.
    struct VerificationIssue final
    {
        /// Stable category for tools that branch on verifier results.
        IssueKind kind{ IssueKind::InvalidFunction };
        /// Machine-readable issue identifier.
        std::string code;
        /// Human-readable explanation of the rejected Xmm construct.
        std::string message;
        /// Function identity containing the issue.
        ::tala::core::SymbolId function{};
        /// Block identity containing the issue, when applicable.
        ::tala::xmm::BlockId block{};
        /// Instruction index within the reported block.
        std::size_t instruction{};

        /// Compare verifier category, message, and program coordinates.
        /// @return true when both issue records are equivalent.
        [[nodiscard]] auto
        operator==(const VerificationIssue &) const -> bool = default;
    };

    /// Verify Xmm structural, type, register, CFG, and ownership invariants.
    /// @param module Xmm module to validate before backend consumption.
    /// @return Deterministically ordered issues; empty means verification
    /// passed.
    [[nodiscard]] auto
    Verify(const ::tala::xmm::Module &module) -> std::vector<VerificationIssue>;
} // namespace Progmasoft::Tala::Xmm
