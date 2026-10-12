// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstdint>
#include <deque>
#include <optional>
#include <string>
#include <string_view>

#include "Progmasoft/Tala/Backend/LLVM.hpp"
#include "Progmasoft/Tala/Interactive/History.hpp"
#include "Progmasoft/Tala/Pipeline.hpp"

namespace Progmasoft::Tala::Interactive
{
    enum class CellStatus : std::uint8_t
    {
        Value,
        Void,
        Type,
        Error
    };

    struct CellResult final
    {
        CellStatus status{ CellStatus::Error };
        std::string text;
        std::optional<Backend::LLVM::JitValue> value;
    };

    /** One frontend-to-LLJIT session, including the `taliPrevious` value and
     * bounded history. */
    class Session final
    {
    public:
        Session() = default;
        Session(const Session &) = delete;
        auto
        operator=(const Session &) -> Session & = delete;

        [[nodiscard]] auto
        Evaluate(std::string_view expression) -> CellResult;

        [[nodiscard]] auto
        TypeOf(std::string_view expression) -> CellResult;

        [[nodiscard]] auto
        Reset() -> std::optional<std::string>;

        [[nodiscard]] auto
        History() const noexcept -> const std::deque<std::string> &;

    private:
        [[nodiscard]] auto
        Compile(std::string_view expression, bool execute) -> CellResult;

        Backend::LLVM::JitSession jit_;
        std::uint64_t nextCell_{};
        std::optional<Backend::LLVM::JitValue> previous_;
        Runtime::History history_;
    };

    [[nodiscard]] auto
    FormatValue(const Backend::LLVM::JitValue &value) -> std::string;

    [[nodiscard]] auto
    FormatType(const tala::core::Type &type) -> std::string;
} // namespace Progmasoft::Tala::Interactive
