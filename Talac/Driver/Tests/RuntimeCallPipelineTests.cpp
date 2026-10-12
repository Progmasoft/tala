// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <ranges>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Backend/LLVM.hpp"
#include "Progmasoft/Tala/Core/CorePrep.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Wire.hpp"
#include "Progmasoft/Tala/Core/RuntimeCall.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Xmm/IR.hpp"
#include "Progmasoft/Tala/Xmm/Verifier.hpp"
#include "Progmasoft/Tala/Xmm/Wire.hpp"
#include "Progmasoft/Tala/Xpp/IR.hpp"
#include "Progmasoft/Tala/Xpp/OwnershipPlacement.hpp"
#include "Progmasoft/Tala/Xpp/Verifier.hpp"
#include "Progmasoft/Tala/Xpp/Wire.hpp"

// A call of a runtime function, followed through every native stage.
//
// The operation names its function with a literal first operand and gives
// the arguments after it. The catalog says what each function takes and
// returns, and every stage checks a call against it for itself: an artifact
// may enter the pipeline at any stage, so no stage relies on the one before
// it having checked. These cases take one module through the stages, pin
// the catalog row by row, and then break a call in each way it can be
// broken, at each stage.

namespace
{
    namespace Core = tala::core;
    namespace Runtime = tala::core::runtime;
    namespace Llvm = Progmasoft::Tala::Backend::LLVM;
    namespace Xmm = tala::xmm;
    namespace Xpp = tala::xpp;

    [[nodiscard]] auto
    Name(Core::SymbolId id, std::u32string spelling) -> Core::SymbolName
    {
        return { id, std::move(spelling) };
    }

    [[nodiscard]] auto
    Variable(Core::SymbolId id, Core::Type type) -> Core::Atom
    {
        return Core::Atom::variable(Name(id, {}), std::move(type));
    }

    [[nodiscard]] auto
    Integer(std::int64_t value) -> Core::Atom
    {
        return Core::Atom::constant(Core::integer_from_signed(value),
                                    Core::Type::int64());
    }

    [[nodiscard]] auto
    Identity(Runtime::Function function) -> Core::Atom
    {
        return Integer(static_cast<std::int64_t>(function));
    }

    [[nodiscard]] auto
    Text(std::u32string value) -> Core::Atom
    {
        return Core::Atom::constant(std::move(value), Core::Type::string());
    }

    [[nodiscard]] auto
    Bind(Core::SymbolId id,
         std::u32string spelling,
         Core::Type type,
         Core::Operation operation,
         std::vector<Core::Atom> operands) -> Core::Instruction
    {
        Core::Instruction instruction;
        instruction.kind = Core::Instruction::Kind::Bind;
        instruction.destination = Name(id, std::move(spelling));
        instruction.type = std::move(type);
        instruction.operation = operation;
        instruction.operands = std::move(operands);
        return instruction;
    }

    // Positions of the calls in the entry block of `Main`.
    constexpr std::size_t kFormat = 1U;
    constexpr std::size_t kConcat = 2U;
    constexpr std::size_t kWrite = 3U;

    /// ```
    /// Main(count):
    ///     label = "Count: "
    ///     digits = runtime TextFormatSigned(0, 5, -1, count)
    ///     line = runtime TextConcat(label, digits)
    ///     runtime ConsoleWrite(line, 1)
    ///     return
    /// ```
    [[nodiscard]] auto
    WritingModule() -> Core::CorePrepModule
    {
        Core::Instruction write;
        write.kind = Core::Instruction::Kind::Evaluate;
        write.type = Core::Type::unit();
        write.operation = Core::Operation::RuntimeCall;
        write.operands = { Identity(Runtime::Function::ConsoleWrite),
                           Variable(5U, Core::Type::string()),
                           Integer(1) };

        Core::Function main;
        main.symbol = Name(1U, U"Main");
        main.parameters
            = { Core::Parameter{ Name(2U, U"count"), Core::Type::int64() } };
        main.return_type = Core::Type::unit();
        main.entry = 0U;
        main.blocks = {
            Core::Block{
                0U,
                { Bind(3U,
                       U"label",
                       Core::Type::string(),
                       Core::Operation::Copy,
                       { Text(U"Count: ") }),
                  Bind(4U,
                       U"digits",
                       Core::Type::string(),
                       Core::Operation::RuntimeCall,
                       { Identity(Runtime::Function::TextFormatSigned),
                         Integer(0),
                         Integer(5),
                         Integer(-1),
                         Variable(2U, Core::Type::int64()) }),
                  Bind(5U,
                       U"line",
                       Core::Type::string(),
                       Core::Operation::RuntimeCall,
                       { Identity(Runtime::Function::TextConcat),
                         Variable(3U, Core::Type::string()),
                         Variable(4U, Core::Type::string()) }),
                  std::move(write) },
                Core::Terminator{
                    Core::Terminator::Kind::Return,
                    Core::Atom::constant(std::monostate{}, Core::Type::unit()),
                    0U,
                    0U },
            },
        };
        return Core::CorePrepModule{ { U"RuntimeCallTests" },
                                     { std::move(main) } };
    }

    [[nodiscard]] auto
    Call(Core::CorePrepModule &module, std::size_t position)
        -> Core::Instruction &
    {
        return module.functions.front().blocks.front().instructions[position];
    }

    template<typename Issues>
    [[nodiscard]] auto
    HasIssue(const Issues &issues, std::string_view code) -> bool
    {
        return std::ranges::any_of(issues, [code](const auto &issue) {
            return issue.code == code;
        });
    }

    template<typename Module, typename Opcode>
    [[nodiscard]] auto
    Calls(Module &module, Opcode opcode) -> std::vector<
        decltype(&module.functions.front().blocks.front().instructions.front())>
    {
        std::vector<decltype(&module.functions.front()
                                  .blocks.front()
                                  .instructions.front())>
            found;
        for (auto &function : module.functions)
            for (auto &block : function.blocks)
                for (auto &instruction : block.instructions)
                    if (instruction.opcode == opcode)
                        found.push_back(&instruction);
        return found;
    }

    [[nodiscard]] auto
    Occurrences(std::string_view text, std::string_view part) -> std::size_t
    {
        std::size_t count{};
        for (auto found = text.find(part); found != std::string_view::npos;
             found = text.find(part, found + part.size()))
            ++count;
        return count;
    }

    /// One row of the catalog as the tests state it.
    struct Row final
    {
        Runtime::Function function;
        std::uint64_t identity;
        std::string_view symbol;
        std::vector<Runtime::Parameter> parameters;
        Runtime::Result result;
        bool observable;
    };

    [[nodiscard]] auto
    Rows() -> std::vector<Row>
    {
        using enum Runtime::Parameter;
        using Runtime::Function;
        using Runtime::Result;
        return {
            { Function::TextConcat,
              1U,
              "tala_text_concat",
              { Text, Text },
              Result::Text,
              false },
            { Function::TextFromSigned,
              2U,
              "tala_text_from_signed",
              { Signed },
              Result::Text,
              false },
            { Function::TextFromUnsigned,
              3U,
              "tala_text_from_unsigned",
              { Unsigned },
              Result::Text,
              false },
            { Function::TextFromBool,
              4U,
              "tala_text_from_bool",
              { Bool },
              Result::Text,
              false },
            { Function::TextFromChar,
              5U,
              "tala_text_from_char",
              { Char },
              Result::Text,
              false },
            { Function::TextFormatSigned,
              6U,
              "tala_text_format_signed",
              { Count, Count, Count, Signed },
              Result::Text,
              false },
            { Function::TextFormatUnsigned,
              7U,
              "tala_text_format_unsigned",
              { Count, Count, Count, Unsigned },
              Result::Text,
              false },
            { Function::TextFormatFloating,
              8U,
              "tala_text_format_floating",
              { Count, Count, Count, Floating },
              Result::Text,
              false },
            { Function::TextFormatString,
              9U,
              "tala_text_format_string",
              { Count, Count, Count, Text },
              Result::Text,
              false },
            { Function::TextFormatChar,
              10U,
              "tala_text_format_char",
              { Count, Count, Count, Char },
              Result::Text,
              false },
            { Function::TextNewline,
              11U,
              "tala_text_newline",
              {},
              Result::Text,
              false },
            { Function::ConsoleWrite,
              12U,
              "tala_console_write",
              { Text, Count },
              Result::Nothing,
              true },
            { Function::TextEquals,
              13U,
              "tala_text_equals",
              { Text, Text },
              Result::Truth,
              false },
        };
    }
} // namespace

TEST_CASE("the runtime catalog has the rows the artifact formats rely on")
{
    // An identity is written into artifacts and a symbol is linked against:
    // a row that changed would silently change what compiled programs call.
    const auto rows = Rows();
    REQUIRE(Runtime::Catalog().size() == rows.size());
    for (const auto &row : rows)
    {
        CAPTURE(row.symbol);
        CHECK(static_cast<std::uint64_t>(row.function) == row.identity);
        const auto *signature = Runtime::Find(row.identity);
        REQUIRE(signature != nullptr);
        CHECK(signature->function == row.function);
        CHECK(signature->symbol == row.symbol);
        CHECK(std::ranges::equal(signature->parameters, row.parameters));
        CHECK(signature->result == row.result);
        CHECK(signature->observable == row.observable);
    }
}

TEST_CASE("every runtime function has an identity and a symbol of its own")
{
    std::set<std::uint64_t> identities;
    std::set<std::string_view> symbols;
    for (const auto &signature : Runtime::Catalog())
    {
        CHECK(identities.insert(static_cast<std::uint64_t>(signature.function))
                  .second);
        CHECK(symbols.insert(signature.symbol).second);
        CHECK(signature.symbol.starts_with("tala_"));
    }
    // Zero is no function, and neither is the number after the last.
    CHECK(Runtime::Find(0U) == nullptr);
    CHECK(Runtime::Find(Runtime::Catalog().size() + 1U) == nullptr);
    CHECK(Runtime::Find(~std::uint64_t{ 0U }) == nullptr);
}

TEST_CASE("a parameter takes its family of types and no other")
{
    using Kind = Core::Type::Kind;
    using enum Runtime::Parameter;
    const std::array kinds{ Kind::Unit,     Kind::Bool,     Kind::Character,
                            Kind::Int8,     Kind::Int16,    Kind::Int32,
                            Kind::Int64,    Kind::Int128,   Kind::UInt8,
                            Kind::UInt16,   Kind::UInt32,   Kind::UInt64,
                            Kind::UInt128,  Kind::Float16,  Kind::Float32,
                            Kind::Float64,  Kind::Float128, Kind::String,
                            Kind::Function, Kind::Named };
    const auto accepted = [&kinds](Runtime::Parameter parameter) {
        std::vector<Kind> taken;
        for (const auto kind : kinds)
            if (Runtime::Accepts(parameter, kind))
                taken.push_back(kind);
        return taken;
    };
    // A signed and an unsigned integer of at most sixty-four bits, a
    // floating-point number of at most sixty-four: what the runtime
    // functions are written for after widening.
    CHECK(accepted(Signed)
          == std::vector{ Kind::Int8, Kind::Int16, Kind::Int32, Kind::Int64 });
    CHECK(accepted(Unsigned)
          == std::vector{ Kind::UInt8,
                          Kind::UInt16,
                          Kind::UInt32,
                          Kind::UInt64 });
    CHECK(accepted(Floating)
          == std::vector{ Kind::Float16, Kind::Float32, Kind::Float64 });
    CHECK(accepted(Bool) == std::vector{ Kind::Bool });
    CHECK(accepted(Char) == std::vector{ Kind::Character });
    CHECK(accepted(Text) == std::vector{ Kind::String });
    CHECK(accepted(Count) == std::vector{ Kind::Int64 });
}

TEST_CASE("an identity is a literal int that is not negative")
{
    const auto literal = [](std::int64_t value) {
        return Core::Literal{ Core::integer_from_signed(value) };
    };
    CHECK(Runtime::IdentityOf(literal(12), Core::Type::int64()) == 12U);
    CHECK(Runtime::IdentityOf(literal(0), Core::Type::int64()) == 0U);
    CHECK_FALSE(Runtime::IdentityOf(literal(-1), Core::Type::int64()));
    // The type is that of the language's int; another integer type, or a
    // literal that is not an integer, names nothing.
    CHECK_FALSE(Runtime::IdentityOf(literal(12), Core::Type::int32()));
    CHECK_FALSE(Runtime::IdentityOf(literal(12), Core::Type::uint64()));
    CHECK_FALSE(
        Runtime::IdentityOf(Core::Literal{ true }, Core::Type::int64()));
    CHECK_FALSE(Runtime::IdentityOf(Core::Literal{ std::u32string(U"12") },
                                    Core::Type::int64()));
    // A magnitude beyond sixty-four bits is not an identity.
    Core::IntegerLiteral wide;
    wide.magnitude.assign(9U, 0xffU);
    CHECK_FALSE(
        Runtime::IdentityOf(Core::Literal{ wide }, Core::Type::int64()));
}

TEST_CASE("CorePrep accepts well-formed runtime calls")
{
    CHECK(Core::verify(WritingModule()).empty());
}

TEST_CASE("CorePrep writes and reads runtime calls unchanged")
{
    const auto source = WritingModule();
    const auto encoded = Core::wire::encode(source);
    REQUIRE_FALSE(encoded.error);
    const auto decoded = Core::wire::decode(encoded.bytes);
    REQUIRE_FALSE(decoded.error);
    REQUIRE(decoded.module);
    CHECK(*decoded.module == source);
}

TEST_CASE("CorePrep rejects a runtime call that names no function")
{
    SECTION("an identity the catalog does not have")
    {
        auto module = WritingModule();
        Call(module, kConcat).operands.front() = Integer(999);
        CHECK(HasIssue(Core::verify(module), "TAC1076"));
    }
    SECTION("zero")
    {
        auto module = WritingModule();
        Call(module, kConcat).operands.front() = Integer(0);
        CHECK(HasIssue(Core::verify(module), "TAC1076"));
    }
    SECTION("a negative number")
    {
        auto module = WritingModule();
        Call(module, kConcat).operands.front() = Integer(-1);
        CHECK(HasIssue(Core::verify(module), "TAC1076"));
    }
    SECTION("a value that is computed")
    {
        // The function is fixed when the program is compiled.
        auto module = WritingModule();
        Call(module, kConcat).operands.front()
            = Variable(2U, Core::Type::int64());
        CHECK(HasIssue(Core::verify(module), "TAC1076"));
    }
    SECTION("no operand at all")
    {
        auto module = WritingModule();
        Call(module, kConcat).operands.clear();
        CHECK(HasIssue(Core::verify(module), "TAC1076"));
    }
}

TEST_CASE("CorePrep holds a runtime call to its function's arguments")
{
    SECTION("one too few")
    {
        auto module = WritingModule();
        Call(module, kConcat).operands.pop_back();
        CHECK(HasIssue(Core::verify(module), "TAC1076"));
    }
    SECTION("one too many")
    {
        auto module = WritingModule();
        Call(module, kConcat)
            .operands.push_back(Variable(3U, Core::Type::string()));
        CHECK(HasIssue(Core::verify(module), "TAC1076"));
    }
    SECTION("a number where a string is taken")
    {
        auto module = WritingModule();
        Call(module, kConcat).operands.back()
            = Variable(2U, Core::Type::int64());
        CHECK(HasIssue(Core::verify(module), "TAC1076"));
    }
    SECTION("a string where a signed integer is taken")
    {
        auto module = WritingModule();
        Call(module, kFormat).operands.back()
            = Variable(3U, Core::Type::string());
        CHECK(HasIssue(Core::verify(module), "TAC1076"));
    }
    SECTION("a width that is not an int")
    {
        auto module = WritingModule();
        Call(module, kFormat).operands[2]
            = Core::Atom::constant(Core::integer_from_signed(5),
                                   Core::Type::int32());
        CHECK(HasIssue(Core::verify(module), "TAC1076"));
    }
}

TEST_CASE("CorePrep holds a runtime call to its function's result")
{
    SECTION("a string result bound as a number")
    {
        auto module = WritingModule();
        Call(module, kConcat).type = Core::Type::int64();
        CHECK(HasIssue(Core::verify(module), "TAC1076"));
    }
    SECTION("a write given a result")
    {
        auto module = WritingModule();
        Call(module, kWrite).type = Core::Type::string();
        CHECK(HasIssue(Core::verify(module), "TAC1076"));
    }
}

TEST_CASE("Xpp carries runtime calls with their identity and arguments")
{
    auto xpp = Xpp::lower(WritingModule());
    CHECK(Progmasoft::Tala::Xpp::Verify(xpp).empty());
    const auto calls = Calls(xpp, Xpp::Opcode::RuntimeCall);
    REQUIRE(calls.size() == 3U);
    // The function is a literal operand, not a symbol that is read.
    for (const auto *call : calls)
    {
        REQUIRE_FALSE(call->operands.empty());
        CHECK(call->operands.front().kind == Xpp::Operand::Kind::Literal);
        CHECK(Runtime::IdentityOf(call->operands.front().literal,
                                  call->operands.front().type));
    }
    CHECK(Runtime::IdentityOf(calls[0]->operands.front().literal,
                              calls[0]->operands.front().type)
          == 6U);
    CHECK(calls[0]->operands.size() == 5U);
    CHECK(calls[0]->result_type == Core::Type::string());
    CHECK(calls[1]->operands.size() == 3U);
    // The write yields nothing and is kept for what it does.
    CHECK(calls[2]->result_type == Core::Type::unit());
    CHECK(calls[2]->effect == Xpp::Instruction::Effect::Discard);
}

TEST_CASE("Xpp writes and reads runtime calls unchanged")
{
    const auto xpp = Xpp::lower(WritingModule());
    const auto encoded = Progmasoft::Tala::Xpp::Wire::Encode(xpp);
    REQUIRE(encoded);
    const auto decoded = Progmasoft::Tala::Xpp::Wire::Decode(encoded.bytes);
    REQUIRE(decoded);
    REQUIRE(decoded.module);
    CHECK(*decoded.module == xpp);
}

TEST_CASE("Xpp checks a runtime call for itself")
{
    SECTION("an unknown function")
    {
        auto xpp = Xpp::lower(WritingModule());
        auto *call = Calls(xpp, Xpp::Opcode::RuntimeCall).front();
        call->operands.front().literal = Core::integer_from_signed(999);
        CHECK(HasIssue(Progmasoft::Tala::Xpp::Verify(xpp), "TAP1048"));
    }
    SECTION("a function named by a symbol")
    {
        auto xpp = Xpp::lower(WritingModule());
        auto *call = Calls(xpp, Xpp::Opcode::RuntimeCall).front();
        call->operands.front().kind = Xpp::Operand::Kind::Symbol;
        call->operands.front().symbol = 2U;
        CHECK(HasIssue(Progmasoft::Tala::Xpp::Verify(xpp), "TAP1048"));
    }
    SECTION("a missing argument")
    {
        auto xpp = Xpp::lower(WritingModule());
        auto *call = Calls(xpp, Xpp::Opcode::RuntimeCall).front();
        call->operands.pop_back();
        CHECK(HasIssue(Progmasoft::Tala::Xpp::Verify(xpp), "TAP1048"));
    }
    SECTION("an argument of another type")
    {
        auto xpp = Xpp::lower(WritingModule());
        auto *call = Calls(xpp, Xpp::Opcode::RuntimeCall).front();
        call->operands.back().type = Core::Type::uint64();
        CHECK(HasIssue(Progmasoft::Tala::Xpp::Verify(xpp), "TAP1048"));
    }
    SECTION("a result of another type")
    {
        auto xpp = Xpp::lower(WritingModule());
        auto *call = Calls(xpp, Xpp::Opcode::RuntimeCall).front();
        call->result_type = Core::Type::boolean();
        CHECK(HasIssue(Progmasoft::Tala::Xpp::Verify(xpp), "TAP1048"));
    }
}

TEST_CASE("Xmm carries runtime calls with an immediate identity")
{
    auto xmm = Xmm::lower(Xpp::lower(WritingModule()));
    CHECK(Progmasoft::Tala::Xmm::Verify(xmm).empty());
    const auto calls = Calls(xmm, Xmm::Opcode::RuntimeCall);
    REQUIRE(calls.size() == 3U);
    for (const auto *call : calls)
    {
        REQUIRE_FALSE(call->operands.empty());
        CHECK(call->operands.front().kind == Xmm::Value::Kind::Immediate);
    }
    CHECK(calls[0]->has_result);
    CHECK(calls[1]->has_result);
    CHECK_FALSE(calls[2]->has_result);
}

TEST_CASE("Xmm writes and reads runtime calls unchanged")
{
    const auto xmm = Xmm::lower(Xpp::lower(WritingModule()));
    const auto encoded = Progmasoft::Tala::Xmm::Wire::Encode(xmm);
    REQUIRE(encoded);
    const auto decoded = Progmasoft::Tala::Xmm::Wire::Decode(encoded.bytes);
    REQUIRE(decoded);
    REQUIRE(decoded.module);
    CHECK(*decoded.module == xmm);
}

TEST_CASE("Xmm checks a runtime call for itself")
{
    SECTION("an unknown function")
    {
        auto xmm = Xmm::lower(Xpp::lower(WritingModule()));
        auto *call = Calls(xmm, Xmm::Opcode::RuntimeCall).front();
        call->operands.front().immediate = Core::integer_from_signed(0);
        CHECK(HasIssue(Progmasoft::Tala::Xmm::Verify(xmm), "TAL1054"));
    }
    SECTION("a missing argument")
    {
        auto xmm = Xmm::lower(Xpp::lower(WritingModule()));
        auto *call = Calls(xmm, Xmm::Opcode::RuntimeCall).front();
        call->operands.pop_back();
        CHECK(HasIssue(Progmasoft::Tala::Xmm::Verify(xmm), "TAL1054"));
    }
    SECTION("an argument of another type")
    {
        auto xmm = Xmm::lower(Xpp::lower(WritingModule()));
        auto *call = Calls(xmm, Xmm::Opcode::RuntimeCall).front();
        call->operands.back().type = Core::Type::float64();
        CHECK(HasIssue(Progmasoft::Tala::Xmm::Verify(xmm), "TAL1054"));
    }
    SECTION("a result of another type")
    {
        auto xmm = Xmm::lower(Xpp::lower(WritingModule()));
        auto *call = Calls(xmm, Xmm::Opcode::RuntimeCall).front();
        call->result_type = Core::Type::int64();
        CHECK(HasIssue(Progmasoft::Tala::Xmm::Verify(xmm), "TAL1054"));
    }
}

TEST_CASE("ownership placement releases the strings a runtime call returns")
{
    // Three strings are created: the literal and the two results. Each is
    // released once, after its last use; the write borrows its argument.
    const auto xpp
        = Progmasoft::Tala::Xpp::PlaceOwnership(Xpp::lower(WritingModule()));
    CHECK(Progmasoft::Tala::Xpp::Verify(xpp).empty());
    std::size_t releases{};
    for (const auto &instruction :
         xpp.functions.front().blocks.front().instructions)
        if (instruction.opcode == Xpp::Opcode::ReleaseStrong)
            ++releases;
    CHECK(releases == 3U);
}

TEST_CASE("LLVM calls the runtime function by the symbol of its row")
{
    const auto xmm = Xmm::lower(
        Progmasoft::Tala::Xpp::PlaceOwnership(Xpp::lower(WritingModule())));
    CHECK(Progmasoft::Tala::Xmm::Verify(xmm).empty());
    Llvm::Options options;
    options.optimization = Llvm::OptimizationLevel::Debug;
    const auto result = Llvm::Lower(xmm, options);
    REQUIRE(result);
    const std::string_view ir = result.artifact->llvm_ir;

    // Flags, width and precision before the value, each sixty-four bits.
    CHECK(ir.find("declare ptr @tala_text_format_signed(i64, i64, i64, i64)")
          != std::string_view::npos);
    CHECK(ir.find("declare ptr @tala_text_concat(ptr, ptr)")
          != std::string_view::npos);
    CHECK(ir.find("declare void @tala_console_write(ptr, i64)")
          != std::string_view::npos);
    CHECK(Occurrences(ir, "call ptr @tala_text_format_signed(") == 1U);
    CHECK(Occurrences(ir, "call ptr @tala_text_concat(") == 1U);
    CHECK(Occurrences(ir, "call void @tala_console_write(") == 1U);
    // The literal, the digits and the line are each released.
    CHECK(Occurrences(ir, "call void @tala_aarc_release_strong(") == 3U);
}

TEST_CASE("LLVM lowers runtime calls at every optimization level")
{
    const auto xmm = Xmm::lower(Xpp::lower(WritingModule()));
    for (const auto level : { Llvm::OptimizationLevel::Debug,
                              Llvm::OptimizationLevel::Less,
                              Llvm::OptimizationLevel::Default,
                              Llvm::OptimizationLevel::Aggressive })
    {
        Llvm::Options options;
        options.optimization = level;
        const auto result = Llvm::Lower(xmm, options);
        REQUIRE(result);
        // A write is observed by whoever reads the output: no level of
        // optimization removes it.
        CHECK(result.artifact->llvm_ir.find("@tala_console_write(")
              != std::string::npos);
    }
}

TEST_CASE("a string literal given to a runtime call is released")
{
    // The literal is the operand itself here, not a binding: it creates a
    // string where it is used, and nothing names that string. Ownership
    // placement gives it a symbol, so that it can be released after the
    // call that borrowed it.
    auto module = WritingModule();
    Call(module, kConcat).operands[1] = Text(U"Count: ");
    auto placed = Progmasoft::Tala::Xpp::PlaceOwnership(Xpp::lower(module));
    CHECK(Progmasoft::Tala::Xpp::Verify(placed).empty());
    for (const auto *call : Calls(placed, Xpp::Opcode::RuntimeCall))
        for (std::size_t index = 1U; index < call->operands.size(); ++index)
            if (call->operands[index].type == Core::Type::string())
                CHECK(call->operands[index].kind == Xpp::Operand::Kind::Symbol);
    // The label nothing reads any more, the literal, the digits and the
    // line: four strings, four releases.
    std::size_t releases{};
    for (const auto &instruction :
         placed.functions.front().blocks.front().instructions)
        if (instruction.opcode == Xpp::Opcode::ReleaseStrong)
            ++releases;
    CHECK(releases == 4U);
}
