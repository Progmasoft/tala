// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep.hpp"

namespace tala::core
{
    /// Semantic ownership/storage category, independent of target memory
    /// layout. Copy-on-write values preserve value semantics even when sharing
    /// buffers.
    enum class StorageClass : std::uint8_t
    {
        TrivialValue,     ///< Value has no managed reference storage.
        CopyOnWriteValue, ///< Value semantics with shared copy-on-write
                          ///< storage.
        AarcReference,    ///< Reference value managed by AARC ownership rules.
        Unresolved ///< Nominal declaration metadata is not yet available.
    };

    /// Source declaration family used to classify nominal ownership semantics.
    /// The family is explicit metadata; it is never guessed from type spelling.
    enum class NominalKind : std::uint8_t
    {
        Data,        ///< Value-like data declaration.
        Type,        ///< Named value type declaration.
        ClassicEnum, ///< Value-like classic enumeration.
        Class,       ///< Reference type declaration.
        DataClass,   ///< Value-like class declaration.
        EnumClass,   ///< Reference-like enumeration declaration.
        Object,      ///< Root reference object declaration.
        Interface    ///< Reference contract declaration.
    };

    /// Qualified nominal type name and its declared family.
    struct NominalTypeDeclaration final
    {
        /// Fully qualified name as Unicode segments.
        std::vector<std::u32string> name;
        /// Source declaration family controlling ownership classification.
        NominalKind kind{ NominalKind::Class };

        /// Compare qualified identity and nominal declaration family.
        /// @return true when both fields match.
        [[nodiscard]] auto
        operator==(const NominalTypeDeclaration &) const -> bool = default;
    };

    /// Sorted catalog mapping resolved names to source declaration families.
    ///
    /// Lookup is deterministic and allocation-free, and never infers ownership
    /// from spelling or a process-dependent hash.
    class NominalTypeCatalog final
    {
    public:
        /// Register a nominal declaration unless its qualified name exists.
        /// @param name Qualified source name as Unicode segments.
        /// @param kind Declaration family associated with name.
        /// @return true when inserted; false when the name was already present.
        [[nodiscard]] auto
        Register(std::vector<std::u32string> name, NominalKind kind) -> bool;
        /// Find the declaration family for a qualified nominal name.
        /// @param name Qualified source name to look up.
        /// @return The registered family, or empty when name is unknown.
        [[nodiscard]] auto
        Lookup(std::span<const std::u32string> name) const noexcept
            -> std::optional<NominalKind>;
        /// Report the number of nominal declarations in the catalog.
        /// @return Current declaration count.
        [[nodiscard]] auto
        Size() const noexcept -> std::size_t;
        /// Check whether the catalog has no registered declarations.
        /// @return true when no names have been registered.
        [[nodiscard]] auto
        Empty() const noexcept -> bool;

    private:
        std::vector<NominalTypeDeclaration> declarations_;
    };

    /// Classify a known declaration family using Tala ownership rules.
    /// @param kind Source declaration family.
    /// @return Semantic storage class for that declaration.
    [[nodiscard]] auto
    ClassifyNominal(NominalKind kind) noexcept -> StorageClass;
    /// Classify a structural type using optional nominal declaration metadata.
    /// @param type Type to classify.
    /// @param nominal Family for a Named type, when already resolved.
    /// @return Ownership category; unresolved names remain Unresolved.
    [[nodiscard]] auto
    ClassifyType(const Type &type,
                 std::optional<NominalKind> nominal = std::nullopt) noexcept
        -> StorageClass;
    /// Classify a structural type using the declaration catalog.
    /// @param type Type to classify.
    /// @param catalog Resolved nominal declarations available to the analysis.
    /// @return Ownership category with nested generic arguments considered.
    [[nodiscard]] auto
    ClassifyType(const Type &type, const NominalTypeCatalog &catalog) noexcept
        -> StorageClass;
    /// Test whether a type requires AARC reference counting.
    /// @param type Type to inspect.
    /// @param nominal Optional declaration family for a nominal type.
    /// @return true when classification yields AarcReference.
    [[nodiscard]] auto
    UsesAarc(const Type &type,
             std::optional<NominalKind> nominal = std::nullopt) noexcept
        -> bool;
    /// Test whether a type uses copy-on-write value storage.
    /// @param type Type to inspect.
    /// @param nominal Optional declaration family for a nominal type.
    /// @return true when classification yields CopyOnWriteValue.
    [[nodiscard]] auto
    UsesCopyOnWrite(const Type &type,
                    std::optional<NominalKind> nominal = std::nullopt) noexcept
        -> bool;
    /// Test whether a catalog-resolved type requires AARC reference counting.
    /// @param type Type to inspect.
    /// @param catalog Nominal declarations used to classify nested types.
    /// @return true when classification yields AarcReference.
    [[nodiscard]] auto
    UsesAarc(const Type &type, const NominalTypeCatalog &catalog) noexcept
        -> bool;
    /// Test whether a catalog-resolved type uses copy-on-write storage.
    /// @param type Type to inspect.
    /// @param catalog Nominal declarations used to classify nested types.
    /// @return true when classification yields CopyOnWriteValue.
    [[nodiscard]] auto
    UsesCopyOnWrite(const Type &type,
                    const NominalTypeCatalog &catalog) noexcept -> bool;
} // namespace tala::core
