// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <algorithm>
#include <optional>
#include <unordered_map>
#include <unordered_set>

#include "Progmasoft/Tala/Core/CorePrep/Verifier/Semantics.hpp"
#include "Progmasoft/Tala/Core/Ownership.hpp"
#include "Progmasoft/Tala/Core/RuntimeCall.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Core/Template.hpp"

namespace tala::core
{
    namespace
    {
        struct Definition final
        {
            Type type;
            bool mutable_binding{};
            bool callable{};
        };

        using SpellingMap = std::unordered_map<SymbolId, std::u32string>;

        // What every function of a module sees of the module around it: the
        // functions it may call, their spellings, and the parameters that
        // closures fill. It is built once for the module. Building it again
        // for every function made verification quadratic in the number of
        // functions: 2000 small methods took 14 seconds here alone.
        struct ModuleCatalog final
        {
            std::unordered_map<SymbolId, Definition> functions;
            SpellingMap spellings;
            // Function symbols whose spelling differs from that of an
            // earlier function with the same id.
            std::size_t conflicting_spellings{};
            // For a lifted function, the parameters its closures capture into.
            std::unordered_map<SymbolId, std::unordered_set<SymbolId>>
                captured_parameters;
        };

        // The symbols a function may refer to: the functions of its module
        // and what the function itself defines. A function of the module
        // takes precedence over a local definition with the same id, as it
        // did when both were entered into one table, functions first.
        class Definitions final
        {
        public:
            explicit Definitions(const ModuleCatalog &catalog) noexcept
                : module_functions(&catalog.functions)
            {}

            void
            emplace(SymbolId id, Definition definition)
            {
                local.emplace(id, std::move(definition));
            }

            [[nodiscard]] auto
            find(SymbolId id) const -> const Definition *
            {
                if (const auto found = module_functions->find(id);
                    found != module_functions->end())
                    return &found->second;
                if (const auto found = local.find(id); found != local.end())
                    return &found->second;
                return nullptr;
            }

        private:
            const std::unordered_map<SymbolId, Definition> *module_functions;
            std::unordered_map<SymbolId, Definition> local;
        };

        // The spelling each symbol id carries where a function can see it:
        // the function's own, then the spellings of the module's functions,
        // then the first spelling the function uses for any other id.
        class Spellings final
        {
        public:
            Spellings(const ModuleCatalog &catalog,
                      const SymbolName &function) noexcept
                : module_spellings(&catalog.spellings)
                , own(&function)
            {}

            // The spelling recorded for the id; the given one is recorded
            // when the id had none.
            [[nodiscard]] auto
            record(SymbolId id, const std::u32string &spelling)
                -> const std::u32string &
            {
                if (id == own->id && !own->spelling.empty())
                    return own->spelling;
                if (const auto found = module_spellings->find(id);
                    found != module_spellings->end())
                    return found->second;
                return local.emplace(id, spelling).first->second;
            }

        private:
            const SpellingMap *module_spellings;
            const SymbolName *own;
            SpellingMap local;
        };

        auto
        issue(std::string code,
              std::string message,
              const Function &function,
              BlockId block) -> VerificationIssue
        {
            return VerificationIssue{ std::move(code),
                                      std::move(message),
                                      function.symbol.id,
                                      block };
        }

        auto
        function_type(const Function &function) -> Type
        {
            std::vector<Type> parameters;
            parameters.reserve(function.parameters.size());
            for (const auto &parameter : function.parameters)
                parameters.push_back(parameter.type);
            return Type::function(std::move(parameters), function.return_type);
        }

        [[nodiscard]] auto
        is_aarc_reference(const Type &type) noexcept -> bool
        {
            // Named declarations cannot be classified precisely until their
            // declaration kind is serialized into Core. Treat them as the
            // conservative reference case; String and callable types are
            // unconditionally AARC according to the public language model.
            return UsesAarc(type) || type.kind == Type::Kind::Named;
        }

        void
        verify_symbol_spelling(const SymbolName &symbol,
                               const Function &function,
                               BlockId block,
                               Spellings &spellings,
                               std::vector<VerificationIssue> &issues)
        {
            if (symbol.id == 0)
                return;
            if (symbol.spelling.empty())
                return;
            if (spellings.record(symbol.id, symbol.spelling) != symbol.spelling)
                issues.push_back(
                    issue("TAC1014",
                          "one symbol id carries conflicting spellings",
                          function,
                          block));
        }

        void
        verify_type(const Type &type,
                    const Function &function,
                    BlockId block,
                    std::size_t depth,
                    Spellings &spellings,
                    std::vector<VerificationIssue> &issues)
        {
            // This boundary also accepts CorePrep assembled by tooling rather
            // than the Haskell pipeline. Validate the root specialization key
            // independently before recursively checking native model payloads.
            if (depth == 0U)
            {
                for (const auto &templateIssue :
                     ::Progmasoft::Tala::Core::Template::Validate(type))
                    issues.push_back(issue("TAC1052",
                                           "invalid CorePrep template type: "
                                               + templateIssue.message,
                                           function,
                                           block));
            }
            if (depth > 128U)
            {
                issues.push_back(
                    issue("TAC1015",
                          "type nesting exceeds the native verifier limit",
                          function,
                          block));
                return;
            }
            switch (type.kind)
            {
                case Type::Kind::Unit:
                case Type::Kind::Bool:
                case Type::Kind::Character:
                case Type::Kind::Int8:
                case Type::Kind::Int16:
                case Type::Kind::Int64:
                case Type::Kind::Int32:
                case Type::Kind::Int128:
                case Type::Kind::UInt8:
                case Type::Kind::UInt16:
                case Type::Kind::UInt32:
                case Type::Kind::UInt64:
                case Type::Kind::UInt128:
                case Type::Kind::Float16:
                case Type::Kind::Float32:
                case Type::Kind::Float64:
                case Type::Kind::Float128:
                case Type::Kind::String:
                    if (!type.name.empty() || !type.components.empty()
                        || !type.templateArguments.empty()
                        || type.variable.id != 0)
                        issues.push_back(
                            issue("TAC1016",
                                  "primitive type contains unexpected payload",
                                  function,
                                  block));
                    return;
                case Type::Kind::Function:
                    if (type.components.empty())
                        issues.push_back(
                            issue("TAC1017",
                                  "function type has no result component",
                                  function,
                                  block));
                    for (const auto &component : type.components)
                        verify_type(component,
                                    function,
                                    block,
                                    depth + 1U,
                                    spellings,
                                    issues);
                    return;
                case Type::Kind::Named:
                    if (type.name.empty())
                        issues.push_back(
                            issue("TAC1018",
                                  "named type has an empty qualified name",
                                  function,
                                  block));
                    for (const auto &part : type.name)
                        if (part.empty())
                            issues.push_back(
                                issue("TAC1019",
                                      "named type contains an empty name part",
                                      function,
                                      block));
                    for (const auto &argument : type.templateArguments)
                    {
                        if (argument.kind == TemplateArgument::Kind::Type)
                        {
                            if (!argument.type)
                                issues.push_back(issue(
                                    "TAC1049",
                                    "type template argument has no payload",
                                    function,
                                    block));
                            else
                                verify_type(*argument.type,
                                            function,
                                            block,
                                            depth + 1U,
                                            spellings,
                                            issues);
                            continue;
                        }
                        if (argument.value.kind
                            == TemplateValue::Kind::Parameter)
                        {
                            verify_symbol_spelling(argument.value.parameter,
                                                   function,
                                                   block,
                                                   spellings,
                                                   issues);
                            if (argument.value.parameter.id == 0)
                                issues.push_back(issue(
                                    "TAC1050",
                                    "template value parameter has no symbol",
                                    function,
                                    block));
                        }
                        else if (argument.value.kind
                                     != TemplateValue::Kind::Boolean
                                 && !integer_is_canonical(
                                     argument.value.integer))
                            issues.push_back(
                                issue("TAC1051",
                                      "template integer value is not canonical",
                                      function,
                                      block));
                    }
                    return;
                case Type::Kind::TypeVariable:
                    verify_symbol_spelling(type.variable,
                                           function,
                                           block,
                                           spellings,
                                           issues);
                    if (type.variable.id == 0)
                        issues.push_back(issue("TAC1020",
                                               "type variable has no symbol",
                                               function,
                                               block));
                    return;
            }
        }

        void
        verify_atom(const Atom &atom,
                    const Function &function,
                    BlockId block,
                    const Definitions &definitions,
                    Spellings &spellings,
                    std::vector<VerificationIssue> &issues)
        {
            verify_type(atom.type, function, block, 0, spellings, issues);
            if (atom.kind == Atom::Kind::Variable)
            {
                verify_symbol_spelling(atom.symbol,
                                       function,
                                       block,
                                       spellings,
                                       issues);
                const auto *const found = definitions.find(atom.symbol.id);
                if (found == nullptr)
                    issues.push_back(
                        issue("TAC1021",
                              "atom references an undefined symbol",
                              function,
                              block));
                else if (found->type != atom.type)
                    issues.push_back(
                        issue("TAC1022",
                              "atom type differs from its symbol definition",
                              function,
                              block));
            }
            else if (const auto literal_issue
                     = validate_literal(atom.literal, atom.type))
                issues.push_back(
                    issue("TAC1048",
                          "literal payload is invalid: " + *literal_issue,
                          function,
                          block));
        }

        /// The row of the runtime catalog a runtime call names with its
        /// first operand, or null when that operand names none.
        [[nodiscard]] auto
        runtime_signature(const std::vector<Atom> &operands)
            -> const runtime::Signature *
        {
            if (operands.empty()
                || operands.front().kind != Atom::Kind::Literal)
                return nullptr;
            const auto identity = runtime::IdentityOf(operands.front().literal,
                                                      operands.front().type);
            return identity ? runtime::Find(*identity) : nullptr;
        }

        auto
        expected_primitive_result(Operation operation,
                                  const std::vector<Atom> &operands)
            -> std::optional<Type>
        {
            switch (operation)
            {
                case Operation::Copy:
                    return operands.empty()
                               ? std::nullopt
                               : std::optional<Type>(operands.front().type);
                case Operation::Call:
                    if (operands.empty()
                        || operands.front().type.kind != Type::Kind::Function
                        || operands.front().type.components.empty())
                        return std::nullopt;
                    return operands.front().type.components.back();
                case Operation::LessThan:
                case Operation::LessEqual:
                case Operation::GreaterThan:
                case Operation::GreaterEqual:
                case Operation::Equal:
                case Operation::NotEqual:
                case Operation::LogicalAnd:
                case Operation::LogicalOr:
                case Operation::LogicalNot:
                case Operation::TypeIs:
                    return Type::boolean();
                case Operation::FloorDivide:
                    if (operands.empty())
                        return std::nullopt;
                    return is_floating(operands.front().type)
                               ? Type::int64()
                               : operands.front().type;
                case Operation::Add:
                case Operation::Subtract:
                case Operation::Multiply:
                case Operation::Divide:
                case Operation::Remainder:
                case Operation::Negate:
                case Operation::Power:
                case Operation::ShiftLeft:
                case Operation::ShiftRight:
                case Operation::BitwiseAnd:
                case Operation::BitwiseXor:
                case Operation::BitwiseOr:
                case Operation::BitwiseNot:
                case Operation::Memoize:
                    return operands.empty()
                               ? std::nullopt
                               : std::optional<Type>(operands.front().type);
                case Operation::MakeClosure:
                    return std::nullopt;
                case Operation::RuntimeCall:
                    if (const auto *signature = runtime_signature(operands))
                        return signature->result == runtime::Result::Text
                                   ? Type::string()
                               : signature->result == runtime::Result::Truth
                                   ? Type::boolean()
                                   : Type::unit();
                    return std::nullopt;
            }
            return std::nullopt;
        }

        // Whether a callable of this type can remember its result: it takes
        // no parameters, and its result owns nothing.
        [[nodiscard]] auto
        remembers_result(const Type &type) -> bool
        {
            return type.kind == Type::Kind::Function
                   && type.components.size() == 1U
                   && (type.components.front().kind == Type::Kind::Bool
                       || is_numeric(type.components.front()));
        }

        void
        verify_operation(const Instruction &instruction,
                         const Function &function,
                         BlockId block,
                         const Definitions &definitions,
                         Spellings &spellings,
                         std::vector<VerificationIssue> &issues)
        {
            for (const auto &operand : instruction.operands)
                verify_atom(operand,
                            function,
                            block,
                            definitions,
                            spellings,
                            issues);

            if (instruction.operation == Operation::MakeClosure)
            {
                verify_symbol_spelling(instruction.closure_function,
                                       function,
                                       block,
                                       spellings,
                                       issues);
                const auto *const target
                    = definitions.find(instruction.closure_function.id);
                if (target == nullptr || !target->callable)
                    issues.push_back(issue(
                        "TAC1040",
                        "closure target is not a declared lifted function",
                        function,
                        block));
                if (instruction.type.kind != Type::Kind::Function
                    || instruction.type.components.empty())
                    issues.push_back(
                        issue("TAC1042",
                              "closure result does not have a callable type",
                              function,
                              block));

                for (const auto &capture : instruction.captures)
                {
                    verify_symbol_spelling(capture.symbol,
                                           function,
                                           block,
                                           spellings,
                                           issues);
                    verify_type(capture.type,
                                function,
                                block,
                                0,
                                spellings,
                                issues);
                    verify_atom(capture.value,
                                function,
                                block,
                                definitions,
                                spellings,
                                issues);
                    if (capture.type != capture.value.type)
                        issues.push_back(
                            issue("TAC1043",
                                  "closure capture type differs from its value",
                                  function,
                                  block));
                    if (capture.mode != CaptureMode::Strong
                        && !is_aarc_reference(capture.type))
                        issues.push_back(
                            issue("TAC1044",
                                  "weak or unowned capture requires an AARC "
                                  "reference value",
                                  function,
                                  block));
                }

                if (target != nullptr && target->callable)
                {
                    const auto &lifted = target->type.components;
                    if (lifted.size() <= instruction.captures.size())
                        issues.push_back(
                            issue("TAC1045",
                                  "lifted function has fewer parameters than "
                                  "the capture environment",
                                  function,
                                  block));
                    else
                    {
                        for (std::size_t index = 0;
                             index < instruction.captures.size();
                             ++index)
                            if (instruction.captures[index].type
                                != lifted[index])
                                issues.push_back(
                                    issue("TAC1046",
                                          "lifted capture parameter type does "
                                          "not match its slot",
                                          function,
                                          block));

                        std::vector<Type> public_components(
                            lifted.begin()
                                + static_cast<std::ptrdiff_t>(
                                    instruction.captures.size()),
                            lifted.end());
                        const auto public_type
                            = Type{ Type::Kind::Function,
                                    {},
                                    std::move(public_components),
                                    {},
                                    {} };
                        if (instruction.type != public_type)
                            issues.push_back(
                                issue("TAC1047",
                                      "closure callable type differs from its "
                                      "lifted function suffix",
                                      function,
                                      block));
                    }
                }
                return;
            }

            const auto arity = instruction.operands.size();
            switch (instruction.operation)
            {
                case Operation::Copy:
                    if (arity != 1U)
                        issues.push_back(
                            issue("TAC1023",
                                  "copy requires exactly one operand",
                                  function,
                                  block));
                    break;
                case Operation::TypeIs:
                    if (arity != 2U
                        || (instruction.operands.front().type.kind
                                != Type::Kind::Named
                            && instruction.operands.front().type.kind
                                   != Type::Kind::String
                            && instruction.operands.front().type.kind
                                   != Type::Kind::Function)
                        || instruction.operands.back().type != Type::uint64())
                        issues.push_back(issue("TAC1054",
                                               "type test requires a reference "
                                               "subject and uint identity",
                                               function,
                                               block));
                    break;
                case Operation::Call:
                    if (arity == 0U)
                    {
                        issues.push_back(issue("TAC1024",
                                               "call requires a callee operand",
                                               function,
                                               block));
                        break;
                    }
                    if (instruction.operands.front().type.kind
                            != Type::Kind::Function
                        || instruction.operands.front().type.components.empty())
                    {
                        issues.push_back(
                            issue("TAC1025",
                                  "call callee does not have a function type",
                                  function,
                                  block));
                        break;
                    }
                    {
                        const auto &signature
                            = instruction.operands.front().type.components;
                        const auto parameter_count = signature.size() - 1U;
                        if (arity - 1U != parameter_count)
                            issues.push_back(
                                issue("TAC1026",
                                      "call argument count differs from the "
                                      "callee signature",
                                      function,
                                      block));
                        const auto comparable
                            = std::min(parameter_count, arity - 1U);
                        for (std::size_t index = 0; index < comparable; ++index)
                            if (instruction.operands[index + 1U].type
                                != signature[index])
                                issues.push_back(
                                    issue("TAC1027",
                                          "call argument type differs from the "
                                          "callee signature",
                                          function,
                                          block));
                    }
                    break;
                case Operation::MakeClosure:
                    break;
                case Operation::Negate:
                    if (arity != 1U
                        || (!is_signed_integer(
                                instruction.operands.front().type)
                            && !is_floating(instruction.operands.front().type)))
                        issues.push_back(issue("TAC1028",
                                               "negate requires one signed "
                                               "integer or floating operand",
                                               function,
                                               block));
                    break;
                case Operation::LogicalNot:
                    if (arity != 1U
                        || !accepts_boolean_context(
                            instruction.operands.front().type))
                        issues.push_back(issue(
                            "TAC1029",
                            "logical not requires one bool or numeric operand",
                            function,
                            block));
                    break;
                case Operation::BitwiseNot:
                    if (arity != 1U
                        || !is_integer(instruction.operands.front().type))
                        issues.push_back(
                            issue("TAC1052",
                                  "bitwise not requires one integer operand",
                                  function,
                                  block));
                    break;
                case Operation::RuntimeCall:
                {
                    std::vector<Type::Kind> arguments;
                    arguments.reserve(arity);
                    for (std::size_t index = 1U; index < arity; ++index)
                        arguments.push_back(
                            instruction.operands[index].type.kind);
                    const auto defect = runtime::Check(
                        runtime_signature(instruction.operands),
                        arguments,
                        instruction.type.kind);
                    if (defect != runtime::Defect::None)
                        issues.push_back(
                            issue("TAC1076",
                                  std::string(runtime::Describe(defect)),
                                  function,
                                  block));
                    break;
                }
                case Operation::Memoize:
                    if (arity != 1U
                        || !remembers_result(instruction.operands.front().type))
                        issues.push_back(
                            issue("TAC1074",
                                  "memoization requires one callable without "
                                  "parameters whose result is bool or numeric",
                                  function,
                                  block));
                    break;
                case Operation::ShiftLeft:
                case Operation::ShiftRight:
                case Operation::BitwiseAnd:
                case Operation::BitwiseXor:
                case Operation::BitwiseOr:
                    if (arity != 2U
                        || !is_integer(instruction.operands.front().type)
                        || instruction.operands.front().type
                               != instruction.operands.back().type)
                        issues.push_back(issue("TAC1053",
                                               "bitwise operation requires two "
                                               "equal integer operands",
                                               function,
                                               block));
                    break;
                case Operation::LogicalAnd:
                case Operation::LogicalOr:
                    if (arity != 2U
                        || !accepts_boolean_context(
                            instruction.operands.front().type)
                        || instruction.operands.front().type
                               != instruction.operands.back().type)
                        issues.push_back(issue("TAC1030",
                                               "logical operation requires two "
                                               "equal bool or numeric operands",
                                               function,
                                               block));
                    break;
                case Operation::Equal:
                case Operation::NotEqual:
                    if (arity != 2U
                        || instruction.operands.front().type
                               != instruction.operands.back().type)
                        issues.push_back(issue(
                            "TAC1031",
                            "equality requires two operands of the same type",
                            function,
                            block));
                    break;
                case Operation::LessThan:
                case Operation::LessEqual:
                case Operation::GreaterThan:
                case Operation::GreaterEqual:
                    if (arity != 2U
                        || !is_numeric(instruction.operands.front().type)
                        || instruction.operands.front().type
                               != instruction.operands.back().type)
                        issues.push_back(issue("TAC1032",
                                               "ordered comparison requires "
                                               "two equal numeric types",
                                               function,
                                               block));
                    break;
                default:
                    if (arity != 2U
                        || !is_numeric(instruction.operands.front().type)
                        || instruction.operands.front().type
                               != instruction.operands.back().type)
                        issues.push_back(issue("TAC1033",
                                               "arithmetic operation requires "
                                               "two equal numeric types",
                                               function,
                                               block));
                    break;
            }

            if (instruction.kind == Instruction::Kind::Bind)
            {
                const auto expected
                    = expected_primitive_result(instruction.operation,
                                                instruction.operands);
                if (expected && *expected != instruction.type)
                    issues.push_back(
                        issue("TAC1034",
                              "binding type differs from the operation result",
                              function,
                              block));
            }
        }

        [[nodiscard]] auto
        catalog_module(const CorePrepModule &module) -> ModuleCatalog
        {
            ModuleCatalog catalog;
            catalog.functions.reserve(module.functions.size());
            catalog.spellings.reserve(module.functions.size());
            for (const auto &candidate : module.functions)
            {
                if (candidate.symbol.id != 0
                    && !candidate.symbol.spelling.empty())
                {
                    const auto [found, inserted]
                        = catalog.spellings.emplace(candidate.symbol.id,
                                                    candidate.symbol.spelling);
                    if (!inserted && found->second != candidate.symbol.spelling)
                        ++catalog.conflicting_spellings;
                }
                catalog.functions.emplace(
                    candidate.symbol.id,
                    Definition{ function_type(candidate), false, true });
                for (const auto &block : candidate.blocks)
                    for (const auto &instruction : block.instructions)
                        if (instruction.operation == Operation::MakeClosure)
                        {
                            auto &captured
                                = catalog.captured_parameters
                                      [instruction.closure_function.id];
                            for (const auto &capture : instruction.captures)
                                captured.insert(capture.symbol.id);
                        }
            }
            return catalog;
        }

        void
        collect_definitions(const ModuleCatalog &catalog,
                            const Function &function,
                            Definitions &definitions,
                            Spellings &spellings,
                            std::vector<VerificationIssue> &issues)
        {
            const auto captured
                = catalog.captured_parameters.find(function.symbol.id);
            const auto isCaptured = [&](SymbolId parameter) {
                return captured != catalog.captured_parameters.end()
                       && captured->second.contains(parameter);
            };
            // A conflict among the function symbols of the module is a fault
            // of every function that sees them, as it was when each function
            // entered them into its own table.
            for (std::size_t conflict = 0;
                 conflict < catalog.conflicting_spellings;
                 ++conflict)
                issues.push_back(
                    issue("TAC1014",
                          "one symbol id carries conflicting spellings",
                          function,
                          0));
            for (const auto &parameter : function.parameters)
            {
                verify_symbol_spelling(parameter.symbol,
                                       function,
                                       function.entry,
                                       spellings,
                                       issues);
                verify_type(parameter.type,
                            function,
                            function.entry,
                            0,
                            spellings,
                            issues);
                // Hidden environment parameters are mutable closure-private
                // slots. Source parameters remain immutable unless ordinary
                // lowering introduces storage.
                definitions.emplace(parameter.symbol.id,
                                    Definition{ parameter.type,
                                                isCaptured(parameter.symbol.id),
                                                false });
            }
            for (const auto &block : function.blocks)
                for (const auto &instruction : block.instructions)
                    if (instruction.kind == Instruction::Kind::Bind)
                    {
                        verify_symbol_spelling(instruction.destination,
                                               function,
                                               block.id,
                                               spellings,
                                               issues);
                        verify_type(instruction.type,
                                    function,
                                    block.id,
                                    0,
                                    spellings,
                                    issues);
                        definitions.emplace(
                            instruction.destination.id,
                            Definition{ instruction.type,
                                        instruction.mutable_binding,
                                        false });
                    }
        }

        void
        verify_function(const ModuleCatalog &catalog,
                        const Function &function,
                        std::vector<VerificationIssue> &issues)
        {
            Definitions definitions{ catalog };
            Spellings spellings{ catalog, function.symbol };
            verify_symbol_spelling(function.symbol,
                                   function,
                                   function.entry,
                                   spellings,
                                   issues);
            verify_type(function.return_type,
                        function,
                        function.entry,
                        0,
                        spellings,
                        issues);
            collect_definitions(catalog,
                                function,
                                definitions,
                                spellings,
                                issues);

            for (const auto &block : function.blocks)
            {
                for (const auto &instruction : block.instructions)
                {
                    if (instruction.kind == Instruction::Kind::Assign)
                    {
                        verify_symbol_spelling(instruction.destination,
                                               function,
                                               block.id,
                                               spellings,
                                               issues);
                        const auto *const target
                            = definitions.find(instruction.destination.id);
                        if (target == nullptr)
                            issues.push_back(
                                issue("TAC1035",
                                      "assignment targets an undefined symbol",
                                      function,
                                      block.id));
                        else if (!target->mutable_binding)
                            issues.push_back(
                                issue("TAC1036",
                                      "assignment targets an immutable symbol",
                                      function,
                                      block.id));
                        if (instruction.operands.size() == 1U
                            && target != nullptr
                            && target->type
                                   != instruction.operands.front().type)
                            issues.push_back(issue(
                                "TAC1037",
                                "assignment value type differs from its target",
                                function,
                                block.id));
                    }
                    verify_operation(instruction,
                                     function,
                                     block.id,
                                     definitions,
                                     spellings,
                                     issues);
                }

                switch (block.terminator.kind)
                {
                    case Terminator::Kind::Return:
                        verify_atom(block.terminator.value,
                                    function,
                                    block.id,
                                    definitions,
                                    spellings,
                                    issues);
                        if (block.terminator.value.type != function.return_type)
                            issues.push_back(issue("TAC1038",
                                                   "return atom type differs "
                                                   "from the function result",
                                                   function,
                                                   block.id));
                        break;
                    case Terminator::Kind::Branch:
                        verify_atom(block.terminator.value,
                                    function,
                                    block.id,
                                    definitions,
                                    spellings,
                                    issues);
                        break;
                    case Terminator::Kind::Jump:
                    case Terminator::Kind::Unreachable:
                        break;
                }
            }
        }
    } // namespace

    auto
    verify_semantics(const CorePrepModule &module)
        -> std::vector<VerificationIssue>
    {
        std::vector<VerificationIssue> issues;
        const auto catalog = catalog_module(module);
        for (const auto &function : module.functions)
            verify_function(catalog, function, issues);
        return issues;
    }
} // namespace tala::core
