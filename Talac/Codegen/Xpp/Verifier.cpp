// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <iterator>
#include <llvm/ADT/SmallString.h>
#include <llvm/ADT/SmallVector.h>
#include <llvm/ADT/StringRef.h>
#include <llvm/ADT/Twine.h>
#include <unordered_set>
#include <utility>

#include "Progmasoft/Tala/ADTs/DenseIdMap.hpp"
#include "Progmasoft/Tala/Analysis/DefiniteInitialization.hpp"
#include "Progmasoft/Tala/Core/Callable.hpp"
#include "Progmasoft/Tala/Core/Ownership.hpp"
#include "Progmasoft/Tala/Core/RuntimeCall.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Xpp/OwnershipVerifier.hpp"
#include "Progmasoft/Tala/Xpp/Verifier.hpp"
#include "Talac/Artifact/SourcePath.hpp"

namespace Progmasoft::Tala::Xpp
{
    namespace
    {
        namespace Core = ::tala::core;
        namespace IR = ::tala::xpp;
        namespace Dataflow = ::Progmasoft::Tala::Analysis;
        namespace ADTs = ::Progmasoft::Tala::ADTs;

        using FunctionCatalog
            = ADTs::DenseIdMap<IR::SymbolId, const IR::Function *>;
        using StorageCatalog = ADTs::DenseIdMap<IR::SymbolId, Core::Type>;
        using BlockCatalog = ADTs::DenseIdSet<IR::BlockId>;

        struct Context final
        {
            std::vector<VerificationIssue> issues;
            IR::SymbolId function{};
            IR::BlockId block{};
            std::size_t instruction{};

            void
            Add(const llvm::StringRef code, const llvm::Twine &message)
            {
                llvm::SmallString<160> storage;
                issues.push_back({ code.str(),
                                   message.toStringRef(storage).str(),
                                   function,
                                   block,
                                   instruction });
            }
        };

        [[nodiscard]] auto
        LiteralMatches(const IR::Operand &operand) -> bool
        {
            if (operand.kind != IR::Operand::Kind::Literal)
                return true;
            return !Core::validate_literal(operand.literal, operand.type)
                        .has_value();
        }

        [[nodiscard]] auto
        ExpectedArity(IR::Opcode opcode) -> std::size_t
        {
            switch (opcode)
            {
                case IR::Opcode::Copy:
                case IR::Opcode::Negate:
                case IR::Opcode::LogicalNot:
                case IR::Opcode::BitwiseNot:
                case IR::Opcode::Memoize:
                case IR::Opcode::RetainStrong:
                case IR::Opcode::ReleaseStrong:
                case IR::Opcode::MakeWeak:
                case IR::Opcode::LockWeak:
                case IR::Opcode::ReleaseWeak:
                case IR::Opcode::MakeUnowned:
                case IR::Opcode::LoadUnowned:
                case IR::Opcode::ReleaseUnowned:
                    return 1U;
                case IR::Opcode::Call:
                case IR::Opcode::MakeClosure:
                    return 0U;
                default:
                    return 2U;
            }
        }

        [[nodiscard]] auto
        IsAarcType(const Core::Type &type) -> bool
        {
            // Nominal declarations are resolved before Xpp in the complete
            // frontend. The current Core wire has no nominal-kind slot, so a
            // surviving Named value is the reference-layout branch; CoW values
            // must be expanded before this boundary.
            return Core::UsesAarc(type) || type.kind == Core::Type::Kind::Named;
        }

        [[nodiscard]] auto
        IsOwnershipOpcode(IR::Opcode opcode) -> bool
        {
            return opcode >= IR::Opcode::RetainStrong
                   && opcode <= IR::Opcode::ReleaseUnowned;
        }

        [[nodiscard]] auto
        FunctionType(const IR::Function &function) -> Core::Type
        {
            std::vector<Core::Type> parameters;
            parameters.reserve(function.parameters.size());
            for (const auto &parameter : function.parameters)
                parameters.push_back(parameter.type);
            return Core::Type::function(std::move(parameters),
                                        function.return_type);
        }

        void
        VerifyOperand(Context &context,
                      const IR::Operand &operand,
                      const StorageCatalog &storage,
                      const FunctionCatalog &functions)
        {
            if (operand.kind == IR::Operand::Kind::Literal)
            {
                if (!LiteralMatches(operand))
                    context.Add(
                        "TAP1010",
                        "literal payload does not match its declared type");
                return;
            }
            if (operand.symbol == 0U)
            {
                context.Add("TAP1011",
                            "symbol operand uses the reserved zero id");
                return;
            }
            if (operand.type.kind == Core::Type::Kind::Function)
            {
                // A function-typed symbol can denote either a module function
                // or local storage containing an AARC closure. Function ids are
                // globally unique, so checking the declaration catalog first is
                // deterministic and retains direct-call identity without
                // misclassifying closure registers.
                if (const auto *direct = functions.Find(operand.symbol))
                {
                    if (operand.type != FunctionType(**direct))
                        context.Add("TAP1024",
                                    "function operand signature differs from "
                                    "its declaration");
                    return;
                }
                if (const auto *local = storage.Find(operand.symbol);
                    local == nullptr)
                    context.Add("TAP1012",
                                "callable operand refers to neither a function "
                                "nor local storage");
                else if (*local != operand.type)
                    context.Add("TAP1014",
                                "callable operand type differs from its "
                                "storage declaration");
                return;
            }
            const auto *found = storage.Find(operand.symbol);
            if (found == nullptr)
                context.Add("TAP1013",
                            "operand reads an undefined storage symbol");
            else if (*found != operand.type)
                context.Add(
                    "TAP1014",
                    "operand type differs from its storage declaration");
        }

        void
        VerifyInstruction(Context &context,
                          const IR::Instruction &value,
                          const StorageCatalog &storage,
                          const FunctionCatalog &functions)
        {
            if (value.opcode == IR::Opcode::Call)
            {
                if (value.operands.empty()
                    || value.operands.front().kind != IR::Operand::Kind::Symbol
                    || value.operands.front().type.kind
                           != Core::Type::Kind::Function)
                    context.Add("TAP1015",
                                "call must begin with a typed direct-function "
                                "or closure-storage operand");
                else
                {
                    const auto signature
                        = ::Progmasoft::Tala::Core::Callable::Decompose(
                            value.operands.front().type);
                    if (!signature
                        || value.operands.size()
                               != signature->parameters.size() + 1U)
                        context.Add(
                            "TAP1025",
                            "call argument count does not match its signature");
                    else
                    {
                        for (std::size_t index = 1;
                             index < value.operands.size();
                             ++index)
                            if (value.operands[index].type
                                != signature->parameters[index - 1U])
                                context.Add("TAP1026",
                                            "call argument type does not match "
                                            "its signature");
                        if (value.result_type != signature->result)
                            context.Add("TAP1027",
                                        "call result type does not match its "
                                        "signature");
                    }
                }
            }
            else if (value.opcode == IR::Opcode::MakeClosure)
            {
                const auto *target = functions.Find(value.closure_function);
                if (value.closure_function == 0U || target == nullptr)
                    context.Add("TAP1028",
                                "closure operation refers to an unknown lifted "
                                "function");
                if (value.result_type.kind != Core::Type::Kind::Function)
                    context.Add(
                        "TAP1029",
                        "closure operation result must have a function type");
                if (value.capture_modes.size() != value.operands.size())
                    context.Add(
                        "TAP1030",
                        "closure capture modes and operands differ in length");
                if (target != nullptr)
                {
                    const auto &parameters = (*target)->parameters;
                    llvm::SmallVector<Core::Type, 8> targetParameters;
                    targetParameters.reserve(parameters.size());
                    for (const auto &parameter : parameters)
                        targetParameters.push_back(parameter.type);
                    llvm::SmallVector<Core::Type, 8> captures;
                    captures.reserve(value.operands.size());
                    for (const auto &operand : value.operands)
                        captures.push_back(operand.type);
                    const auto contract
                        = ::Progmasoft::Tala::Core::Callable::ValidateClosure(
                            captures,
                            targetParameters,
                            (*target)->return_type,
                            value.result_type);
                    using ContractError = ::Progmasoft::Tala::Core::Callable::
                        ClosureContractError;
                    switch (contract.error)
                    {
                        case ContractError::None:
                        case ContractError::ResultIsNotCallable:
                            // TAP1029 already reports this shape without
                            // duplicating it.
                            break;
                        case ContractError::TargetHasTooFewParameters:
                            context.Add("TAP1031",
                                        "lifted function has fewer parameters "
                                        "than closure captures");
                            break;
                        case ContractError::CaptureTypeMismatch:
                            context.Add("TAP1032",
                                        "closure capture type differs from its "
                                        "lifted parameter");
                            break;
                        case ContractError::PublicParameterCountMismatch:
                            context.Add(
                                "TAP1038",
                                "lifted function public parameter count "
                                "differs from the closure signature");
                            break;
                        case ContractError::PublicParameterTypeMismatch:
                            context.Add("TAP1039",
                                        "lifted function public parameter type "
                                        "differs from the closure signature");
                            break;
                        case ContractError::ResultTypeMismatch:
                            context.Add("TAP1040",
                                        "lifted function result differs from "
                                        "the closure signature");
                            break;
                    }
                }
                // Shape is diagnosed above, but malformed artifacts must not
                // turn verification into an out-of-bounds read. Validate the
                // paired prefix and leave the cardinality error authoritative.
                const auto pairedCaptures = std::min(value.capture_modes.size(),
                                                     value.operands.size());
                for (std::size_t index = 0; index < pairedCaptures; ++index)
                    if (value.capture_modes[index] != Core::CaptureMode::Strong
                        && !IsAarcType(value.operands[index].type))
                        context.Add("TAP1033",
                                    "weak and unowned captures require an AARC "
                                    "reference type");
            }
            else if (IsOwnershipOpcode(value.opcode))
            {
                if (value.operands.size() != 1U)
                    context.Add(
                        "TAP1034",
                        "ownership instruction requires exactly one operand");
                else if (!IsAarcType(value.operands.front().type))
                    context.Add("TAP1035",
                                "ownership instruction requires an AARC "
                                "reference type");

                const auto releases
                    = value.opcode == IR::Opcode::ReleaseStrong
                      || value.opcode == IR::Opcode::ReleaseWeak
                      || value.opcode == IR::Opcode::ReleaseUnowned;
                if (releases)
                {
                    if (value.effect != IR::Instruction::Effect::Discard
                        || value.result_type.kind != Core::Type::Kind::Unit)
                        context.Add("TAP1036",
                                    "release ownership instruction must "
                                    "discard a Unit result");
                }
                else if (value.effect == IR::Instruction::Effect::Discard
                         || value.operands.empty()
                         || value.result_type != value.operands.front().type)
                    context.Add("TAP1037",
                                "producing ownership instruction must preserve "
                                "its operand type");
            }
            else if (value.opcode == IR::Opcode::TypeIs)
            {
                // TypeIs is the native boundary for source-level type patterns.
                // Keep its ABI tuple strict here instead of letting malformed
                // artifacts reach LLVM as an arbitrary runtime call.
                if (value.result_type.kind != Core::Type::Kind::Bool
                    || value.operands.size() != 2U
                    || (value.operands[0].type.kind != Core::Type::Kind::Named
                        && value.operands[0].type.kind
                               != Core::Type::Kind::String
                        && value.operands[0].type.kind
                               != Core::Type::Kind::Function)
                    || value.operands[1].type != Core::Type::uint64())
                    context.Add("TAP1045",
                                "type test requires a reference subject, uint "
                                "identity and Bool result");
            }
            else if (value.opcode == IR::Opcode::RuntimeCall)
            {
                // The function is named by a literal, never by a value that
                // is computed: what is called is fixed when the program is
                // compiled.
                namespace runtime = Core::runtime;
                const runtime::Signature *signature = nullptr;
                if (!value.operands.empty()
                    && value.operands.front().kind
                           == IR::Operand::Kind::Literal)
                    if (const auto identity
                        = runtime::IdentityOf(value.operands.front().literal,
                                              value.operands.front().type))
                        signature = runtime::Find(*identity);
                std::vector<Core::Type::Kind> arguments;
                arguments.reserve(value.operands.size());
                for (std::size_t index = 1U; index < value.operands.size();
                     ++index)
                    arguments.push_back(value.operands[index].type.kind);
                const auto defect = runtime::Check(signature,
                                                   arguments,
                                                   value.result_type.kind);
                if (defect != runtime::Defect::None)
                    context.Add("TAP1048",
                                std::string(runtime::Describe(defect)));
            }
            else if (value.opcode == IR::Opcode::Memoize)
            {
                // The result is a new owner of the same callable type; the
                // remembered value is kept in it and owns nothing.
                const auto remembers
                    = value.operands.size() == 1U
                      && value.operands.front().type.kind
                             == Core::Type::Kind::Function
                      && value.operands.front().type.components.size() == 1U
                      && (value.operands.front().type.components.front().kind
                              == Core::Type::Kind::Bool
                          || Core::is_numeric(
                              value.operands.front().type.components.front()));
                if (!remembers
                    || value.result_type != value.operands.front().type)
                    context.Add("TAP1047",
                                "memoization requires one callable without "
                                "parameters whose result is Bool or numeric, "
                                "and yields a callable of the same type");
            }
            else if (value.opcode == IR::Opcode::FloorDivide)
            {
                const auto hasNumericPair
                    = value.operands.size() == 2U
                      && Core::is_numeric(value.operands[0].type)
                      && value.operands[0].type == value.operands[1].type;
                const auto expectedResult
                    = !hasNumericPair ? Core::Type::unit()
                      : Core::is_floating(value.operands[0].type)
                          ? Core::Type::int64()
                          : value.operands[0].type;
                if (!hasNumericPair || value.result_type != expectedResult)
                    context.Add("TAP1046",
                                "rounded division requires matching numeric "
                                "operands and its specified result type");
            }
            else if (value.operands.size() != ExpectedArity(value.opcode))
                context.Add("TAP1016",
                            "instruction has the wrong operand count");

            if (value.effect == IR::Instruction::Effect::Discard)
            {
                if (value.destination != 0U)
                    context.Add(
                        "TAP1017",
                        "discard instruction must not name a destination");
            }
            else
            {
                const auto *found = storage.Find(value.destination);
                if (value.destination == 0U || found == nullptr)
                    context.Add(
                        "TAP1018",
                        "result destination does not name declared storage");
                else if (*found != value.result_type)
                    context.Add("TAP1019",
                                "result type differs from destination storage");
            }
            for (const auto &operand : value.operands)
                VerifyOperand(context, operand, storage, functions);
        }

        void
        VerifyTerminator(Context &context,
                         const IR::Terminator &value,
                         const IR::Function &function,
                         const StorageCatalog &storage,
                         const FunctionCatalog &functions,
                         const BlockCatalog &blocks)
        {
            if (value.kind == IR::Terminator::Kind::Return)
            {
                VerifyOperand(context, value.value, storage, functions);
                if (value.value.type != function.return_type)
                    context.Add("TAP1020",
                                "return value type differs from the function "
                                "result type");
            }
            else if (value.kind == IR::Terminator::Kind::Branch)
            {
                VerifyOperand(context, value.value, storage, functions);
                if (value.value.type.kind != Core::Type::Kind::Bool)
                    context.Add("TAP1021", "branch condition must be Bool");
                if (!blocks.Contains(value.true_target)
                    || !blocks.Contains(value.false_target))
                    context.Add("TAP1022",
                                "branch target does not name a function block");
            }
            else if (value.kind == IR::Terminator::Kind::Jump
                     && !blocks.Contains(value.true_target))
                context.Add("TAP1023",
                            "jump target does not name a function block");
        }

        [[nodiscard]] auto
        Successors(const IR::Terminator &terminator)
            -> std::vector<Dataflow::BlockId>
        {
            switch (terminator.kind)
            {
                case IR::Terminator::Kind::Branch:
                    return { terminator.true_target, terminator.false_target };
                case IR::Terminator::Kind::Jump:
                    return { terminator.true_target };
                case IR::Terminator::Kind::Return:
                case IR::Terminator::Kind::Unreachable:
                    return {};
            }
            return {};
        }

        void
        AppendStorageRead(const IR::Operand &operand,
                          const StorageCatalog &storage,
                          const FunctionCatalog &functions,
                          std::vector<Dataflow::StorageId> &reads)
        {
            if (operand.kind != IR::Operand::Kind::Symbol)
                return;
            // A direct function symbol is callable identity, not local storage.
            // Closure values have the same function type but are present in the
            // storage catalog and therefore participate in initialization.
            if (functions.Contains(operand.symbol))
                return;
            if (storage.Contains(operand.symbol))
                reads.push_back(operand.symbol);
        }

        [[nodiscard]] auto
        DataflowFunction(const IR::Function &function,
                         const StorageCatalog &storage,
                         const FunctionCatalog &functions) -> Dataflow::Function
        {
            Dataflow::Function model;
            model.entry = function.entry;
            model.declarations.reserve(storage.Size());
            storage.ForEach(
                [&model](const IR::SymbolId symbol, const Core::Type &type) {
                    static_cast<void>(type);
                    model.declarations.push_back(symbol);
                });
            std::ranges::sort(model.declarations);

            model.initiallyInitialized.reserve(function.parameters.size());
            for (const auto &parameter : function.parameters)
                if (storage.Contains(parameter.symbol.id))
                    model.initiallyInitialized.push_back(parameter.symbol.id);

            model.blocks.reserve(function.blocks.size());
            for (const auto &block : function.blocks)
            {
                Dataflow::Block flowBlock;
                flowBlock.id = block.id;
                flowBlock.successors = Successors(block.terminator);
                flowBlock.accesses.reserve(block.instructions.size() + 1U);
                for (std::size_t index = 0; index < block.instructions.size();
                     ++index)
                {
                    const auto &instruction = block.instructions[index];
                    Dataflow::AccessPoint access;
                    access.instruction = index;
                    for (const auto &operand : instruction.operands)
                        AppendStorageRead(operand,
                                          storage,
                                          functions,
                                          access.reads);
                    if (instruction.effect != IR::Instruction::Effect::Discard
                        && storage.Contains(instruction.destination))
                        access.write = instruction.destination;
                    flowBlock.accesses.push_back(std::move(access));
                }

                Dataflow::AccessPoint terminatorAccess;
                terminatorAccess.instruction = block.instructions.size();
                terminatorAccess.terminator = true;
                if (block.terminator.kind == IR::Terminator::Kind::Return
                    || block.terminator.kind == IR::Terminator::Kind::Branch)
                    AppendStorageRead(block.terminator.value,
                                      storage,
                                      functions,
                                      terminatorAccess.reads);
                flowBlock.accesses.push_back(std::move(terminatorAccess));
                model.blocks.push_back(std::move(flowBlock));
            }
            return model;
        }

        void
        VerifyDefiniteInitialization(Context &context,
                                     const IR::Function &function,
                                     const StorageCatalog &storage,
                                     const FunctionCatalog &functions)
        {
            const auto result = Dataflow::Analyze(
                DataflowFunction(function, storage, functions),
                { .materializeFacts = false });
            for (const auto &issue : result.issues)
            {
                if (issue.kind != Dataflow::IssueKind::ReadBeforeInitialization)
                    continue;
                context.block = issue.block;
                context.instruction = issue.instruction;
                context.Add("TAP1041",
                            issue.terminator
                                ? "terminator reads storage that is not "
                                  "initialized on every incoming path"
                                : "instruction reads storage that is not "
                                  "initialized on every incoming path");
            }
        }
    } // namespace

    auto
    Verify(const ::tala::xpp::Module &module) -> std::vector<VerificationIssue>
    {
        Context context;
        if (module.name.empty()
            || std::ranges::any_of(module.name, [](const auto &part) {
                   return part.empty();
               }))
            context.Add("TAP1001",
                        "Xpp module name must contain non-empty components");
        if (module.functions.empty())
            context.Add("TAP1002", "Xpp module contains no functions");
        std::unordered_set<std::u32string> sourceFiles;
        for (const auto &sourceFile : module.source_files)
        {
            if (!Artifact::IsNormalizedSourcePath(sourceFile))
                context.Add("TAP1020",
                            "Xpp source path must be a normalized relative "
                            ".tala path");
            if (!sourceFiles.insert(sourceFile).second)
                context.Add("TAP1020",
                            "Xpp source catalog contains a duplicate path");
        }

        FunctionCatalog functions;
        functions.Reserve(module.functions.size());
        for (const auto &function : module.functions)
            if (function.symbol.id == 0U || function.symbol.spelling.empty()
                || !functions.TryEmplace(function.symbol.id, &function)
                        .inserted)
            {
                context.function = function.symbol.id;
                context.Add("TAP1003",
                            "function symbol is missing, empty, or duplicated");
            }

        for (const auto &function : module.functions)
        {
            context.function = function.symbol.id;
            if (!function.source_file.empty()
                && !Artifact::IsNormalizedSourcePath(function.source_file))
                context.Add("TAP1021",
                            "Xpp function owner must be a normalized "
                            "relative .tala path");
            if (!module.source_files.empty()
                && !sourceFiles.contains(function.source_file))
                context.Add("TAP1021",
                            "Xpp function owner is absent from the source "
                            "catalog");
            BlockCatalog blocks;
            blocks.Reserve(function.blocks.size());
            for (const auto &block : function.blocks)
                if (!blocks.Insert(block.id))
                {
                    context.block = block.id;
                    context.Add("TAP1004",
                                "block id is declared more than once");
                }
            if (!blocks.Contains(function.entry))
                context.Add("TAP1005", "function entry does not name a block");

            StorageCatalog storage;
            storage.Reserve(function.parameters.size());
            for (const auto &parameter : function.parameters)
                if (parameter.symbol.id == 0U
                    || !storage.TryEmplace(parameter.symbol.id, parameter.type)
                            .inserted)
                    context.Add(
                        "TAP1006",
                        "parameter storage symbol is missing or duplicated");
            for (const auto &block : function.blocks)
            {
                context.block = block.id;
                for (std::size_t index = 0; index < block.instructions.size();
                     ++index)
                {
                    context.instruction = index;
                    const auto &instruction = block.instructions[index];
                    if (instruction.effect == IR::Instruction::Effect::Define
                        && (instruction.destination == 0U
                            || !storage
                                    .TryEmplace(instruction.destination,
                                                instruction.result_type)
                                    .inserted))
                        context.Add(
                            "TAP1007",
                            "defined storage symbol is missing or duplicated");
                }
            }

            for (const auto &block : function.blocks)
            {
                context.block = block.id;
                for (std::size_t index = 0; index < block.instructions.size();
                     ++index)
                {
                    context.instruction = index;
                    VerifyInstruction(context,
                                      block.instructions[index],
                                      storage,
                                      functions);
                }
                context.instruction = block.instructions.size();
                VerifyTerminator(context,
                                 block.terminator,
                                 function,
                                 storage,
                                 functions,
                                 blocks);
            }
            VerifyDefiniteInitialization(context, function, storage, functions);
        }
        auto ownershipIssues = VerifyOwnership(module);
        context.issues.insert(context.issues.end(),
                              std::make_move_iterator(ownershipIssues.begin()),
                              std::make_move_iterator(ownershipIssues.end()));
        return context.issues;
    }
} // namespace Progmasoft::Tala::Xpp
