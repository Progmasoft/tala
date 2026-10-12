// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <cstddef>
#include <ranges>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Backend/LLVM.hpp"
#include "Progmasoft/Tala/Core/CorePrep.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Wire.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Xmm/IR.hpp"
#include "Progmasoft/Tala/Xmm/Verifier.hpp"
#include "Progmasoft/Tala/Xmm/Wire.hpp"
#include "Progmasoft/Tala/Xpp/IR.hpp"
#include "Progmasoft/Tala/Xpp/Verifier.hpp"
#include "Progmasoft/Tala/Xpp/Wire.hpp"

// A callable that remembers its result, followed through every native stage.
//
// The operation takes a callable without parameters whose result is a Bool
// or a number, and yields a callable of the same type that calls the first
// one at most once. Each stage carries the operation under its own name,
// checks that rule for itself, and writes it to its artifact. These cases
// take one module through the stages and then break the rule at each of
// them, so that no stage relies on the one before it having checked.

namespace
{
    namespace Core = tala::core;
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
    Computation(Core::Type result = Core::Type::int64()) -> Core::Type
    {
        return Core::Type::function({}, std::move(result));
    }

    // Position of the remembering instruction in the entry block of `Main`.
    constexpr std::size_t kMemoize = 2U;

    /// ```
    /// Main():
    ///     count = 0
    ///     next = closure $closure10 capturing count
    ///     once = memoize next
    ///     first = once()
    ///     second = once()
    ///     return
    /// $closure10(count): return count
    /// ```
    [[nodiscard]] auto
    MemoizeModule() -> Core::CorePrepModule
    {
        Core::Instruction seed;
        seed.kind = Core::Instruction::Kind::Bind;
        seed.destination = Name(2U, U"count");
        seed.type = Core::Type::int64();
        seed.mutable_binding = true;
        seed.operation = Core::Operation::Copy;
        seed.operands = { Integer(0) };

        Core::Instruction closure;
        closure.kind = Core::Instruction::Kind::Bind;
        closure.destination = Name(3U, U"next");
        closure.type = Computation();
        closure.operation = Core::Operation::MakeClosure;
        closure.closure_function = Name(10U, U"$closure10");
        closure.captures.push_back(Core::Capture{
            Core::CaptureMode::Strong,
            Name(4U, U"count"),
            Core::Type::int64(),
            Integer(0),
        });

        Core::Instruction memoize;
        memoize.kind = Core::Instruction::Kind::Bind;
        memoize.destination = Name(5U, U"once");
        memoize.type = Computation();
        memoize.operation = Core::Operation::Memoize;
        memoize.operands = { Variable(3U, Computation()) };

        const auto call = [](Core::SymbolId id, std::u32string spelling) {
            Core::Instruction instruction;
            instruction.kind = Core::Instruction::Kind::Bind;
            instruction.destination = Name(id, std::move(spelling));
            instruction.type = Core::Type::int64();
            instruction.operation = Core::Operation::Call;
            instruction.operands = { Variable(5U, Computation()) };
            return instruction;
        };

        Core::Function main;
        main.symbol = Name(1U, U"Main");
        main.return_type = Core::Type::unit();
        main.entry = 0U;
        main.blocks = {
            Core::Block{
                0U,
                { std::move(seed),
                  std::move(closure),
                  std::move(memoize),
                  call(6U, U"first"),
                  call(7U, U"second") },
                Core::Terminator{
                    Core::Terminator::Kind::Return,
                    Core::Atom::constant(std::monostate{}, Core::Type::unit()),
                    0U,
                    0U },
            },
        };

        Core::Function lifted;
        lifted.symbol = Name(10U, U"$closure10");
        lifted.parameters
            = { Core::Parameter{ Name(4U, U"count"), Core::Type::int64() } };
        lifted.return_type = Core::Type::int64();
        lifted.entry = 0U;
        lifted.blocks = {
            Core::Block{
                0U,
                {},
                Core::Terminator{ Core::Terminator::Kind::Return,
                                  Variable(4U, Core::Type::int64()),
                                  0U,
                                  0U },
            },
        };

        return Core::CorePrepModule{ { U"MemoizeTests" },
                                     { std::move(main), std::move(lifted) } };
    }

    [[nodiscard]] auto
    MemoizeOf(Core::CorePrepModule &module) -> Core::Instruction &
    {
        return module.functions.front().blocks.front().instructions[kMemoize];
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
    Find(Module &module, Opcode opcode) -> decltype(&module.functions.front()
                                                         .blocks.front()
                                                         .instructions.front())
    {
        for (auto &function : module.functions)
            for (auto &block : function.blocks)
                for (auto &instruction : block.instructions)
                    if (instruction.opcode == opcode)
                        return &instruction;
        return nullptr;
    }

    template<typename Module, typename Opcode>
    [[nodiscard]] auto
    Count(const Module &module, Opcode opcode) -> std::size_t
    {
        std::size_t count{};
        for (const auto &function : module.functions)
            for (const auto &block : function.blocks)
                for (const auto &instruction : block.instructions)
                    if (instruction.opcode == opcode)
                        ++count;
        return count;
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
} // namespace

TEST_CASE("CorePrep accepts a callable that remembers its result")
{
    CHECK(Core::verify(MemoizeModule()).empty());
}

TEST_CASE("CorePrep writes and reads the remembering operation unchanged")
{
    const auto source = MemoizeModule();
    const auto encoded = Core::wire::encode(source);
    REQUIRE_FALSE(encoded.error);
    const auto decoded = Core::wire::decode(encoded.bytes);
    REQUIRE_FALSE(decoded.error);
    REQUIRE(decoded.module);
    CHECK(*decoded.module == source);
    auto read = *decoded.module;
    CHECK(MemoizeOf(read).operation == Core::Operation::Memoize);
}

TEST_CASE("CorePrep remembers only a computation without parameters")
{
    auto module = MemoizeModule();
    const auto taking
        = Core::Type::function({ Core::Type::int64() }, Core::Type::int64());
    MemoizeOf(module).operands = { Variable(3U, taking) };
    MemoizeOf(module).type = taking;
    CHECK(HasIssue(Core::verify(module), "TAC1074"));
}

TEST_CASE("CorePrep remembers only a Bool or a number")
{
    SECTION("a Bool is remembered")
    {
        auto module = MemoizeModule();
        auto &instructions = module.functions.front().blocks.front();
        instructions.instructions[1].type = Computation(Core::Type::boolean());
        MemoizeOf(module).operands
            = { Variable(3U, Computation(Core::Type::boolean())) };
        MemoizeOf(module).type = Computation(Core::Type::boolean());
        CHECK_FALSE(HasIssue(Core::verify(module), "TAC1074"));
    }
    SECTION("no result is not")
    {
        auto module = MemoizeModule();
        MemoizeOf(module).operands
            = { Variable(3U, Computation(Core::Type::unit())) };
        MemoizeOf(module).type = Computation(Core::Type::unit());
        CHECK(HasIssue(Core::verify(module), "TAC1074"));
    }
    SECTION("a string is not")
    {
        auto module = MemoizeModule();
        MemoizeOf(module).operands
            = { Variable(3U, Computation(Core::Type::string())) };
        MemoizeOf(module).type = Computation(Core::Type::string());
        CHECK(HasIssue(Core::verify(module), "TAC1074"));
    }
    SECTION("a callable is not")
    {
        auto module = MemoizeModule();
        MemoizeOf(module).operands
            = { Variable(3U, Computation(Computation())) };
        MemoizeOf(module).type = Computation(Computation());
        CHECK(HasIssue(Core::verify(module), "TAC1074"));
    }
}

TEST_CASE("CorePrep does not remember a value that is not a callable")
{
    auto module = MemoizeModule();
    MemoizeOf(module).operands = { Variable(2U, Core::Type::int64()) };
    MemoizeOf(module).type = Core::Type::int64();
    CHECK(HasIssue(Core::verify(module), "TAC1074"));
}

TEST_CASE("CorePrep requires the remembering callable to keep the type")
{
    auto module = MemoizeModule();
    MemoizeOf(module).type = Computation(Core::Type::boolean());
    CHECK_FALSE(Core::verify(module).empty());
}

TEST_CASE("CorePrep requires exactly one computation to remember")
{
    SECTION("none")
    {
        auto module = MemoizeModule();
        MemoizeOf(module).operands.clear();
        CHECK_FALSE(Core::verify(module).empty());
    }
    SECTION("two")
    {
        auto module = MemoizeModule();
        MemoizeOf(module).operands.push_back(Variable(3U, Computation()));
        CHECK_FALSE(Core::verify(module).empty());
    }
}

TEST_CASE("Xpp carries the remembering operation and its operand")
{
    auto xpp = Xpp::lower(MemoizeModule());
    CHECK(Progmasoft::Tala::Xpp::Verify(xpp).empty());
    REQUIRE(Count(xpp, Xpp::Opcode::Memoize) == 1U);
    const auto *memoize = Find(xpp, Xpp::Opcode::Memoize);
    REQUIRE(memoize != nullptr);
    CHECK(memoize->destination == 5U);
    CHECK(memoize->result_type == Computation());
    REQUIRE(memoize->operands.size() == 1U);
    CHECK(memoize->operands.front().kind == Xpp::Operand::Kind::Symbol);
    CHECK(memoize->operands.front().symbol == 3U);
    CHECK(memoize->operands.front().type == Computation());
}

TEST_CASE("Xpp calls the remembering callable, not the computation")
{
    const auto xpp = Xpp::lower(MemoizeModule());
    std::size_t calls{};
    for (const auto &instruction :
         xpp.functions.front().blocks.front().instructions)
    {
        if (instruction.opcode != Xpp::Opcode::Call)
            continue;
        ++calls;
        REQUIRE(instruction.operands.size() == 1U);
        CHECK(instruction.operands.front().symbol == 5U);
    }
    CHECK(calls == 2U);
}

TEST_CASE("Xpp writes and reads the remembering operation unchanged")
{
    const auto xpp = Xpp::lower(MemoizeModule());
    const auto encoded = Progmasoft::Tala::Xpp::Wire::Encode(xpp);
    REQUIRE(encoded);
    const auto decoded = Progmasoft::Tala::Xpp::Wire::Decode(encoded.bytes);
    REQUIRE(decoded);
    REQUIRE(decoded.module);
    CHECK(*decoded.module == xpp);
    CHECK(Count(*decoded.module, Xpp::Opcode::Memoize) == 1U);
}

TEST_CASE("Xpp checks the remembering rule for itself")
{
    SECTION("a computation with a parameter")
    {
        auto xpp = Xpp::lower(MemoizeModule());
        auto *memoize = Find(xpp, Xpp::Opcode::Memoize);
        REQUIRE(memoize != nullptr);
        const auto taking = Core::Type::function({ Core::Type::int64() },
                                                 Core::Type::int64());
        memoize->operands.front().type = taking;
        memoize->result_type = taking;
        CHECK(HasIssue(Progmasoft::Tala::Xpp::Verify(xpp), "TAP1047"));
    }
    SECTION("a result that owns something")
    {
        auto xpp = Xpp::lower(MemoizeModule());
        auto *memoize = Find(xpp, Xpp::Opcode::Memoize);
        REQUIRE(memoize != nullptr);
        memoize->operands.front().type = Computation(Core::Type::string());
        memoize->result_type = Computation(Core::Type::string());
        CHECK(HasIssue(Progmasoft::Tala::Xpp::Verify(xpp), "TAP1047"));
    }
    SECTION("a callable of another type")
    {
        auto xpp = Xpp::lower(MemoizeModule());
        auto *memoize = Find(xpp, Xpp::Opcode::Memoize);
        REQUIRE(memoize != nullptr);
        memoize->result_type = Computation(Core::Type::boolean());
        CHECK(HasIssue(Progmasoft::Tala::Xpp::Verify(xpp), "TAP1047"));
    }
    SECTION("a value that is not a callable")
    {
        auto xpp = Xpp::lower(MemoizeModule());
        auto *memoize = Find(xpp, Xpp::Opcode::Memoize);
        REQUIRE(memoize != nullptr);
        memoize->operands.front().type = Core::Type::int64();
        memoize->result_type = Core::Type::int64();
        CHECK(HasIssue(Progmasoft::Tala::Xpp::Verify(xpp), "TAP1047"));
    }
}

TEST_CASE("Xmm carries the remembering operation in a register")
{
    auto xmm = Xmm::lower(Xpp::lower(MemoizeModule()));
    CHECK(Progmasoft::Tala::Xmm::Verify(xmm).empty());
    REQUIRE(Count(xmm, Xmm::Opcode::Memoize) == 1U);
    const auto *memoize = Find(xmm, Xmm::Opcode::Memoize);
    REQUIRE(memoize != nullptr);
    CHECK(memoize->has_result);
    CHECK(memoize->result_type == Computation());
    REQUIRE(memoize->operands.size() == 1U);
    CHECK(memoize->operands.front().kind == Xmm::Value::Kind::Register);
    CHECK(memoize->operands.front().type == Computation());
}

TEST_CASE("Xmm writes and reads the remembering operation unchanged")
{
    const auto xmm = Xmm::lower(Xpp::lower(MemoizeModule()));
    const auto encoded = Progmasoft::Tala::Xmm::Wire::Encode(xmm);
    REQUIRE(encoded);
    const auto decoded = Progmasoft::Tala::Xmm::Wire::Decode(encoded.bytes);
    REQUIRE(decoded);
    REQUIRE(decoded.module);
    CHECK(*decoded.module == xmm);
    CHECK(Count(*decoded.module, Xmm::Opcode::Memoize) == 1U);
}

TEST_CASE("Xmm checks the remembering rule for itself")
{
    SECTION("a computation with a parameter")
    {
        auto xmm = Xmm::lower(Xpp::lower(MemoizeModule()));
        auto *memoize = Find(xmm, Xmm::Opcode::Memoize);
        REQUIRE(memoize != nullptr);
        const auto taking = Core::Type::function({ Core::Type::int64() },
                                                 Core::Type::int64());
        memoize->operands.front().type = taking;
        memoize->result_type = taking;
        CHECK(HasIssue(Progmasoft::Tala::Xmm::Verify(xmm), "TAL1053"));
    }
    SECTION("a result that owns something")
    {
        auto xmm = Xmm::lower(Xpp::lower(MemoizeModule()));
        auto *memoize = Find(xmm, Xmm::Opcode::Memoize);
        REQUIRE(memoize != nullptr);
        memoize->operands.front().type = Computation(Core::Type::string());
        memoize->result_type = Computation(Core::Type::string());
        CHECK(HasIssue(Progmasoft::Tala::Xmm::Verify(xmm), "TAL1053"));
    }
    SECTION("a callable of another type")
    {
        auto xmm = Xmm::lower(Xpp::lower(MemoizeModule()));
        auto *memoize = Find(xmm, Xmm::Opcode::Memoize);
        REQUIRE(memoize != nullptr);
        memoize->result_type = Computation(Core::Type::boolean());
        CHECK(HasIssue(Progmasoft::Tala::Xmm::Verify(xmm), "TAL1053"));
    }
    SECTION("a value that is not a callable")
    {
        auto xmm = Xmm::lower(Xpp::lower(MemoizeModule()));
        auto *memoize = Find(xmm, Xmm::Opcode::Memoize);
        REQUIRE(memoize != nullptr);
        memoize->operands.front().type = Core::Type::int64();
        memoize->result_type = Core::Type::int64();
        CHECK(HasIssue(Progmasoft::Tala::Xmm::Verify(xmm), "TAL1053"));
    }
}

TEST_CASE("LLVM gives the remembering callable an object of its own")
{
    const auto xmm = Xmm::lower(Xpp::lower(MemoizeModule()));
    Llvm::Options options;
    options.optimization = Llvm::OptimizationLevel::Debug;
    const auto result = Llvm::Lower(xmm, options);
    REQUIRE(result);
    const std::string_view ir = result.artifact->llvm_ir;

    // The object: how to call it, whether the result is known, the result,
    // and the computation it owns.
    CHECK(ir.find("%.tala.aarc.memo.payload.") != std::string_view::npos);
    CHECK(ir.find("{ ptr, i8, i64, ptr }") != std::string_view::npos);
    // It is called the way a closure is called, and released the way a
    // closure is released: through the functions its object names.
    CHECK(ir.find("define internal i64 @.tala.aarc.memo.invoke.")
          != std::string_view::npos);
    CHECK(ir.find("define internal void @.tala.aarc.memo.destroy.")
          != std::string_view::npos);
    CHECK(ir.find("@.tala.aarc.memo.metadata.") != std::string_view::npos);
    // One object for the closure and one for the callable that remembers.
    CHECK(Occurrences(ir, "call ptr @tala_aarc_allocate(") == 2U);
}

TEST_CASE("LLVM keeps the computation alive for as long as it is remembered")
{
    const auto xmm = Xmm::lower(Xpp::lower(MemoizeModule()));
    Llvm::Options options;
    options.optimization = Llvm::OptimizationLevel::Debug;
    const auto result = Llvm::Lower(xmm, options);
    REQUIRE(result);
    const std::string_view ir = result.artifact->llvm_ir;

    // The remembering object takes a reference of its own to the
    // computation, and its destructor gives that reference back.
    CHECK(ir.find("%memo.owned = call ptr @tala_aarc_retain_strong(")
          != std::string_view::npos);
    const auto destructor
        = ir.find("define internal void @.tala.aarc.memo.destroy.");
    REQUIRE(destructor != std::string_view::npos);
    const auto body = ir.substr(destructor, ir.find("\n}\n", destructor));
    CHECK(body.find("call void @tala_aarc_release_strong(")
          != std::string_view::npos);
}

TEST_CASE("LLVM lowers the remembering callable at every optimization level")
{
    const auto xmm = Xmm::lower(Xpp::lower(MemoizeModule()));
    for (const auto level : { Llvm::OptimizationLevel::Debug,
                              Llvm::OptimizationLevel::Less,
                              Llvm::OptimizationLevel::Default,
                              Llvm::OptimizationLevel::Aggressive })
    {
        Llvm::Options options;
        options.optimization = level;
        const auto result = Llvm::Lower(xmm, options);
        REQUIRE(result);
        CHECK_FALSE(result.artifact->bitcode.empty());
    }
}
