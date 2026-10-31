// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep/Prepare.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"
#include "Progmasoft/Tala/Core/IR.hpp"
#include "Progmasoft/Tala/Core/RuntimeCall.hpp"
#include "Progmasoft/Tala/Core/Verifier.hpp"
#include "Progmasoft/Tala/Core/Wire.hpp"
#include "Progmasoft/Tala/Pipeline.hpp"

// The runtime call in native Core: what the verifier that reads a Core
// artifact from the frontend accepts and rejects, and that an accepted call
// reaches generated code. The Haskell verifier has the same cases in
// `RuntimeCallTests.hs`; the stages after Core are in
// `RuntimeCallPipelineTests.cpp`.

namespace
{
    namespace Core = Progmasoft::Tala::Core;
    namespace Runtime = tala::core::runtime;
    namespace Pipeline = Progmasoft::Tala::Pipeline;

    [[nodiscard]] auto
    Integer(std::int64_t value) -> Core::Expression
    {
        return Core::Expression::Constant(value, Core::Type::int64());
    }

    [[nodiscard]] auto
    Text(std::u32string value) -> Core::Expression
    {
        return Core::Expression::Constant(std::move(value),
                                          Core::Type::string());
    }

    [[nodiscard]] auto
    Count() -> Core::Expression
    {
        return Core::Expression::Variable({ 2U, U"count" },
                                          Core::Type::int64());
    }

    /// A call of the function with the given arguments and type.
    [[nodiscard]] auto
    Call(Runtime::Function function,
         std::vector<Core::Expression> arguments,
         Core::Type type) -> Core::Expression
    {
        std::vector<Core::Expression> operands;
        operands.reserve(arguments.size() + 1U);
        operands.push_back(Integer(static_cast<std::int64_t>(function)));
        for (auto &argument : arguments)
            operands.push_back(std::move(argument));
        return Core::Expression::InvokePrimitive(Core::Primitive::RuntimeCall,
                                                 std::move(operands),
                                                 std::move(type));
    }

    /// `Run(count) { <statement>; return count; }`
    [[nodiscard]] auto
    Module(Core::Statement statement) -> Core::Module
    {
        return { { U"Calls" },
                 { Core::Function{
                     { 1U, U"Run" },
                     { { { 2U, U"count" }, Core::Type::int64() } },
                     Core::Type::int64(),
                     { std::move(statement), Core::Statement::Return(Count()) },
                 } } };
    }

    [[nodiscard]] auto
    Evaluating(Core::Expression expression) -> Core::Module
    {
        return Module(Core::Statement::Evaluate(std::move(expression)));
    }

    [[nodiscard]] auto
    Binding(Core::Type type, Core::Expression expression) -> Core::Module
    {
        return Module(Core::Statement::Bind({ { 3U, U"line" },
                                              std::move(type),
                                              false,
                                              std::move(expression) }));
    }

    [[nodiscard]] auto
    Rejected(const Core::Module &module) -> bool
    {
        const auto issues = Core::Verify(module);
        return std::ranges::any_of(issues, [](const auto &issue) {
            return issue.code == "TAC1075";
        });
    }

    /// `Console.Printfn("Count: %5d", count)` as the frontend lowers it.
    [[nodiscard]] auto
    Writing() -> Core::Module
    {
        return Evaluating(
            Call(Runtime::Function::ConsoleWrite,
                 { Call(Runtime::Function::TextConcat,
                        { Text(U"Count: "),
                          Call(Runtime::Function::TextFormatSigned,
                               { Integer(0), Integer(5), Integer(-1), Count() },
                               Core::Type::string()) },
                        Core::Type::string()),
                   Integer(1) },
                 Core::Type::unit()));
    }
} // namespace

TEST_CASE("native Core accepts well-formed runtime calls")
{
    CHECK(Core::Verify(Writing()).empty());
    CHECK(Core::Verify(Binding(Core::Type::boolean(),
                               Call(Runtime::Function::TextEquals,
                                    { Text(U"a"), Text(U"b") },
                                    Core::Type::boolean())))
              .empty());
    CHECK(Core::Verify(Binding(Core::Type::string(),
                               Call(Runtime::Function::TextNewline,
                                    {},
                                    Core::Type::string())))
              .empty());
}

TEST_CASE("native Core wire carries runtime calls")
{
    const auto module = Writing();
    const auto encoded = Core::Wire::Encode(module);
    REQUIRE(encoded);
    const auto decoded = Core::Wire::Decode(encoded.bytes);
    REQUIRE(decoded);
    REQUIRE(decoded.module);
    CHECK(*decoded.module == module);
}

TEST_CASE("native Core rejects a runtime call that names no function")
{
    const auto raw = [](std::vector<Core::Expression> operands) {
        return Core::Expression::InvokePrimitive(Core::Primitive::RuntimeCall,
                                                 std::move(operands),
                                                 Core::Type::unit());
    };
    // An identity the catalog does not have, zero, and a negative number.
    CHECK(Rejected(Evaluating(raw({ Integer(999) }))));
    CHECK(Rejected(Evaluating(raw({ Integer(0) }))));
    CHECK(Rejected(Evaluating(raw({ Integer(-12) }))));
    // No operand, and an identity that is computed: the function is fixed
    // when the program is compiled.
    CHECK(Rejected(Evaluating(raw({}))));
    CHECK(Rejected(Evaluating(raw({ Count(), Text(U"a"), Integer(0) }))));
    // An identity of another integer type.
    CHECK(Rejected(Evaluating(raw(
        { Core::Expression::Constant(std::int64_t{ 12 }, Core::Type::uint64()),
          Text(U"a"),
          Integer(0) }))));
}

TEST_CASE("native Core holds a runtime call to its function's arguments")
{
    const auto text = Core::Type::string();
    // One too few, one too many, and one where none is taken.
    CHECK(Rejected(
        Binding(text,
                Call(Runtime::Function::TextConcat, { Text(U"a") }, text))));
    CHECK(Rejected(Binding(text,
                           Call(Runtime::Function::TextConcat,
                                { Text(U"a"), Text(U"b"), Text(U"c") },
                                text))));
    CHECK(Rejected(
        Binding(text,
                Call(Runtime::Function::TextNewline, { Count() }, text))));
    // A number where a string is taken, and a string where a number is.
    CHECK(Rejected(Binding(
        text,
        Call(Runtime::Function::TextConcat, { Text(U"a"), Count() }, text))));
    CHECK(Rejected(Binding(
        text,
        Call(Runtime::Function::TextFromSigned, { Text(U"a") }, text))));
    // A signed integer where an unsigned one is taken.
    CHECK(Rejected(
        Binding(text,
                Call(Runtime::Function::TextFromUnsigned, { Count() }, text))));
    // A width that is not an int.
    CHECK(
        Rejected(Binding(text,
                         Call(Runtime::Function::TextFormatSigned,
                              { Integer(0),
                                Core::Expression::Constant(std::int64_t{ 5 },
                                                           Core::Type::int32()),
                                Integer(-1),
                                Count() },
                              text))));
}

TEST_CASE("native Core holds a runtime call to its function's result")
{
    CHECK(Rejected(Binding(Core::Type::int64(),
                           Call(Runtime::Function::TextConcat,
                                { Text(U"a"), Text(U"b") },
                                Core::Type::int64()))));
    CHECK(Rejected(Binding(Core::Type::string(),
                           Call(Runtime::Function::ConsoleWrite,
                                { Text(U"a"), Integer(0) },
                                Core::Type::string()))));
    CHECK(Rejected(Binding(Core::Type::string(),
                           Call(Runtime::Function::TextEquals,
                                { Text(U"a"), Text(U"b") },
                                Core::Type::string()))));
}

TEST_CASE("the adapter names the function with a literal in CorePrep")
{
    const auto prepared = Core::CorePrep::Prepare(Writing());
    REQUIRE(tala::core::verify(prepared).empty());
    std::size_t calls{};
    for (const auto &function : prepared.functions)
        for (const auto &block : function.blocks)
            for (const auto &instruction : block.instructions)
            {
                if (instruction.operation != tala::core::Operation::RuntimeCall)
                    continue;
                ++calls;
                REQUIRE_FALSE(instruction.operands.empty());
                // The identity is not bound to a temporary on the way.
                CHECK(instruction.operands.front().kind
                      == tala::core::Atom::Kind::Literal);
            }
    CHECK(calls == 3U);
}

TEST_CASE("a runtime call in Core reaches generated code")
{
    const auto encoded = Core::Wire::Encode(Writing());
    REQUIRE(encoded);
    for (const auto optimize : { false, true })
    {
        Pipeline::Options options;
        options.optimize_xpp = optimize;
        options.optimize_xmm = optimize;
        const auto pipeline = Pipeline::ConsumeCore(encoded.bytes, options);
        REQUIRE(pipeline);
        REQUIRE(pipeline.llvm);
        const std::string_view ir = pipeline.llvm->llvm_ir;
        // A write is observed by whoever reads the output: no pipeline mode
        // removes it, and it is made once.
        const auto first = ir.find("call void @tala_console_write(");
        REQUIRE(first != std::string_view::npos);
        CHECK(ir.find("call void @tala_console_write(", first + 1U)
              == std::string_view::npos);
        CHECK(ir.find("@tala_text_format_signed(") != std::string_view::npos);
        CHECK(ir.find("@tala_text_concat(") != std::string_view::npos);
    }
}

TEST_CASE("a runtime call that the verifier rejects is never lowered")
{
    const auto encoded = Core::Wire::Encode(Evaluating(
        Core::Expression::InvokePrimitive(Core::Primitive::RuntimeCall,
                                          { Integer(999) },
                                          Core::Type::unit())));
    REQUIRE(encoded);
    const auto pipeline = Pipeline::ConsumeCore(encoded.bytes, {});
    CHECK_FALSE(pipeline);
    CHECK_FALSE(pipeline.llvm);
}
