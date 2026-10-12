// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"

// What a function of a CorePrep module sees of the module around it: the
// functions it may call, their spellings, and the parameters that closures
// fill. The verifier builds that view once for the module. These cases pin
// what each function sees through it, so that the view cannot be built
// faster by seeing something else.

namespace
{
    namespace Prepared = tala::core;

    [[nodiscard]] auto
    Name(std::uint64_t id, std::u32string spelling) -> Prepared::SymbolName
    {
        return { id, std::move(spelling) };
    }

    [[nodiscard]] auto
    IntegerFunction() -> Prepared::Type
    {
        return Prepared::Type::function({}, Prepared::Type::int64());
    }

    // `return 0;`
    [[nodiscard]] auto
    Constant(Prepared::SymbolName name) -> Prepared::Function
    {
        Prepared::Terminator terminator;
        terminator.kind = Prepared::Terminator::Kind::Return;
        terminator.value = Prepared::Atom::constant(std::int64_t{ 0 },
                                                    Prepared::Type::int64());
        return { std::move(name),
                 {},
                 Prepared::Type::int64(),
                 0U,
                 { { 0U, {}, std::move(terminator) } } };
    }

    // `result = callee(); return result;`
    [[nodiscard]] auto
    Caller(Prepared::SymbolName name,
           Prepared::SymbolName callee,
           std::uint64_t result) -> Prepared::Function
    {
        Prepared::Instruction call;
        call.kind = Prepared::Instruction::Kind::Bind;
        call.destination = Name(result, U"result");
        call.type = Prepared::Type::int64();
        call.operation = Prepared::Operation::Call;
        call.operands = { Prepared::Atom::variable(std::move(callee),
                                                   IntegerFunction()) };
        Prepared::Terminator terminator;
        terminator.kind = Prepared::Terminator::Kind::Return;
        terminator.value = Prepared::Atom::variable(Name(result, U"result"),
                                                    Prepared::Type::int64());
        return { std::move(name),
                 {},
                 Prepared::Type::int64(),
                 0U,
                 { { 0U, { std::move(call) }, std::move(terminator) } } };
    }

    [[nodiscard]] auto
    Count(const std::vector<Prepared::VerificationIssue> &issues,
          std::string_view code) -> std::ptrdiff_t
    {
        return std::count_if(issues.begin(),
                             issues.end(),
                             [code](const Prepared::VerificationIssue &issue) {
                                 return issue.code == code;
                             });
    }
} // namespace

TEST_CASE("a function may call a function that the module declares after it")
{
    const Prepared::CorePrepModule module{
        { U"Verifier" },
        { Caller(Name(1U, U"First"), Name(2U, U"Second"), 10U),
          Constant(Name(2U, U"Second")) },
    };

    CHECK(Prepared::verify(module).empty());
}

TEST_CASE("a module of several thousand functions that call one another "
          "verifies")
{
    constexpr std::uint64_t kFunctions = 3000U;
    Prepared::CorePrepModule module{ { U"Verifier" }, {} };
    module.functions.reserve(kFunctions);
    // Every function calls the one after it; the last returns a constant.
    for (std::uint64_t index = 1U; index < kFunctions; ++index)
        module.functions.push_back(Caller(Name(index, U"Method"),
                                          Name(index + 1U, U"Method"),
                                          kFunctions + index));
    module.functions.push_back(Constant(Name(kFunctions, U"Method")));

    const auto issues = Prepared::verify(module);

    CHECK(issues.empty());
}

TEST_CASE("a call of a symbol that no function and no binding defines is "
          "refused")
{
    const Prepared::CorePrepModule module{
        { U"Verifier" },
        { Caller(Name(1U, U"First"), Name(7U, U"Absent"), 10U) },
    };

    const auto issues = Prepared::verify(module);

    CHECK(Count(issues, "TAC1021") == 1);
}

TEST_CASE("a use that spells a function of the module differently is one "
          "conflict, in the function that uses it")
{
    const Prepared::CorePrepModule module{
        { U"Verifier" },
        { Caller(Name(1U, U"First"), Name(2U, U"Other"), 10U),
          Constant(Name(2U, U"Second")),
          Constant(Name(3U, U"Third")) },
    };

    const auto issues = Prepared::verify(module);

    CHECK(Count(issues, "TAC1014") == 1);
    const auto conflict
        = std::find_if(issues.begin(), issues.end(), [](const auto &issue) {
              return issue.code == "TAC1014";
          });
    REQUIRE(conflict != issues.end());
    CHECK(conflict->function == 1U);
}

TEST_CASE("two functions with one identity and two spellings are a conflict "
          "for every function that sees them")
{
    const Prepared::CorePrepModule module{
        { U"Verifier" },
        { Constant(Name(1U, U"First")),
          Constant(Name(1U, U"Second")),
          Constant(Name(3U, U"Third")) },
    };

    const auto issues = Prepared::verify(module);

    // The duplicated identity is reported once, as the fault it is.
    CHECK(Count(issues, "TAC1001") == 1);
    // Each of the three functions sees the two spellings.
    CHECK(Count(issues, "TAC1014") == 3);
}

TEST_CASE("a function of the module takes precedence over a binding with "
          "its identity")
{
    // The body binds identity 2, which is also a function of the module,
    // to an integer and returns it. A read of identity 2 is a read of the
    // function, whose type is not the integer the return carries.
    Prepared::Instruction bind;
    bind.kind = Prepared::Instruction::Kind::Bind;
    bind.destination = Name(2U, U"Second");
    bind.type = Prepared::Type::int64();
    bind.operation = Prepared::Operation::Copy;
    bind.operands = { Prepared::Atom::constant(std::int64_t{ 1 },
                                               Prepared::Type::int64()) };
    Prepared::Terminator terminator;
    terminator.kind = Prepared::Terminator::Kind::Return;
    terminator.value = Prepared::Atom::variable(Name(2U, U"Second"),
                                                Prepared::Type::int64());
    const Prepared::CorePrepModule module{
        { U"Verifier" },
        { Prepared::Function{
              Name(1U, U"First"),
              {},
              Prepared::Type::int64(),
              0U,
              { { 0U, { std::move(bind) }, std::move(terminator) } } },
          Constant(Name(2U, U"Second")) },
    };

    const auto issues = Prepared::verify(module);

    CHECK(Count(issues, "TAC1022") == 1);
}

TEST_CASE("a parameter may be assigned only when a closure of the module "
          "captures into it")
{
    const auto assigning = [] {
        // `slot = 1; return slot;` with `slot` a parameter.
        Prepared::Instruction assign;
        assign.kind = Prepared::Instruction::Kind::Assign;
        assign.destination = Name(20U, U"slot");
        assign.type = Prepared::Type::int64();
        assign.operation = Prepared::Operation::Copy;
        assign.operands = { Prepared::Atom::constant(std::int64_t{ 1 },
                                                     Prepared::Type::int64()) };
        Prepared::Terminator terminator;
        terminator.kind = Prepared::Terminator::Kind::Return;
        terminator.value = Prepared::Atom::variable(Name(20U, U"slot"),
                                                    Prepared::Type::int64());
        return Prepared::Function{
            Name(2U, U"Lifted"),
            { { Name(20U, U"slot"), Prepared::Type::int64() } },
            Prepared::Type::int64(),
            0U,
            { { 0U, { std::move(assign) }, std::move(terminator) } }
        };
    };

    const Prepared::CorePrepModule plain{ { U"Verifier" }, { assigning() } };
    CHECK(Count(Prepared::verify(plain), "TAC1036") == 1);

    // A closure anywhere in the module that captures into the parameter
    // makes it a slot of the closure's environment, which may be assigned.
    Prepared::Instruction make;
    make.kind = Prepared::Instruction::Kind::Bind;
    make.destination = Name(30U, U"closure");
    make.type = IntegerFunction();
    make.operation = Prepared::Operation::MakeClosure;
    make.closure_function = Name(2U, U"Lifted");
    make.captures = { { Prepared::CaptureMode::Strong,
                        Name(20U, U"slot"),
                        Prepared::Type::int64(),
                        Prepared::Atom::constant(std::int64_t{ 5 },
                                                 Prepared::Type::int64()) } };
    Prepared::Terminator terminator;
    terminator.kind = Prepared::Terminator::Kind::Return;
    terminator.value
        = Prepared::Atom::constant(std::int64_t{ 0 }, Prepared::Type::int64());
    const Prepared::CorePrepModule captured{
        { U"Verifier" },
        { assigning(),
          Prepared::Function{
              Name(1U, U"Owner"),
              {},
              Prepared::Type::int64(),
              0U,
              { { 0U, { std::move(make) }, std::move(terminator) } } } },
    };
    CHECK(Count(Prepared::verify(captured), "TAC1036") == 0);
}
