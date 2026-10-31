// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep.hpp"
#include "Talac/Fuzzing/CorePrepParity.hpp"

// The parity oracle is only as strong as its notion of "same program". These
// tests pin what it must ignore (block and temporary numbering, unreachable
// blocks) and, more importantly, what it must never ignore.

namespace
{
    namespace Prepared = tala::core;
    using Progmasoft::Tala::Fuzzing::CompareCorePrep;

    [[nodiscard]] auto
    Symbol(std::uint64_t id, std::u32string spelling) -> Prepared::SymbolName
    {
        return { id, std::move(spelling) };
    }

    [[nodiscard]] auto
    Read(std::uint64_t id, std::u32string spelling, Prepared::Type type)
        -> Prepared::Atom
    {
        return Prepared::Atom::variable(Symbol(id, std::move(spelling)),
                                        std::move(type));
    }

    [[nodiscard]] auto
    Number(std::int64_t value) -> Prepared::Atom
    {
        return Prepared::Atom::constant(value, Prepared::Type::int64());
    }

    [[nodiscard]] auto
    Bind(Prepared::SymbolName destination,
         Prepared::Type type,
         Prepared::Operation operation,
         std::vector<Prepared::Atom> operands) -> Prepared::Instruction
    {
        return { Prepared::Instruction::Kind::Bind,
                 std::move(destination),
                 std::move(type),
                 false,
                 operation,
                 std::move(operands),
                 {},
                 {} };
    }

    [[nodiscard]] auto
    Jump(Prepared::BlockId target) -> Prepared::Terminator
    {
        return { Prepared::Terminator::Kind::Jump, {}, target, 0U };
    }

    [[nodiscard]] auto
    Branch(Prepared::Atom condition,
           Prepared::BlockId whenTrue,
           Prepared::BlockId whenFalse) -> Prepared::Terminator
    {
        return { Prepared::Terminator::Kind::Branch,
                 std::move(condition),
                 whenTrue,
                 whenFalse };
    }

    [[nodiscard]] auto
    Return(Prepared::Atom value) -> Prepared::Terminator
    {
        return { Prepared::Terminator::Kind::Return, std::move(value), 0U, 0U };
    }

    /**
     * `while (value < 3) { value = value + 1 } return value`, with caller
     * chosen block identities, temporary identities and block order.
     */
    [[nodiscard]] auto
    Loop(Prepared::BlockId header,
         Prepared::BlockId body,
         Prepared::BlockId exit,
         std::uint64_t condition,
         std::uint64_t sum,
         bool reversed) -> Prepared::CorePrepModule
    {
        const auto value = [] {
            return Read(2U, U"value", Prepared::Type::int64());
        };
        const auto conditionName
            = Symbol(condition, U"$coreprep" + std::u32string(1U, U'0'));
        const auto sumName
            = Symbol(sum, U"$coreprep" + std::u32string(2U, U'9'));
        std::vector<Prepared::Block> blocks{
            { 0U,
              { Bind(Symbol(2U, U"value"),
                     Prepared::Type::int64(),
                     Prepared::Operation::Copy,
                     { Number(0) }) },
              Jump(header) },
            { header,
              { Bind(conditionName,
                     Prepared::Type::boolean(),
                     Prepared::Operation::LessThan,
                     { value(), Number(3) }) },
              Branch(Prepared::Atom::variable(conditionName,
                                              Prepared::Type::boolean()),
                     body,
                     exit) },
            { body,
              { Bind(sumName,
                     Prepared::Type::int64(),
                     Prepared::Operation::Add,
                     { value(), Number(1) }),
                { Prepared::Instruction::Kind::Assign,
                  Symbol(2U, U"value"),
                  Prepared::Type::int64(),
                  false,
                  Prepared::Operation::Copy,
                  { Prepared::Atom::variable(sumName,
                                             Prepared::Type::int64()) },
                  {},
                  {} } },
              Jump(header) },
            { exit, {}, Return(value()) },
        };
        if (reversed)
            std::swap(blocks[1], blocks[3]);
        return { { U"Parity" },
                 { Prepared::Function{ Symbol(1U, U"Evaluate"),
                                       {},
                                       Prepared::Type::int64(),
                                       0U,
                                       std::move(blocks) } } };
    }

    [[nodiscard]] auto
    Reference() -> Prepared::CorePrepModule
    {
        return Loop(1U, 2U, 3U, 10U, 11U, false);
    }
} // namespace

TEST_CASE("parity ignores block identities, block order and temporary "
          "identities",
          "[fuzzing][parity]")
{
    CHECK_FALSE(CompareCorePrep(Reference(), Reference()));
    // Different block numbers, a different emission order, and temporaries
    // numbered in the opposite order describe the same program.
    CHECK_FALSE(CompareCorePrep(Reference(), Loop(7U, 4U, 9U, 31U, 30U, true)));
}

TEST_CASE("parity ignores blocks that cannot be reached from the entry",
          "[fuzzing][parity]")
{
    auto withDeadBlock = Reference();
    withDeadBlock.functions.front().blocks.push_back(
        { 40U,
          { Bind(Symbol(99U, U"$coreprep99"),
                 Prepared::Type::int64(),
                 Prepared::Operation::Copy,
                 { Number(5) }) },
          Jump(1U) });
    CHECK_FALSE(CompareCorePrep(Reference(), withDeadBlock));
}

TEST_CASE("parity reports a back-edge that targets the wrong block",
          "[fuzzing][parity]")
{
    // The defect class this oracle exists for: the body jumps to itself
    // instead of the loop header. Every block is still well formed.
    auto selfLoop = Reference();
    selfLoop.functions.front().blocks[2].terminator = Jump(2U);
    const auto difference = CompareCorePrep(Reference(), selfLoop);
    REQUIRE(difference);
    CHECK(difference->find("Evaluate") != std::string::npos);
    CHECK(difference->find("terminator") != std::string::npos);
}

TEST_CASE("parity distinguishes the true edge from the false edge",
          "[fuzzing][parity]")
{
    auto swapped = Reference();
    auto &terminator = swapped.functions.front().blocks[1].terminator;
    std::swap(terminator.true_target, terminator.false_target);
    CHECK(CompareCorePrep(Reference(), swapped));
}

TEST_CASE("parity compares operations, operands, literals and types exactly",
          "[fuzzing][parity]")
{
    SECTION("operation")
    {
        auto changed = Reference();
        changed.functions.front().blocks[1].instructions[0].operation
            = Prepared::Operation::LessEqual;
        CHECK(CompareCorePrep(Reference(), changed));
    }
    SECTION("literal")
    {
        auto changed = Reference();
        changed.functions.front().blocks[1].instructions[0].operands[1]
            = Number(4);
        CHECK(CompareCorePrep(Reference(), changed));
    }
    SECTION("operand order")
    {
        auto changed = Reference();
        auto &operands
            = changed.functions.front().blocks[2].instructions[0].operands;
        std::swap(operands[0], operands[1]);
        CHECK(CompareCorePrep(Reference(), changed));
    }
    SECTION("type")
    {
        auto changed = Reference();
        changed.functions.front().blocks[2].instructions[0].type
            = Prepared::Type::int32();
        CHECK(CompareCorePrep(Reference(), changed));
    }
    SECTION("instruction order")
    {
        auto changed = Reference();
        auto &instructions = changed.functions.front().blocks[2].instructions;
        std::swap(instructions[0], instructions[1]);
        CHECK(CompareCorePrep(Reference(), changed));
    }
    SECTION("missing instruction")
    {
        auto changed = Reference();
        changed.functions.front().blocks[2].instructions.pop_back();
        CHECK(CompareCorePrep(Reference(), changed));
    }
}

TEST_CASE("parity never renames source symbols or temporary kinds",
          "[fuzzing][parity]")
{
    SECTION("source symbol identity")
    {
        auto changed = Reference();
        changed.functions.front().blocks[3].terminator
            = Return(Read(5U, U"value", Prepared::Type::int64()));
        CHECK(CompareCorePrep(Reference(), changed));
    }
    SECTION("source symbol spelling")
    {
        auto changed = Reference();
        changed.functions.front().symbol.spelling = U"Other";
        CHECK(CompareCorePrep(Reference(), changed));
    }
    SECTION("temporary kind")
    {
        // A condition slot and a plain temporary are different generated
        // symbols even when they hold the same value.
        auto changed = Reference();
        auto &header = changed.functions.front().blocks[1];
        const auto renamed = Symbol(10U, U"$condition10");
        header.instructions[0].destination = renamed;
        header.terminator.value
            = Prepared::Atom::variable(renamed, Prepared::Type::boolean());
        CHECK(CompareCorePrep(Reference(), changed));
    }
    SECTION("temporary reuse")
    {
        // Reading the condition temporary where the sum belongs changes
        // which value flows, although the instruction shapes are equal.
        auto changed = Reference();
        changed.functions.front().blocks[2].instructions[1].operands[0]
            = Read(10U, U"$coreprep0", Prepared::Type::int64());
        CHECK(CompareCorePrep(Reference(), changed));
    }
}

TEST_CASE("parity compares function count and module identity",
          "[fuzzing][parity]")
{
    auto extra = Reference();
    extra.functions.push_back(extra.functions.front());
    extra.functions.back().symbol = Symbol(50U, U"Second");
    const auto difference = CompareCorePrep(Reference(), extra);
    REQUIRE(difference);
    CHECK(difference->find("function count") != std::string::npos);

    auto renamed = Reference();
    renamed.name = { U"Elsewhere" };
    CHECK(CompareCorePrep(Reference(), renamed));
}
