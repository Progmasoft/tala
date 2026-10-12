// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <unordered_set>

#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Verifier/Semantics.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Talac/Artifact/SourcePath.hpp"

namespace tala::core
{
    namespace Artifact = ::Progmasoft::Tala::Artifact;

    namespace
    {
        auto
        issue(std::string code,
              std::string message,
              SymbolId function,
              BlockId block = 0) -> VerificationIssue
        {
            return VerificationIssue{ std::move(code),
                                      std::move(message),
                                      function,
                                      block };
        }

        auto
        atom_valid(const Atom &atom) -> bool
        {
            if (atom.kind == Atom::Kind::Variable)
                return atom.symbol.id != 0;
            return !validate_literal(atom.literal, atom.type).has_value();
        }

        auto
        expected_arity(Operation operation) -> std::size_t
        {
            switch (operation)
            {
                case Operation::Copy:
                    return 1;
                case Operation::Call:
                case Operation::MakeClosure:
                    return 0;
                case Operation::Negate:
                case Operation::LogicalNot:
                case Operation::BitwiseNot:
                case Operation::Memoize:
                    return 1;
                default:
                    return 2;
            }
        }

        void
        verify_instruction(const Instruction &instruction,
                           SymbolId function,
                           BlockId block,
                           std::vector<VerificationIssue> &issues)
        {
            if (instruction.kind != Instruction::Kind::Evaluate
                && instruction.destination.id == 0)
                issues.push_back(
                    issue("TAC1006",
                          "defining instruction has no destination symbol",
                          function,
                          block));
            if (instruction.operation != Operation::Call
                && instruction.operation != Operation::MakeClosure
                && instruction.operation != Operation::RuntimeCall
                && instruction.operands.size()
                       != expected_arity(instruction.operation))
                issues.push_back(issue("TAC1007",
                                       "operation has the wrong operand count",
                                       function,
                                       block));
            if (instruction.operation == Operation::Call
                && instruction.operands.empty())
                issues.push_back(issue("TAC1008",
                                       "call operation has no callee operand",
                                       function,
                                       block));
            if (instruction.operation == Operation::MakeClosure)
            {
                if (instruction.closure_function.id == 0)
                    issues.push_back(
                        issue("TAC1040",
                              "closure operation has no lifted function symbol",
                              function,
                              block));
                if (std::any_of(instruction.captures.begin(),
                                instruction.captures.end(),
                                [](const Capture &capture) {
                                    return capture.symbol.id == 0
                                           || !atom_valid(capture.value);
                                }))
                    issues.push_back(
                        issue("TAC1041",
                              "closure contains an invalid capture slot",
                              function,
                              block));
            }
            if (std::any_of(instruction.operands.begin(),
                            instruction.operands.end(),
                            [](const Atom &atom) {
                                return !atom_valid(atom);
                            }))
                issues.push_back(
                    issue("TAC1009",
                          "instruction contains an invalid typed atom",
                          function,
                          block));
        }

        void
        verify_terminator(const Terminator &terminator,
                          const std::unordered_set<BlockId> &block_ids,
                          SymbolId function,
                          BlockId block,
                          std::vector<VerificationIssue> &issues)
        {
            if (terminator.kind == Terminator::Kind::Return
                && !atom_valid(terminator.value))
                issues.push_back(issue("TAC1010",
                                       "return contains an invalid typed atom",
                                       function,
                                       block));
            if (terminator.kind == Terminator::Kind::Branch)
            {
                if (!atom_valid(terminator.value)
                    || terminator.value.type.kind != Type::Kind::Bool)
                    issues.push_back(
                        issue("TAC1011",
                              "branch condition must be a valid bool atom",
                              function,
                              block));
                if (!block_ids.contains(terminator.true_target)
                    || !block_ids.contains(terminator.false_target))
                    issues.push_back(issue("TAC1012",
                                           "branch targets a missing block",
                                           function,
                                           block));
            }
            if (terminator.kind == Terminator::Kind::Jump
                && !block_ids.contains(terminator.true_target))
                issues.push_back(issue("TAC1013",
                                       "jump targets a missing block",
                                       function,
                                       block));
        }
    } // namespace

    auto
    verify(const CorePrepModule &module) -> std::vector<VerificationIssue>
    {
        std::vector<VerificationIssue> issues;
        std::unordered_set<std::u32string> source_files;
        for (const auto &sourceFile : module.sourceFiles)
        {
            if (!Artifact::IsNormalizedSourcePath(sourceFile))
                issues.push_back(issue("TAC1064",
                                       "CorePrep source path must be a "
                                       "normalized relative .tala path",
                                       0U));
            if (!source_files.insert(sourceFile).second)
                issues.push_back(issue("TAC1064",
                                       "CorePrep source catalog contains an "
                                       "duplicate path",
                                       0U));
        }
        std::unordered_set<SymbolId> function_ids;
        for (const auto &function : module.functions)
        {
            if (!function.sourceFile.empty()
                && !Artifact::IsNormalizedSourcePath(function.sourceFile))
                issues.push_back(issue("TAC1065",
                                       "CorePrep function owner must be a "
                                       "normalized relative .tala path",
                                       function.symbol.id));
            if (!module.sourceFiles.empty()
                && !source_files.contains(function.sourceFile))
                issues.push_back(issue("TAC1065",
                                       "CorePrep function owner is absent "
                                       "from the module source catalog",
                                       function.symbol.id));
            if (function.symbol.id == 0
                || !function_ids.insert(function.symbol.id).second)
                issues.push_back(
                    issue("TAC1001",
                          "function symbol is missing or duplicated",
                          function.symbol.id));

            std::unordered_set<BlockId> block_ids;
            for (const auto &block : function.blocks)
                if (!block_ids.insert(block.id).second)
                    issues.push_back(issue("TAC1002",
                                           "block id is duplicated",
                                           function.symbol.id,
                                           block.id));
            if (!block_ids.contains(function.entry))
                issues.push_back(issue("TAC1003",
                                       "entry block does not exist",
                                       function.symbol.id));

            std::unordered_set<SymbolId> definitions;
            for (const auto &parameter : function.parameters)
                if (parameter.symbol.id == 0
                    || !definitions.insert(parameter.symbol.id).second)
                    issues.push_back(
                        issue("TAC1004",
                              "parameter symbol is missing or duplicated",
                              function.symbol.id));
            for (const auto &block : function.blocks)
            {
                for (const auto &instruction : block.instructions)
                {
                    if (instruction.kind == Instruction::Kind::Bind
                        && !definitions.insert(instruction.destination.id)
                                .second)
                        issues.push_back(
                            issue("TAC1005",
                                  "binding symbol is defined more than once",
                                  function.symbol.id,
                                  block.id));
                    verify_instruction(instruction,
                                       function.symbol.id,
                                       block.id,
                                       issues);
                }
                verify_terminator(block.terminator,
                                  block_ids,
                                  function.symbol.id,
                                  block.id,
                                  issues);
            }
        }
        auto semantic_issues = verify_semantics(module);
        issues.insert(issues.end(),
                      std::make_move_iterator(semantic_issues.begin()),
                      std::make_move_iterator(semantic_issues.end()));
        return issues;
    }
} // namespace tala::core
