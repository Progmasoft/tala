// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <shared_mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep.hpp"
#include "Progmasoft/Tala/Namespace.hpp"

namespace Progmasoft::Tala::Core::Template
{
    /// Substitutions for resolved type-parameter symbols.
    using TypeBindingMap
        = std::unordered_map<::tala::core::SymbolId, ::tala::core::Type>;
    /// Substitutions for resolved compile-time value-parameter symbols.
    using ValueBindingMap = std::unordered_map<::tala::core::SymbolId,
                                               ::tala::core::TemplateValue>;

    /// Structural validation failure category for a generic type key.
    enum class IssueKind : std::uint8_t
    {
        DepthExceeded,
        EmptyQualifiedName,
        EmptyNamePart,
        InvalidTypeArgument,
        InvalidValueParameter,
        UnboundParameter,
        InvalidInteger,
        InvalidCharacter,
        NegativeArraySize,
        MalformedArrayFamily
    };

    /// Validation issue with a stable path into the specialization key.
    struct Issue final
    {
        /// Structural failure category.
        IssueKind kind{ IssueKind::InvalidTypeArgument };
        /// Ordered component indexes from the root type to the invalid value.
        std::vector<std::size_t> path;
        /// Human-readable explanation of the failure.
        std::string message;

        /// Compare failure category, component path, and message.
        /// @return true when all issue details match.
        [[nodiscard]] auto
        operator==(const Issue &) const -> bool = default;
    };

    /// Complexity measurements used to enforce generic expansion limits.
    struct Metrics final
    {
        /// Number of visited type nodes.
        std::size_t typeNodes{};
        /// Number of type-valued generic arguments.
        std::size_t typeArguments{};
        /// Number of constant-valued generic arguments.
        std::size_t valueArguments{};
        /// Number of type or value parameter references.
        std::size_t parameterReferences{};
        /// Maximum recursive nesting observed.
        std::size_t maximumDepth{};

        /// Compare every measured template-complexity value.
        /// @return true when all metrics are equal.
        [[nodiscard]] auto
        operator==(const Metrics &) const -> bool = default;
    };

    /// Canonical classification of one supported array type spelling.
    struct ArrayShape final
    {
        /// Distinguishes built-in syntax from the dynamic and fixed
        /// System.Array forms.
        enum class Kind : std::uint8_t
        {
            Builtin, ///< Built-in []T spelling.
            Dynamic, ///< Generic dynamic System.Array<T> spelling.
            Fixed    ///< Generic fixed System.Array<T, N> spelling.
        };

        /// Classified array representation.
        Kind kind{ Kind::Builtin };
        /// Element type retained by this array shape.
        ::tala::core::Type element;
        /// Fixed length for Fixed arrays; empty for the other kinds.
        std::optional<::tala::core::IntegerLiteral> size;

        /// Compare array category, element type, and optional length.
        /// @return true when all shape fields match.
        [[nodiscard]] auto
        operator==(const ArrayShape &) const -> bool = default;
    };

    /// Classify built-in, dynamic System.Array, or fixed System.Array syntax.
    /// @param type Type to inspect.
    /// @return Canonical shape when type is a supported array, otherwise empty.
    [[nodiscard]] auto
    ClassifyArray(const ::tala::core::Type &type) -> std::optional<ArrayShape>;

    /// Validate a type before serialization or specialization-cache insertion.
    /// Issue paths index ordered type/function components from the root.
    /// @param type Structural type key to validate.
    /// @param maximumDepth Maximum accepted recursive type depth.
    /// @return All validation issues, with stable component paths.
    [[nodiscard]] auto
    Validate(const ::tala::core::Type &type, std::size_t maximumDepth = 128U)
        -> std::vector<Issue>;

    /// Measure structural complexity and depth of a generic type key.
    /// @param type Type whose structure is measured.
    /// @return Counts of nodes, arguments, parameters, and maximum depth.
    [[nodiscard]] auto
    Measure(const ::tala::core::Type &type) -> Metrics;
    /// Collect referenced type and value parameters in first-seen order.
    /// @param type Type to inspect.
    /// @return Unique parameter symbol IDs in deterministic traversal order.
    [[nodiscard]] auto
    CollectParameters(const ::tala::core::Type &type)
        -> std::vector<::tala::core::SymbolId>;
    /// Determine whether the type contains no unresolved generic parameters.
    /// @param type Type to inspect.
    /// @return true when every type and value parameter is concrete.
    [[nodiscard]] auto
    IsConcrete(const ::tala::core::Type &type) -> bool;

    /// Substitute known type and value parameters independently.
    /// Unbound parameters remain present to support partial specialization.
    /// @param type Type expression to substitute.
    /// @param typeBindings Resolved type-parameter substitutions.
    /// @param valueBindings Resolved compile-time value substitutions.
    /// @return Type with every available substitution applied.
    [[nodiscard]] auto
    Substitute(const ::tala::core::Type &type,
               const TypeBindingMap &typeBindings,
               const ValueBindingMap &valueBindings) -> ::tala::core::Type;

    /// Render a stable kind-tagged identity for caching and serialization.
    /// The length-prefixed result is not a user-facing type name.
    /// @param type Type whose specialization identity is rendered.
    /// @return Deterministic identity string for equivalent structural types.
    [[nodiscard]] auto
    RenderIdentity(const ::tala::core::Type &type) -> std::string;

    /// Table-local identity assigned to one interned concrete type.
    using SpecializationId = std::uint64_t;

    /// Concrete type and deterministic identity stored in the specialization
    /// table.
    struct Specialization final
    {
        /// Table-local specialization identifier.
        SpecializationId id{};
        /// Stable structural identity used as the table key.
        std::string identity;
        /// Concrete type represented by this table entry.
        ::tala::core::Type type;

        /// Compare identifier, identity string, and structural type.
        /// @return true when all specialization data match.
        [[nodiscard]] auto
        operator==(const Specialization &) const -> bool = default;
    };

    /// Outcome of validating and interning one concrete type.
    struct InternResult final
    {
        /// Interned value when validation succeeds.
        std::optional<Specialization> specialization;
        /// Validation issues when the type cannot be interned.
        std::vector<Issue> issues;
        /// Whether this call inserted a new table entry.
        bool inserted{};

        /// Test whether interning produced a specialization.
        /// @return true when specialization is present.
        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return specialization.has_value();
        }
    };

    /// Thread-safe, deterministic table of concrete type specializations.
    ///
    /// Intern performs a shared lookup first and then rechecks identity under
    /// the exclusive lock, coalescing concurrent insertion races.
    class SpecializationTable final
    {
    public:
        /// Construct an empty specialization table.
        SpecializationTable() = default;
        /// Copying would duplicate synchronization state and is not supported.
        SpecializationTable(const SpecializationTable &) = delete;
        /// Copy assignment is disabled for the same synchronization reason.
        auto
        operator=(const SpecializationTable &)
            -> SpecializationTable & = delete;

        /// Validate and intern a concrete type.
        /// @param type Type to validate and add.
        /// @return Existing or newly inserted specialization, or validation
        /// issues.
        [[nodiscard]] auto
        Intern(const ::tala::core::Type &type) -> InternResult;
        /// Find an interned specialization by its table-local identifier.
        /// @param id Identifier returned by a successful Intern call.
        /// @return Specialization when the identifier is present.
        [[nodiscard]] auto
        Find(SpecializationId id) const -> std::optional<Specialization>;
        /// Find an interned specialization by structural type equality.
        /// @param type Type whose canonical identity is looked up.
        /// @return Matching specialization when one is present.
        [[nodiscard]] auto
        Find(const ::tala::core::Type &type) const
            -> std::optional<Specialization>;
        /// Take a deterministic snapshot of all interned entries.
        /// @return Specializations ordered by table-local identifier.
        [[nodiscard]] auto
        Snapshot() const -> std::vector<Specialization>;
        /// Report the number of interned concrete types.
        /// @return Current entry count.
        [[nodiscard]] auto
        Size() const -> std::size_t;

    private:
        mutable std::shared_mutex mutex_;
        std::unordered_map<std::string, SpecializationId> byIdentity_;
        std::vector<Specialization> entries_;
    };
} // namespace Progmasoft::Tala::Core::Template
