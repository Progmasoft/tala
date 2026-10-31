// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <algorithm>
#include <utility>

#include "Progmasoft/Tala/Core/Ownership.hpp"

namespace tala::core
{
    namespace
    {
        [[nodiscard]] auto
        IntrinsicStorage(const Type &type) noexcept
            -> std::optional<StorageClass>
        {
            switch (type.kind)
            {
                case Type::Kind::Unit:
                case Type::Kind::Bool:
                case Type::Kind::Character:
                case Type::Kind::Int8:
                case Type::Kind::Int16:
                case Type::Kind::Int32:
                case Type::Kind::Int64:
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
                    return StorageClass::TrivialValue;

                // String has reference identity even when its character
                // storage uses CoW internally. Callable values likewise own
                // an AARC closure environment rather than behaving as data.
                case Type::Kind::String:
                case Type::Kind::Function:
                    return StorageClass::AarcReference;

                case Type::Kind::Named:
                case Type::Kind::TypeVariable:
                    return std::nullopt;
            }
            return std::nullopt;
        }

        [[nodiscard]] auto
        NameLess(std::span<const std::u32string> left,
                 std::span<const std::u32string> right) noexcept -> bool
        {
            return std::lexicographical_compare(left.begin(),
                                                left.end(),
                                                right.begin(),
                                                right.end());
        }

        [[nodiscard]] auto
        NameEqual(std::span<const std::u32string> left,
                  std::span<const std::u32string> right) noexcept -> bool
        {
            return std::ranges::equal(left, right);
        }

        template<typename Classifier>
        [[nodiscard]] auto
        RefineConstructedValue(const Type &type,
                               StorageClass outer,
                               const Classifier &classify) noexcept
            -> StorageClass
        {
            // A reference declaration stays a reference independently of its
            // arguments. Only a value declaration needs recursive refinement.
            if (outer != StorageClass::CopyOnWriteValue)
                return outer;

            bool hasUnresolvedArgument = false;
            for (const auto &argument : type.templateArguments)
            {
                // Compile-time value arguments affect specialization identity,
                // not value/reference classification.
                if (argument.kind == TemplateArgument::Kind::Value)
                    continue;
                if (!argument.type)
                {
                    hasUnresolvedArgument = true;
                    continue;
                }

                const auto nested = classify(*argument.type);
                if (nested == StorageClass::AarcReference)
                    return StorageClass::AarcReference;
                if (nested == StorageClass::Unresolved)
                    hasUnresolvedArgument = true;
            }

            // An unresolved argument cannot hide a known reference argument.
            // Deferring the unresolved result until every type argument has
            // been inspected makes classification independent of source order.
            return hasUnresolvedArgument ? StorageClass::Unresolved
                                         : StorageClass::CopyOnWriteValue;
        }
    } // namespace

    auto
    NominalTypeCatalog::Register(std::vector<std::u32string> name,
                                 NominalKind kind) -> bool
    {
        if (name.empty()
            || std::ranges::any_of(name, [](const auto &component) {
                   return component.empty();
               }))
            return false;

        const auto key = std::span<const std::u32string>(name);
        const auto insertion
            = std::lower_bound(declarations_.begin(),
                               declarations_.end(),
                               key,
                               [](const NominalTypeDeclaration &declaration,
                                  std::span<const std::u32string> candidate) {
                                   return NameLess(declaration.name, candidate);
                               });
        if (insertion != declarations_.end() && NameEqual(insertion->name, key))
            return false;
        declarations_.insert(insertion,
                             NominalTypeDeclaration{ std::move(name), kind });
        return true;
    }

    auto
    NominalTypeCatalog::Lookup(std::span<const std::u32string> name)
        const noexcept -> std::optional<NominalKind>
    {
        const auto found
            = std::lower_bound(declarations_.begin(),
                               declarations_.end(),
                               name,
                               [](const NominalTypeDeclaration &declaration,
                                  std::span<const std::u32string> candidate) {
                                   return NameLess(declaration.name, candidate);
                               });
        if (found != declarations_.end() && NameEqual(found->name, name))
            return found->kind;
        return std::nullopt;
    }

    auto
    NominalTypeCatalog::Size() const noexcept -> std::size_t
    {
        return declarations_.size();
    }

    auto
    NominalTypeCatalog::Empty() const noexcept -> bool
    {
        return declarations_.empty();
    }

    auto
    ClassifyNominal(NominalKind kind) noexcept -> StorageClass
    {
        switch (kind)
        {
            case NominalKind::Data:
            case NominalKind::Type:
            case NominalKind::ClassicEnum:
                return StorageClass::CopyOnWriteValue;
            case NominalKind::Class:
            case NominalKind::DataClass:
            case NominalKind::EnumClass:
            case NominalKind::Object:
            case NominalKind::Interface:
                return StorageClass::AarcReference;
        }
        return StorageClass::Unresolved;
    }

    auto
    ClassifyType(const Type &type, std::optional<NominalKind> nominal) noexcept
        -> StorageClass
    {
        if (const auto intrinsic = IntrinsicStorage(type))
            return *intrinsic;
        if (type.kind != Type::Kind::Named || !nominal)
            return StorageClass::Unresolved;

        return RefineConstructedValue(type,
                                      ClassifyNominal(*nominal),
                                      [](const Type &nested) {
                                          return ClassifyType(nested);
                                      });
    }

    auto
    ClassifyType(const Type &type, const NominalTypeCatalog &catalog) noexcept
        -> StorageClass
    {
        if (const auto intrinsic = IntrinsicStorage(type))
            return *intrinsic;
        if (type.kind != Type::Kind::Named)
            return StorageClass::Unresolved;

        const auto nominal = catalog.Lookup(type.name);
        if (!nominal)
            return StorageClass::Unresolved;
        return RefineConstructedValue(type,
                                      ClassifyNominal(*nominal),
                                      [&catalog](const Type &nested) {
                                          return ClassifyType(nested, catalog);
                                      });
    }

    auto
    UsesAarc(const Type &type, std::optional<NominalKind> nominal) noexcept
        -> bool
    {
        return ClassifyType(type, nominal) == StorageClass::AarcReference;
    }

    auto
    UsesCopyOnWrite(const Type &type,
                    std::optional<NominalKind> nominal) noexcept -> bool
    {
        return ClassifyType(type, nominal) == StorageClass::CopyOnWriteValue;
    }

    auto
    UsesAarc(const Type &type, const NominalTypeCatalog &catalog) noexcept
        -> bool
    {
        return ClassifyType(type, catalog) == StorageClass::AarcReference;
    }

    auto
    UsesCopyOnWrite(const Type &type,
                    const NominalTypeCatalog &catalog) noexcept -> bool
    {
        return ClassifyType(type, catalog) == StorageClass::CopyOnWriteValue;
    }
} // namespace tala::core
