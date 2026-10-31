// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <cstdint>
#include <optional>
#include <ranges>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep/Prepare.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Wire.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Core/Verifier.hpp"
#include "Progmasoft/Tala/Core/Wire.hpp"

// A Core conditional evaluates exactly one of its two arms. In CorePrep that
// is control flow: each arm lives in its own block, reached only through the
// edge that selects it, and both write one result slot that the join reads.
// These tests pin that shape on the native Core-to-CorePrep adapter, the
// verifier rules that make the shape sound, and the wire encoding that
// carries the expression from the Haskell frontend.

namespace
{
    namespace Core = Progmasoft::Tala::Core;
    namespace Prepared = tala::core;

    constexpr std::uint64_t kFlag = 2U;
    constexpr std::uint64_t kLeft = 3U;
    constexpr std::uint64_t kRight = 4U;
    constexpr std::uint64_t kOther = 5U;
    constexpr std::uint64_t kScoped = 6U;

    [[nodiscard]] auto
    Integer(std::int64_t value) -> Core::Expression
    {
        return Core::Expression::Constant(value, Core::Type::int64());
    }

    [[nodiscard]] auto
    Boolean(bool value) -> Core::Expression
    {
        return Core::Expression::Constant(value, Core::Type::boolean());
    }

    [[nodiscard]] auto
    Flag() -> Core::Expression
    {
        return Core::Expression::Variable({ kFlag, U"flag" },
                                          Core::Type::boolean());
    }

    [[nodiscard]] auto
    Other() -> Core::Expression
    {
        return Core::Expression::Variable({ kOther, U"other" },
                                          Core::Type::boolean());
    }

    [[nodiscard]] auto
    Left() -> Core::Expression
    {
        return Core::Expression::Variable({ kLeft, U"left" },
                                          Core::Type::int64());
    }

    [[nodiscard]] auto
    Right() -> Core::Expression
    {
        return Core::Expression::Variable({ kRight, U"right" },
                                          Core::Type::int64());
    }

    /// `12 / operand`; the division marks the block that owns an arm.
    [[nodiscard]] auto
    Quotient(Core::Expression operand) -> Core::Expression
    {
        return Core::Expression::InvokePrimitive(
            Core::Primitive::Divide,
            { Integer(12), std::move(operand) },
            Core::Type::int64());
    }

    [[nodiscard]] auto
    Choose(Core::Expression test,
           Core::Expression whenTrue,
           Core::Expression whenFalse,
           Core::Type type = Core::Type::int64()) -> Core::Expression
    {
        return Core::Expression::Conditional(std::move(test),
                                             std::move(whenTrue),
                                             std::move(whenFalse),
                                             std::move(type));
    }

    /// `Evaluate(bool flag, int left, int right, bool other)` with one body.
    [[nodiscard]] auto
    Module(Core::Type returnType, std::vector<Core::Statement> body)
        -> Core::Module
    {
        return { { U"Conditional" },
                 { Core::Function{
                     { 1U, U"Evaluate" },
                     { { { kFlag, U"flag" }, Core::Type::boolean() },
                       { { kLeft, U"left" }, Core::Type::int64() },
                       { { kRight, U"right" }, Core::Type::int64() },
                       { { kOther, U"other" }, Core::Type::boolean() } },
                     std::move(returnType),
                     std::move(body) } } };
    }

    [[nodiscard]] auto
    Returning(Core::Expression value) -> Core::Module
    {
        auto type = value.type;
        return Module(std::move(type),
                      { Core::Statement::Return(std::move(value)) });
    }

    [[nodiscard]] auto
    PrepareVerified(const Core::Module &module) -> Prepared::Function
    {
        for (const auto &issue : Core::Verify(module))
            FAIL_CHECK("Core " << issue.code << ": " << issue.message);
        REQUIRE(Core::Verify(module).empty());
        auto prepared = Core::CorePrep::Prepare(module);
        for (const auto &issue : Prepared::verify(prepared))
            FAIL_CHECK("CorePrep " << issue.code << ": " << issue.message
                                   << " (block " << issue.block << ")");
        REQUIRE(Prepared::verify(prepared).empty());
        REQUIRE(prepared.functions.size() == 1U);
        return std::move(prepared.functions.front());
    }

    [[nodiscard]] auto
    Find(const Prepared::Function &function, Prepared::BlockId id)
        -> const Prepared::Block &
    {
        const auto found
            = std::ranges::find(function.blocks, id, &Prepared::Block::id);
        REQUIRE(found != function.blocks.end());
        return *found;
    }

    [[nodiscard]] auto
    IsJumpTo(const Prepared::Block &block, Prepared::BlockId target) -> bool
    {
        return block.terminator.kind == Prepared::Terminator::Kind::Jump
               && block.terminator.true_target == target;
    }

    [[nodiscard]] auto
    Count(const Prepared::Block &block, Prepared::Operation operation)
        -> std::size_t
    {
        return static_cast<std::size_t>(
            std::ranges::count(block.instructions,
                               operation,
                               &Prepared::Instruction::operation));
    }

    [[nodiscard]] auto
    CountBranches(const Prepared::Function &function) -> std::size_t
    {
        return static_cast<std::size_t>(
            std::ranges::count_if(function.blocks, [](const auto &block) {
                return block.terminator.kind
                       == Prepared::Terminator::Kind::Branch;
            }));
    }

    /// Mutable bindings of generated `$conditional` result slots.
    [[nodiscard]] auto
    SlotSeeds(const Prepared::Function &function)
        -> std::vector<Prepared::Instruction>
    {
        std::vector<Prepared::Instruction> seeds;
        for (const auto &block : function.blocks)
            for (const auto &instruction : block.instructions)
                if (instruction.kind == Prepared::Instruction::Kind::Bind
                    && instruction.destination.spelling.starts_with(
                        U"$conditional"))
                    seeds.push_back(instruction);
        return seeds;
    }

    [[nodiscard]] auto
    HasIssue(const Core::Module &module, std::string_view code) -> bool
    {
        return std::ranges::any_of(Core::Verify(module),
                                   [code](const auto &issue) {
                                       return issue.code == code;
                                   });
    }
} // namespace

TEST_CASE("a conditional lowers to a branch, two arms and one join",
          "[coreprep][conditional]")
{
    const auto function
        = PrepareVerified(Returning(Choose(Flag(), Left(), Right())));
    REQUIRE(function.blocks.size() == 4U);

    const auto &entry = Find(function, function.entry);
    REQUIRE(entry.terminator.kind == Prepared::Terminator::Kind::Branch);
    const auto trueId = entry.terminator.true_target;
    const auto falseId = entry.terminator.false_target;
    CHECK(trueId != falseId);
    CHECK(trueId != function.entry);
    CHECK(falseId != function.entry);

    // The Boolean parameter is branched on directly, without a comparison.
    REQUIRE(entry.terminator.value.kind == Prepared::Atom::Kind::Variable);
    CHECK(entry.terminator.value.symbol.id == kFlag);
    CHECK(Count(entry, Prepared::Operation::NotEqual) == 0U);

    const auto &whenTrue = Find(function, trueId);
    const auto &whenFalse = Find(function, falseId);
    REQUIRE(whenTrue.terminator.kind == Prepared::Terminator::Kind::Jump);
    const auto joinId = whenTrue.terminator.true_target;
    CHECK(IsJumpTo(whenFalse, joinId));
    CHECK(joinId != trueId);
    CHECK(joinId != falseId);

    // The join returns the slot; each arm stores its own operand into it.
    const auto &join = Find(function, joinId);
    REQUIRE(join.terminator.kind == Prepared::Terminator::Kind::Return);
    REQUIRE(join.terminator.value.kind == Prepared::Atom::Kind::Variable);
    const auto slot = join.terminator.value.symbol.id;
    CHECK(join.instructions.empty());

    REQUIRE(whenTrue.instructions.size() == 1U);
    CHECK(whenTrue.instructions.front().kind
          == Prepared::Instruction::Kind::Assign);
    CHECK(whenTrue.instructions.front().destination.id == slot);
    REQUIRE(whenTrue.instructions.front().operands.size() == 1U);
    CHECK(whenTrue.instructions.front().operands.front().symbol.id == kLeft);

    REQUIRE(whenFalse.instructions.size() == 1U);
    CHECK(whenFalse.instructions.front().kind
          == Prepared::Instruction::Kind::Assign);
    CHECK(whenFalse.instructions.front().destination.id == slot);
    REQUIRE(whenFalse.instructions.front().operands.size() == 1U);
    CHECK(whenFalse.instructions.front().operands.front().symbol.id == kRight);
}

TEST_CASE("the result slot is seeded once before the branch",
          "[coreprep][conditional]")
{
    const auto function
        = PrepareVerified(Returning(Choose(Flag(), Left(), Right())));
    const auto seeds = SlotSeeds(function);
    REQUIRE(seeds.size() == 1U);
    CHECK(seeds.front().mutable_binding);
    CHECK(seeds.front().type == Core::Type::int64());
    CHECK(seeds.front().operation == Prepared::Operation::Copy);
    REQUIRE(seeds.front().operands.size() == 1U);
    CHECK(seeds.front().operands.front().kind == Prepared::Atom::Kind::Literal);
    CHECK(seeds.front().operands.front().literal
          == Prepared::Literal{ Prepared::integer_from_signed(0) });

    // The seed dominates both arms: it is in the block that branches.
    const auto &entry = Find(function, function.entry);
    CHECK(std::ranges::any_of(entry.instructions,
                              [&seeds](const auto &instruction) {
                                  return instruction.destination.id
                                         == seeds.front().destination.id;
                              }));
}

TEST_CASE("slot seeds follow the result type", "[coreprep][conditional]")
{
    SECTION("a Boolean result starts from false")
    {
        const auto function = PrepareVerified(Returning(
            Choose(Flag(), Other(), Boolean(true), Core::Type::boolean())));
        const auto seeds = SlotSeeds(function);
        REQUIRE(seeds.size() == 1U);
        CHECK(seeds.front().type == Core::Type::boolean());
        REQUIRE(seeds.front().operands.size() == 1U);
        CHECK(seeds.front().operands.front().literal
              == Prepared::Literal{ false });
    }
    SECTION("a floating result starts from a floating zero")
    {
        const auto half
            = Core::Expression::Constant(Prepared::FloatingLiteral{ "0.5" },
                                         Core::Type::float64());
        const auto whole
            = Core::Expression::Constant(Prepared::FloatingLiteral{ "2.0" },
                                         Core::Type::float64());
        const auto function = PrepareVerified(
            Returning(Choose(Flag(), half, whole, Core::Type::float64())));
        const auto seeds = SlotSeeds(function);
        REQUIRE(seeds.size() == 1U);
        CHECK(seeds.front().type == Core::Type::float64());
        REQUIRE(seeds.front().operands.size() == 1U);
        CHECK(seeds.front().operands.front().literal
              == Prepared::Literal{ Prepared::FloatingLiteral{ "0" } });
    }
}

TEST_CASE("a numeric test is compared with zero before the branch",
          "[coreprep][conditional]")
{
    const auto function
        = PrepareVerified(Returning(Choose(Left(), Left(), Right())));
    const auto &entry = Find(function, function.entry);
    REQUIRE(entry.terminator.kind == Prepared::Terminator::Kind::Branch);
    CHECK(Count(entry, Prepared::Operation::NotEqual) == 1U);
    REQUIRE(entry.terminator.value.kind == Prepared::Atom::Kind::Variable);
    CHECK(entry.terminator.value.type == Core::Type::boolean());
    CHECK(entry.terminator.value.symbol.id != kLeft);
}

TEST_CASE("each arm's computation stays in that arm's block",
          "[coreprep][conditional]")
{
    // flag ? 12 / left : 12 / right. Neither division may be hoisted into
    // the entry block or the join: one of the divisors may be zero.
    const auto function = PrepareVerified(
        Returning(Choose(Flag(), Quotient(Left()), Quotient(Right()))));
    REQUIRE(function.blocks.size() == 4U);
    const auto &entry = Find(function, function.entry);
    REQUIRE(entry.terminator.kind == Prepared::Terminator::Kind::Branch);
    const auto &whenTrue = Find(function, entry.terminator.true_target);
    const auto &whenFalse = Find(function, entry.terminator.false_target);
    const auto &join = Find(function, whenTrue.terminator.true_target);

    CHECK(Count(entry, Prepared::Operation::Divide) == 0U);
    CHECK(Count(join, Prepared::Operation::Divide) == 0U);
    REQUIRE(Count(whenTrue, Prepared::Operation::Divide) == 1U);
    REQUIRE(Count(whenFalse, Prepared::Operation::Divide) == 1U);

    const auto divisor = [](const Prepared::Block &block) {
        const auto found = std::ranges::find(block.instructions,
                                             Prepared::Operation::Divide,
                                             &Prepared::Instruction::operation);
        return found->operands.back().symbol.id;
    };
    CHECK(divisor(whenTrue) == kLeft);
    CHECK(divisor(whenFalse) == kRight);
}

TEST_CASE("nested conditionals create one region each",
          "[coreprep][conditional]")
{
    SECTION("nested in the first arm")
    {
        // flag ? (other ? left : right) : 0
        const auto function = PrepareVerified(Returning(
            Choose(Flag(), Choose(Other(), Left(), Right()), Integer(0))));
        CHECK(function.blocks.size() == 7U);
        CHECK(CountBranches(function) == 2U);
        CHECK(SlotSeeds(function).size() == 2U);

        // The inner test is evaluated only on the outer true edge.
        const auto &entry = Find(function, function.entry);
        REQUIRE(entry.terminator.kind == Prepared::Terminator::Kind::Branch);
        const auto &outerTrue = Find(function, entry.terminator.true_target);
        REQUIRE(outerTrue.terminator.kind
                == Prepared::Terminator::Kind::Branch);
        CHECK(outerTrue.terminator.value.symbol.id == kOther);
        const auto &outerFalse = Find(function, entry.terminator.false_target);
        CHECK(outerFalse.terminator.kind == Prepared::Terminator::Kind::Jump);
    }
    SECTION("chained in the second arm")
    {
        // flag ? left : (other ? right : 0)
        const auto function = PrepareVerified(Returning(
            Choose(Flag(), Left(), Choose(Other(), Right(), Integer(0)))));
        CHECK(function.blocks.size() == 7U);
        CHECK(CountBranches(function) == 2U);
        const auto &entry = Find(function, function.entry);
        REQUIRE(entry.terminator.kind == Prepared::Terminator::Kind::Branch);
        const auto &outerFalse = Find(function, entry.terminator.false_target);
        REQUIRE(outerFalse.terminator.kind
                == Prepared::Terminator::Kind::Branch);
        CHECK(outerFalse.terminator.value.symbol.id == kOther);
    }
    SECTION("as the test of another conditional")
    {
        // (flag ? other : false) ? left : right
        const auto function = PrepareVerified(Returning(Choose(
            Choose(Flag(), Other(), Boolean(false), Core::Type::boolean()),
            Left(),
            Right())));
        CHECK(function.blocks.size() == 7U);
        CHECK(CountBranches(function) == 2U);
        CHECK(SlotSeeds(function).size() == 2U);
    }
}

TEST_CASE("a conditional composes with the surrounding statement",
          "[coreprep][conditional]")
{
    SECTION("as a binding initializer")
    {
        constexpr std::uint64_t kChosen = 7U;
        const auto function = PrepareVerified(
            Module(Core::Type::int64(),
                   { Core::Statement::Bind({ { kChosen, U"chosen" },
                                             Core::Type::int64(),
                                             false,
                                             Choose(Flag(), Left(), Right()) }),
                     Core::Statement::Return(
                         Core::Expression::Variable({ kChosen, U"chosen" },
                                                    Core::Type::int64())) }));
        REQUIRE(function.blocks.size() == 4U);
        // The binding continues in the join, after both arms have stored.
        const auto &entry = Find(function, function.entry);
        const auto &whenTrue = Find(function, entry.terminator.true_target);
        const auto &join = Find(function, whenTrue.terminator.true_target);
        REQUIRE(join.instructions.size() == 1U);
        CHECK(join.instructions.front().destination.id == kChosen);
        CHECK(join.terminator.kind == Prepared::Terminator::Kind::Return);
    }
    SECTION("as an operand of a primitive")
    {
        // left + (flag ? left : right): the left operand is read before the
        // branch and the addition happens after the join.
        const auto function
            = PrepareVerified(Returning(Core::Expression::InvokePrimitive(
                Core::Primitive::Add,
                { Left(), Choose(Flag(), Left(), Right()) },
                Core::Type::int64())));
        REQUIRE(function.blocks.size() == 4U);
        const auto &entry = Find(function, function.entry);
        const auto &whenTrue = Find(function, entry.terminator.true_target);
        const auto &join = Find(function, whenTrue.terminator.true_target);
        CHECK(Count(entry, Prepared::Operation::Add) == 0U);
        CHECK(Count(join, Prepared::Operation::Add) == 1U);
    }
    SECTION("as an if condition")
    {
        const auto function = PrepareVerified(Module(
            Core::Type::int64(),
            { Core::Statement::If(
                  Choose(Flag(), Other(), Boolean(true), Core::Type::boolean()),
                  { Core::Statement::Return(Left()) },
                  {}),
              Core::Statement::Return(Right()) }));
        CHECK(CountBranches(function) == 2U);
    }
    SECTION("as a while condition keeps one back-edge")
    {
        constexpr std::uint64_t kCounter = 7U;
        const auto counter = [] {
            return Core::Expression::Variable({ kCounter, U"counter" },
                                              Core::Type::int64());
        };
        const auto positive = [&counter] {
            return Core::Expression::InvokePrimitive(
                Core::Primitive::GreaterThan,
                { counter(), Integer(0) },
                Core::Type::boolean());
        };
        const auto function = PrepareVerified(Module(
            Core::Type::int64(),
            { Core::Statement::Bind({ { kCounter, U"counter" },
                                      Core::Type::int64(),
                                      true,
                                      Left() }),
              Core::Statement::While(
                  Choose(Flag(),
                         positive(),
                         Boolean(false),
                         Core::Type::boolean()),
                  { Core::Statement::Assign({ kCounter, U"counter" },
                                            Core::Expression::InvokePrimitive(
                                                Core::Primitive::Subtract,
                                                { counter(), Integer(1) },
                                                Core::Type::int64())) }),
              Core::Statement::Return(counter()) }));
        CHECK(CountBranches(function) == 2U);
        const auto backEdges
            = std::ranges::count_if(function.blocks, [](const auto &block) {
                  return block.terminator.kind
                             == Prepared::Terminator::Kind::Jump
                         && block.terminator.true_target < block.id;
              });
        CHECK(backEdges == 1);
    }
}

TEST_CASE("a let inside an arm binds in that arm", "[coreprep][conditional]")
{
    // flag ? (let scoped = 12 / left in scoped) : right
    const auto function = PrepareVerified(Returning(Choose(
        Flag(),
        Core::Expression::Let({ kScoped, U"scoped" },
                              Core::Type::int64(),
                              Quotient(Left()),
                              Core::Expression::Variable({ kScoped, U"scoped" },
                                                         Core::Type::int64()),
                              Core::Type::int64()),
        Right())));
    const auto &entry = Find(function, function.entry);
    REQUIRE(entry.terminator.kind == Prepared::Terminator::Kind::Branch);
    const auto &whenTrue = Find(function, entry.terminator.true_target);
    // The bound value keeps its own operation instead of a copied temporary.
    const auto binding
        = std::ranges::find_if(whenTrue.instructions,
                               [](const auto &instruction) {
                                   return instruction.destination.id == kScoped;
                               });
    REQUIRE(binding != whenTrue.instructions.end());
    CHECK(binding->operation == Prepared::Operation::Divide);
    CHECK(Count(entry, Prepared::Operation::Divide) == 0U);
}

TEST_CASE("the Core verifier enforces the conditional contract",
          "[core][verifier][conditional]")
{
    const auto text = Core::Expression::Constant(std::u32string{ U"text" },
                                                 Core::Type::string());
    CHECK(Core::Verify(Returning(Choose(Flag(), Left(), Right()))).empty());
    CHECK(Core::Verify(Returning(Choose(Left(), Left(), Right()))).empty());

    SECTION("the test must be bool or numeric")
    {
        CHECK(HasIssue(Returning(Choose(text, Left(), Right())), "TAC1067"));
    }
    SECTION("the first arm must have the result type")
    {
        CHECK(HasIssue(Returning(Choose(Flag(), Other(), Right())), "TAC1068"));
    }
    SECTION("the second arm must have the result type")
    {
        CHECK(HasIssue(Returning(Choose(Flag(), Left(), Other())), "TAC1069"));
    }
    SECTION("the result must be a scalar")
    {
        CHECK(HasIssue(
            Returning(Choose(Flag(), text, text, Core::Type::string())),
            "TAC1070"));
    }
    SECTION("a conditional needs exactly three operands")
    {
        auto malformed = Choose(Flag(), Left(), Right());
        malformed.operands.pop_back();
        CHECK(HasIssue(Returning(malformed), "TAC1071"));
        malformed.operands.clear();
        CHECK(HasIssue(Returning(malformed), "TAC1071"));
    }
    SECTION("names are checked in the test and in both arms")
    {
        const auto missing = Core::Expression::Variable({ 90U, U"missing" },
                                                        Core::Type::int64());
        const auto missingFlag
            = Core::Expression::Variable({ 91U, U"missing" },
                                         Core::Type::boolean());
        CHECK(HasIssue(Returning(Choose(Flag(), missing, Right())), "TAC1020"));
        CHECK(HasIssue(Returning(Choose(Flag(), Left(), missing)), "TAC1020"));
        CHECK(HasIssue(Returning(Choose(missingFlag, Left(), Right())),
                       "TAC1020"));
    }
    SECTION("a let in one arm is not visible in the other")
    {
        const auto scoped = Core::Expression::Variable({ kScoped, U"scoped" },
                                                       Core::Type::int64());
        CHECK(HasIssue(
            Returning(Choose(Flag(),
                             Core::Expression::Let({ kScoped, U"scoped" },
                                                   Core::Type::int64(),
                                                   Left(),
                                                   scoped,
                                                   Core::Type::int64()),
                             scoped)),
            "TAC1020"));
    }
}

TEST_CASE("Core wire v10 round-trips conditional expressions",
          "[core][wire][conditional]")
{
    const auto module = Returning(
        Choose(Flag(),
               Choose(Other(), Quotient(Left()), Right()),
               Core::Expression::Let(
                   { kScoped, U"scoped" },
                   Core::Type::int64(),
                   Right(),
                   Choose(Core::Expression::Variable({ kScoped, U"scoped" },
                                                     Core::Type::int64()),
                          Left(),
                          Integer(7)),
                   Core::Type::int64())));
    REQUIRE(Core::Verify(module).empty());
    const auto encoded = Core::Wire::Encode(module);
    REQUIRE(encoded);
    CHECK(encoded.bytes.at(4) == 10U);
    const auto decoded = Core::Wire::Decode(encoded.bytes);
    REQUIRE(decoded);
    CHECK(*decoded.module == module);

    SECTION("every proper prefix is rejected")
    {
        // The three children have fixed positions; no shorter payload can
        // be mistaken for a complete conditional.
        for (std::size_t size = 0U; size < encoded.bytes.size(); ++size)
        {
            const std::vector<std::uint8_t> prefix(
                encoded.bytes.begin(),
                encoded.bytes.begin() + static_cast<std::ptrdiff_t>(size));
            CAPTURE(size);
            CHECK_FALSE(Core::Wire::Decode(prefix));
        }
    }
    SECTION("trailing bytes are rejected")
    {
        auto extended = encoded.bytes;
        extended.push_back(0U);
        CHECK_FALSE(Core::Wire::Decode(extended));
    }
    SECTION("the previous schema version is rejected")
    {
        auto previous = encoded.bytes;
        previous[4] = 7U;
        const auto rejected = Core::Wire::Decode(previous);
        REQUIRE_FALSE(rejected);
        CHECK(rejected.error->kind
              == Core::Wire::ErrorKind::UnsupportedVersion);
    }
}

TEST_CASE("the wire writer rejects a malformed conditional",
          "[core][wire][conditional]")
{
    auto malformed = Choose(Flag(), Left(), Right());
    malformed.operands.pop_back();
    const auto encoded = Core::Wire::Encode(Returning(malformed));
    REQUIRE_FALSE(encoded);
    CHECK(encoded.error->kind == Core::Wire::ErrorKind::InvalidCount);
}

TEST_CASE("a discarded call keeps its result type across the CorePrep wire",
          "[coreprep][wire][conditional]")
{
    // int Next() { return 7; }
    // int Evaluate(...) { Next(); <discarded values>; return left; }
    // The evaluate record has no type field. The reader used to leave the
    // decoded instruction as Unit, which disagrees with the adapter and
    // fails the Xpp signature check for every value-returning callee.
    constexpr std::uint64_t kNext = 20U;
    const auto nextType = Core::Type::function({}, Core::Type::int64());
    const auto call = [&nextType] {
        return Core::Expression::Apply(
            Core::Expression::Variable({ kNext, U"Next" }, nextType),
            {},
            Core::Type::int64());
    };
    auto module
        = Module(Core::Type::int64(),
                 { Core::Statement::Evaluate(call()),
                   Core::Statement::Evaluate(Quotient(Left())),
                   Core::Statement::Evaluate(Choose(Flag(), call(), Right())),
                   Core::Statement::Evaluate(Left()),
                   Core::Statement::Return(Left()) });
    module.functions.push_back(
        Core::Function{ { kNext, U"Next" },
                        {},
                        Core::Type::int64(),
                        { Core::Statement::Return(Integer(7)) } });
    REQUIRE(Core::Verify(module).empty());
    // Read the module back from Core wire first, as the pipeline does.
    const auto coreBytes = Core::Wire::Encode(module);
    REQUIRE(coreBytes);
    const auto canonical = Core::Wire::Decode(coreBytes.bytes);
    REQUIRE(canonical);
    const auto prepared = Core::CorePrep::Prepare(*canonical.module);
    REQUIRE(Prepared::verify(prepared).empty());

    // Exactly one result-dropping instruction: the direct call. The
    // division and the conditional are bound; the plain read emits nothing.
    std::vector<Prepared::Instruction> evaluations;
    for (const auto &block : prepared.functions.front().blocks)
        for (const auto &instruction : block.instructions)
            if (instruction.kind == Prepared::Instruction::Kind::Evaluate)
                evaluations.push_back(instruction);
    REQUIRE(evaluations.size() == 1U);
    CHECK(evaluations.front().operation == Prepared::Operation::Call);
    CHECK(evaluations.front().type == Core::Type::int64());

    const auto encoded = Prepared::wire::encode(prepared);
    REQUIRE_FALSE(encoded.error);
    const auto decoded = Prepared::wire::decode(encoded.bytes);
    REQUIRE(decoded);
    // The adapter emits integers in the canonical form the reader
    // produces, so a round trip reproduces the module exactly.
    CHECK(*decoded.module == prepared);
}
