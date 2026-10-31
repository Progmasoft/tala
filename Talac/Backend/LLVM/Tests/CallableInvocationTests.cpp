// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <string_view>

#include "Progmasoft/Tala/Backend/LLVM.hpp"
#include "Progmasoft/Tala/Core/CorePrep.hpp"
#include "Progmasoft/Tala/Xmm/IR.hpp"
#include "Progmasoft/Tala/Xpp/IR.hpp"

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
        return Core::Atom::constant(value, Core::Type::int64());
    }

    [[nodiscard]] auto
    ClosureModule() -> Core::CorePrepModule
    {
        const auto callableType = Core::Type::function({ Core::Type::int64() },
                                                       Core::Type::int64());

        Core::Instruction seed;
        seed.kind = Core::Instruction::Kind::Bind;
        seed.destination = Name(2U, U"base");
        seed.type = Core::Type::int64();
        seed.operation = Core::Operation::Copy;
        seed.operands = { Integer(40) };

        Core::Instruction closure;
        closure.kind = Core::Instruction::Kind::Bind;
        closure.destination = Name(3U, U"addBase");
        closure.type = callableType;
        closure.operation = Core::Operation::MakeClosure;
        closure.closure_function = Name(10U, U"$addBase");
        closure.captures = {
            Core::Capture{
                Core::CaptureMode::Strong,
                Name(2U, U"base"),
                Core::Type::int64(),
                Variable(2U, Core::Type::int64()),
            },
        };

        Core::Instruction invoke;
        invoke.kind = Core::Instruction::Kind::Bind;
        invoke.destination = Name(4U, U"answer");
        invoke.type = Core::Type::int64();
        invoke.operation = Core::Operation::Call;
        invoke.operands = {
            Variable(3U, callableType),
            Integer(2),
        };

        Core::Function main;
        main.symbol = Name(1U, U"Main");
        main.return_type = Core::Type::int64();
        main.entry = 0U;
        main.blocks = {
            Core::Block{
                0U,
                { std::move(seed), std::move(closure), std::move(invoke) },
                Core::Terminator{
                    Core::Terminator::Kind::Return,
                    Variable(4U, Core::Type::int64()),
                    0U,
                    0U,
                },
            },
        };

        Core::Instruction sum;
        sum.kind = Core::Instruction::Kind::Bind;
        sum.destination = Name(13U, U"sum");
        sum.type = Core::Type::int64();
        sum.operation = Core::Operation::Add;
        sum.operands = {
            Variable(11U, Core::Type::int64()),
            Variable(12U, Core::Type::int64()),
        };

        Core::Function lifted;
        lifted.symbol = Name(10U, U"$addBase");
        lifted.parameters = {
            Core::Parameter{ Name(11U, U"base"), Core::Type::int64() },
            Core::Parameter{ Name(12U, U"value"), Core::Type::int64() },
        };
        lifted.return_type = Core::Type::int64();
        lifted.entry = 0U;
        lifted.blocks = {
            Core::Block{
                0U,
                { std::move(sum) },
                Core::Terminator{
                    Core::Terminator::Kind::Return,
                    Variable(13U, Core::Type::int64()),
                    0U,
                    0U,
                },
            },
        };

        return Core::CorePrepModule{
            { U"Callable", U"Backend" },
            { std::move(main), std::move(lifted) },
        };
    }

    [[nodiscard]] auto
    Lower(const Core::CorePrepModule &module) -> Llvm::Result
    {
        const auto xpp = Xpp::lower(module);
        const auto xmm = Xmm::lower(xpp);
        Llvm::Options options;
        options.optimization = Llvm::OptimizationLevel::Debug;
        return Llvm::Lower(xmm, options);
    }

    [[nodiscard]] auto
    Contains(std::string_view text, std::string_view fragment) -> bool
    {
        return text.find(fragment) != std::string_view::npos;
    }
} // namespace

TEST_CASE("LLVM lowers closure invocation through an environment-aware thunk")
{
    const auto result = Lower(ClosureModule());
    REQUIRE(result);
    REQUIRE(result.artifact);
    const auto &ir = result.artifact->llvm_ir;

    CHECK(Contains(ir, ".tala.aarc.closure.invoke"));
    CHECK(Contains(ir, "closure.invoke = load ptr"));
    CHECK(Contains(ir, "call i64 %closure.invoke(ptr"));
    CHECK(Contains(ir, "capture.load = load i64"));
    CHECK(Contains(
        ir,
        "closure.result = call i64 @\"Callable.Backend.$addBase.10\""));
    CHECK(Contains(ir, "addBase.10"));
}

TEST_CASE("closure payload stores a thunk rather than the lifted function")
{
    const auto result = Lower(ClosureModule());
    REQUIRE(result);
    const auto &ir = result.artifact->llvm_ir;

    const auto store = ir.find("store ptr @.tala.aarc.closure.invoke");
    const auto lifted = ir.find("store ptr @Callable.Backend._addBase.10");
    CHECK(store != std::string::npos);
    CHECK(lifted == std::string::npos);
}

TEST_CASE("closure destruction remains independent from invocation")
{
    const auto result = Lower(ClosureModule());
    REQUIRE(result);
    const auto &ir = result.artifact->llvm_ir;

    CHECK(Contains(ir, "@tala_aarc_allocate"));
    // The capture is a scalar, so destruction must not invent an AARC release.
    CHECK_FALSE(Contains(ir, "call void @tala_aarc_release_strong"));
    // A closure that owns nothing has nothing to do when it is destroyed:
    // its metadata names no destructor, which the runtime accepts, and the
    // module holds no function for it. The entry it is called through is
    // still its own.
    CHECK_FALSE(Contains(ir, ".tala.aarc.closure.destroy"));
    CHECK(Contains(ir, ".tala.aarc.closure.invoke"));
    CHECK(Contains(ir, "i64 16, ptr null, ptr null }"));
}

TEST_CASE("Xmm preserves direct and indirect callees as different value kinds")
{
    const auto xpp = Xpp::lower(ClosureModule());
    const auto xmm = Xmm::lower(xpp);

    const Xmm::Instruction *closureCall = nullptr;
    for (const auto &function : xmm.functions)
        for (const auto &block : function.blocks)
            for (const auto &instruction : block.instructions)
                if (instruction.opcode == Xmm::Opcode::Call)
                    closureCall = &instruction;

    REQUIRE(closureCall != nullptr);
    REQUIRE_FALSE(closureCall->operands.empty());
    CHECK(closureCall->operands.front().kind == Xmm::Value::Kind::Register);
    CHECK(closureCall->operands.front().reg != 0U);
}

TEST_CASE("LLVM rejects an indirect callee whose register is not callable")
{
    auto xpp = Xpp::lower(ClosureModule());
    auto xmm = Xmm::lower(xpp);

    for (auto &function : xmm.functions)
        for (auto &block : function.blocks)
            for (auto &instruction : block.instructions)
                if (instruction.opcode == Xmm::Opcode::Call)
                    instruction.operands.front().type = Core::Type::int64();

    const auto result = Llvm::Lower(xmm);
    CHECK_FALSE(result);
    REQUIRE(result.error);
    CHECK(result.error->kind == Llvm::ErrorKind::InvalidXmm);
}
