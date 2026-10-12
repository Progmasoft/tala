// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <array>
#include <utility>

#include "Progmasoft/Tala/Xpp/Verifier.hpp"
#include "Progmasoft/Tala/Xpp/Wire.hpp"

namespace Progmasoft::Tala::Xpp::Wire
{
    namespace
    {
        namespace Common = Artifact::Wire;
        namespace Core = ::tala::core;
        namespace IR = ::tala::xpp;

        inline constexpr std::array<std::uint8_t, 4U> kMagic{ 'T',
                                                              'A',
                                                              'P',
                                                              'P' };

        void
        WriteOperand(Common::Writer &writer, const IR::Operand &operand)
        {
            writer.Byte(static_cast<std::uint8_t>(operand.kind));
            writer.Type(operand.type, "Xpp operand type");
            if (operand.kind == IR::Operand::Kind::Symbol)
                writer.U64(operand.symbol);
            else
                writer.Literal(operand.literal,
                               operand.type,
                               "Xpp operand literal");
        }

        void
        WriteInstruction(Common::Writer &writer,
                         const IR::Instruction &instruction,
                         const Limits &limits)
        {
            writer.Byte(static_cast<std::uint8_t>(instruction.effect));
            writer.Byte(static_cast<std::uint8_t>(instruction.opcode));
            writer.U64(instruction.destination);
            writer.Type(instruction.result_type, "Xpp instruction result");
            writer.Count(instruction.operands.size(),
                         limits.maximumOperands,
                         "Xpp operand count");
            for (const auto &operand : instruction.operands)
                WriteOperand(writer, operand);
            writer.U64(instruction.closure_function);
            writer.Count(instruction.capture_modes.size(),
                         limits.maximumOperands,
                         "Xpp capture mode count");
            for (const auto mode : instruction.capture_modes)
                writer.Byte(static_cast<std::uint8_t>(mode));
        }

        void
        WriteTerminator(Common::Writer &writer,
                        const IR::Terminator &terminator)
        {
            writer.Byte(static_cast<std::uint8_t>(terminator.kind));
            WriteOperand(writer, terminator.value);
            writer.U32(terminator.true_target);
            writer.U32(terminator.false_target);
        }

        void
        WriteFunction(Common::Writer &writer,
                      const IR::Function &function,
                      const Limits &limits)
        {
            writer.Symbol(function.symbol, "Xpp function symbol");
            writer.Text(function.source_file, "Xpp function source file");
            writer.Count(function.parameters.size(),
                         limits.maximumParameters,
                         "Xpp parameter count");
            for (const auto &parameter : function.parameters)
            {
                writer.Symbol(parameter.symbol, "Xpp parameter symbol");
                writer.Type(parameter.type, "Xpp parameter type");
            }
            writer.Type(function.return_type, "Xpp function result");
            writer.U32(function.entry);
            writer.Count(function.blocks.size(),
                         limits.maximumBlocks,
                         "Xpp block count");
            for (const auto &block : function.blocks)
            {
                writer.U32(block.id);
                writer.Count(block.instructions.size(),
                             limits.maximumInstructions,
                             "Xpp instruction count");
                for (const auto &instruction : block.instructions)
                    WriteInstruction(writer, instruction, limits);
                WriteTerminator(writer, block.terminator);
            }
        }

        [[nodiscard]] auto
        ReadTag(Common::Reader &reader,
                std::uint8_t maximum,
                std::string context) -> std::uint8_t
        {
            const auto tag = reader.Byte(context);
            if (tag <= maximum)
                return tag;
            if (!reader.Failure())
                reader.Fail(ErrorKind::InvalidTag,
                            std::move(context),
                            "wire tag is outside the stage catalog");
            // The document is already rejected. Returning the first catalog
            // entry keeps the caller's enumeration cast in range.
            return 0U;
        }

        [[nodiscard]] auto
        ReadOperand(Common::Reader &reader) -> IR::Operand
        {
            IR::Operand operand;
            operand.kind = static_cast<IR::Operand::Kind>(
                ReadTag(reader, 1U, "Xpp operand kind"));
            operand.type = reader.Type("Xpp operand type");
            if (operand.kind == IR::Operand::Kind::Symbol)
                operand.symbol = reader.U64("Xpp operand symbol");
            else
                operand.literal
                    = reader.Literal(operand.type, "Xpp operand literal");
            return operand;
        }

        [[nodiscard]] auto
        ReadCaptureMode(Common::Reader &reader) -> Core::CaptureMode
        {
            return static_cast<Core::CaptureMode>(
                ReadTag(reader, 2U, "Xpp capture mode"));
        }

        [[nodiscard]] auto
        ReadInstruction(Common::Reader &reader, const Limits &limits)
            -> IR::Instruction
        {
            IR::Instruction instruction;
            instruction.effect = static_cast<IR::Instruction::Effect>(
                ReadTag(reader, 2U, "Xpp instruction effect"));
            instruction.opcode = static_cast<IR::Opcode>(
                ReadTag(reader,
                        static_cast<std::uint8_t>(IR::Opcode::RuntimeCall),
                        "Xpp opcode"));
            instruction.destination = reader.U64("Xpp destination");
            instruction.result_type = reader.Type("Xpp instruction result");
            const auto operandCount
                = reader.Count(limits.maximumOperands, "Xpp operand count");
            instruction.operands.reserve(operandCount);
            for (std::size_t index = 0;
                 index < operandCount && !reader.Failure();
                 ++index)
                instruction.operands.push_back(ReadOperand(reader));
            instruction.closure_function = reader.U64("Xpp closure function");
            const auto captureCount = reader.Count(limits.maximumOperands,
                                                   "Xpp capture mode count");
            instruction.capture_modes.reserve(captureCount);
            for (std::size_t index = 0;
                 index < captureCount && !reader.Failure();
                 ++index)
                instruction.capture_modes.push_back(ReadCaptureMode(reader));
            return instruction;
        }

        [[nodiscard]] auto
        ReadTerminator(Common::Reader &reader) -> IR::Terminator
        {
            IR::Terminator terminator;
            terminator.kind = static_cast<IR::Terminator::Kind>(
                ReadTag(reader, 3U, "Xpp terminator kind"));
            terminator.value = ReadOperand(reader);
            terminator.true_target = reader.U32("Xpp true target");
            terminator.false_target = reader.U32("Xpp false target");
            return terminator;
        }

        [[nodiscard]] auto
        ReadFunction(Common::Reader &reader, const Limits &limits)
            -> IR::Function
        {
            IR::Function function;
            function.symbol = reader.Symbol("Xpp function symbol");
            function.source_file = reader.Text("Xpp function source file");
            const auto parameterCount
                = reader.Count(limits.maximumParameters, "Xpp parameter count");
            function.parameters.reserve(parameterCount);
            for (std::size_t index = 0;
                 index < parameterCount && !reader.Failure();
                 ++index)
                function.parameters.push_back(
                    Core::Parameter{ reader.Symbol("Xpp parameter symbol"),
                                     reader.Type("Xpp parameter type") });
            function.return_type = reader.Type("Xpp function result");
            function.entry = reader.U32("Xpp entry block");
            const auto blockCount
                = reader.Count(limits.maximumBlocks, "Xpp block count");
            function.blocks.reserve(blockCount);
            for (std::size_t blockIndex = 0;
                 blockIndex < blockCount && !reader.Failure();
                 ++blockIndex)
            {
                IR::Block block;
                block.id = reader.U32("Xpp block id");
                const auto instructionCount
                    = reader.Count(limits.maximumInstructions,
                                   "Xpp instruction count");
                block.instructions.reserve(instructionCount);
                for (std::size_t index = 0;
                     index < instructionCount && !reader.Failure();
                     ++index)
                    block.instructions.push_back(
                        ReadInstruction(reader, limits));
                block.terminator = ReadTerminator(reader);
                function.blocks.push_back(std::move(block));
            }
            return function;
        }
    } // namespace

    auto
    Encode(const IR::Module &module, const Limits &limits) -> EncodeResult
    {
        const auto issues = Verify(module);
        if (!issues.empty())
            return { {},
                     Error{ ErrorKind::InvalidModel,
                            0U,
                            "Xpp verifier",
                            issues.front().message } };

        Common::Writer writer(limits);
        for (const auto byte : kMagic)
            writer.Byte(byte);
        writer.U16(kCurrentVersion);
        writer.U16(0U);
        writer.QualifiedName(module.name, "Xpp module name");
        writer.Count(module.source_files.size(),
                     limits.maximumFunctions,
                     "Xpp source file count");
        for (const auto &sourceFile : module.source_files)
            writer.Text(sourceFile, "Xpp source file");
        writer.Count(module.functions.size(),
                     limits.maximumFunctions,
                     "Xpp function count");
        for (const auto &function : module.functions)
            WriteFunction(writer, function, limits);
        if (writer.Failure())
            return { {}, writer.Failure() };
        return { writer.TakeBytes(), std::nullopt };
    }

    auto
    Decode(std::span<const std::uint8_t> bytes, const Limits &limits)
        -> DecodeResult
    {
        Common::Reader reader(bytes, limits);
        for (const auto expected : kMagic)
            if (reader.Byte("Xpp magic") != expected)
            {
                reader.Fail(ErrorKind::InvalidMagic,
                            "Xpp magic",
                            "input is not a Tala Xpp document");
                break;
            }
        const auto version = reader.U16("Xpp version");
        if (!reader.Failure() && version != kCurrentVersion)
            reader.Fail(ErrorKind::UnsupportedVersion,
                        "Xpp version",
                        "unsupported Xpp wire version");
        const auto flags = reader.U16("Xpp flags");
        if (!reader.Failure() && flags != 0U)
            reader.Fail(ErrorKind::InvalidTag,
                        "Xpp flags",
                        "reserved Xpp flags must be zero");

        IR::Module module;
        module.name = reader.QualifiedName("Xpp module name");
        const auto sourceCount
            = reader.Count(limits.maximumFunctions, "Xpp source file count");
        module.source_files.reserve(sourceCount);
        for (std::size_t index = 0; index < sourceCount && !reader.Failure();
             ++index)
            module.source_files.push_back(reader.Text("Xpp source file"));
        const auto functionCount
            = reader.Count(limits.maximumFunctions, "Xpp function count");
        module.functions.reserve(functionCount);
        for (std::size_t index = 0; index < functionCount && !reader.Failure();
             ++index)
            module.functions.push_back(ReadFunction(reader, limits));
        if (!reader.Failure() && !reader.AtEnd())
            reader.Fail(ErrorKind::TrailingInput,
                        "Xpp document",
                        "bytes remain after Xpp module");
        if (reader.Failure())
            return { std::nullopt, reader.Failure() };
        return { std::move(module), std::nullopt };
    }
} // namespace Progmasoft::Tala::Xpp::Wire
