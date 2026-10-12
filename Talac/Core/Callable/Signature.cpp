// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <cstddef>
#include <utility>

#include "Progmasoft/Tala/Core/Callable.hpp"

namespace Progmasoft::Tala::Core::Callable
{
    auto
    Decompose(const ::tala::core::Type &type) -> std::optional<Signature>
    {
        if (type.kind != ::tala::core::Type::Kind::Function
            || type.components.empty())
            return std::nullopt;

        Signature signature;
        signature.parameters.assign(type.components.begin(),
                                    type.components.end() - 1);
        signature.result = type.components.back();
        return signature;
    }

    auto
    Compose(Signature signature) -> ::tala::core::Type
    {
        return ::tala::core::Type::function(std::move(signature.parameters),
                                            std::move(signature.result));
    }

    auto
    ValidateClosure(std::span<const ::tala::core::Type> captures,
                    std::span<const ::tala::core::Type> targetParameters,
                    const ::tala::core::Type &targetResult,
                    const ::tala::core::Type &publicCallable) -> ClosureContract
    {
        ClosureContract contract;
        const auto signature = Decompose(publicCallable);
        if (!signature)
        {
            contract.error = ClosureContractError::ResultIsNotCallable;
            return contract;
        }
        contract.publicSignature = *signature;

        if (targetParameters.size() < captures.size())
        {
            contract.error = ClosureContractError::TargetHasTooFewParameters;
            contract.index = targetParameters.size();
            return contract;
        }

        for (std::size_t index = 0; index < captures.size(); ++index)
            if (captures[index] != targetParameters[index])
            {
                contract.error = ClosureContractError::CaptureTypeMismatch;
                contract.index = index;
                return contract;
            }

        const auto publicParameterCount
            = targetParameters.size() - captures.size();
        if (publicParameterCount != signature->parameters.size())
        {
            contract.error = ClosureContractError::PublicParameterCountMismatch;
            contract.index = publicParameterCount;
            return contract;
        }

        for (std::size_t index = 0; index < publicParameterCount; ++index)
            if (targetParameters[captures.size() + index]
                != signature->parameters[index])
            {
                contract.error
                    = ClosureContractError::PublicParameterTypeMismatch;
                contract.index = index;
                return contract;
            }

        if (targetResult != signature->result)
        {
            contract.error = ClosureContractError::ResultTypeMismatch;
            return contract;
        }
        return contract;
    }
} // namespace Progmasoft::Tala::Core::Callable
