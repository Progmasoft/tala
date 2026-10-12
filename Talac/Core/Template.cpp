// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <algorithm>
#include <array>
#include <charconv>
#include <mutex>
#include <ranges>
#include <string_view>
#include <utility>

#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Core/Template.hpp"

namespace Progmasoft::Tala::Core::Template
{
    namespace
    {
        namespace Model = ::tala::core;

        constexpr std::array<char, 16> kHexDigits{ '0', '1', '2', '3', '4', '5',
                                                   '6', '7', '8', '9', 'a', 'b',
                                                   'c', 'd', 'e', 'f' };

        [[nodiscard]] auto
        IsName(const Model::Type &type,
               const std::initializer_list<std::u32string_view> expected)
            -> bool
        {
            if (type.kind != Model::Type::Kind::Named
                || type.name.size() != expected.size())
                return false;
            return std::ranges::equal(type.name,
                                      expected,
                                      {},
                                      [](const auto &part) {
                                          return std::u32string_view(part);
                                      });
        }

        [[nodiscard]] auto
        TypeArgument(const Model::TemplateArgument &argument)
            -> const Model::Type *
        {
            return argument.kind == Model::TemplateArgument::Kind::Type
                           && argument.type
                       ? argument.type.get()
                       : nullptr;
        }

        [[nodiscard]] auto
        IsUnicodeScalar(const Model::IntegerLiteral &value) -> bool
        {
            if (value.negative || !Model::integer_is_canonical(value)
                || value.magnitude.size() > 3U)
                return false;
            std::uint32_t scalar{};
            for (const auto octet : value.magnitude)
                scalar = (scalar << 8U) | octet;
            return scalar <= 0x10ffffU
                   && (scalar < 0xd800U || scalar > 0xdfffU);
        }

        [[nodiscard]] auto
        IsNegative(const Model::IntegerLiteral &value) -> bool
        {
            return value.negative && !value.magnitude.empty();
        }

        void
        AddIssue(std::vector<Issue> &issues,
                 IssueKind kind,
                 const std::vector<std::size_t> &path,
                 std::string message)
        {
            issues.push_back(Issue{ kind, path, std::move(message) });
        }

        void
        ValidateParameter(const Model::SymbolName &parameter,
                          const std::vector<std::size_t> &path,
                          std::vector<Issue> &issues)
        {
            if (parameter.id == 0U)
                AddIssue(issues,
                         IssueKind::InvalidValueParameter,
                         path,
                         "template parameter SymbolId must be positive");
            if (parameter.spelling.empty())
                AddIssue(issues,
                         IssueKind::InvalidValueParameter,
                         path,
                         "template parameter spelling cannot be empty");
        }

        void
        ValidateValue(const Model::TemplateValue &value,
                      const std::vector<std::size_t> &path,
                      std::vector<Issue> &issues)
        {
            switch (value.kind)
            {
                case Model::TemplateValue::Kind::Boolean:
                    return;
                case Model::TemplateValue::Kind::Parameter:
                    ValidateParameter(value.parameter, path, issues);
                    return;
                case Model::TemplateValue::Kind::Integer:
                    if (!Model::integer_is_canonical(value.integer))
                        AddIssue(issues,
                                 IssueKind::InvalidInteger,
                                 path,
                                 "template integer is not canonical");
                    return;
                case Model::TemplateValue::Kind::Character:
                    if (!IsUnicodeScalar(value.integer))
                        AddIssue(issues,
                                 IssueKind::InvalidCharacter,
                                 path,
                                 "template character is not a Unicode scalar");
                    return;
            }
        }

        void
        ValidateArray(const Model::Type &type,
                      const std::vector<std::size_t> &path,
                      std::vector<Issue> &issues)
        {
            if (IsName(type, { U"[]" }))
            {
                if (type.templateArguments.size() != 1U
                    || TypeArgument(type.templateArguments.front()) == nullptr)
                    AddIssue(issues,
                             IssueKind::MalformedArrayFamily,
                             path,
                             "built-in [] requires exactly one type argument");
                return;
            }
            if (!IsName(type, { U"System", U"Array" }))
                return;
            if (type.templateArguments.size() == 1U
                && TypeArgument(type.templateArguments.front()) != nullptr)
                return;
            if (type.templateArguments.size() == 2U
                && TypeArgument(type.templateArguments.front()) != nullptr)
            {
                const auto &size = type.templateArguments[1U];
                if (size.kind == Model::TemplateArgument::Kind::Value
                    && size.value.kind == Model::TemplateValue::Kind::Integer)
                {
                    if (IsNegative(size.value.integer))
                    {
                        auto sizePath = path;
                        sizePath.push_back(1U);
                        AddIssue(issues,
                                 IssueKind::NegativeArraySize,
                                 sizePath,
                                 "fixed System.Array size cannot be negative");
                    }
                    return;
                }
                if (size.kind == Model::TemplateArgument::Kind::Value
                    && size.value.kind == Model::TemplateValue::Kind::Parameter)
                    return;
            }
            AddIssue(issues,
                     IssueKind::MalformedArrayFamily,
                     path,
                     "System.Array requires <T> or <T, integral size N>");
        }

        void
        ValidateType(const Model::Type &type,
                     std::size_t depth,
                     std::size_t maximumDepth,
                     std::vector<std::size_t> &path,
                     std::vector<Issue> &issues)
        {
            if (depth > maximumDepth)
            {
                AddIssue(issues,
                         IssueKind::DepthExceeded,
                         path,
                         "template type nesting exceeds the configured limit");
                return;
            }

            if (type.kind == Model::Type::Kind::Named)
            {
                if (type.name.empty())
                    AddIssue(issues,
                             IssueKind::EmptyQualifiedName,
                             path,
                             "named type has an empty qualified name");
                for (std::size_t index = 0; index < type.name.size(); ++index)
                {
                    if (type.name[index].empty())
                    {
                        auto namePath = path;
                        namePath.push_back(index);
                        AddIssue(issues,
                                 IssueKind::EmptyNamePart,
                                 namePath,
                                 "named type contains an empty name component");
                    }
                }
                if (!type.components.empty())
                    AddIssue(issues,
                             IssueKind::InvalidTypeArgument,
                             path,
                             "named type contains function components");
                for (std::size_t index = 0;
                     index < type.templateArguments.size();
                     ++index)
                {
                    path.push_back(index);
                    const auto &argument = type.templateArguments[index];
                    if (argument.kind == Model::TemplateArgument::Kind::Type)
                    {
                        if (!argument.type)
                            AddIssue(issues,
                                     IssueKind::InvalidTypeArgument,
                                     path,
                                     "type template argument has no payload");
                        else
                            ValidateType(*argument.type,
                                         depth + 1U,
                                         maximumDepth,
                                         path,
                                         issues);
                    }
                    else
                        ValidateValue(argument.value, path, issues);
                    path.pop_back();
                }
                ValidateArray(type, path, issues);
                return;
            }

            if (!type.templateArguments.empty())
                AddIssue(issues,
                         IssueKind::InvalidTypeArgument,
                         path,
                         "non-named type contains template arguments");
            if (type.kind == Model::Type::Kind::Function)
            {
                if (type.components.empty())
                    AddIssue(issues,
                             IssueKind::InvalidTypeArgument,
                             path,
                             "function type has no result component");
                for (std::size_t index = 0; index < type.components.size();
                     ++index)
                {
                    path.push_back(index);
                    ValidateType(type.components[index],
                                 depth + 1U,
                                 maximumDepth,
                                 path,
                                 issues);
                    path.pop_back();
                }
                return;
            }
            if (type.kind == Model::Type::Kind::TypeVariable)
                ValidateParameter(type.variable, path, issues);
            else if (!type.components.empty() || !type.name.empty()
                     || type.variable.id != 0U)
                AddIssue(issues,
                         IssueKind::InvalidTypeArgument,
                         path,
                         "scalar type contains aggregate payload");
        }

        [[nodiscard]] auto
        Add(Metrics left, const Metrics &right) -> Metrics
        {
            left.typeNodes += right.typeNodes;
            left.typeArguments += right.typeArguments;
            left.valueArguments += right.valueArguments;
            left.parameterReferences += right.parameterReferences;
            left.maximumDepth = std::max(left.maximumDepth, right.maximumDepth);
            return left;
        }

        [[nodiscard]] auto
        MeasureType(const Model::Type &type, std::size_t depth) -> Metrics
        {
            Metrics result{ 1U,
                            0U,
                            0U,
                            type.kind == Model::Type::Kind::TypeVariable ? 1U
                                                                         : 0U,
                            depth };
            for (const auto &component : type.components)
                result = Add(result, MeasureType(component, depth + 1U));
            for (const auto &argument : type.templateArguments)
            {
                if (argument.kind == Model::TemplateArgument::Kind::Type)
                {
                    ++result.typeArguments;
                    if (argument.type)
                        result = Add(result,
                                     MeasureType(*argument.type, depth + 1U));
                }
                else
                {
                    ++result.valueArguments;
                    result.maximumDepth
                        = std::max(result.maximumDepth, depth + 1U);
                    if (argument.value.kind
                        == Model::TemplateValue::Kind::Parameter)
                        ++result.parameterReferences;
                }
            }
            return result;
        }

        void
        Collect(const Model::Type &type,
                std::vector<Model::SymbolId> &parameters)
        {
            if (type.kind == Model::Type::Kind::TypeVariable)
                parameters.push_back(type.variable.id);
            for (const auto &component : type.components)
                Collect(component, parameters);
            for (const auto &argument : type.templateArguments)
            {
                if (argument.kind == Model::TemplateArgument::Kind::Type
                    && argument.type)
                    Collect(*argument.type, parameters);
                else if (argument.kind == Model::TemplateArgument::Kind::Value
                         && argument.value.kind
                                == Model::TemplateValue::Kind::Parameter)
                    parameters.push_back(argument.value.parameter.id);
            }
        }

        [[nodiscard]] auto
        SubstituteType(const Model::Type &type,
                       const TypeBindingMap &typeBindings,
                       const ValueBindingMap &valueBindings) -> Model::Type
        {
            if (type.kind == Model::Type::Kind::TypeVariable)
            {
                if (const auto replacement
                    = typeBindings.find(type.variable.id);
                    replacement != typeBindings.end())
                    return replacement->second;
                return type;
            }

            auto result = type;
            for (auto &component : result.components)
                component
                    = SubstituteType(component, typeBindings, valueBindings);
            for (auto &argument : result.templateArguments)
            {
                if (argument.kind == Model::TemplateArgument::Kind::Type
                    && argument.type)
                {
                    argument = Model::TemplateArgument::type_argument(
                        SubstituteType(*argument.type,
                                       typeBindings,
                                       valueBindings));
                }
                else if (argument.kind == Model::TemplateArgument::Kind::Value
                         && argument.value.kind
                                == Model::TemplateValue::Kind::Parameter)
                {
                    if (const auto replacement
                        = valueBindings.find(argument.value.parameter.id);
                        replacement != valueBindings.end())
                        argument = Model::TemplateArgument::value_argument(
                            replacement->second);
                }
            }
            return result;
        }

        void
        AppendUnsigned(std::string &output, std::size_t value)
        {
            std::array<char, 32> buffer{};
            const auto result = std::to_chars(buffer.data(),
                                              buffer.data() + buffer.size(),
                                              value);
            output.append(buffer.data(), result.ptr);
        }

        void
        AppendText(std::string &output, std::u32string_view text)
        {
            AppendUnsigned(output, text.size());
            output.push_back(':');
            for (const auto scalar : text)
            {
                output.push_back(
                    kHexDigits[(static_cast<std::uint32_t>(scalar) >> 20U)
                               & 0xfU]);
                output.push_back(
                    kHexDigits[(static_cast<std::uint32_t>(scalar) >> 16U)
                               & 0xfU]);
                output.push_back(
                    kHexDigits[(static_cast<std::uint32_t>(scalar) >> 12U)
                               & 0xfU]);
                output.push_back(
                    kHexDigits[(static_cast<std::uint32_t>(scalar) >> 8U)
                               & 0xfU]);
                output.push_back(
                    kHexDigits[(static_cast<std::uint32_t>(scalar) >> 4U)
                               & 0xfU]);
                output.push_back(
                    kHexDigits[static_cast<std::uint32_t>(scalar) & 0xfU]);
            }
        }

        void
        RenderInteger(std::string &output, const Model::IntegerLiteral &integer)
        {
            output.push_back(integer.negative ? '-' : '+');
            AppendUnsigned(output, integer.magnitude.size());
            output.push_back(':');
            for (const auto octet : integer.magnitude)
            {
                output.push_back(kHexDigits[octet >> 4U]);
                output.push_back(kHexDigits[octet & 0xfU]);
            }
        }

        void
        RenderSymbol(std::string &output, const Model::SymbolName &symbol)
        {
            AppendUnsigned(output, symbol.id);
            output.push_back('@');
            AppendText(output, symbol.spelling);
        }

        void
        RenderType(std::string &output, const Model::Type &type)
        {
            output.push_back('T');
            AppendUnsigned(output, static_cast<std::size_t>(type.kind));
            output.push_back('{');
            if (type.kind == Model::Type::Kind::Named)
            {
                AppendUnsigned(output, type.name.size());
                output.push_back(':');
                for (const auto &part : type.name)
                    AppendText(output, part);
                output.push_back('<');
                for (const auto &argument : type.templateArguments)
                {
                    if (argument.kind == Model::TemplateArgument::Kind::Type)
                    {
                        output.push_back('t');
                        if (argument.type)
                            RenderType(output, *argument.type);
                        else
                            output.append("null");
                    }
                    else
                    {
                        output.push_back('v');
                        AppendUnsigned(
                            output,
                            static_cast<std::size_t>(argument.value.kind));
                        output.push_back(':');
                        switch (argument.value.kind)
                        {
                            case Model::TemplateValue::Kind::Integer:
                            case Model::TemplateValue::Kind::Character:
                                RenderInteger(output, argument.value.integer);
                                break;
                            case Model::TemplateValue::Kind::Boolean:
                                output.push_back(argument.value.boolean ? '1'
                                                                        : '0');
                                break;
                            case Model::TemplateValue::Kind::Parameter:
                                RenderSymbol(output, argument.value.parameter);
                                break;
                        }
                    }
                    output.push_back(';');
                }
                output.push_back('>');
            }
            else if (type.kind == Model::Type::Kind::Function)
            {
                AppendUnsigned(output, type.components.size());
                output.push_back(':');
                for (const auto &component : type.components)
                    RenderType(output, component);
            }
            else if (type.kind == Model::Type::Kind::TypeVariable)
                RenderSymbol(output, type.variable);
            output.push_back('}');
        }
    } // namespace

    auto
    ClassifyArray(const Model::Type &type) -> std::optional<ArrayShape>
    {
        if (IsName(type, { U"[]" }) && type.templateArguments.size() == 1U)
        {
            if (const auto *element = TypeArgument(type.templateArguments[0U]))
                return ArrayShape{ ArrayShape::Kind::Builtin,
                                   *element,
                                   std::nullopt };
        }
        if (!IsName(type, { U"System", U"Array" })
            || type.templateArguments.empty())
            return std::nullopt;
        const auto *element = TypeArgument(type.templateArguments[0U]);
        if (element == nullptr)
            return std::nullopt;
        if (type.templateArguments.size() == 1U)
            return ArrayShape{ ArrayShape::Kind::Dynamic,
                               *element,
                               std::nullopt };
        if (type.templateArguments.size() == 2U)
        {
            const auto &size = type.templateArguments[1U];
            if (size.kind == Model::TemplateArgument::Kind::Value
                && size.value.kind == Model::TemplateValue::Kind::Integer)
                return ArrayShape{ ArrayShape::Kind::Fixed,
                                   *element,
                                   size.value.integer };
        }
        return std::nullopt;
    }

    auto
    Validate(const Model::Type &type, const std::size_t maximumDepth)
        -> std::vector<Issue>
    {
        std::vector<Issue> issues;
        std::vector<std::size_t> path;
        ValidateType(type, 0U, maximumDepth, path, issues);
        return issues;
    }

    auto
    Measure(const Model::Type &type) -> Metrics
    {
        return MeasureType(type, 0U);
    }

    auto
    CollectParameters(const Model::Type &type) -> std::vector<Model::SymbolId>
    {
        std::vector<Model::SymbolId> parameters;
        Collect(type, parameters);
        std::ranges::sort(parameters);
        const auto duplicate = std::ranges::unique(parameters);
        parameters.erase(duplicate.begin(), duplicate.end());
        return parameters;
    }

    auto
    IsConcrete(const Model::Type &type) -> bool
    {
        return CollectParameters(type).empty();
    }

    auto
    Substitute(const Model::Type &type,
               const TypeBindingMap &typeBindings,
               const ValueBindingMap &valueBindings) -> Model::Type
    {
        return SubstituteType(type, typeBindings, valueBindings);
    }

    auto
    RenderIdentity(const Model::Type &type) -> std::string
    {
        std::string result;
        result.reserve(128U);
        RenderType(result, type);
        return result;
    }

    auto
    SpecializationTable::Intern(const Model::Type &type) -> InternResult
    {
        auto issues = Validate(type);
        if (!issues.empty())
            return InternResult{ std::nullopt, std::move(issues), false };
        if (!IsConcrete(type))
        {
            issues.push_back(
                Issue{ IssueKind::UnboundParameter,
                       {},
                       "specialization table accepts only concrete types" });
            return InternResult{ std::nullopt, std::move(issues), false };
        }

        auto identity = RenderIdentity(type);
        {
            const std::shared_lock lock(mutex_);
            if (const auto found = byIdentity_.find(identity);
                found != byIdentity_.end())
                return InternResult{ entries_.at(static_cast<std::size_t>(
                                         found->second - 1U)),
                                     {},
                                     false };
        }

        const std::unique_lock lock(mutex_);
        if (const auto found = byIdentity_.find(identity);
            found != byIdentity_.end())
            return InternResult{ entries_.at(static_cast<std::size_t>(
                                     found->second - 1U)),
                                 {},
                                 false };

        const auto id = static_cast<SpecializationId>(entries_.size()) + 1U;
        Specialization entry{ id, std::move(identity), type };
        byIdentity_.emplace(entry.identity, id);
        entries_.push_back(entry);
        return InternResult{ std::move(entry), {}, true };
    }

    auto
    SpecializationTable::Find(const SpecializationId id) const
        -> std::optional<Specialization>
    {
        const std::shared_lock lock(mutex_);
        if (id == 0U || id > entries_.size())
            return std::nullopt;
        return entries_[static_cast<std::size_t>(id - 1U)];
    }

    auto
    SpecializationTable::Find(const Model::Type &type) const
        -> std::optional<Specialization>
    {
        const auto identity = RenderIdentity(type);
        const std::shared_lock lock(mutex_);
        const auto found = byIdentity_.find(identity);
        if (found == byIdentity_.end())
            return std::nullopt;
        return entries_[static_cast<std::size_t>(found->second - 1U)];
    }

    auto
    SpecializationTable::Snapshot() const -> std::vector<Specialization>
    {
        const std::shared_lock lock(mutex_);
        return entries_;
    }

    auto
    SpecializationTable::Size() const -> std::size_t
    {
        const std::shared_lock lock(mutex_);
        return entries_.size();
    }
} // namespace Progmasoft::Tala::Core::Template
