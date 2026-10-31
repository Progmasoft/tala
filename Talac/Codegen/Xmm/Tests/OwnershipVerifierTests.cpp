// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <ranges>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Xmm/OwnershipVerifier.hpp"

namespace
{
    namespace Core = ::tala::core;
    namespace IR = ::tala::xmm;
    namespace Xmm = ::Progmasoft::Tala::Xmm;

    [[nodiscard]] auto
    TextType() -> Core::Type
    {
        return Core::Type::string();
    }

    [[nodiscard]] auto
    Register(IR::VirtualRegister reg, Core::Type type = TextType()) -> IR::Value
    {
        return {
            IR::Value::Kind::Register, std::move(type), reg, 0U,
            std::monostate{},
        };
    }

    [[nodiscard]] auto
    Unit() -> IR::Value
    {
        return {
            IR::Value::Kind::Immediate, Core::Type::unit(), 0U, 0U,
            std::monostate{},
        };
    }

    [[nodiscard]] auto
    Ownership(IR::Opcode opcode,
              IR::VirtualRegister source,
              IR::VirtualRegister destination = 0U) -> IR::Instruction
    {
        const auto release = opcode == IR::Opcode::ReleaseStrong
                             || opcode == IR::Opcode::ReleaseWeak
                             || opcode == IR::Opcode::ReleaseUnowned;
        return {
            opcode,
            destination,
            release ? Core::Type::unit() : TextType(),
            { Register(source) },
            !release,
            0U,
            {},
        };
    }

    [[nodiscard]] auto
    Move(IR::VirtualRegister source, IR::VirtualRegister destination)
        -> IR::Instruction
    {
        return {
            IR::Opcode::Move,
            destination,
            TextType(),
            { Register(source) },
            true,
            0U,
            {},
        };
    }

    [[nodiscard]] auto
    IntegerMove(IR::VirtualRegister source, IR::VirtualRegister destination)
        -> IR::Instruction
    {
        return {
            IR::Opcode::Move,
            destination,
            Core::Type::int64(),
            { Register(source, Core::Type::int64()) },
            true,
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
    Return(IR::VirtualRegister reg) -> IR::Terminator
    {
        IR::Terminator terminator;
        terminator.kind = IR::Terminator::Kind::Return;
        terminator.value = Register(reg);
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
            IR::Value::Kind::Immediate, Core::Type::boolean(), 0U, 0U, true,
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
        function.parameter_registers = { 1U };
        function.parameter_types = { TextType() };
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
    HasCode(const std::vector<Xmm::VerificationIssue> &issues,
            std::string_view code) -> bool
    {
        return std::ranges::any_of(issues, [code](const auto &issue) {
            return issue.code == code;
        });
    }
} // namespace

TEST_CASE("Xmm ownership accepts a balanced strong weak and unowned chain")
{
    const auto function
        = Function({ Block(0U,
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
                           ReturnUnit()) });
    CHECK(Xmm::VerifyOwnership(function).empty());
}

TEST_CASE("Xmm ownership rejects a double strong release")
{
    const auto issues = Xmm::VerifyOwnership(
        Function({ Block(0U,
                         {
                             Ownership(IR::Opcode::ReleaseStrong, 1U),
                             Ownership(IR::Opcode::ReleaseStrong, 1U),
                         },
                         ReturnUnit()) }));
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().code == "TAL1046");
    CHECK(issues.front().instruction == 1U);
}

TEST_CASE("Xmm ownership rejects a weak handle released as strong")
{
    const auto issues = Xmm::VerifyOwnership(
        Function({ Block(0U,
                         {
                             Ownership(IR::Opcode::MakeWeak, 1U, 2U),
                             Ownership(IR::Opcode::ReleaseStrong, 2U),
                         },
                         ReturnUnit()) }));
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().code == "TAL1047");
}

TEST_CASE("Xmm ownership rejects an unowned handle locked as weak")
{
    const auto issues = Xmm::VerifyOwnership(
        Function({ Block(0U,
                         {
                             Ownership(IR::Opcode::MakeUnowned, 1U, 2U),
                             Ownership(IR::Opcode::LockWeak, 2U, 3U),
                         },
                         ReturnUnit()) }));
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().code == "TAL1047");
}

TEST_CASE("Xmm ownership rejects ordinary use after strong release")
{
    const auto issues = Xmm::VerifyOwnership(
        Function({ Block(0U,
                         {
                             Ownership(IR::Opcode::ReleaseStrong, 1U),
                             Move(1U, 2U),
                         },
                         ReturnUnit()) }));
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().code == "TAL1046");
    CHECK(issues.front().instruction == 1U);
}

TEST_CASE("Xmm ownership rejects returning a released reference")
{
    auto function
        = Function({ Block(0U,
                           { Ownership(IR::Opcode::ReleaseStrong, 1U) },
                           Return(1U)) });
    function.return_type = TextType();
    const auto issues = Xmm::VerifyOwnership(function);
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().code == "TAL1046");
    CHECK(issues.front().instruction == 1U);
    CHECK(issues.front().message.find("return") != std::string::npos);
}

TEST_CASE("Xmm ownership rejects a conditional release followed by use")
{
    const auto issues = Xmm::VerifyOwnership(Function({
        Block(0U, {}, Branch(1U, 2U)),
        Block(1U, { Ownership(IR::Opcode::ReleaseStrong, 1U) }, Jump(3U)),
        Block(2U, {}, Jump(3U)),
        Block(3U, { Move(1U, 2U) }, ReturnUnit()),
    }));
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().code == "TAL1048");
    CHECK(issues.front().block == 3U);
}

TEST_CASE("Xmm ownership accepts release on every incoming path")
{
    const auto issues = Xmm::VerifyOwnership(Function({
        Block(0U, {}, Branch(1U, 2U)),
        Block(1U, { Ownership(IR::Opcode::ReleaseStrong, 1U) }, Jump(3U)),
        Block(2U, { Ownership(IR::Opcode::ReleaseStrong, 1U) }, Jump(3U)),
        Block(3U, {}, ReturnUnit()),
    }));
    CHECK(issues.empty());
}

TEST_CASE("Xmm ownership rejects different handle representations at a join")
{
    const auto issues = Xmm::VerifyOwnership(Function({
        Block(0U, {}, Branch(1U, 2U)),
        Block(1U, { Ownership(IR::Opcode::MakeWeak, 1U, 2U) }, Jump(3U)),
        Block(2U, { Ownership(IR::Opcode::MakeUnowned, 1U, 2U) }, Jump(3U)),
        Block(3U, { Ownership(IR::Opcode::ReleaseWeak, 2U) }, ReturnUnit()),
    }));
    REQUIRE(issues.size() == 1U);
    CHECK(issues.front().code == "TAL1048");
}

TEST_CASE("Xmm ownership handles a live loop without depending on block order")
{
    auto function = Function({
        Block(0U, {}, Jump(1U)),
        Block(1U, { Move(1U, 2U) }, Branch(1U, 2U)),
        Block(2U, {}, ReturnUnit()),
    });
    const auto forward = Xmm::VerifyOwnership(function);
    std::ranges::reverse(function.blocks);
    const auto reverse = Xmm::VerifyOwnership(function);
    CHECK(forward.empty());
    CHECK(reverse.empty());
}

TEST_CASE("Xmm ownership ignores unreachable release misuse")
{
    const auto issues = Xmm::VerifyOwnership(Function({
        Block(0U, {}, ReturnUnit()),
        Block(8U,
              {
                  Ownership(IR::Opcode::ReleaseStrong, 1U),
                  Move(1U, 2U),
              },
              ReturnUnit()),
    }));
    CHECK(issues.empty());
}

TEST_CASE("Xmm ownership ignores non-AARC registers")
{
    auto function
        = Function({ Block(0U, { IntegerMove(9U, 10U) }, ReturnUnit()) });
    function.parameter_registers.push_back(9U);
    function.parameter_types.push_back(Core::Type::int64());
    CHECK(Xmm::VerifyOwnership(function).empty());
}

TEST_CASE("Xmm structural verifier publishes ownership diagnostics")
{
    const auto module
        = Module(Function({ Block(0U,
                                  {
                                      Ownership(IR::Opcode::ReleaseStrong, 1U),
                                      Move(1U, 2U),
                                  },
                                  ReturnUnit()) }));
    const auto issues = Xmm::Verify(module);
    CHECK(HasCode(issues, "TAL1046"));
}

TEST_CASE("Xmm weak lock does not consume the weak handle")
{
    const auto issues = Xmm::VerifyOwnership(
        Function({ Block(0U,
                         {
                             Ownership(IR::Opcode::MakeWeak, 1U, 2U),
                             Ownership(IR::Opcode::LockWeak, 2U, 3U),
                             Ownership(IR::Opcode::LockWeak, 2U, 4U),
                             Ownership(IR::Opcode::ReleaseStrong, 3U),
                             Ownership(IR::Opcode::ReleaseStrong, 4U),
                             Ownership(IR::Opcode::ReleaseWeak, 2U),
                         },
                         ReturnUnit()) }));
    CHECK(issues.empty());
}

TEST_CASE("Xmm unowned load does not consume the unowned handle")
{
    const auto issues = Xmm::VerifyOwnership(
        Function({ Block(0U,
                         {
                             Ownership(IR::Opcode::MakeUnowned, 1U, 2U),
                             Ownership(IR::Opcode::LoadUnowned, 2U, 3U),
                             Ownership(IR::Opcode::LoadUnowned, 2U, 4U),
                             Ownership(IR::Opcode::ReleaseStrong, 3U),
                             Ownership(IR::Opcode::ReleaseStrong, 4U),
                             Ownership(IR::Opcode::ReleaseUnowned, 2U),
                         },
                         ReturnUnit()) }));
    CHECK(issues.empty());
}

TEST_CASE("Xmm retain does not consume the original strong handle")
{
    const auto issues = Xmm::VerifyOwnership(
        Function({ Block(0U,
                         {
                             Ownership(IR::Opcode::RetainStrong, 1U, 2U),
                             Move(1U, 3U),
                             Ownership(IR::Opcode::ReleaseStrong, 2U),
                         },
                         ReturnUnit()) }));
    CHECK(issues.empty());
}
