// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <ranges>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Xpp/OwnershipVerifier.hpp"

namespace
{
    namespace Core = ::tala::core;
    namespace IR = ::tala::xpp;
    namespace Xpp = ::Progmasoft::Tala::Xpp;

    [[nodiscard]] auto
    TextType() -> Core::Type
    {
        return Core::Type::string();
    }

    [[nodiscard]] auto
    Symbol(IR::SymbolId symbol, Core::Type type = TextType()) -> IR::Operand
    {
        return {
            IR::Operand::Kind::Symbol,
            std::move(type),
            symbol,
            std::monostate{},
        };
    }

    [[nodiscard]] auto
    Unit() -> IR::Operand
    {
        return {
            IR::Operand::Kind::Literal,
            Core::Type::unit(),
            0U,
            std::monostate{},
        };
    }

    [[nodiscard]] auto
    Ownership(IR::Opcode opcode,
              IR::SymbolId source,
              IR::SymbolId destination = 0U) -> IR::Instruction
    {
        const auto release = opcode == IR::Opcode::ReleaseStrong
                             || opcode == IR::Opcode::ReleaseWeak
                             || opcode == IR::Opcode::ReleaseUnowned;
        return {
            release ? IR::Instruction::Effect::Discard
                    : IR::Instruction::Effect::Define,
            opcode,
            destination,
            release ? Core::Type::unit() : TextType(),
            { Symbol(source) },
            0U,
            {},
        };
    }

    [[nodiscard]] auto
    Copy(IR::SymbolId source, IR::SymbolId destination) -> IR::Instruction
    {
        return {
            IR::Instruction::Effect::Define,
            IR::Opcode::Copy,
            destination,
            TextType(),
            { Symbol(source) },
            0U,
            {},
        };
    }

    [[nodiscard]] auto
    IntegerCopy(IR::SymbolId source, IR::SymbolId destination)
        -> IR::Instruction
    {
        return {
            IR::Instruction::Effect::Define,
            IR::Opcode::Copy,
            destination,
            Core::Type::int64(),
            { Symbol(source, Core::Type::int64()) },
            0U,
            {},
        };
    }

    [[nodiscard]] auto
    ReturnUnit() -> IR::Terminator
    {
        IR::Terminator terminator;
        terminator.kind = IR::Terminator::Kind::Return;
        terminator.value = Unit();
        return terminator;
    }

    [[nodiscard]] auto
    Return(IR::SymbolId symbol) -> IR::Terminator
    {
        IR::Terminator terminator;
        terminator.kind = IR::Terminator::Kind::Return;
        terminator.value = Symbol(symbol);
        return terminator;
    }

    [[nodiscard]] auto
    Jump(IR::BlockId target) -> IR::Terminator
    {
        IR::Terminator terminator;
        terminator.kind = IR::Terminator::Kind::Jump;
        terminator.true_target = target;
        return terminator;
    }

    [[nodiscard]] auto
    Branch(IR::BlockId trueTarget, IR::BlockId falseTarget) -> IR::Terminator
    {
        IR::Terminator terminator;
        terminator.kind = IR::Terminator::Kind::Branch;
        terminator.value = {
            IR::Operand::Kind::Literal,
            Core::Type::boolean(),
            0U,
            true,
        };
        terminator.true_target = trueTarget;
        terminator.false_target = falseTarget;
        return terminator;
    }

    [[nodiscard]] auto
    Block(IR::BlockId id,
          std::vector<IR::Instruction> instructions,
          IR::Terminator terminator) -> IR::Block
    {
        return { id, std::move(instructions), std::move(terminator) };
    }

    [[nodiscard]] auto
    Function(std::vector<IR::Block> blocks) -> IR::Function
    {
        IR::Function function;
        function.symbol = { 700U, U"Own" };
        function.parameters = { { { 1U, U"text" }, TextType() } };
        function.return_type = Core::Type::unit();
        function.entry = 0U;
        function.blocks = std::move(blocks);
        return function;
    }

    [[nodiscard]] auto
    Module(IR::Function function) -> IR::Module
    {
        return { { U"Verifier", U"Ownership" }, { std::move(function) } };
    }

    [[nodiscard]] auto
    HasCode(const std::vector<Xpp::VerificationIssue> &issues,
            std::string_view code) -> bool
    {
        return std::ranges::any_of(issues, [code](const auto &issue) {
            return issue.code == code;
        });
    }
} // namespace

TEST_CASE("Xpp ownership accepts a balanced conversion chain")
{
    const auto issues = Xpp::VerifyOwnership(
        Module(Function({ Block(0U,
                                {
                                    Ownership(IR::Opcode::RetainStrong, 1U, 2U),
                                    Ownership(IR::Opcode::MakeWeak, 2U, 3U),
                                    Ownership(IR::Opcode::LockWeak, 3U, 4U),
                                    Ownership(IR::Opcode::MakeUnowned, 4U, 5U),
                                    Ownership(IR::Opcode::LoadUnowned, 5U, 6U),
                                    Ownership(IR::Opcode::ReleaseStrong, 2U),
                                    Ownership(IR::Opcode::ReleaseStrong, 4U),
                                    Ownership(IR::Opcode::ReleaseStrong, 6U),
                                    Ownership(IR::Opcode::ReleaseWeak, 3U),
                                    Ownership(IR::Opcode::ReleaseUnowned, 5U),
                                },
                                ReturnUnit()) })));
    CHECK(issues.empty());
}

TEST_CASE("Xpp ownership rejects a double strong release")
{
    const auto issues = Xpp::VerifyOwnership(
        Module(Function({ Block(0U,
                                {
                                    Ownership(IR::Opcode::ReleaseStrong, 1U),
                                    Ownership(IR::Opcode::ReleaseStrong, 1U),
                                },
                                ReturnUnit()) })));
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().code == "TAP1042");
    CHECK(issues.front().instruction == 1U);
}

TEST_CASE("Xpp ownership rejects a weak handle released as strong")
{
    const auto issues = Xpp::VerifyOwnership(
        Module(Function({ Block(0U,
                                {
                                    Ownership(IR::Opcode::MakeWeak, 1U, 2U),
                                    Ownership(IR::Opcode::ReleaseStrong, 2U),
                                },
                                ReturnUnit()) })));
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().code == "TAP1043");
}

TEST_CASE("Xpp ownership rejects unowned input passed to weak lock")
{
    const auto issues = Xpp::VerifyOwnership(
        Module(Function({ Block(0U,
                                {
                                    Ownership(IR::Opcode::MakeUnowned, 1U, 2U),
                                    Ownership(IR::Opcode::LockWeak, 2U, 3U),
                                },
                                ReturnUnit()) })));
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().code == "TAP1043");
}

TEST_CASE("Xpp ownership rejects ordinary use after release")
{
    const auto issues = Xpp::VerifyOwnership(
        Module(Function({ Block(0U,
                                {
                                    Ownership(IR::Opcode::ReleaseStrong, 1U),
                                    Copy(1U, 2U),
                                },
                                ReturnUnit()) })));
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().code == "TAP1042");
    CHECK(issues.front().instruction == 1U);
}

TEST_CASE("Xpp ownership rejects returning a released value")
{
    auto function
        = Function({ Block(0U,
                           { Ownership(IR::Opcode::ReleaseStrong, 1U) },
                           Return(1U)) });
    function.return_type = TextType();
    const auto issues = Xpp::VerifyOwnership(Module(std::move(function)));
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().code == "TAP1042");
    CHECK(issues.front().message.find("return") != std::string::npos);
}

TEST_CASE("Xpp ownership rejects a conditional release followed by use")
{
    const auto issues = Xpp::VerifyOwnership(Module(Function({
        Block(0U, {}, Branch(1U, 2U)),
        Block(1U, { Ownership(IR::Opcode::ReleaseStrong, 1U) }, Jump(3U)),
        Block(2U, {}, Jump(3U)),
        Block(3U, { Copy(1U, 2U) }, ReturnUnit()),
    })));
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().code == "TAP1044");
    CHECK(issues.front().block == 3U);
}

TEST_CASE("Xpp ownership accepts release on every incoming path")
{
    const auto issues = Xpp::VerifyOwnership(Module(Function({
        Block(0U, {}, Branch(1U, 2U)),
        Block(1U, { Ownership(IR::Opcode::ReleaseStrong, 1U) }, Jump(3U)),
        Block(2U, { Ownership(IR::Opcode::ReleaseStrong, 1U) }, Jump(3U)),
        Block(3U, {}, ReturnUnit()),
    })));
    CHECK(issues.empty());
}

TEST_CASE("Xpp ownership rejects representation disagreement at a join")
{
    const auto issues = Xpp::VerifyOwnership(Module(Function({
        Block(0U, {}, Branch(1U, 2U)),
        Block(1U, { Ownership(IR::Opcode::MakeWeak, 1U, 2U) }, Jump(3U)),
        Block(2U, { Ownership(IR::Opcode::MakeUnowned, 1U, 2U) }, Jump(3U)),
        Block(3U, { Ownership(IR::Opcode::ReleaseWeak, 2U) }, ReturnUnit()),
    })));
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().code == "TAP1044");
}

TEST_CASE("Xpp ownership ignores scalar storage")
{
    auto function
        = Function({ Block(0U, { IntegerCopy(9U, 10U) }, ReturnUnit()) });
    function.parameters.push_back({ { 9U, U"number" }, Core::Type::int64() });
    const auto issues = Xpp::VerifyOwnership(Module(std::move(function)));
    CHECK(issues.empty());
}

TEST_CASE("Xpp ownership ignores unreachable misuse")
{
    const auto issues = Xpp::VerifyOwnership(Module(Function({
        Block(0U, {}, ReturnUnit()),
        Block(8U,
              {
                  Ownership(IR::Opcode::ReleaseStrong, 1U),
                  Copy(1U, 2U),
              },
              ReturnUnit()),
    })));
    CHECK(issues.empty());
}

TEST_CASE("Xpp ownership accepts repeated weak locks before release")
{
    const auto issues = Xpp::VerifyOwnership(
        Module(Function({ Block(0U,
                                {
                                    Ownership(IR::Opcode::MakeWeak, 1U, 2U),
                                    Ownership(IR::Opcode::LockWeak, 2U, 3U),
                                    Ownership(IR::Opcode::LockWeak, 2U, 4U),
                                    Ownership(IR::Opcode::ReleaseStrong, 3U),
                                    Ownership(IR::Opcode::ReleaseStrong, 4U),
                                    Ownership(IR::Opcode::ReleaseWeak, 2U),
                                },
                                ReturnUnit()) })));
    CHECK(issues.empty());
}

TEST_CASE("Xpp ownership accepts repeated unowned loads before release")
{
    const auto issues = Xpp::VerifyOwnership(
        Module(Function({ Block(0U,
                                {
                                    Ownership(IR::Opcode::MakeUnowned, 1U, 2U),
                                    Ownership(IR::Opcode::LoadUnowned, 2U, 3U),
                                    Ownership(IR::Opcode::LoadUnowned, 2U, 4U),
                                    Ownership(IR::Opcode::ReleaseStrong, 3U),
                                    Ownership(IR::Opcode::ReleaseStrong, 4U),
                                    Ownership(IR::Opcode::ReleaseUnowned, 2U),
                                },
                                ReturnUnit()) })));
    CHECK(issues.empty());
}

TEST_CASE("Xpp ownership does not classify a direct function as local storage")
{
    auto caller = Function({ Block(0U, {}, ReturnUnit()) });
    const auto callable = Core::Type::function({}, Core::Type::unit());
    caller.blocks.front().instructions.push_back(
        { IR::Instruction::Effect::Discard,
          IR::Opcode::Call,
          0U,
          Core::Type::unit(),
          { Symbol(800U, callable) },
          0U,
          {} });

    IR::Function callee;
    callee.symbol = { 800U, U"Target" };
    callee.return_type = Core::Type::unit();
    callee.entry = 0U;
    callee.blocks = { Block(0U, {}, ReturnUnit()) };
    IR::Module module{ { U"Verifier", U"DirectCall" },
                       { std::move(caller), std::move(callee) } };
    CHECK(Xpp::VerifyOwnership(module).empty());
}

TEST_CASE("Xpp structural verifier publishes ownership diagnostics")
{
    const auto module
        = Module(Function({ Block(0U,
                                  {
                                      Ownership(IR::Opcode::ReleaseStrong, 1U),
                                      Copy(1U, 2U),
                                  },
                                  ReturnUnit()) }));
    const auto issues = Xpp::Verify(module);
    CHECK(HasCode(issues, "TAP1042"));
}
