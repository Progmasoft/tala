// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep.hpp"

namespace Progmasoft::Tala::Core::Callable
{
    /// Owning view of a function type's public parameters and result.
    /// The view hides Core's encoding of the result as the last component.
    struct Signature final
    {
        /// Parameter types in call order.
        std::vector<::tala::core::Type> parameters;
        /// Function result type.
        ::tala::core::Type result{ ::tala::core::Type::unit() };

        /// Compare parameter order and result type.
        /// @return true when both callable signatures match.
        [[nodiscard]] auto
        operator==(const Signature &) const -> bool = default;
    };

    /// Reason a lifted closure target does not match its public signature.
    enum class ClosureContractError : std::uint8_t
    {
        None,                         ///< No signature mismatch was found.
        ResultIsNotCallable,          ///< Public result type is not a function.
        TargetHasTooFewParameters,    ///< Lifted target omits hidden or public
                                      ///< inputs.
        CaptureTypeMismatch,          ///< A hidden capture type differs.
        PublicParameterCountMismatch, ///< Target and public arity differ.
        PublicParameterTypeMismatch,  ///< A public parameter type differs.
        ResultTypeMismatch ///< Target and callable result types differ.
    };

    /// Result of checking the lifted target's hidden and public parameters.
    struct ClosureContract final
    {
        /// First closure-contract failure, or None when valid.
        ClosureContractError error{ ClosureContractError::None };
        /// Parameter index associated with a mismatch, when applicable.
        std::size_t index{};
        /// Public callable signature that the target must implement.
        Signature publicSignature;

        /// Test whether the closure contract is valid.
        /// @return true when error is None.
        [[nodiscard]] explicit
        operator bool() const noexcept
        {
            return error == ClosureContractError::None;
        }
    };

    /// Split a function type into its parameter and result types.
    /// @param type Function type to decompose.
    /// @return Signature when type is callable, otherwise empty.
    [[nodiscard]] auto
    Decompose(const ::tala::core::Type &type) -> std::optional<Signature>;

    /// Construct a function type from an owning signature.
    /// @param signature Parameter and result types to encode.
    /// @return Structural Core function type.
    [[nodiscard]] auto
    Compose(Signature signature) -> ::tala::core::Type;

    /// Validate the target signature of a lifted closure.
    ///
    /// Hidden capture parameters precede public callable parameters, and the
    /// lifted target must return the callable's declared result type.
    /// @param captures Capture parameter types in environment order.
    /// @param targetParameters Complete lifted target parameters.
    /// @param targetResult Lifted target's declared result type.
    /// @param publicCallable Function type exposed at the source level.
    /// @return Contract status, mismatch index, and public signature.
    [[nodiscard]] auto
    ValidateClosure(std::span<const ::tala::core::Type> captures,
                    std::span<const ::tala::core::Type> targetParameters,
                    const ::tala::core::Type &targetResult,
                    const ::tala::core::Type &publicCallable)
        -> ClosureContract;
} // namespace Progmasoft::Tala::Core::Callable
