// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <llvm/ADT/Twine.h>
#include <llvm/Support/ErrorHandling.h>
#include <utility>

#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Wire.hpp"
#include "Progmasoft/Tala/Core/Verifier.hpp"
#include "Progmasoft/Tala/Core/Wire.hpp"
#include "Progmasoft/Tala/Xmm/Verifier.hpp"
#include "Progmasoft/Tala/Xmm/Wire.hpp"
#include "Progmasoft/Tala/Xpp/Verifier.hpp"
#include "Progmasoft/Tala/Xpp/Wire.hpp"
#include "WireFuzz.hpp"

namespace Progmasoft::Tala::Fuzzing
{
    namespace
    {
        constexpr std::size_t kMaximumInputBytes = 16U * 1024U;

        [[nodiscard]] auto
        CoreLimits() -> Core::Wire::Limits
        {
            Core::Wire::Limits limits;
            limits.maximumWireBytes = kMaximumInputBytes;
            limits.maximumTextScalars = 256U;
            limits.maximumFunctions = 32U;
            limits.maximumParameters = 32U;
            limits.maximumStatements = 128U;
            limits.maximumOperands = 32U;
            limits.maximumTypeDepth = 16U;
            limits.maximumExpressionDepth = 32U;
            limits.maximumStatementDepth = 32U;
            limits.maximumNumericBytes = 128U;
            return limits;
        }

        [[nodiscard]] auto
        CorePrepLimits() -> ::tala::core::wire::Limits
        {
            ::tala::core::wire::Limits limits;
            limits.maximum_wire_bytes = kMaximumInputBytes;
            limits.maximum_string_code_points = 256U;
            limits.maximum_functions = 32U;
            limits.maximum_parameters_per_function = 32U;
            limits.maximum_blocks_per_function = 64U;
            limits.maximum_instructions_per_block = 128U;
            limits.maximum_operands_per_instruction = 32U;
            limits.maximum_type_depth = 16U;
            limits.maximum_numeric_bytes = 128U;
            return limits;
        }

        [[nodiscard]] auto
        ArtifactLimits() -> Artifact::Wire::Limits
        {
            Artifact::Wire::Limits limits;
            limits.maximumWireBytes = kMaximumInputBytes;
            limits.maximumTextScalars = 256U;
            limits.maximumFunctions = 32U;
            limits.maximumParameters = 32U;
            limits.maximumBlocks = 64U;
            limits.maximumInstructions = 128U;
            limits.maximumOperands = 32U;
            limits.maximumTypeDepth = 16U;
            limits.maximumNumericBytes = 128U;
            return limits;
        }

        void
        CheckCore(std::span<const std::uint8_t> bytes)
        {
            const auto limits = CoreLimits();
            const auto decoded = Core::Wire::Decode(bytes, limits);
            if (!decoded)
                return;
            // Decoding proves only wire structure. Run the independent
            // semantic verifier on every structurally valid model before the
            // encoder and round-trip oracle see it.
            if (!Core::Verify(*decoded.module).empty())
                return;
            const auto encoded = Core::Wire::Encode(*decoded.module, limits);
            if (!encoded)
                llvm::report_fatal_error(
                    llvm::Twine("verified Core model could not encode"));
            const auto again = Core::Wire::Decode(encoded.bytes, limits);
            if (!again || *again.module != *decoded.module)
                llvm::report_fatal_error(
                    llvm::Twine("Core wire round trip changed the model"));
        }

        void
        CheckCorePrep(std::span<const std::uint8_t> bytes)
        {
            const auto limits = CorePrepLimits();
            const auto decoded = ::tala::core::wire::decode(bytes, limits);
            if (!decoded)
                return;
            if (!::tala::core::verify(*decoded.module).empty())
                return;
            const auto encoded
                = ::tala::core::wire::encode(*decoded.module, limits);
            if (!encoded)
                llvm::report_fatal_error(
                    llvm::Twine("verified CorePrep model could not encode"));
            const auto again
                = ::tala::core::wire::decode(encoded.bytes, limits);
            if (!again || *again.module != *decoded.module)
                llvm::report_fatal_error(
                    llvm::Twine("CorePrep wire round trip changed the model"));
        }

        void
        CheckXpp(std::span<const std::uint8_t> bytes)
        {
            const auto limits = ArtifactLimits();
            const auto decoded = Xpp::Wire::Decode(bytes, limits);
            if (!decoded)
                return;
            if (!Xpp::Verify(*decoded.module).empty())
                return;
            const auto encoded = Xpp::Wire::Encode(*decoded.module, limits);
            if (!encoded)
                llvm::report_fatal_error(
                    llvm::Twine("verified Xpp model could not encode"));
            const auto again = Xpp::Wire::Decode(encoded.bytes, limits);
            if (!again || *again.module != *decoded.module)
                llvm::report_fatal_error(
                    llvm::Twine("Xpp wire round trip changed the model"));
        }

        void
        CheckXmm(std::span<const std::uint8_t> bytes)
        {
            const auto limits = ArtifactLimits();
            const auto decoded = Xmm::Wire::Decode(bytes, limits);
            if (!decoded)
                return;
            if (!Xmm::Verify(*decoded.module).empty())
                return;
            const auto encoded = Xmm::Wire::Encode(*decoded.module, limits);
            if (!encoded)
                llvm::report_fatal_error(
                    llvm::Twine("verified Xmm model could not encode"));
            const auto again = Xmm::Wire::Decode(encoded.bytes, limits);
            if (!again || *again.module != *decoded.module)
                llvm::report_fatal_error(
                    llvm::Twine("Xmm wire round trip changed the model"));
        }

        [[nodiscard]] auto
        WithSelector(std::uint8_t selector, std::vector<std::uint8_t> bytes)
            -> std::vector<std::uint8_t>
        {
            bytes.insert(bytes.begin(), selector);
            return bytes;
        }
    } // namespace

    void
    ExerciseWire(std::span<const std::uint8_t> input)
    {
        if (input.empty() || input.size() > kMaximumInputBytes + 1U)
            return;
        const auto bytes = input.subspan(1U);
        switch (input.front() % 4U)
        {
            case 0U:
                CheckCore(bytes);
                break;
            case 1U:
                CheckCorePrep(bytes);
                break;
            case 2U:
                CheckXpp(bytes);
                break;
            default:
                CheckXmm(bytes);
                break;
        }
    }

    auto
    WireSeeds() -> std::vector<std::vector<std::uint8_t>>
    {
        // Valid, small documents let mutations reach counts, names, and the
        // versioned body rather than spending every case on magic rejection.
        const Core::Module core{ { U"Demo" }, {} };
        const ::tala::core::CorePrepModule corePrep{ { U"Demo" }, {} };
        ::tala::xpp::Function xppFunction;
        xppFunction.symbol = { 1U, U"Main" };
        xppFunction.entry = 0U;
        ::tala::xpp::Terminator xppReturn;
        xppReturn.kind = ::tala::xpp::Terminator::Kind::Return;
        xppReturn.value = { ::tala::xpp::Operand::Kind::Literal,
                            Core::Type::unit(),
                            0U,
                            std::monostate{} };
        xppFunction.blocks.push_back({ 0U, {}, xppReturn });
        const ::tala::xpp::Module xpp{ { U"Demo" },
                                       { std::move(xppFunction) } };

        ::tala::xmm::Function xmmFunction;
        xmmFunction.symbol = { 1U, U"Main" };
        xmmFunction.entry = 0U;
        ::tala::xmm::Terminator xmmReturn;
        xmmReturn.kind = ::tala::xmm::Terminator::Kind::Return;
        xmmReturn.value = { ::tala::xmm::Value::Kind::Immediate,
                            Core::Type::unit(),
                            0U,
                            0U,
                            std::monostate{} };
        xmmFunction.blocks.push_back({ 0U, {}, xmmReturn });
        const ::tala::xmm::Module xmm{ { U"Demo" },
                                       { std::move(xmmFunction) } };
        const auto coreBytes = Core::Wire::Encode(core, CoreLimits());
        const auto corePrepBytes
            = ::tala::core::wire::encode(corePrep, CorePrepLimits());
        const auto xppBytes = Xpp::Wire::Encode(xpp, ArtifactLimits());
        const auto xmmBytes = Xmm::Wire::Encode(xmm, ArtifactLimits());
        if (!coreBytes)
            llvm::report_fatal_error(
                llvm::Twine("Could not create Core wire fuzz seed: "
                            + coreBytes.error->message));
        if (!corePrepBytes)
            llvm::report_fatal_error(
                llvm::Twine("Could not create CorePrep wire fuzz seed: "
                            + corePrepBytes.error->message));
        if (!xppBytes)
            llvm::report_fatal_error(
                llvm::Twine("Could not create Xpp wire fuzz seed: "
                            + xppBytes.error->message));
        if (!xmmBytes)
            llvm::report_fatal_error(
                llvm::Twine("Could not create Xmm wire fuzz seed: "
                            + xmmBytes.error->message));
        return { WithSelector(0U, coreBytes.bytes),
                 WithSelector(1U, corePrepBytes.bytes),
                 WithSelector(2U, xppBytes.bytes),
                 WithSelector(3U, xmmBytes.bytes) };
    }
} // namespace Progmasoft::Tala::Fuzzing
