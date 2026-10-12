// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <array>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

#include "Progmasoft/Tala/Artifact/WireSupport.hpp"
#include "Progmasoft/Tala/Core/CorePrep.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"

namespace
{
    namespace Core = ::tala::core;
    namespace Wire = ::Progmasoft::Tala::Artifact::Wire;

    [[nodiscard]] auto
    Bytes(const Wire::Writer &writer) -> const std::vector<std::uint8_t> &
    {
        REQUIRE_FALSE(writer.Failure().has_value());
        return writer.Bytes();
    }

    void
    RequireFailure(const Wire::Reader &reader, Wire::ErrorKind expected)
    {
        REQUIRE(reader.Failure().has_value());
        REQUIRE(reader.Failure()->kind == expected);
        REQUIRE_FALSE(reader.Failure()->context.empty());
        REQUIRE_FALSE(reader.Failure()->message.empty());
    }

    [[nodiscard]] auto
    DeepFunctionType(std::size_t depth) -> Core::Type
    {
        auto type = Core::Type::int64();
        for (std::size_t index = 0; index < depth; ++index)
            type = Core::Type::function({ Core::Type::boolean() },
                                        std::move(type));
        return type;
    }
} // namespace

TEST_CASE("wire fixed-width integers use deterministic little-endian order")
{
    Wire::Limits limits;
    Wire::Writer writer(limits);
    writer.Byte(0x7fU);
    writer.U16(0x1234U);
    writer.U32(0x89abcdefU);
    writer.U64(0x0123456789abcdefULL);

    const std::vector<std::uint8_t> expected{
        0x7fU, 0x34U, 0x12U, 0xefU, 0xcdU, 0xabU, 0x89U, 0xefU,
        0xcdU, 0xabU, 0x89U, 0x67U, 0x45U, 0x23U, 0x01U,
    };
    REQUIRE(Bytes(writer) == expected);

    Wire::Reader reader(writer.Bytes(), limits);
    REQUIRE(reader.Byte("byte") == 0x7fU);
    REQUIRE(reader.U16("u16") == 0x1234U);
    REQUIRE(reader.U32("u32") == 0x89abcdefU);
    REQUIRE(reader.U64("u64") == 0x0123456789abcdefULL);
    REQUIRE(reader.AtEnd());
    REQUIRE_FALSE(reader.Failure().has_value());
}

TEST_CASE(
    "wire text accepts Unicode scalar values and rejects surrogate code points")
{
    Wire::Limits limits;
    Wire::Writer writer(limits);
    const std::u32string original{ U"Tala · 🐺" };
    writer.Text(original, "display name");
    Wire::Reader reader(Bytes(writer), limits);
    REQUIRE(reader.Text("display name") == original);
    REQUIRE(reader.AtEnd());

    SECTION("writer rejects a surrogate")
    {
        Wire::Writer invalid(limits);
        invalid.Text(std::u32string{ static_cast<char32_t>(0xd800U) },
                     "surrogate");
        REQUIRE(invalid.Failure().has_value());
        REQUIRE(invalid.Failure()->kind == Wire::ErrorKind::InvalidScalar);
    }

    SECTION("reader rejects a surrogate")
    {
        // A text value is a scalar count followed by little-endian u32 code
        // points.
        const std::array<std::uint8_t, 8U> malformed{ 1U, 0U,    0U, 0U,
                                                      0U, 0xd8U, 0U, 0U };
        Wire::Reader invalid(malformed, limits);
        REQUIRE(invalid.Text("surrogate").empty());
        RequireFailure(invalid, Wire::ErrorKind::InvalidScalar);
    }
}

TEST_CASE("wire booleans have exactly two canonical encodings")
{
    Wire::Limits limits;
    const std::array<std::uint8_t, 2U> valid{ 0U, 1U };
    Wire::Reader reader(valid, limits);
    REQUIRE_FALSE(reader.Boolean("false"));
    REQUIRE(reader.Boolean("true"));
    REQUIRE(reader.AtEnd());

    const std::array<std::uint8_t, 1U> malformed{ 2U };
    Wire::Reader invalid(malformed, limits);
    REQUIRE_FALSE(invalid.Boolean("invalid boolean"));
    RequireFailure(invalid, Wire::ErrorKind::InvalidBoolean);
}

TEST_CASE(
    "wire types preserve named, generic, function, and variable structure")
{
    Wire::Limits limits;
    const auto variable
        = Core::Type::type_variable(Core::SymbolName{ 91U, U"Element" });
    const auto array = Core::Type::named({ U"System", U"Array" }, { variable });
    const auto signature
        = Core::Type::function({ array, Core::Type::uint128() },
                               Core::Type::boolean());

    Wire::Writer writer(limits);
    writer.Type(signature, "signature");
    Wire::Reader reader(Bytes(writer), limits);
    REQUIRE(reader.Type("signature") == signature);
    REQUIRE(reader.AtEnd());

    SECTION("unknown type tag is rejected")
    {
        const std::array<std::uint8_t, 1U> malformed{ 0xffU };
        Wire::Reader invalid(malformed, limits);
        REQUIRE(invalid.Type("unknown") == Core::Type::unit());
        RequireFailure(invalid, Wire::ErrorKind::InvalidTag);
    }

    SECTION("empty function shape is rejected")
    {
        const std::array<std::uint8_t, 5U> malformed{
            static_cast<std::uint8_t>(Core::Type::Kind::Function),
            0U,
            0U,
            0U,
            0U
        };
        Wire::Reader invalid(malformed, limits);
        REQUIRE(invalid.Type("function") == Core::Type::unit());
        RequireFailure(invalid, Wire::ErrorKind::InvalidModel);
    }
}

TEST_CASE("wire rejects types deeper than the configured recursive budget")
{
    Wire::Limits tight;
    tight.maximumTypeDepth = 3U;
    const auto nested = DeepFunctionType(5U);

    Wire::Writer writer(tight);
    writer.Type(nested, "deep signature");
    REQUIRE(writer.Failure().has_value());
    REQUIRE(writer.Failure()->kind == Wire::ErrorKind::LimitExceeded);

    Wire::Limits broad;
    broad.maximumTypeDepth = 16U;
    Wire::Writer encoded(broad);
    encoded.Type(nested, "deep signature");
    Wire::Reader reader(Bytes(encoded), tight);
    static_cast<void>(reader.Type("deep signature"));
    RequireFailure(reader, Wire::ErrorKind::LimitExceeded);
}

TEST_CASE(
    "wire integer literals reject negative zero and redundant leading octets")
{
    Wire::Limits limits;
    SECTION("negative zero")
    {
        // Literal tag 2, negative sign 1, zero-length magnitude.
        const std::array<std::uint8_t, 6U> malformed{ 2U, 1U, 0U, 0U, 0U, 0U };
        Wire::Reader reader(malformed, limits);
        static_cast<void>(reader.Literal(Core::Type::int64(), "integer"));
        RequireFailure(reader, Wire::ErrorKind::InvalidInteger);
    }

    SECTION("leading zero magnitude")
    {
        // Literal tag 2, positive sign 0, magnitude length 2, then 0x00 0x01.
        const std::array<std::uint8_t, 8U> malformed{ 2U, 0U, 2U, 0U,
                                                      0U, 0U, 0U, 1U };
        Wire::Reader reader(malformed, limits);
        static_cast<void>(reader.Literal(Core::Type::int64(), "integer"));
        RequireFailure(reader, Wire::ErrorKind::InvalidInteger);
    }
}

TEST_CASE("wire errors are sticky and preserve the first diagnostic offset")
{
    Wire::Limits limits;
    limits.maximumWireBytes = 1U;
    Wire::Writer writer(limits);
    writer.Byte(0xaaU);
    writer.U64(std::numeric_limits<std::uint64_t>::max());
    REQUIRE(writer.Failure().has_value());
    const auto first = *writer.Failure();

    // Once a failure is recorded, later fields cannot mutate bytes or replace
    // the diagnostic that identifies the first broken field.
    writer.U16(0x1234U);
    writer.Text(U"ignored", "later field");
    REQUIRE(writer.Bytes() == std::vector<std::uint8_t>{ 0xaaU });
    REQUIRE(*writer.Failure() == first);

    const std::array<std::uint8_t, 1U> truncated{ 0x34U };
    Wire::Reader reader(truncated, limits);
    REQUIRE(reader.U32("first field") == 0x34U);
    RequireFailure(reader, Wire::ErrorKind::TruncatedInput);
    const auto readerFailure = *reader.Failure();
    REQUIRE(reader.U16("later field") == 0U);
    REQUIRE(*reader.Failure() == readerFailure);
}
