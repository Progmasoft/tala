// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <string_view>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Wire.hpp"
#include "Progmasoft/Tala/Core/IR.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Core/Verifier.hpp"
#include "Progmasoft/Tala/Core/Wire.hpp"
#include "Progmasoft/Tala/Xmm/IR.hpp"
#include "Progmasoft/Tala/Xmm/Verifier.hpp"
#include "Progmasoft/Tala/Xpp/IR.hpp"
#include "Progmasoft/Tala/Xpp/Verifier.hpp"

namespace
{
    namespace core = ::tala::core;
    namespace core_wire = ::tala::core::wire;
    namespace native_core = ::Progmasoft::Tala::Core;
    namespace native_wire = ::Progmasoft::Tala::Core::Wire;
    namespace xmm = ::tala::xmm;
    namespace xpp = ::tala::xpp;

    struct ScalarCase final
    {
        core::Type type;
        core::ScalarFamily family;
        std::uint16_t width;
        std::string_view spelling;
    };

    const std::array kScalarCases{
        ScalarCase{ core::Type::boolean(),
                    core::ScalarFamily::Boolean,
                    8U,
                    "bool" },
        ScalarCase{ core::Type::character(),
                    core::ScalarFamily::Character,
                    32U,
                    "char" },
        ScalarCase{ core::Type::int8(),
                    core::ScalarFamily::SignedInteger,
                    8U,
                    "byte" },
        ScalarCase{ core::Type::int16(),
                    core::ScalarFamily::SignedInteger,
                    16U,
                    "short" },
        ScalarCase{ core::Type::int32(),
                    core::ScalarFamily::SignedInteger,
                    32U,
                    "long" },
        ScalarCase{ core::Type::int64(),
                    core::ScalarFamily::SignedInteger,
                    64U,
                    "int" },
        ScalarCase{ core::Type::int128(),
                    core::ScalarFamily::SignedInteger,
                    128U,
                    "longint" },
        ScalarCase{ core::Type::uint8(),
                    core::ScalarFamily::UnsignedInteger,
                    8U,
                    "ubyte" },
        ScalarCase{ core::Type::uint16(),
                    core::ScalarFamily::UnsignedInteger,
                    16U,
                    "ushort" },
        ScalarCase{ core::Type::uint32(),
                    core::ScalarFamily::UnsignedInteger,
                    32U,
                    "ulong" },
        ScalarCase{ core::Type::uint64(),
                    core::ScalarFamily::UnsignedInteger,
                    64U,
                    "uint" },
        ScalarCase{ core::Type::uint128(),
                    core::ScalarFamily::UnsignedInteger,
                    128U,
                    "ulongint" },
        ScalarCase{ core::Type::float16(),
                    core::ScalarFamily::Floating,
                    16U,
                    "sfloat" },
        ScalarCase{ core::Type::float32(),
                    core::ScalarFamily::Floating,
                    32U,
                    "lfloat" },
        ScalarCase{ core::Type::float64(),
                    core::ScalarFamily::Floating,
                    64U,
                    "float" },
        ScalarCase{ core::Type::float128(),
                    core::ScalarFamily::Floating,
                    128U,
                    "double" },
    };

    auto
    integer(bool negative, std::initializer_list<std::uint8_t> magnitude)
        -> core::IntegerLiteral
    {
        return core::IntegerLiteral{ negative,
                                     std::vector<std::uint8_t>(magnitude) };
    }

    auto
    maximum_unsigned(std::size_t bytes) -> core::IntegerLiteral
    {
        return core::IntegerLiteral{ false,
                                     std::vector<std::uint8_t>(bytes, 0xffU) };
    }

    auto
    maximum_signed(std::size_t bytes) -> core::IntegerLiteral
    {
        auto value = maximum_unsigned(bytes);
        value.magnitude.front() = 0x7fU;
        return value;
    }

    auto
    minimum_signed(std::size_t bytes) -> core::IntegerLiteral
    {
        core::IntegerLiteral value{ true,
                                    std::vector<std::uint8_t>(bytes, 0U) };
        value.magnitude.front() = 0x80U;
        return value;
    }

    auto
    one_past_signed_maximum(std::size_t bytes) -> core::IntegerLiteral
    {
        auto value = minimum_signed(bytes);
        value.negative = false;
        return value;
    }

    auto
    one_past_unsigned_maximum(std::size_t bytes) -> core::IntegerLiteral
    {
        core::IntegerLiteral value{ false,
                                    std::vector<std::uint8_t>(bytes + 1U, 0U) };
        value.magnitude.front() = 1U;
        return value;
    }

    auto
    symbol(core::SymbolId id, std::u32string spelling) -> core::SymbolName
    {
        return core::SymbolName{ id, std::move(spelling) };
    }

    auto
    literal_for(const core::Type &type) -> core::Literal
    {
        if (type.kind == core::Type::Kind::Unit)
            return std::monostate{};
        if (type.kind == core::Type::Kind::Bool)
            return true;
        if (type.kind == core::Type::Kind::String)
            return std::u32string(U"Tala scalar wire");
        if (core::is_floating(type))
            return core::FloatingLiteral{ "-12345.625e-2" };
        return integer(false, { 0x2aU });
    }

    auto
    coreprep_module(const core::Type &type, core::Literal literal)
        -> core::CorePrepModule
    {
        core::Terminator terminator;
        terminator.kind = core::Terminator::Kind::Return;
        terminator.value = core::Atom::constant(std::move(literal), type);
        core::Block block{ 1U, {}, std::move(terminator) };
        core::Function function{ symbol(1U, U"Value"),
                                 {},
                                 type,
                                 1U,
                                 { std::move(block) } };
        return core::CorePrepModule{ { U"Scalar", U"Wire" },
                                     { std::move(function) } };
    }

    auto
    binary_module(const core::Type &operandType,
                  core::Operation operation,
                  const core::Type &resultType) -> core::CorePrepModule
    {
        // Build a complete verified function rather than calling a backend
        // helper directly. This catches disagreements in operation typing at
        // every native boundary before the value reaches LLVM.
        core::Instruction instruction;
        instruction.kind = core::Instruction::Kind::Bind;
        instruction.destination = symbol(2U, U"result");
        instruction.type = resultType;
        instruction.operation = operation;
        instruction.operands = {
            core::Atom::constant(literal_for(operandType), operandType),
            core::Atom::constant(literal_for(operandType), operandType),
        };

        core::Terminator terminator;
        terminator.kind = core::Terminator::Kind::Return;
        terminator.value
            = core::Atom::variable(symbol(2U, U"result"), resultType);
        core::Block block{ 1U,
                           { std::move(instruction) },
                           std::move(terminator) };
        core::Function function{ symbol(1U, U"Calculate"),
                                 {},
                                 resultType,
                                 1U,
                                 { std::move(block) } };
        return core::CorePrepModule{ { U"Scalar", U"Operations" },
                                     { std::move(function) } };
    }

    auto
    core_module(const core::Type &type, core::Literal literal)
        -> native_core::Module
    {
        native_core::Function function;
        function.symbol = symbol(1U, U"Value");
        function.returnType = type;
        function.body.push_back(native_core::Statement::Return(
            native_core::Expression::Constant(std::move(literal), type)));
        return native_core::Module{ { U"Scalar", U"Core" },
                                    { std::move(function) } };
    }

    auto
    wire_round_trips(const core::Type &type) -> bool
    {
        const auto source = coreprep_module(type, literal_for(type));
        const auto encoded = core_wire::encode(source);
        if (!encoded)
            return false;
        const auto decoded = core_wire::decode(encoded.bytes);
        return decoded && *decoded.module == source;
    }

    auto
    native_wire_round_trips(const core::Type &type) -> bool
    {
        const auto source = core_module(type, literal_for(type));
        const auto encoded = native_wire::Encode(source);
        if (!encoded)
            return false;
        const auto decoded = native_wire::Decode(encoded.bytes);
        return decoded && *decoded.module == source;
    }
} // namespace

TEST_CASE("the native scalar catalog matches the language width contract",
          "[scalar][catalog]")
{
    for (const auto &entry : kScalarCases)
    {
        CAPTURE(entry.spelling);
        const auto description = core::describe_scalar(entry.type);
        REQUIRE(description.has_value());
        CHECK(description->family == entry.family);
        CHECK(description->bit_width == entry.width);
        CHECK(description->spelling == entry.spelling);
        CHECK(description->is_numeric()
              == (entry.family == core::ScalarFamily::SignedInteger
                  || entry.family == core::ScalarFamily::UnsignedInteger
                  || entry.family == core::ScalarFamily::Floating));
        CHECK(description->is_integer()
              == (entry.family == core::ScalarFamily::SignedInteger
                  || entry.family == core::ScalarFamily::UnsignedInteger));
        CHECK(description->is_signed()
              == (entry.family == core::ScalarFamily::SignedInteger));
        CHECK(description->is_floating()
              == (entry.family == core::ScalarFamily::Floating));
    }

    CHECK_FALSE(core::describe_scalar(core::Type::unit()).has_value());
    CHECK_FALSE(core::describe_scalar(core::Type::string()).has_value());
    CHECK_FALSE(
        core::describe_scalar(core::Type::named({ U"UserType" })).has_value());
    CHECK_FALSE(
        core::describe_scalar(core::Type::function({}, core::Type::unit()))
            .has_value());
}

TEST_CASE(
    "signed integer ranges include exactly their two's-complement endpoints",
    "[scalar][integer]")
{
    const std::array signedCases{
        std::pair{ core::Type::int8(), 1U },
        std::pair{ core::Type::int16(), 2U },
        std::pair{ core::Type::int32(), 4U },
        std::pair{ core::Type::int64(), 8U },
        std::pair{ core::Type::int128(), 16U },
    };
    for (const auto &[type, bytes] : signedCases)
    {
        CAPTURE(core::describe_scalar(type)->spelling);
        CHECK(core::integer_fits(core::IntegerLiteral{}, type));
        CHECK(core::integer_fits(integer(false, { 1U }), type));
        CHECK(core::integer_fits(integer(true, { 1U }), type));
        CHECK(core::integer_fits(maximum_signed(bytes), type));
        CHECK(core::integer_fits(minimum_signed(bytes), type));
        CHECK_FALSE(core::integer_fits(one_past_signed_maximum(bytes), type));
        auto belowMinimum = one_past_signed_maximum(bytes);
        belowMinimum.negative = true;
        belowMinimum.magnitude.back() += 1U;
        CHECK_FALSE(core::integer_fits(belowMinimum, type));
    }
}

TEST_CASE("unsigned integer and character ranges reject negative or oversized "
          "payloads",
          "[scalar][integer]")
{
    const std::array unsignedCases{
        std::pair{ core::Type::uint8(), 1U },
        std::pair{ core::Type::uint16(), 2U },
        std::pair{ core::Type::uint32(), 4U },
        std::pair{ core::Type::uint64(), 8U },
        std::pair{ core::Type::uint128(), 16U },
        std::pair{ core::Type::character(), 4U },
    };
    for (const auto &[type, bytes] : unsignedCases)
    {
        CAPTURE(core::describe_scalar(type)->spelling);
        CHECK(core::integer_fits(core::IntegerLiteral{}, type));
        CHECK(core::integer_fits(maximum_unsigned(bytes), type));
        CHECK_FALSE(core::integer_fits(integer(true, { 1U }), type));
        CHECK_FALSE(core::integer_fits(one_past_unsigned_maximum(bytes), type));
    }
}

TEST_CASE("integer normalization is host independent and canonical",
          "[scalar][integer]")
{
    CHECK(core::normalize_integer(integer(true, { 0U, 0U })).magnitude.empty());
    CHECK_FALSE(core::normalize_integer(integer(true, { 0U, 0U })).negative);
    CHECK(core::normalize_integer(integer(false, { 0U, 0U, 0x2aU }))
          == integer(false, { 0x2aU }));
    CHECK(core::integer_is_canonical(integer(false, { 0x80U })));
    CHECK_FALSE(core::integer_is_canonical(integer(false, { 0U, 0x80U })));
    CHECK_FALSE(core::integer_is_canonical(integer(true, {})));
    CHECK(core::integer_is_zero(core::IntegerLiteral{}));
    CHECK(core::integer_is_zero(integer(false, { 0U, 0U })));
    CHECK_FALSE(core::integer_is_zero(integer(false, { 0U, 1U })));
    CHECK(core::integer_from_signed(0) == core::IntegerLiteral{});
    CHECK(core::integer_from_signed(127) == integer(false, { 0x7fU }));
    CHECK(core::integer_from_signed(-128) == integer(true, { 0x80U }));
    CHECK(core::integer_from_unsigned(0xffffU)
          == integer(false, { 0xffU, 0xffU }));
    CHECK(core::integer_hex_magnitude(core::IntegerLiteral{}) == "0");
    CHECK(core::integer_hex_magnitude(integer(false, { 0x01U, 0xabU, 0xcdU }))
          == "1abcd");
    CHECK(core::integer_from_signed(std::numeric_limits<std::int64_t>::min())
          == integer(true, { 0x80U, 0U, 0U, 0U, 0U, 0U, 0U, 0U }));
}

TEST_CASE("floating spellings use a strict locale-independent grammar",
          "[scalar][floating]")
{
    const std::array valid{ "0",     "1.0",      ".5",   "5.",   "+1.25",
                            "-1.25", "6.022e23", "1e-9", "1E+9", "nan",
                            "+nan",  "-nan",     "inf",  "+inf", "-inf" };
    const std::array invalid{ "",      "+",     "-",   ".",        "e1",
                              "1e",    "1e+",   "1e-", "1.2.3",    " 1",
                              "1 ",    "1,5",   "NaN", "Infinity", "0x1p2",
                              "1_000", "1'000", "--1" };
    for (const auto spelling : valid)
    {
        CAPTURE(spelling);
        CHECK(core::floating_spelling_is_valid(spelling));
    }
    for (const auto spelling : invalid)
    {
        CAPTURE(spelling);
        CHECK_FALSE(core::floating_spelling_is_valid(spelling));
    }
}

TEST_CASE("literal validation combines payload kind and scalar range",
          "[scalar][literal]")
{
    CHECK_FALSE(core::validate_literal(std::monostate{}, core::Type::unit()));
    CHECK_FALSE(core::validate_literal(true, core::Type::boolean()));
    CHECK_FALSE(
        core::validate_literal(integer(false, { 0x7fU }), core::Type::int8()));
    CHECK_FALSE(
        core::validate_literal(integer(false, { 0xffU }), core::Type::uint8()));
    CHECK_FALSE(core::validate_literal(core::FloatingLiteral{ "1.25" },
                                       core::Type::float64()));
    CHECK_FALSE(
        core::validate_literal(std::u32string(U"text"), core::Type::string()));
    CHECK(
        core::validate_literal(integer(false, { 0x80U }), core::Type::int8()));
    CHECK(core::validate_literal(integer(true, { 1U }), core::Type::uint8()));
    CHECK(core::validate_literal(core::FloatingLiteral{ "1e" },
                                 core::Type::float64()));
    CHECK(core::validate_literal(core::FloatingLiteral{ "1.0" },
                                 core::Type::int64()));
    CHECK(
        core::validate_literal(std::u32string(U"text"), core::Type::boolean()));
}

TEST_CASE("CorePrep wire v7 round-trips every scalar family",
          "[scalar][wire][coreprep]")
{
    CHECK(core_wire::current_version == 8U);
    CHECK(wire_round_trips(core::Type::unit()));
    CHECK(wire_round_trips(core::Type::string()));
    for (const auto &entry : kScalarCases)
    {
        CAPTURE(entry.spelling);
        CHECK(wire_round_trips(entry.type));
    }
}

TEST_CASE("Core wire v10 round-trips every scalar family",
          "[scalar][wire][core]")
{
    CHECK(native_wire::kCurrentVersion == 10U);
    CHECK(native_wire_round_trips(core::Type::unit()));
    CHECK(native_wire_round_trips(core::Type::string()));
    for (const auto &entry : kScalarCases)
    {
        CAPTURE(entry.spelling);
        CHECK(native_wire_round_trips(entry.type));
    }
}

TEST_CASE("CorePrep wire canonicalizes producers and rejects over-limit "
          "integer payloads",
          "[scalar][wire][negative]")
{
    auto nonCanonical
        = coreprep_module(core::Type::int64(), integer(false, { 0U, 1U }));
    const auto canonicalResult = core_wire::encode(nonCanonical);
    REQUIRE(canonicalResult);
    const auto decoded = core_wire::decode(canonicalResult.bytes);
    REQUIRE(decoded);
    CHECK(*decoded.module
          == coreprep_module(core::Type::int64(), integer(false, { 1U })));

    core_wire::Limits limits;
    limits.maximum_numeric_bytes = 1U;
    auto oversized
        = coreprep_module(core::Type::int16(), integer(false, { 1U, 0U }));
    const auto oversizedResult = core_wire::encode(oversized, limits);
    REQUIRE_FALSE(oversizedResult);
    CHECK(oversizedResult.error->kind == core_wire::ErrorKind::LimitExceeded);
}

TEST_CASE("Core and CorePrep verifiers reject scalar payload mismatches",
          "[scalar][verifier]")
{
    const auto invalidCore
        = core_module(core::Type::uint8(), integer(false, { 1U, 0U }));
    const auto coreIssues = native_core::Verify(invalidCore);
    REQUIRE_FALSE(coreIssues.empty());
    CHECK(coreIssues.front().code == "TAC1029");

    const auto invalidCorePrep
        = coreprep_module(core::Type::float32(), core::FloatingLiteral{ "1e" });
    const auto corePrepIssues = core::verify(invalidCorePrep);
    REQUIRE_FALSE(corePrepIssues.empty());
    CHECK(std::ranges::any_of(corePrepIssues,
                              [](const core::VerificationIssue &issue) {
                                  return issue.code == "TAC1009"
                                         || issue.code == "TAC1048";
                              }));
}

TEST_CASE("Xpp and Xmm retain scalar types and literals without narrowing",
          "[scalar][xpp][xmm]")
{
    for (const auto &entry : kScalarCases)
    {
        if (entry.family == core::ScalarFamily::Boolean)
            continue;
        CAPTURE(entry.spelling);
        const auto prepared
            = coreprep_module(entry.type, literal_for(entry.type));
        REQUIRE(core::verify(prepared).empty());
        const auto xppModule = xpp::lower(prepared);
        CHECK(::Progmasoft::Tala::Xpp::Verify(xppModule).empty());
        const auto xmmModule = xmm::lower(xppModule);
        CHECK(::Progmasoft::Tala::Xmm::Verify(xmmModule).empty());
        REQUIRE(xmmModule.functions.size() == 1U);
        CHECK(xmmModule.functions.front().return_type == entry.type);
        CHECK(xmmModule.functions.front().blocks.front().terminator.value.type
              == entry.type);
        CHECK(xmmModule.functions.front()
                  .blocks.front()
                  .terminator.value.immediate
              == literal_for(entry.type));
    }
}

TEST_CASE("numeric arithmetic remains valid through CorePrep Xpp and Xmm",
          "[scalar][operations]")
{
    const std::array arithmetic{
        core::Operation::Add,         core::Operation::Subtract,
        core::Operation::Multiply,    core::Operation::Divide,
        core::Operation::FloorDivide, core::Operation::Remainder,
    };

    for (const auto &entry : kScalarCases)
    {
        if (!core::is_numeric(entry.type))
            continue;
        for (const auto operation : arithmetic)
        {
            CAPTURE(entry.spelling, operation);
            const auto resultType = operation == core::Operation::FloorDivide
                                            && core::is_floating(entry.type)
                                        ? core::Type::int64()
                                        : entry.type;
            const auto prepared
                = binary_module(entry.type, operation, resultType);
            CHECK(core::verify(prepared).empty());
            const auto xppModule = xpp::lower(prepared);
            CHECK(::Progmasoft::Tala::Xpp::Verify(xppModule).empty());
            const auto xmmModule = xmm::lower(xppModule);
            CHECK(::Progmasoft::Tala::Xmm::Verify(xmmModule).empty());
            CHECK(xmmModule.functions.front()
                      .blocks.front()
                      .instructions.front()
                      .result_type
                  == resultType);
        }
    }
}

TEST_CASE("numeric comparisons produce bool through every native verifier",
          "[scalar][operations]")
{
    const std::array comparisons{
        core::Operation::Equal,       core::Operation::NotEqual,
        core::Operation::LessThan,    core::Operation::LessEqual,
        core::Operation::GreaterThan, core::Operation::GreaterEqual,
    };

    for (const auto &entry : kScalarCases)
    {
        if (!core::is_numeric(entry.type))
            continue;
        for (const auto operation : comparisons)
        {
            CAPTURE(entry.spelling, operation);
            const auto prepared
                = binary_module(entry.type, operation, core::Type::boolean());
            CHECK(core::verify(prepared).empty());
            const auto xppModule = xpp::lower(prepared);
            CHECK(::Progmasoft::Tala::Xpp::Verify(xppModule).empty());
            const auto xmmModule = xmm::lower(xppModule);
            CHECK(::Progmasoft::Tala::Xmm::Verify(xmmModule).empty());
        }
    }
}

TEST_CASE(
    "CorePrep wire reports structural corruption before semantic lowering",
    "[scalar][wire][negative]")
{
    const auto source = coreprep_module(core::Type::int128(),
                                        integer(false, { 1U, 0U, 0U, 0U, 0U }));
    const auto encoded = core_wire::encode(source);
    REQUIRE(encoded);

    auto badMagic = encoded.bytes;
    badMagic.front() ^= 0xffU;
    const auto magicResult = core_wire::decode(badMagic);
    REQUIRE_FALSE(magicResult);
    CHECK(magicResult.error->kind == core_wire::ErrorKind::InvalidMagic);

    auto oldVersion = encoded.bytes;
    oldVersion[4] = 2U;
    const auto versionResult = core_wire::decode(oldVersion);
    REQUIRE_FALSE(versionResult);
    CHECK(versionResult.error->kind
          == core_wire::ErrorKind::UnsupportedVersion);

    auto truncated = encoded.bytes;
    truncated.pop_back();
    const auto truncatedResult = core_wire::decode(truncated);
    REQUIRE_FALSE(truncatedResult);
    CHECK(truncatedResult.error->kind == core_wire::ErrorKind::TruncatedInput);

    auto trailing = encoded.bytes;
    trailing.push_back(0U);
    const auto trailingResult = core_wire::decode(trailing);
    REQUIRE_FALSE(trailingResult);
    CHECK(trailingResult.error->kind == core_wire::ErrorKind::TrailingInput);

    core_wire::Limits limits;
    limits.maximum_wire_bytes = encoded.bytes.size() - 1U;
    const auto limitedResult = core_wire::decode(encoded.bytes, limits);
    REQUIRE_FALSE(limitedResult);
    CHECK(limitedResult.error->kind == core_wire::ErrorKind::LimitExceeded);
}
