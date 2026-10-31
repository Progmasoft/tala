// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <array>
#include <vector>

#include "Progmasoft/Tala/Core/Callable.hpp"

namespace
{
    namespace Callable = Progmasoft::Tala::Core::Callable;
    namespace Core = tala::core;

    [[nodiscard]] auto
    PublicSignature() -> Core::Type
    {
        return Core::Type::function(
            { Core::Type::int64(), Core::Type::boolean() },
            Core::Type::string());
    }

    [[nodiscard]] auto
    TargetParameters() -> std::vector<Core::Type>
    {
        // Lifted targets receive environment fields before source-visible
        // arguments.
        return {
            Core::Type::string(),
            Core::Type::int32(),
            Core::Type::int64(),
            Core::Type::boolean(),
        };
    }

    [[nodiscard]] auto
    Captures() -> std::vector<Core::Type>
    {
        return { Core::Type::string(), Core::Type::int32() };
    }
} // namespace

TEST_CASE("callable signatures decompose public parameters and result")
{
    const auto signature = Callable::Decompose(PublicSignature());
    REQUIRE(signature);
    REQUIRE(signature->parameters.size() == 2U);
    CHECK(signature->parameters[0] == Core::Type::int64());
    CHECK(signature->parameters[1] == Core::Type::boolean());
    CHECK(signature->result == Core::Type::string());
}

TEST_CASE(
    "callable signatures compose without exposing their packed Type layout")
{
    Callable::Signature signature;
    signature.parameters = { Core::Type::int8(), Core::Type::float64() };
    signature.result = Core::Type::uint128();

    const auto type = Callable::Compose(signature);
    const auto roundTrip = Callable::Decompose(type);
    REQUIRE(roundTrip);
    CHECK(*roundTrip == signature);
}

TEST_CASE("non-callable types do not acquire an invented signature")
{
    CHECK_FALSE(Callable::Decompose(Core::Type::unit()));
    CHECK_FALSE(Callable::Decompose(Core::Type::boolean()));
    CHECK_FALSE(Callable::Decompose(Core::Type::string()));
    CHECK_FALSE(
        Callable::Decompose(Core::Type::named({ U"Application", U"Worker" })));
}

TEST_CASE("malformed function storage without a result is rejected")
{
    Core::Type malformed;
    malformed.kind = Core::Type::Kind::Function;
    CHECK_FALSE(Callable::Decompose(malformed));
}

TEST_CASE("closure contract accepts capture prefix and public suffix")
{
    const auto captures = Captures();
    const auto target = TargetParameters();
    const auto contract = Callable::ValidateClosure(captures,
                                                    target,
                                                    Core::Type::string(),
                                                    PublicSignature());

    REQUIRE(contract);
    CHECK(contract.error == Callable::ClosureContractError::None);
    CHECK(contract.publicSignature.parameters.size() == 2U);
    CHECK(contract.publicSignature.result == Core::Type::string());
}

TEST_CASE("closure contract rejects a non-callable public result")
{
    const auto captures = Captures();
    const auto target = TargetParameters();
    const auto contract = Callable::ValidateClosure(captures,
                                                    target,
                                                    Core::Type::string(),
                                                    Core::Type::string());

    CHECK_FALSE(contract);
    CHECK(contract.error
          == Callable::ClosureContractError::ResultIsNotCallable);
}

TEST_CASE(
    "closure contract reports a lifted target shorter than its environment")
{
    const auto captures = Captures();
    const std::array target{ Core::Type::string() };
    const auto contract = Callable::ValidateClosure(captures,
                                                    target,
                                                    Core::Type::string(),
                                                    PublicSignature());

    CHECK_FALSE(contract);
    CHECK(contract.error
          == Callable::ClosureContractError::TargetHasTooFewParameters);
    CHECK(contract.index == 1U);
}

TEST_CASE("closure contract identifies the first mismatched capture slot")
{
    const auto captures = Captures();
    auto target = TargetParameters();
    target[1] = Core::Type::uint32();
    const auto contract = Callable::ValidateClosure(captures,
                                                    target,
                                                    Core::Type::string(),
                                                    PublicSignature());

    CHECK_FALSE(contract);
    CHECK(contract.error
          == Callable::ClosureContractError::CaptureTypeMismatch);
    CHECK(contract.index == 1U);
}

TEST_CASE("closure contract distinguishes public arity from capture arity")
{
    const auto captures = Captures();
    auto target = TargetParameters();
    target.pop_back();
    const auto contract = Callable::ValidateClosure(captures,
                                                    target,
                                                    Core::Type::string(),
                                                    PublicSignature());

    CHECK_FALSE(contract);
    CHECK(contract.error
          == Callable::ClosureContractError::PublicParameterCountMismatch);
    CHECK(contract.index == 1U);
}

TEST_CASE("closure contract identifies a mismatched public parameter")
{
    const auto captures = Captures();
    auto target = TargetParameters();
    target[2] = Core::Type::uint64();
    const auto contract = Callable::ValidateClosure(captures,
                                                    target,
                                                    Core::Type::string(),
                                                    PublicSignature());

    CHECK_FALSE(contract);
    CHECK(contract.error
          == Callable::ClosureContractError::PublicParameterTypeMismatch);
    CHECK(contract.index == 0U);
}

TEST_CASE("closure contract requires the lifted and public results to agree")
{
    const auto captures = Captures();
    const auto target = TargetParameters();
    const auto contract = Callable::ValidateClosure(captures,
                                                    target,
                                                    Core::Type::boolean(),
                                                    PublicSignature());

    CHECK_FALSE(contract);
    CHECK(contract.error == Callable::ClosureContractError::ResultTypeMismatch);
}

TEST_CASE(
    "zero-capture void callables retain the internal no-result ABI marker")
{
    const std::array<Core::Type, 0> captures{};
    const std::array target{ Core::Type::int16(), Core::Type::float32() };
    const auto callable
        = Core::Type::function({ Core::Type::int16(), Core::Type::float32() },
                               Core::Type::unit());
    const auto contract = Callable::ValidateClosure(captures,
                                                    target,
                                                    Core::Type::unit(),
                                                    callable);

    REQUIRE(contract);
    CHECK(contract.publicSignature.parameters.size() == 2U);
    // Tala spells this source result `void`; Unit is deliberately private
    // compiler vocabulary and must never become a second source-language type.
    CHECK(contract.publicSignature.result == Core::Type::unit());
}
