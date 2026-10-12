// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <array>
#include <utility>

#include "Progmasoft/Tala/Xmm/Verifier.hpp"
#include "Progmasoft/Tala/Xmm/Wire.hpp"

namespace Progmasoft::Tala::Xmm::Wire
{
    namespace
    {
        namespace Common = Artifact::Wire;
        namespace Core = ::tala::core;
        namespace IR = ::tala::xmm;

        inline constexpr std::array<std::uint8_t, 4U> kMagic{ 'T',
                                                              'A',
                                                              'M',
                                                              'M' };

        void
        WriteValue(Common::Writer &writer, const IR::Value &value)
        {
            writer.Byte(static_cast<std::uint8_t>(value.kind));
            writer.Type(value.type, "Xmm value type");
            switch (value.kind)
            {
                case IR::Value::Kind::Register:
                    writer.U32(value.reg);
                    break;
                case IR::Value::Kind::Immediate:
                    writer.Literal(value.immediate,
                                   value.type,
                                   "Xmm immediate");
                    break;
                case IR::Value::Kind::Function:
                    writer.U64(value.symbol);
                    break;
            }
        }

        void
        WriteInstruction(Common::Writer &writer,
                         const IR::Instruction &instruction,
                         const Limits &limits)
        {
            writer.Byte(static_cast<std::uint8_t>(instruction.opcode));
            writer.U32(instruction.destination);
            writer.Type(instruction.result_type, "Xmm instruction result");
            writer.Boolean(instruction.has_result);
            writer.Count(instruction.operands.size(),
                         limits.maximumOperands,
                         "Xmm operand count");
            for (const auto &operand : instruction.operands)
                WriteValue(writer, operand);
            writer.U64(instruction.closure_function);
            writer.Count(instruction.capture_modes.size(),
                         limits.maximumOperands,
                         "Xmm capture mode count");
            for (const auto mode : instruction.capture_modes)
                writer.Byte(static_cast<std::uint8_t>(mode));
        }

        void
        WriteTerminator(Common::Writer &writer,
                        const IR::Terminator &terminator)
        {
            writer.Byte(static_cast<std::uint8_t>(terminator.kind));
            WriteValue(writer, terminator.value);
            writer.U32(terminator.true_target);
            writer.U32(terminator.false_target);
        }

        void
        WriteFunction(Common::Writer &writer,
                      const IR::Function &function,
                      const Limits &limits)
        {
            writer.Symbol(function.symbol, "Xmm function symbol");
            writer.Text(function.source_file, "Xmm function source file");
            writer.Count(function.parameter_registers.size(),
                         limits.maximumParameters,
                         "Xmm parameter register count");
            for (const auto reg : function.parameter_registers)
                writer.U32(reg);
            writer.Count(function.parameter_types.size(),
                         limits.maximumParameters,
                         "Xmm parameter type count");
            for (const auto &type : function.parameter_types)
                writer.Type(type, "Xmm parameter type");
            writer.Type(function.return_type, "Xmm function result");
            writer.U32(function.entry);
            writer.Count(function.blocks.size(),
                         limits.maximumBlocks,
                         "Xmm block count");
            for (const auto &block : function.blocks)
            {
                writer.U32(block.id);
                writer.Count(block.instructions.size(),
                             limits.maximumInstructions,
                             "Xmm instruction count");
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
        ReadValue(Common::Reader &reader) -> IR::Value
        {
            IR::Value value;
            value.kind = static_cast<IR::Value::Kind>(
                ReadTag(reader, 2U, "Xmm value kind"));
            value.type = reader.Type("Xmm value type");
            switch (value.kind)
            {
                case IR::Value::Kind::Register:
                    value.reg = reader.U32("Xmm virtual register");
                    break;
                case IR::Value::Kind::Immediate:
                    value.immediate
                        = reader.Literal(value.type, "Xmm immediate");
                    break;
                case IR::Value::Kind::Function:
                    value.symbol = reader.U64("Xmm function value");
                    break;
            }
            return value;
        }

        [[nodiscard]] auto
        ReadCaptureMode(Common::Reader &reader) -> Core::CaptureMode
        {
            return static_cast<Core::CaptureMode>(
                ReadTag(reader, 2U, "Xmm capture mode"));
        }

        [[nodiscard]] auto
        ReadInstruction(Common::Reader &reader, const Limits &limits)
            -> IR::Instruction
        {
            IR::Instruction instruction;
            instruction.opcode = static_cast<IR::Opcode>(
                ReadTag(reader,
                        static_cast<std::uint8_t>(IR::Opcode::RuntimeCall),
                        "Xmm opcode"));
            instruction.destination = reader.U32("Xmm destination register");
            instruction.result_type = reader.Type("Xmm instruction result");
            instruction.has_result = reader.Boolean("Xmm has-result flag");
            const auto operandCount
                = reader.Count(limits.maximumOperands, "Xmm operand count");
            instruction.operands.reserve(operandCount);
            for (std::size_t index = 0;
                 index < operandCount && !reader.Failure();
                 ++index)
                instruction.operands.push_back(ReadValue(reader));
            instruction.closure_function = reader.U64("Xmm closure function");
            const auto captureCount = reader.Count(limits.maximumOperands,
                                                   "Xmm capture mode count");
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
                ReadTag(reader, 3U, "Xmm terminator kind"));
            terminator.value = ReadValue(reader);
            terminator.true_target = reader.U32("Xmm true target");
            terminator.false_target = reader.U32("Xmm false target");
            return terminator;
        }

        [[nodiscard]] auto
        ReadFunction(Common::Reader &reader, const Limits &limits)
            -> IR::Function
        {
            IR::Function function;
            function.symbol = reader.Symbol("Xmm function symbol");
            function.source_file = reader.Text("Xmm function source file");
            const auto registerCount
                = reader.Count(limits.maximumParameters,
                               "Xmm parameter register count");
            function.parameter_registers.reserve(registerCount);
            for (std::size_t index = 0;
                 index < registerCount && !reader.Failure();
                 ++index)
                function.parameter_registers.push_back(
                    reader.U32("Xmm parameter register"));
            const auto typeCount = reader.Count(limits.maximumParameters,
                                                "Xmm parameter type count");
            function.parameter_types.reserve(typeCount);
            for (std::size_t index = 0; index < typeCount && !reader.Failure();
                 ++index)
                function.parameter_types.push_back(
                    reader.Type("Xmm parameter type"));
            function.return_type = reader.Type("Xmm function result");
            function.entry = reader.U32("Xmm entry block");
            const auto blockCount
                = reader.Count(limits.maximumBlocks, "Xmm block count");
            function.blocks.reserve(blockCount);
            for (std::size_t blockIndex = 0;
                 blockIndex < blockCount && !reader.Failure();
                 ++blockIndex)
            {
                IR::Block block;
                block.id = reader.U32("Xmm block id");
                const auto instructionCount
                    = reader.Count(limits.maximumInstructions,
                                   "Xmm instruction count");
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
                            "Xmm verifier",
                            issues.front().message } };

        Common::Writer writer(limits);
        for (const auto byte : kMagic)
            writer.Byte(byte);
        writer.U16(kCurrentVersion);
        writer.U16(0U);
        writer.QualifiedName(module.name, "Xmm module name");
        writer.Count(module.source_files.size(),
                     limits.maximumFunctions,
                     "Xmm source file count");
        for (const auto &sourceFile : module.source_files)
            writer.Text(sourceFile, "Xmm source file");
        writer.Count(module.functions.size(),
                     limits.maximumFunctions,
                     "Xmm function count");
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
            if (reader.Byte("Xmm magic") != expected)
            {
                reader.Fail(ErrorKind::InvalidMagic,
                            "Xmm magic",
                            "input is not a Tala Xmm document");
                break;
            }
        const auto version = reader.U16("Xmm version");
        if (!reader.Failure() && version != kCurrentVersion)
            reader.Fail(ErrorKind::UnsupportedVersion,
                        "Xmm version",
                        "unsupported Xmm wire version");
        const auto flags = reader.U16("Xmm flags");
        if (!reader.Failure() && flags != 0U)
            reader.Fail(ErrorKind::InvalidTag,
                        "Xmm flags",
                        "reserved Xmm flags must be zero");

        IR::Module module;
        module.name = reader.QualifiedName("Xmm module name");
        const auto sourceCount
            = reader.Count(limits.maximumFunctions, "Xmm source file count");
        module.source_files.reserve(sourceCount);
        for (std::size_t index = 0; index < sourceCount && !reader.Failure();
             ++index)
            module.source_files.push_back(reader.Text("Xmm source file"));
        const auto functionCount
            = reader.Count(limits.maximumFunctions, "Xmm function count");
        module.functions.reserve(functionCount);
        for (std::size_t index = 0; index < functionCount && !reader.Failure();
             ++index)
            module.functions.push_back(ReadFunction(reader, limits));
        if (!reader.Failure() && !reader.AtEnd())
            reader.Fail(ErrorKind::TrailingInput,
                        "Xmm document",
                        "bytes remain after Xmm module");
        if (reader.Failure())
            return { std::nullopt, reader.Failure() };
        return { std::move(module), std::nullopt };
    }
} // namespace Progmasoft::Tala::Xmm::Wire
