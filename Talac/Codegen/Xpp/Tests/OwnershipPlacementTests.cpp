// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <variant>
#include <vector>

#include "Progmasoft/Tala/Xpp/OwnershipPlacement.hpp"
#include "Progmasoft/Tala/Xpp/OwnershipVerifier.hpp"

// The placement pass is checked against a model that knows nothing of how it
// works: the placed function is executed on reference counts, along every
// path through its graph, and every path must end with each reference
// accounted for. A release the pass forgot, a release it wrote twice and a
// use after the last release are different failures of the model.

namespace
{
    namespace Core = ::tala::core;
    namespace IR = ::tala::xpp;
    namespace Xpp = ::Progmasoft::Tala::Xpp;
    using Effect = IR::Instruction::Effect;

    constexpr IR::SymbolId kFunction = 1U;
    constexpr IR::SymbolId kHelper = 2U;

    [[nodiscard]] auto
    Text() -> Core::Type
    {
        return Core::Type::string();
    }

    [[nodiscard]] auto
    Callable() -> Core::Type
    {
        return Core::Type::function({}, Core::Type::int64());
    }

    [[nodiscard]] auto
    Symbol(IR::SymbolId symbol, Core::Type type = Text()) -> IR::Operand
    {
        return { IR::Operand::Kind::Symbol,
                 std::move(type),
                 symbol,
                 std::monostate{} };
    }

    [[nodiscard]] auto
    Instruction(Effect effect,
                IR::Opcode opcode,
                IR::SymbolId destination,
                Core::Type type,
                std::vector<IR::Operand> operands) -> IR::Instruction
    {
        return {
            effect, opcode, destination, std::move(type), std::move(operands),
            0U,     {}
        };
    }

    /// `destination = Helper(arguments...)`: a call that returns a value.
    [[nodiscard]] auto
    Call(IR::SymbolId destination,
         const std::vector<IR::SymbolId> &arguments = {},
         Effect effect = Effect::Define) -> IR::Instruction
    {
        std::vector<IR::Operand> operands;
        operands.reserve(arguments.size() + 1U);
        operands.push_back(Symbol(kHelper, Callable()));
        for (const auto argument : arguments)
            operands.push_back(Symbol(argument));
        return Instruction(effect,
                           IR::Opcode::Call,
                           destination,
                           Text(),
                           std::move(operands));
    }

    [[nodiscard]] auto
    Copy(IR::SymbolId destination,
         IR::SymbolId source,
         Effect effect = Effect::Define) -> IR::Instruction
    {
        return Instruction(effect,
                           IR::Opcode::Copy,
                           destination,
                           Text(),
                           { Symbol(source) });
    }

    /// `destination = closure capturing the given values strongly`.
    [[nodiscard]] auto
    Closure(IR::SymbolId destination, const std::vector<IR::SymbolId> &captures)
        -> IR::Instruction
    {
        std::vector<IR::Operand> operands;
        operands.reserve(captures.size());
        for (const auto capture : captures)
            operands.push_back(Symbol(capture));
        auto closure = Instruction(Effect::Define,
                                   IR::Opcode::MakeClosure,
                                   destination,
                                   Callable(),
                                   std::move(operands));
        closure.closure_function = kHelper;
        closure.capture_modes.assign(captures.size(),
                                     Core::CaptureMode::Strong);
        return closure;
    }

    [[nodiscard]] auto
    Return(std::optional<IR::SymbolId> symbol = std::nullopt) -> IR::Terminator
    {
        IR::Terminator terminator;
        terminator.kind = IR::Terminator::Kind::Return;
        terminator.value = symbol ? Symbol(*symbol)
                                  : IR::Operand{ IR::Operand::Kind::Literal,
                                                 Core::Type::unit(),
                                                 0U,
                                                 std::monostate{} };
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
    Branch(IR::BlockId whenTrue, IR::BlockId whenFalse) -> IR::Terminator
    {
        IR::Terminator terminator;
        terminator.kind = IR::Terminator::Kind::Branch;
        terminator.value
            = { IR::Operand::Kind::Literal, Core::Type::boolean(), 0U, true };
        terminator.true_target = whenTrue;
        terminator.false_target = whenFalse;
        return terminator;
    }

    [[nodiscard]] auto
    Block(IR::BlockId id,
          std::vector<IR::Instruction> instructions,
          IR::Terminator terminator) -> IR::Block
    {
        return { id, std::move(instructions), std::move(terminator) };
    }

    /// A module of the function under test and a helper it may call.
    [[nodiscard]] auto
    Module(const std::vector<IR::SymbolId> &parameters,
           std::vector<IR::Block> blocks) -> IR::Module
    {
        IR::Function function;
        function.symbol = { kFunction, U"Subject" };
        function.parameters.reserve(parameters.size());
        for (const auto parameter : parameters)
            function.parameters.push_back(
                { { parameter, U"parameter" }, Text() });
        function.return_type = Text();
        function.entry = blocks.front().id;
        function.blocks = std::move(blocks);

        IR::Function helper;
        helper.symbol = { kHelper, U"Helper" };
        helper.return_type = Text();
        helper.entry = 0U;
        helper.blocks.push_back(Block(0U, {}, Return()));

        IR::Module module;
        module.name = { U"Placement" };
        module.functions.push_back(std::move(function));
        module.functions.push_back(std::move(helper));
        return module;
    }

    /**
     * The reference-count model.
     *
     * A call result and a new closure are objects with one reference. A
     * closure holds a reference to each strong capture until it is
     * destroyed. A parameter enters with the reference of the caller. The
     * function may run a block at most twice on one path, which takes
     * every loop around once more than it needs to be entered.
     */
    class Model final
    {
    public:
        explicit Model(const IR::Function &function)
            : function_(function)
        {}

        /// The first failure on any path, or nothing.
        [[nodiscard]] auto
        Check() -> std::optional<std::string>
        {
            State state;
            for (const auto &parameter : function_.parameters)
            {
                state.objects.push_back({ 1, {} });
                state.symbols[parameter.symbol.id] = state.objects.size() - 1U;
            }
            parameters_ = state.objects.size();
            Walk(function_.entry, state, {});
            return failure_;
        }

        [[nodiscard]] auto
        Paths() const -> std::size_t
        {
            return paths_;
        }

    private:
        struct Object final
        {
            std::int64_t references{};
            std::vector<std::size_t> captures;
        };
        struct State final
        {
            std::vector<Object> objects;
            std::map<IR::SymbolId, std::size_t> symbols;
        };

        void
        Fail(std::string message)
        {
            if (!failure_)
                failure_ = std::move(message);
        }

        void
        Drop(State &state, std::size_t object)
        {
            if (state.objects[object].references <= 0)
            {
                Fail("released an object that has no reference left");
                return;
            }
            if (--state.objects[object].references != 0)
                return;
            const auto captures = state.objects[object].captures;
            for (const auto capture : captures)
                Drop(state, capture);
        }

        /// The object a symbol holds, which must still have a reference.
        [[nodiscard]] auto
        Read(State &state, const IR::Operand &operand)
            -> std::optional<std::size_t>
        {
            if (operand.kind != IR::Operand::Kind::Symbol
                || operand.symbol == kHelper || operand.symbol == kFunction)
                return std::nullopt;
            const auto found = state.symbols.find(operand.symbol);
            if (found == state.symbols.end())
            {
                Fail("read a symbol that holds nothing");
                return std::nullopt;
            }
            if (state.objects[found->second].references <= 0)
                Fail("used an object after its last reference was released");
            return found->second;
        }

        void
        Execute(State &state, const IR::Instruction &instruction)
        {
            std::vector<std::size_t> inputs;
            for (const auto &operand : instruction.operands)
                if (const auto object = Read(state, operand))
                    inputs.push_back(*object);
            std::optional<std::size_t> result;
            switch (instruction.opcode)
            {
                case IR::Opcode::Call:
                    state.objects.push_back({ 1, {} });
                    result = state.objects.size() - 1U;
                    break;
                case IR::Opcode::MakeClosure:
                    for (const auto capture : inputs)
                        ++state.objects[capture].references;
                    state.objects.push_back({ 1, inputs });
                    result = state.objects.size() - 1U;
                    break;
                case IR::Opcode::Copy:
                    if (!inputs.empty())
                        result = inputs.front();
                    break;
                case IR::Opcode::RetainStrong:
                    if (!inputs.empty())
                    {
                        ++state.objects[inputs.front()].references;
                        result = inputs.front();
                    }
                    break;
                case IR::Opcode::ReleaseStrong:
                    if (!inputs.empty())
                        Drop(state, inputs.front());
                    break;
                default:
                    Fail("the model does not know this operation");
                    break;
            }
            if (instruction.effect != Effect::Discard && result)
                state.symbols[instruction.destination] = *result;
            else if (instruction.effect == Effect::Discard && result
                     && instruction.opcode != IR::Opcode::Copy)
                // The backend releases a closure that nothing receives.
                // Any other discarded result has no owner.
                instruction.opcode == IR::Opcode::MakeClosure
                    ? Drop(state, *result)
                    : Fail("an owned result was discarded");
        }

        void
        Finish(State state, const IR::Terminator &terminator)
        {
            ++paths_;
            // The caller releases what it receives.
            if (const auto returned = Read(state, terminator.value))
                Drop(state, *returned);
            for (std::size_t object = 0U; object < state.objects.size();
                 ++object)
            {
                const auto expected = object < parameters_ ? 1 : 0;
                if (state.objects[object].references > expected)
                    Fail("a path ends with a reference that nobody "
                         "releases");
                if (state.objects[object].references < expected)
                    Fail("a path released a reference it did not own");
            }
        }

        void
        Walk(IR::BlockId id, State state, std::map<IR::BlockId, int> visits)
        {
            if (failure_ || ++visits[id] > 2)
                return;
            const auto block
                = std::ranges::find(function_.blocks, id, &IR::Block::id);
            if (block == function_.blocks.end())
            {
                Fail("an edge leads to a block that does not exist");
                return;
            }
            for (const auto &instruction : block->instructions)
                Execute(state, instruction);
            const auto &terminator = block->terminator;
            switch (terminator.kind)
            {
                case IR::Terminator::Kind::Return:
                    Finish(std::move(state), terminator);
                    break;
                case IR::Terminator::Kind::Jump:
                    Walk(terminator.true_target, std::move(state), visits);
                    break;
                case IR::Terminator::Kind::Branch:
                    Walk(terminator.true_target, state, visits);
                    Walk(terminator.false_target, std::move(state), visits);
                    break;
                case IR::Terminator::Kind::Unreachable:
                    break;
            }
        }

        const IR::Function &function_;
        std::size_t parameters_{};
        std::size_t paths_{};
        std::optional<std::string> failure_;
    };

    [[nodiscard]] auto
    Count(const IR::Function &function, IR::Opcode opcode) -> std::size_t
    {
        std::size_t count = 0U;
        for (const auto &block : function.blocks)
            count += static_cast<std::size_t>(
                std::ranges::count(block.instructions,
                                   opcode,
                                   &IR::Instruction::opcode));
        return count;
    }

    /// Place the ownership of a module and require a balanced result that
    /// the ownership verifier accepts.
    [[nodiscard]] auto
    Placed(IR::Module module) -> IR::Function
    {
        auto placed = Xpp::PlaceOwnership(std::move(module));
        const auto issues = Xpp::VerifyOwnership(placed);
        for (const auto &issue : issues)
            UNSCOPED_INFO(issue.code << ": " << issue.message);
        CHECK(issues.empty());
        Model model(placed.functions.front());
        const auto failure = model.Check();
        if (failure)
            UNSCOPED_INFO(*failure);
        CHECK_FALSE(failure.has_value());
        CHECK(model.Paths() > 0U);
        return std::move(placed.functions.front());
    }
} // namespace

TEST_CASE("the model rejects what the pass must not produce",
          "[xpp][ownership][placement]")
{
    // Without the pass the same functions are wrong in the three ways the
    // model tells apart, so a pass that did nothing could not pass below.
    const auto check = [](std::vector<IR::Block> blocks) {
        const auto module = Module({}, std::move(blocks));
        return Model(module.functions.front()).Check();
    };
    const auto release = [](IR::SymbolId symbol) {
        return Instruction(Effect::Discard,
                           IR::Opcode::ReleaseStrong,
                           0U,
                           Core::Type::unit(),
                           { Symbol(symbol) });
    };
    std::vector<IR::Block> leak;
    leak.push_back(Block(0U, { Call(10U) }, Return()));
    const auto leaked = check(std::move(leak));
    CHECK(leaked.has_value());

    std::vector<IR::Block> twice;
    twice.push_back(
        Block(0U, { Call(10U), release(10U), release(10U) }, Return()));
    const auto releasedTwice = check(std::move(twice));
    CHECK(releasedTwice.has_value());

    std::vector<IR::Block> late;
    late.push_back(
        Block(0U, { Call(10U), release(10U), Call(11U, { 10U }) }, Return()));
    const auto usedLate = check(std::move(late));
    CHECK(usedLate.has_value());

    std::vector<IR::Block> balanced;
    balanced.push_back(Block(0U, { Call(10U), release(10U) }, Return()));
    const auto sound = check(std::move(balanced));
    CHECK_FALSE(sound.has_value());
}

TEST_CASE("a value is released after its last use on a straight path",
          "[xpp][ownership][placement]")
{
    SECTION("a value nothing uses is released where it is defined")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, { Call(10U) }, Return()));
        const auto function = Placed(Module({}, std::move(blocks)));
        REQUIRE(function.blocks.front().instructions.size() == 2U);
        CHECK(function.blocks.front().instructions[1].opcode
              == IR::Opcode::ReleaseStrong);
    }
    SECTION("a value is released after the call that uses it last")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(
            Block(0U,
                  { Call(10U), Call(11U, { 10U }), Call(12U, { 10U, 11U }) },
                  Return()));
        const auto function = Placed(Module({}, std::move(blocks)));
        CHECK(Count(function, IR::Opcode::ReleaseStrong) == 3U);
        // Nothing is released before the last call has read it.
        CHECK(function.blocks.front().instructions[1].opcode
              == IR::Opcode::Call);
        CHECK(function.blocks.front().instructions[2].opcode
              == IR::Opcode::Call);
    }
    SECTION("a returned value leaves with its reference")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, { Call(10U), Call(11U) }, Return(10U)));
        const auto function = Placed(Module({}, std::move(blocks)));
        CHECK(Count(function, IR::Opcode::ReleaseStrong) == 1U);
    }
    SECTION("a discarded result is given a symbol and released")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(
            Block(0U, { Call(0U, {}, Effect::Discard) }, Return()));
        const auto function = Placed(Module({}, std::move(blocks)));
        CHECK(function.blocks.front().instructions.front().effect
              == Effect::Define);
        CHECK(Count(function, IR::Opcode::ReleaseStrong) == 1U);
    }
}

TEST_CASE("a copy shares or takes over the reference of its source",
          "[xpp][ownership][placement]")
{
    SECTION("the source is used again: the copy retains")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(
            Block(0U,
                  { Call(10U), Copy(11U, 10U), Call(12U, { 10U, 11U }) },
                  Return()));
        const auto function = Placed(Module({}, std::move(blocks)));
        CHECK(Count(function, IR::Opcode::RetainStrong) == 1U);
        CHECK(Count(function, IR::Opcode::Copy) == 0U);
    }
    SECTION("the source is not used again: the copy moves")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, { Call(10U), Copy(11U, 10U) }, Return(11U)));
        const auto function = Placed(Module({}, std::move(blocks)));
        CHECK(Count(function, IR::Opcode::RetainStrong) == 0U);
        CHECK(Count(function, IR::Opcode::ReleaseStrong) == 0U);
    }
    SECTION("a store over a value that is still needed elsewhere")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U,
                               { Call(10U),
                                 Call(11U),
                                 Copy(10U, 11U, Effect::Store),
                                 Call(12U, { 10U, 11U }) },
                               Return()));
        (void)Placed(Module({}, std::move(blocks)));
    }
    SECTION("an instruction that reads the symbol it writes")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U,
                               { Call(10U), Call(10U, { 10U }, Effect::Store) },
                               Return(10U)));
        const auto function = Placed(Module({}, std::move(blocks)));
        // The old value is read from a symbol of its own and released.
        CHECK(Count(function, IR::Opcode::ReleaseStrong) == 1U);
    }
}

TEST_CASE("a parameter is borrowed and a result is owned",
          "[xpp][ownership][placement]")
{
    SECTION("a parameter that is only read is never released")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, { Call(10U, { 5U }) }, Return()));
        const auto function = Placed(Module({ 5U }, std::move(blocks)));
        CHECK(Count(function, IR::Opcode::ReleaseStrong) == 1U);
        CHECK(Count(function, IR::Opcode::RetainStrong) == 0U);
    }
    SECTION("a returned parameter is retained for the caller")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, {}, Return(5U)));
        const auto function = Placed(Module({ 5U }, std::move(blocks)));
        CHECK(Count(function, IR::Opcode::RetainStrong) == 1U);
        CHECK(Count(function, IR::Opcode::ReleaseStrong) == 0U);
    }
    SECTION("a copy of a parameter has a reference of its own")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, { Copy(10U, 5U) }, Return(10U)));
        const auto function = Placed(Module({ 5U }, std::move(blocks)));
        CHECK(Count(function, IR::Opcode::RetainStrong) == 1U);
    }
    SECTION("a parameter the body assigns is owned by the body")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, { Call(10U, { 5U }) }, Branch(1U, 2U)));
        blocks.push_back(Block(1U, { Call(5U, {}, Effect::Store) }, Jump(2U)));
        blocks.push_back(Block(2U, { Call(11U, { 5U }) }, Return(5U)));
        const auto function = Placed(Module({ 5U }, std::move(blocks)));
        // The entry is a block of its own, so the copy runs once.
        CHECK(function.entry != 0U);
        CHECK(function.blocks.front().instructions.front().opcode
              == IR::Opcode::RetainStrong);
    }
}

TEST_CASE("a value that dies on one edge is released on that edge",
          "[xpp][ownership][placement]")
{
    SECTION("the target has one predecessor: the release opens it")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, { Call(10U) }, Branch(1U, 2U)));
        blocks.push_back(Block(1U, { Call(11U, { 10U }) }, Return()));
        blocks.push_back(Block(2U, {}, Return()));
        const auto function = Placed(Module({}, std::move(blocks)));
        CHECK(function.blocks.size() == 3U);
        CHECK(function.blocks[2].instructions.front().opcode
              == IR::Opcode::ReleaseStrong);
    }
    SECTION("the target has other predecessors: the edge gets a block")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, { Call(10U) }, Branch(1U, 2U)));
        blocks.push_back(Block(1U, { Call(11U, { 10U }) }, Jump(2U)));
        blocks.push_back(Block(2U, {}, Return()));
        const auto function = Placed(Module({}, std::move(blocks)));
        REQUIRE(function.blocks.size() == 4U);
        CHECK(function.blocks[3].instructions.front().opcode
              == IR::Opcode::ReleaseStrong);
        CHECK(function.blocks[3].terminator.true_target == 2U);
        CHECK(function.blocks[0].terminator.false_target
              == function.blocks[3].id);
        // The join itself releases nothing: each way in already has.
        CHECK(function.blocks[2].instructions.empty());
    }
    SECTION("a value defined on one side only")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, {}, Branch(1U, 2U)));
        blocks.push_back(
            Block(1U, { Call(10U), Call(11U, { 10U }) }, Jump(2U)));
        blocks.push_back(Block(2U, {}, Return()));
        (void)Placed(Module({}, std::move(blocks)));
    }
    SECTION("a value returned on one side and dropped on the other")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, { Call(10U), Call(11U) }, Branch(1U, 2U)));
        blocks.push_back(Block(1U, {}, Return(10U)));
        blocks.push_back(Block(2U, {}, Return(11U)));
        (void)Placed(Module({}, std::move(blocks)));
    }
}

TEST_CASE("values in loops are released once for each time they are made",
          "[xpp][ownership][placement]")
{
    SECTION("a value made in every pass")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, {}, Jump(1U)));
        blocks.push_back(Block(1U, {}, Branch(2U, 3U)));
        blocks.push_back(
            Block(2U, { Call(10U), Call(11U, { 10U }) }, Jump(1U)));
        blocks.push_back(Block(3U, {}, Return()));
        (void)Placed(Module({}, std::move(blocks)));
    }
    SECTION("a value made before the loop and used in it and after it")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, { Call(10U) }, Jump(1U)));
        blocks.push_back(Block(1U, {}, Branch(2U, 3U)));
        blocks.push_back(Block(2U, { Call(11U, { 10U }) }, Jump(1U)));
        blocks.push_back(Block(3U, { Call(12U, { 10U }) }, Return()));
        (void)Placed(Module({}, std::move(blocks)));
    }
    SECTION("a value made before the loop and used only in it")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, { Call(10U) }, Jump(1U)));
        blocks.push_back(Block(1U, {}, Branch(2U, 3U)));
        blocks.push_back(Block(2U, { Call(11U, { 10U }) }, Jump(1U)));
        blocks.push_back(Block(3U, {}, Return()));
        const auto function = Placed(Module({}, std::move(blocks)));
        // It dies on the way out of the loop, not inside it.
        CHECK(function.blocks[3].instructions.front().opcode
              == IR::Opcode::ReleaseStrong);
    }
    SECTION("a variable reassigned in every pass and returned after")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, { Call(10U) }, Jump(1U)));
        blocks.push_back(Block(1U, {}, Branch(2U, 3U)));
        blocks.push_back(
            Block(2U, { Call(10U, { 10U }, Effect::Store) }, Jump(1U)));
        blocks.push_back(Block(3U, {}, Return(10U)));
        (void)Placed(Module({}, std::move(blocks)));
    }
    SECTION("a variable overwritten in the loop without being read")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, { Call(10U) }, Jump(1U)));
        blocks.push_back(Block(1U, {}, Branch(2U, 3U)));
        blocks.push_back(Block(2U, { Call(10U, {}, Effect::Store) }, Jump(1U)));
        blocks.push_back(Block(3U, {}, Return(10U)));
        (void)Placed(Module({}, std::move(blocks)));
    }
    SECTION("a loop that leaves from its middle")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, { Call(10U) }, Jump(1U)));
        blocks.push_back(Block(1U, { Call(11U) }, Branch(2U, 4U)));
        blocks.push_back(
            Block(2U, { Call(12U, { 10U, 11U }) }, Branch(3U, 4U)));
        blocks.push_back(Block(3U, {}, Jump(1U)));
        blocks.push_back(Block(4U, {}, Return(10U)));
        (void)Placed(Module({}, std::move(blocks)));
    }
}

TEST_CASE("closures own their captures", "[xpp][ownership][placement]")
{
    SECTION("a capture is released by its owner and kept by the closure")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(
            Block(0U, { Call(10U), Closure(11U, { 10U }) }, Return(11U)));
        const auto function = Placed(Module({}, std::move(blocks)));
        CHECK(Count(function, IR::Opcode::ReleaseStrong) == 1U);
    }
    SECTION("a closure that nothing uses is released with its captures")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(
            0U,
            { Call(10U), Closure(11U, { 10U }), Closure(12U, { 10U, 11U }) },
            Return()));
        (void)Placed(Module({}, std::move(blocks)));
    }
    SECTION("a captured parameter stays the caller's")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U, { Closure(11U, { 5U }) }, Return(11U)));
        const auto function = Placed(Module({ 5U }, std::move(blocks)));
        CHECK(Count(function, IR::Opcode::ReleaseStrong) == 0U);
    }
}

TEST_CASE("a method used as a value becomes a closure",
          "[xpp][ownership][placement]")
{
    const auto method = [] {
        return Symbol(kHelper, Callable());
    };
    SECTION("stored in a local")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U,
                               { Instruction(Effect::Define,
                                             IR::Opcode::Copy,
                                             10U,
                                             Callable(),
                                             { method() }) },
                               Return()));
        const auto function = Placed(Module({}, std::move(blocks)));
        const auto &first = function.blocks.front().instructions.front();
        CHECK(first.opcode == IR::Opcode::MakeClosure);
        CHECK(first.closure_function == kHelper);
        CHECK(first.operands.empty());
        CHECK(Count(function, IR::Opcode::ReleaseStrong) == 1U);
    }
    SECTION("passed as an argument, while the callee stays a method")
    {
        std::vector<IR::Block> blocks;
        blocks.push_back(Block(0U,
                               { Instruction(Effect::Define,
                                             IR::Opcode::Call,
                                             10U,
                                             Text(),
                                             { method(), method() }) },
                               Return(10U)));
        const auto function = Placed(Module({}, std::move(blocks)));
        const auto &instructions = function.blocks.front().instructions;
        REQUIRE(instructions.size() == 3U);
        CHECK(instructions[0].opcode == IR::Opcode::MakeClosure);
        CHECK(instructions[1].opcode == IR::Opcode::Call);
        CHECK(instructions[1].operands[0].symbol == kHelper);
        CHECK(instructions[1].operands[1].symbol
              == instructions[0].destination);
        CHECK(instructions[2].opcode == IR::Opcode::ReleaseStrong);
    }
    SECTION("returned")
    {
        std::vector<IR::Block> blocks;
        IR::Terminator terminator;
        terminator.kind = IR::Terminator::Kind::Return;
        terminator.value = method();
        blocks.push_back(Block(0U, {}, std::move(terminator)));
        const auto function = Placed(Module({}, std::move(blocks)));
        CHECK(Count(function, IR::Opcode::MakeClosure) == 1U);
        CHECK(Count(function, IR::Opcode::ReleaseStrong) == 0U);
    }
}

TEST_CASE("what holds no reference is left alone",
          "[xpp][ownership][placement]")
{
    std::vector<IR::Block> blocks;
    blocks.push_back(Block(0U,
                           { Instruction(Effect::Define,
                                         IR::Opcode::Add,
                                         10U,
                                         Core::Type::int64(),
                                         {}) },
                           Return()));
    // A block nothing reaches keeps its instructions as they are.
    blocks.push_back(Block(7U, { Call(11U) }, Return()));
    const auto before = Module({}, std::move(blocks));
    const auto placed = Xpp::PlaceOwnership(before);
    CHECK(placed == before);
}
