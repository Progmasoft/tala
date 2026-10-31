// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <ranges>

#include "Progmasoft/Tala/Core/CorePrep.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Wire.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Xmm/IR.hpp"
#include "Progmasoft/Tala/Xmm/Verifier.hpp"
#include "Progmasoft/Tala/Xpp/IR.hpp"
#include "Progmasoft/Tala/Xpp/Verifier.hpp"

namespace
{
    namespace Core = tala::core;
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
    Unit() -> Core::Atom
    {
        return Core::Atom::constant(std::monostate{}, Core::Type::unit());
    }

    [[nodiscard]] auto
    ClosureInstruction(Core::CaptureMode mode = Core::CaptureMode::Strong,
                       Core::Type captureType = Core::Type::int64())
        -> Core::Instruction
    {
        Core::Instruction instruction;
        instruction.kind = Core::Instruction::Kind::Bind;
        instruction.destination = Name(3U, U"next");
        instruction.type = Core::Type::function({}, Core::Type::int64());
        instruction.mutable_binding = false;
        instruction.operation = Core::Operation::MakeClosure;
        instruction.closure_function = Name(10U, U"$closure10");
        instruction.captures.push_back(Core::Capture{
            mode,
            Name(4U, U"count"),
            std::move(captureType),
            Integer(0),
        });
        return instruction;
    }

    [[nodiscard]] auto
    ClosureCallInstruction() -> Core::Instruction
    {
        Core::Instruction instruction;
        instruction.kind = Core::Instruction::Kind::Bind;
        instruction.destination = Name(6U, U"value");
        instruction.type = Core::Type::int64();
        instruction.mutable_binding = false;
        instruction.operation = Core::Operation::Call;
        instruction.operands = {
            Variable(3U, Core::Type::function({}, Core::Type::int64())),
        };
        return instruction;
    }

    [[nodiscard]] auto
    ClosureModule() -> Core::CorePrepModule
    {
        Core::Instruction seed;
        seed.kind = Core::Instruction::Kind::Bind;
        seed.destination = Name(2U, U"count");
        seed.type = Core::Type::int64();
        seed.mutable_binding = true;
        seed.operation = Core::Operation::Copy;
        seed.operands = { Integer(0) };

        Core::Function main;
        main.symbol = Name(1U, U"Main");
        main.return_type = Core::Type::unit();
        main.entry = 0U;
        main.blocks = {
            Core::Block{
                0U,
                { std::move(seed),
                  ClosureInstruction(),
                  ClosureCallInstruction() },
                Core::Terminator{ Core::Terminator::Kind::Return,
                                  Unit(),
                                  0U,
                                  0U },
            },
        };

        Core::Instruction add;
        add.kind = Core::Instruction::Kind::Bind;
        add.destination = Name(5U, U"updated");
        add.type = Core::Type::int64();
        add.operation = Core::Operation::Add;
        add.operands = { Variable(4U, Core::Type::int64()), Integer(1) };

        Core::Instruction store;
        store.kind = Core::Instruction::Kind::Assign;
        store.destination = Name(4U, U"count");
        store.type = Core::Type::int64();
        store.operation = Core::Operation::Copy;
        store.operands = { Variable(5U, Core::Type::int64()) };

        Core::Function lifted;
        lifted.symbol = Name(10U, U"$closure10");
        lifted.parameters
            = { Core::Parameter{ Name(4U, U"count"), Core::Type::int64() } };
        lifted.return_type = Core::Type::int64();
        lifted.entry = 0U;
        lifted.blocks = {
            Core::Block{
                0U,
                { std::move(add), std::move(store) },
                Core::Terminator{
                    Core::Terminator::Kind::Return,
                    Variable(4U, Core::Type::int64()),
                    0U,
                    0U,
                },
            },
        };

        return Core::CorePrepModule{ { U"ClosureTests" },
                                     { std::move(main), std::move(lifted) } };
    }

    [[nodiscard]] auto
    HasIssue(const std::vector<Core::VerificationIssue> &issues,
             std::string_view code) -> bool
    {
        return std::ranges::any_of(issues, [code](const auto &issue) {
            return issue.code == code;
        });
    }

    [[nodiscard]] auto
    HasXppIssue(
        const std::vector<Progmasoft::Tala::Xpp::VerificationIssue> &issues,
        std::string_view code) -> bool
    {
        return std::ranges::any_of(issues, [code](const auto &issue) {
            return issue.code == code;
        });
    }

    [[nodiscard]] auto
    HasXmmIssue(
        const std::vector<Progmasoft::Tala::Xmm::VerificationIssue> &issues,
        std::string_view code) -> bool
    {
        return std::ranges::any_of(issues, [code](const auto &issue) {
            return issue.code == code;
        });
    }

    [[nodiscard]] auto
    FindClosure(const Xpp::Module &module) -> const Xpp::Instruction *
    {
        for (const auto &function : module.functions)
            for (const auto &block : function.blocks)
                for (const auto &instruction : block.instructions)
                    if (instruction.opcode == Xpp::Opcode::MakeClosure)
                        return &instruction;
        return nullptr;
    }

    [[nodiscard]] auto
    FindClosure(const Xmm::Module &module) -> const Xmm::Instruction *
    {
        for (const auto &function : module.functions)
            for (const auto &block : function.blocks)
                for (const auto &instruction : block.instructions)
                    if (instruction.opcode == Xmm::Opcode::MakeClosure)
                        return &instruction;
        return nullptr;
    }

    [[nodiscard]] auto
    FindCall(const Xpp::Module &module) -> const Xpp::Instruction *
    {
        for (const auto &function : module.functions)
            for (const auto &block : function.blocks)
                for (const auto &instruction : block.instructions)
                    if (instruction.opcode == Xpp::Opcode::Call)
                        return &instruction;
        return nullptr;
    }

    [[nodiscard]] auto
    FindCall(const Xmm::Module &module) -> const Xmm::Instruction *
    {
        for (const auto &function : module.functions)
            for (const auto &block : function.blocks)
                for (const auto &instruction : block.instructions)
                    if (instruction.opcode == Xmm::Opcode::Call)
                        return &instruction;
        return nullptr;
    }
} // namespace

TEST_CASE("CorePrep v8 round-trips closure targets captures and modes")
{
    const auto source = ClosureModule();
    const auto encoded = Core::wire::encode(source);
    REQUIRE_FALSE(encoded.error);
    REQUIRE(encoded.bytes.size() > 8U);
    CHECK(encoded.bytes[4] == 8U);
    CHECK(encoded.bytes[5] == 0U);

    const auto decoded = Core::wire::decode(encoded.bytes);
    REQUIRE_FALSE(decoded.error);
    REQUIRE(decoded.module);
    CHECK(*decoded.module == source);
}

TEST_CASE("CorePrep verifier accepts a well-formed closure conversion")
{
    CHECK(Core::verify(ClosureModule()).empty());
}

TEST_CASE("CorePrep verifier rejects a missing lifted closure target")
{
    auto module = ClosureModule();
    module.functions.front().blocks.front().instructions[1].closure_function
        = Name(99U, U"missing");
    CHECK(HasIssue(Core::verify(module), "TAC1040"));
}

TEST_CASE("CorePrep verifier rejects mismatched capture storage")
{
    auto module = ClosureModule();
    auto &capture = module.functions.front()
                        .blocks.front()
                        .instructions[1]
                        .captures.front();
    capture.type = Core::Type::boolean();
    CHECK_FALSE(Core::verify(module).empty());
}

TEST_CASE("Xpp preserves closure target capture order and ownership")
{
    const auto xpp = Xpp::lower(ClosureModule());
    const auto *closure = FindClosure(xpp);
    REQUIRE(closure != nullptr);
    CHECK(closure->closure_function == 10U);
    REQUIRE(closure->operands.size() == 1U);
    REQUIRE(closure->capture_modes.size() == 1U);
    CHECK(closure->capture_modes.front() == Core::CaptureMode::Strong);
    CHECK(closure->operands.front().type == Core::Type::int64());
}

TEST_CASE("Xpp distinguishes a callable local from a direct function symbol")
{
    const auto xpp = Xpp::lower(ClosureModule());
    REQUIRE(Progmasoft::Tala::Xpp::Verify(xpp).empty());
    const auto *call = FindCall(xpp);
    REQUIRE(call != nullptr);
    REQUIRE(call->operands.size() == 1U);
    CHECK(call->operands.front().kind == Xpp::Operand::Kind::Symbol);
    CHECK(call->operands.front().symbol == 3U);
    CHECK(call->operands.front().type
          == Core::Type::function({}, Core::Type::int64()));
}

TEST_CASE("Xpp rejects a closure whose public arity disagrees with its target")
{
    auto xpp = Xpp::lower(ClosureModule());
    auto *closure = const_cast<Xpp::Instruction *>(FindClosure(xpp));
    REQUIRE(closure != nullptr);
    closure->result_type
        = Core::Type::function({ Core::Type::int64() }, Core::Type::int64());
    CHECK(HasXppIssue(Progmasoft::Tala::Xpp::Verify(xpp), "TAP1038"));
}

TEST_CASE("Xpp rejects a closure whose public result disagrees with its target")
{
    auto xpp = Xpp::lower(ClosureModule());
    auto *closure = const_cast<Xpp::Instruction *>(FindClosure(xpp));
    REQUIRE(closure != nullptr);
    closure->result_type = Core::Type::function({}, Core::Type::boolean());
    CHECK(HasXppIssue(Progmasoft::Tala::Xpp::Verify(xpp), "TAP1040"));
}

TEST_CASE("Xpp verifier checks the lifted closure signature")
{
    auto xpp = Xpp::lower(ClosureModule());
    REQUIRE(Progmasoft::Tala::Xpp::Verify(xpp).empty());
    xpp.functions.back().parameters.front().type = Core::Type::boolean();
    CHECK(HasXppIssue(Progmasoft::Tala::Xpp::Verify(xpp), "TAP1032"));
}

TEST_CASE("Xpp verifier requires one ownership mode per capture")
{
    auto xpp = Xpp::lower(ClosureModule());
    auto *closure = const_cast<Xpp::Instruction *>(FindClosure(xpp));
    REQUIRE(closure != nullptr);
    closure->capture_modes.clear();
    CHECK(HasXppIssue(Progmasoft::Tala::Xpp::Verify(xpp), "TAP1030"));
}

TEST_CASE("Xmm preserves closure metadata without inventing an ABI")
{
    const auto xmm = Xmm::lower(Xpp::lower(ClosureModule()));
    const auto *closure = FindClosure(xmm);
    REQUIRE(closure != nullptr);
    CHECK(closure->closure_function == 10U);
    REQUIRE(closure->capture_modes.size() == 1U);
    CHECK(closure->capture_modes.front() == Core::CaptureMode::Strong);
}

TEST_CASE("Xmm lowers a closure callee to a data register")
{
    const auto xmm = Xmm::lower(Xpp::lower(ClosureModule()));
    REQUIRE(Progmasoft::Tala::Xmm::Verify(xmm).empty());
    const auto *call = FindCall(xmm);
    REQUIRE(call != nullptr);
    REQUIRE(call->operands.size() == 1U);
    CHECK(call->operands.front().kind == Xmm::Value::Kind::Register);
    CHECK(call->operands.front().type
          == Core::Type::function({}, Core::Type::int64()));
}

TEST_CASE("Xmm rejects a closure whose public arity disagrees with its target")
{
    auto xmm = Xmm::lower(Xpp::lower(ClosureModule()));
    auto *closure = const_cast<Xmm::Instruction *>(FindClosure(xmm));
    REQUIRE(closure != nullptr);
    closure->result_type
        = Core::Type::function({ Core::Type::int64() }, Core::Type::int64());
    CHECK(HasXmmIssue(Progmasoft::Tala::Xmm::Verify(xmm), "TAL1042"));
}

TEST_CASE("Xmm rejects a closure whose public result disagrees with its target")
{
    auto xmm = Xmm::lower(Xpp::lower(ClosureModule()));
    auto *closure = const_cast<Xmm::Instruction *>(FindClosure(xmm));
    REQUIRE(closure != nullptr);
    closure->result_type = Core::Type::function({}, Core::Type::boolean());
    CHECK(HasXmmIssue(Progmasoft::Tala::Xmm::Verify(xmm), "TAL1044"));
}

TEST_CASE("Xmm verifier checks closure metadata independently of LLVM")
{
    auto xmm = Xmm::lower(Xpp::lower(ClosureModule()));
    REQUIRE(Progmasoft::Tala::Xmm::Verify(xmm).empty());
    auto *closure = const_cast<Xmm::Instruction *>(FindClosure(xmm));
    REQUIRE(closure != nullptr);
    closure->closure_function = 999U;
    CHECK(HasXmmIssue(Progmasoft::Tala::Xmm::Verify(xmm), "TAL1032"));
}

TEST_CASE("non-owning primitive capture is rejected before backend lowering")
{
    auto module = ClosureModule();
    module.functions.front()
        .blocks.front()
        .instructions[1]
        .captures.front()
        .mode = Core::CaptureMode::Weak;
    CHECK_FALSE(Core::verify(module).empty());
}
