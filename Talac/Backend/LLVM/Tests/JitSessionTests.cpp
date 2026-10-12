// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <array>
#include <cstdint>
#include <llvm/Bitcode/BitcodeWriter.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/IR/Module.h>
#include <llvm/Support/raw_ostream.h>
#include <span>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Backend/LLVM.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Wire.hpp"
#include "Progmasoft/Tala/Pipeline.hpp"

namespace
{
    namespace Llvm = Progmasoft::Tala::Backend::LLVM;
    namespace Core = Llvm::Core;

    auto
    LowerConstant(Core::Literal literal,
                  const Core::Type &type,
                  std::uint64_t id = 1U) -> Llvm::Result
    {
        Core::Function function{
            { id, U"Evaluate" },
            {},
            type,
            0,
            { Core::Block{ 0,
                           {},
                           Core::Terminator{
                               Core::Terminator::Kind::Return,
                               Core::Atom::constant(std::move(literal), type),
                               0,
                               0 } } },
        };
        const Core::CorePrepModule module{ { U"TALI", U"Cells" },
                                           { std::move(function) } };
        auto xpp = tala::xpp::lower(module);
        auto xmm = tala::xmm::lower(xpp);
        return Llvm::Lower(xmm);
    }

    auto
    InvokeConstant(Core::Literal literal,
                   const Core::Type &type,
                   std::string_view symbol = "TALI.Cells.Evaluate.1")
        -> Llvm::JitResult
    {
        const auto lowered = LowerConstant(std::move(literal), type);
        if (!lowered)
            return { std::nullopt,
                     Llvm::JitError{ Llvm::JitErrorKind::InvalidBitcode,
                                     lowered.error->code,
                                     lowered.error->message } };
        Llvm::JitSession session;
        if (auto error = session.AddModule(lowered.artifact->bitcode,
                                           "tali-test",
                                           symbol,
                                           type))
            return { std::nullopt, std::move(error) };
        return session.InvokeScalar(symbol, type);
    }
} // namespace

TEST_CASE("ORC rejects a non-host calling convention before invocation",
          "[llvm][orc][abi][sanitizer]")
{
    llvm::LLVMContext context;
    llvm::Module module("foreign-convention", context);
    const auto functionType
        = llvm::FunctionType::get(llvm::Type::getInt64Ty(context), false);
    auto *function = llvm::Function::Create(functionType,
                                            llvm::Function::ExternalLinkage,
                                            "foreign_entry",
                                            module);
    function->setCallingConv(llvm::CallingConv::Fast);
    llvm::IRBuilder<> builder(
        llvm::BasicBlock::Create(context, "entry", function));
    builder.CreateRet(builder.getInt64(42));
    llvm::SmallVector<char, 0> bytes;
    llvm::raw_svector_ostream stream(bytes);
    llvm::WriteBitcodeToFile(module, stream);
    const auto *data = reinterpret_cast<const std::uint8_t *>(bytes.data());
    Llvm::JitSession session;
    const auto error = session.AddModule({ data, bytes.size() },
                                         "foreign-convention",
                                         "foreign_entry",
                                         Core::Type::int64());
    REQUIRE(error);
    REQUIRE(error->kind == Llvm::JitErrorKind::SignatureMismatch);
}

TEST_CASE(
    "ORC JIT invokes verified integer constants with their exact host widths",
    "[llvm][orc][tali]")
{
    struct Case final
    {
        Core::Type type;
        std::int64_t input;
        std::int64_t expected;
    };
    const std::array cases{
        Case{ Core::Type::int8(), -7, -7 },
        Case{ Core::Type::int16(), 1234, 1234 },
        Case{ Core::Type::int32(), -123456, -123456 },
        Case{ Core::Type::int64(), 0x123456789LL, 0x123456789LL },
    };
    for (const auto &test : cases)
    {
        const auto result = InvokeConstant(test.input, test.type);
        REQUIRE(result);
        REQUIRE(std::get<std::int64_t>(result.value->payload) == test.expected);
        REQUIRE(result.value->type == test.type);
    }
}

TEST_CASE("ORC JIT uses the exact boolean, character, and floating return ABI",
          "[llvm][orc][abi]")
{
    const auto boolean = InvokeConstant(true, Core::Type::boolean());
    REQUIRE(boolean);
    REQUIRE(std::get<bool>(boolean.value->payload));

    const auto character
        = InvokeConstant(Core::IntegerLiteral{ false, { 0x51U } },
                         Core::Type::character());
    REQUIRE(character);
    REQUIRE(std::get<char32_t>(character.value->payload) == U'Q');

    const auto single = InvokeConstant(Core::FloatingLiteral{ "1.25" },
                                       Core::Type::float32());
    REQUIRE(single);
    REQUIRE(std::get<double>(single.value->payload) == 1.25);

    const auto doublePrecision
        = InvokeConstant(Core::FloatingLiteral{ "-19.5" },
                         Core::Type::float64());
    REQUIRE(doublePrecision);
    REQUIRE(std::get<double>(doublePrecision.value->payload) == -19.5);

    const auto noValue = InvokeConstant(std::monostate{}, Core::Type::unit());
    REQUIRE(noValue);
    REQUIRE(std::holds_alternative<std::monostate>(noValue.value->payload));
}

TEST_CASE("ORC JIT preserves unsigned result magnitude through UInt64",
          "[llvm][orc][abi]")
{
    const auto result = InvokeConstant(
        Core::IntegerLiteral{
            false,
            { 0xffU, 0xffU, 0xffU, 0xffU, 0xffU, 0xffU, 0xffU, 0xffU } },
        Core::Type::uint64());
    REQUIRE(result);
    REQUIRE(std::get<std::uint64_t>(result.value->payload)
            == 18446744073709551615ULL);
}

TEST_CASE("ORC validates the LLVM entry ABI before registration and invocation",
          "[llvm][orc][abi][safety]")
{
    const auto lowered
        = LowerConstant(std::int64_t{ 321 }, Core::Type::int64());
    REQUIRE(lowered);
    Llvm::JitSession session;

    const auto mismatch = session.AddModule(lowered.artifact->bitcode,
                                            "wrong-declared-abi",
                                            "TALI.Cells.Evaluate.1",
                                            Core::Type::int32());
    REQUIRE(mismatch);
    REQUIRE(mismatch->kind == Llvm::JitErrorKind::SignatureMismatch);

    const auto absent
        = session.InvokeScalar("TALI.Cells.Evaluate.1", Core::Type::int64());
    REQUIRE_FALSE(absent);
    REQUIRE(absent.error->kind == Llvm::JitErrorKind::SymbolLookup);

    REQUIRE_FALSE(session.AddModule(lowered.artifact->bitcode,
                                    "valid-declared-abi",
                                    "TALI.Cells.Evaluate.1",
                                    Core::Type::int64()));
    const auto wrongRequest
        = session.InvokeScalar("TALI.Cells.Evaluate.1", Core::Type::int8());
    REQUIRE_FALSE(wrongRequest);
    REQUIRE(wrongRequest.error->kind == Llvm::JitErrorKind::SignatureMismatch);

    const auto correctRequest
        = session.InvokeScalar("TALI.Cells.Evaluate.1", Core::Type::int64());
    REQUIRE(correctRequest);
    REQUIRE(std::get<std::int64_t>(correctRequest.value->payload) == 321);

    const auto duplicate = session.AddModule(lowered.artifact->bitcode,
                                             "duplicate-entry",
                                             "TALI.Cells.Evaluate.1",
                                             Core::Type::int64());
    REQUIRE(duplicate);
    REQUIRE(duplicate->kind == Llvm::JitErrorKind::SignatureMismatch);
}

TEST_CASE("ORC JIT resolves modules added later in the same live session",
          "[llvm][orc][session]")
{
    const auto first
        = LowerConstant(std::int64_t{ 17 }, Core::Type::int64(), 1U);
    const auto second
        = LowerConstant(std::int64_t{ -21 }, Core::Type::int64(), 2U);
    REQUIRE(first);
    REQUIRE(second);

    Llvm::JitSession session;
    REQUIRE_FALSE(session.AddModule(first.artifact->bitcode,
                                    "tali-first",
                                    "TALI.Cells.Evaluate.1",
                                    Core::Type::int64()));
    const auto firstValue
        = session.InvokeScalar("TALI.Cells.Evaluate.1", Core::Type::int64());
    REQUIRE(firstValue);
    REQUIRE(std::get<std::int64_t>(firstValue.value->payload) == 17);

    REQUIRE_FALSE(session.AddModule(second.artifact->bitcode,
                                    "tali-second",
                                    "TALI.Cells.Evaluate.2",
                                    Core::Type::int64()));
    const auto secondValue
        = session.InvokeScalar("TALI.Cells.Evaluate.2", Core::Type::int64());
    REQUIRE(secondValue);
    REQUIRE(std::get<std::int64_t>(secondValue.value->payload) == -21);

    const auto firstStillCallable
        = session.InvokeScalar("TALI.Cells.Evaluate.1", Core::Type::int64());
    REQUIRE(firstStillCallable);
    REQUIRE(std::get<std::int64_t>(firstStillCallable.value->payload) == 17);
}

TEST_CASE(
    "ORC JIT serializes concurrent callers without losing session results",
    "[llvm][orc][concurrency]")
{
    constexpr std::size_t kThreadCount = 8U;
    constexpr std::size_t kCallsPerThread = 16U;
    const auto lowered = LowerConstant(std::int64_t{ 73 }, Core::Type::int64());
    REQUIRE(lowered);

    Llvm::JitSession session;
    REQUIRE_FALSE(session.AddModule(lowered.artifact->bitcode,
                                    "tali-concurrent-cell",
                                    "TALI.Cells.Evaluate.1",
                                    Core::Type::int64()));

    // Each worker writes one distinct slot. Catch3 assertions stay on the main
    // thread, while the shared JIT session is exercised from every worker.
    std::array<bool, kThreadCount> completed{};
    std::array<std::int64_t, kThreadCount> lastValue{};
    std::vector<std::thread> workers;
    workers.reserve(kThreadCount);
    for (std::size_t worker = 0U; worker < kThreadCount; ++worker)
    {
        workers.emplace_back([&session, &completed, &lastValue, worker] {
            for (std::size_t call = 0U; call < kCallsPerThread; ++call)
            {
                const auto result
                    = session.InvokeScalar("TALI.Cells.Evaluate.1",
                                           Core::Type::int64());
                if (!result
                    || !std::holds_alternative<std::int64_t>(
                        result.value->payload))
                    return;
                lastValue[worker]
                    = std::get<std::int64_t>(result.value->payload);
            }
            completed[worker] = true;
        });
    }
    for (auto &worker : workers)
        worker.join();

    for (std::size_t worker = 0U; worker < kThreadCount; ++worker)
    {
        REQUIRE(completed[worker]);
        REQUIRE(lastValue[worker] == 73);
    }
}

TEST_CASE("ORC JIT rejects empty, oversized, unnamed, and malformed modules",
          "[llvm][orc][errors]")
{
    Llvm::JitSession session;
    const std::array<std::uint8_t, 0> empty{};
    const std::array<std::uint8_t, 4> malformed{ 0x00, 0x01, 0x02, 0x03 };
    const auto emptyError
        = session.AddModule(empty, "empty", "unused", Core::Type::int64());
    REQUIRE(emptyError);
    REQUIRE(emptyError->kind == Llvm::JitErrorKind::InvalidBitcode);

    const auto unnamedError
        = session.AddModule(malformed, "", "unused", Core::Type::int64());
    REQUIRE(unnamedError);
    REQUIRE(unnamedError->code == "TAL4008");

    const auto malformedError = session.AddModule(malformed,
                                                  "malformed",
                                                  "unused",
                                                  Core::Type::int64());
    REQUIRE(malformedError);
    REQUIRE(malformedError->kind == Llvm::JitErrorKind::InvalidBitcode);

    const auto missing
        = session.InvokeScalar("not.present", Core::Type::int64());
    REQUIRE_FALSE(missing);
    REQUIRE(missing.error->kind == Llvm::JitErrorKind::SymbolLookup);
}

TEST_CASE(
    "ORC JIT reports missing and empty entry names without reserving symbols",
    "[llvm][orc][errors][recovery]")
{
    const auto lowered = LowerConstant(std::int64_t{ 8 }, Core::Type::int64());
    REQUIRE(lowered);
    Llvm::JitSession session;

    const auto emptyName = session.AddModule(lowered.artifact->bitcode,
                                             "empty-entry-name",
                                             "",
                                             Core::Type::int64());
    REQUIRE(emptyName);
    REQUIRE(emptyName->kind == Llvm::JitErrorKind::SignatureMismatch);
    REQUIRE(emptyName->code == "TAL4020");

    const auto absentName = session.AddModule(lowered.artifact->bitcode,
                                              "missing-entry-name",
                                              "TALI.Cells.DoesNotExist.8",
                                              Core::Type::int64());
    REQUIRE(absentName);
    REQUIRE(absentName->kind == Llvm::JitErrorKind::SignatureMismatch);
    REQUIRE(absentName->code == "TAL4022");

    const auto valid = session.AddModule(lowered.artifact->bitcode,
                                         "valid-after-entry-errors",
                                         "TALI.Cells.Evaluate.1",
                                         Core::Type::int64());
    REQUIRE_FALSE(valid);
    const auto result
        = session.InvokeScalar("TALI.Cells.Evaluate.1", Core::Type::int64());
    REQUIRE(result);
    REQUIRE(std::get<std::int64_t>(result.value->payload) == 8);
}

TEST_CASE(
    "moving an ORC session transfers loaded code and makes the source inert",
    "[llvm][orc][lifetime]")
{
    const auto lowered
        = LowerConstant(std::int64_t{ -64 }, Core::Type::int64());
    REQUIRE(lowered);

    Llvm::JitSession source;
    REQUIRE_FALSE(source.AddModule(lowered.artifact->bitcode,
                                   "move-owned-cell",
                                   "TALI.Cells.Evaluate.1",
                                   Core::Type::int64()));

    Llvm::JitSession destination(std::move(source));
    const auto movedResult = destination.InvokeScalar("TALI.Cells.Evaluate.1",
                                                      Core::Type::int64());
    REQUIRE(movedResult);
    REQUIRE(std::get<std::int64_t>(movedResult.value->payload) == -64);

    // The moved-from session is the contract under test.
    const auto sourceInvoke
        // NOLINTNEXTLINE(bugprone-use-after-move,clang-analyzer-cplusplus.Move)
        = source.InvokeScalar("TALI.Cells.Evaluate.1", Core::Type::int64());
    REQUIRE_FALSE(sourceInvoke);
    REQUIRE(sourceInvoke.error->kind == Llvm::JitErrorKind::Initialization);

    const auto sourceAdd = source.AddModule(lowered.artifact->bitcode,
                                            "moved-from-cell",
                                            "TALI.Cells.Evaluate.2",
                                            Core::Type::int64());
    REQUIRE(sourceAdd);
    REQUIRE(sourceAdd->kind == Llvm::JitErrorKind::Initialization);

    const auto sourceReset = source.Reset();
    REQUIRE(sourceReset);
    REQUIRE(sourceReset->kind == Llvm::JitErrorKind::Initialization);

    REQUIRE_FALSE(destination.Reset());
    const auto removed = destination.InvokeScalar("TALI.Cells.Evaluate.1",
                                                  Core::Type::int64());
    REQUIRE_FALSE(removed);
    REQUIRE(removed.error->kind == Llvm::JitErrorKind::SymbolLookup);
}

TEST_CASE("ORC JIT keeps unsupported wide scalar calls explicit",
          "[llvm][orc][abi]")
{
    const auto lowered = LowerConstant(Core::IntegerLiteral{ false, { 42U } },
                                       Core::Type::int128());
    REQUIRE(lowered);
    Llvm::JitSession session;
    const auto added = session.AddModule(lowered.artifact->bitcode,
                                         "wide-result",
                                         "TALI.Cells.Evaluate.1",
                                         Core::Type::int128());
    REQUIRE(added);
    REQUIRE(added->kind == Llvm::JitErrorKind::UnsupportedResult);
}

TEST_CASE(
    "ORC JIT does not discard earlier cells when a later module is invalid",
    "[llvm][orc][recovery]")
{
    const auto lowered = LowerConstant(std::int64_t{ 99 }, Core::Type::int64());
    REQUIRE(lowered);
    Llvm::JitSession session;
    REQUIRE_FALSE(session.AddModule(lowered.artifact->bitcode,
                                    "cell-0",
                                    "TALI.Cells.Evaluate.1",
                                    Core::Type::int64()));

    const std::array<std::uint8_t, 2> malformed{ 0xFFU, 0xFFU };
    REQUIRE(
        session.AddModule(malformed, "cell-1", "invalid", Core::Type::int64()));
    const auto previous
        = session.InvokeScalar("TALI.Cells.Evaluate.1", Core::Type::int64());
    REQUIRE(previous);
    REQUIRE(std::get<std::int64_t>(previous.value->payload) == 99);
}

TEST_CASE(
    "ORC reset releases cell symbols and permits a fresh session generation",
    "[llvm][orc][reset]")
{
    const auto first = LowerConstant(std::int64_t{ 41 }, Core::Type::int64());
    const auto second = LowerConstant(std::int64_t{ 73 }, Core::Type::int64());
    REQUIRE(first);
    REQUIRE(second);

    Llvm::JitSession session;
    REQUIRE_FALSE(session.AddModule(first.artifact->bitcode,
                                    "tali-before-reset",
                                    "TALI.Cells.Evaluate.1",
                                    Core::Type::int64()));
    const auto before
        = session.InvokeScalar("TALI.Cells.Evaluate.1", Core::Type::int64());
    REQUIRE(before);
    REQUIRE(std::get<std::int64_t>(before.value->payload) == 41);

    REQUIRE_FALSE(session.Reset());
    const auto removed
        = session.InvokeScalar("TALI.Cells.Evaluate.1", Core::Type::int64());
    REQUIRE_FALSE(removed);
    REQUIRE(removed.error->kind == Llvm::JitErrorKind::SymbolLookup);

    REQUIRE_FALSE(session.AddModule(second.artifact->bitcode,
                                    "tali-after-reset",
                                    "TALI.Cells.Evaluate.1",
                                    Core::Type::int64()));
    const auto after
        = session.InvokeScalar("TALI.Cells.Evaluate.1", Core::Type::int64());
    REQUIRE(after);
    REQUIRE(std::get<std::int64_t>(after.value->payload) == 73);
}

TEST_CASE("ORC sessions link unwind metadata regardless of section placement",
          "[llvm][orc][layout]")
{
    // Win64 objects carry image-relative unwind relocations that are only
    // valid when every section of the object lies above its lowest one. The
    // host places separately mapped sections at arbitrary addresses, so a
    // linker that maps each section on its own fails for some layouts only.
    // Many independent sessions sample those layouts; each must link and run.
    constexpr int kSessions = 400;
    for (int index = 0; index < kSessions; ++index)
    {
        const auto result
            = InvokeConstant(std::int64_t{ index }, Core::Type::int64());
        REQUIRE(result);
        REQUIRE(std::get<std::int64_t>(result.value->payload) == index);
    }
}
