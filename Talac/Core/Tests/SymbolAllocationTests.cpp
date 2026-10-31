// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <cstdint>
#include <map>
#include <string>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep/Prepare.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"
#include "Progmasoft/Tala/Core/Verifier.hpp"
#include "Progmasoft/Tala/Core/Wire.hpp"
#include "Progmasoft/Tala/Pipeline.hpp"

// Symbol identities are unique across a whole module, and CorePrep
// verification checks that one identity never carries two spellings. The
// adapter's generated temporaries and lifted closure names must therefore be
// allocated above every identity of the module from one shared counter, not
// above the identities of the function being lowered. These cases were found
// by the source-to-LLVM fuzz campaign as a verified Core module that the
// native pipeline then rejected.

namespace
{
    namespace Core = Progmasoft::Tala::Core;
    namespace Prepared = tala::core;

    [[nodiscard]] auto
    Integer(std::int64_t value) -> Core::Expression
    {
        return Core::Expression::Constant(value, Core::Type::int64());
    }

    [[nodiscard]] auto
    Variable(std::uint64_t id, std::u32string spelling) -> Core::Expression
    {
        return Core::Expression::Variable({ id, std::move(spelling) },
                                          Core::Type::int64());
    }

    /// `int result = 8; if (result > 4) { result = result - 2; } return
    /// result;` The comparison and the subtraction each need a generated
    /// temporary.
    [[nodiscard]] auto
    Branching(std::uint64_t function, std::uint64_t local, std::u32string name)
        -> Core::Function
    {
        return {
            { function, std::move(name) },
            {},
            Core::Type::int64(),
            { Core::Statement::Bind({ { local, U"result" },
                                      Core::Type::int64(),
                                      true,
                                      Integer(8) }),
              Core::Statement::If(
                  Core::Expression::InvokePrimitive(
                      Core::Primitive::GreaterThan,
                      { Variable(local, U"result"), Integer(4) },
                      Core::Type::boolean()),
                  { Core::Statement::Assign(
                      { local, U"result" },
                      Core::Expression::InvokePrimitive(
                          Core::Primitive::Subtract,
                          { Variable(local, U"result"), Integer(2) },
                          Core::Type::int64())) },
                  {}),
              Core::Statement::Return(Variable(local, U"result")) },
        };
    }

    /// Every identity in the prepared module with each spelling it carries.
    void
    Record(std::map<std::uint64_t, std::vector<std::u32string>> &seen,
           const Prepared::SymbolName &symbol)
    {
        if (symbol.id == 0U)
            return;
        auto &spellings = seen[symbol.id];
        if (std::ranges::find(spellings, symbol.spelling) == spellings.end())
            spellings.push_back(symbol.spelling);
    }

    void
    RequireUniqueIdentities(const Prepared::CorePrepModule &module)
    {
        std::map<std::uint64_t, std::vector<std::u32string>> seen;
        for (const auto &function : module.functions)
        {
            Record(seen, function.symbol);
            for (const auto &parameter : function.parameters)
                Record(seen, parameter.symbol);
            for (const auto &block : function.blocks)
                for (const auto &instruction : block.instructions)
                {
                    Record(seen, instruction.destination);
                    Record(seen, instruction.closure_function);
                    for (const auto &operand : instruction.operands)
                        if (operand.kind == Prepared::Atom::Kind::Variable)
                            Record(seen, operand.symbol);
                }
        }
        for (const auto &[id, spellings] : seen)
        {
            CAPTURE(id);
            CHECK(spellings.size() == 1U);
        }
    }

    void
    RequireVerifiedPipeline(const Core::Module &module)
    {
        for (const auto &issue : Core::Verify(module))
            FAIL_CHECK("Core " << issue.code << ": " << issue.message);
        REQUIRE(Core::Verify(module).empty());
        const auto prepared = Core::CorePrep::Prepare(module);
        for (const auto &issue : Prepared::verify(prepared))
            FAIL_CHECK("CorePrep " << issue.code << ": " << issue.message);
        CHECK(Prepared::verify(prepared).empty());
        RequireUniqueIdentities(prepared);
        const auto encoded = Core::Wire::Encode(module);
        REQUIRE(encoded);
        const auto pipeline
            = Progmasoft::Tala::Pipeline::ConsumeCore(encoded.bytes);
        CHECK(pipeline);
        CHECK(pipeline.llvm);
    }
} // namespace

TEST_CASE("temporaries of one function do not reuse another function's "
          "identities",
          "[coreprep][symbols]")
{
    // Identities 1 and 2 belong to the first function. Its first temporary
    // would be 3 if allocation only looked at that function, which is the
    // second function's own name.
    RequireVerifiedPipeline(
        { { U"Symbols" },
          { Branching(1U, 2U, U"First"), Branching(3U, 4U, U"Second") } });
}

TEST_CASE("temporaries stay unique when a later function has lower "
          "identities",
          "[coreprep][symbols]")
{
    RequireVerifiedPipeline(
        { { U"Symbols" },
          { Branching(10U, 11U, U"First"), Branching(1U, 2U, U"Second") } });
}

TEST_CASE("lifted closure names and temporaries share one identity counter",
          "[coreprep][symbols]")
{
    // The closure is lifted to a generated function symbol while the
    // enclosing body also needs temporaries for its arithmetic.
    const auto closureType
        = Core::Type::function({ Core::Type::int64() }, Core::Type::int64());
    Core::Function function{
        { 1U, U"Evaluate" },
        {},
        Core::Type::int64(),
        { Core::Statement::Bind(
              { { 2U, U"base" }, Core::Type::int64(), false, Integer(5) }),
          Core::Statement::Bind(
              { { 3U, U"scale" },
                closureType,
                false,
                Core::Expression::Closure(
                    {},
                    { { { 4U, U"value" }, Core::Type::int64() } },
                    Core::Type::int64(),
                    { Core::Statement::Return(Core::Expression::InvokePrimitive(
                        Core::Primitive::Multiply,
                        { Core::Expression::InvokePrimitive(
                              Core::Primitive::Add,
                              { Variable(4U, U"value"), Integer(1) },
                              Core::Type::int64()),
                          Integer(2) },
                        Core::Type::int64())) },
                    closureType) }),
          Core::Statement::Return(Core::Expression::InvokePrimitive(
              Core::Primitive::Add,
              { Core::Expression::InvokePrimitive(
                    Core::Primitive::Multiply,
                    { Variable(2U, U"base"), Integer(3) },
                    Core::Type::int64()),
                Core::Expression::Apply(
                    Core::Expression::Variable({ 3U, U"scale" }, closureType),
                    { Integer(4) },
                    Core::Type::int64()) },
              Core::Type::int64())) },
    };
    RequireVerifiedPipeline({ { U"Symbols" }, { std::move(function) } });
}
