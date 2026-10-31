// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <llvm/Support/ErrorHandling.h>
#include <string>
#include <variant>

#include "Progmasoft/Tala/Interactive/Session.hpp"

extern "C" int
LLVMFuzzerTestOneInput(const std::uint8_t *data, std::size_t size)
{
    namespace Repl = Progmasoft::Tala::Interactive;
    Repl::Session session;
    std::int64_t expected{};
    bool hasPrevious{};
    const auto initial = session.Evaluate("return 0;");
    if (initial.status != Repl::CellStatus::Value)
        llvm::report_fatal_error(
            "REPL fuzz runtime could not evaluate its valid initial cell");
    hasPrevious = true;
    for (std::size_t index = 0U; index < std::min(size, std::size_t{ 8U });
         ++index)
    {
        const auto selector = data[index];
        if (selector % 5U == 0U)
        {
            if (session.Reset() || !session.History().empty())
                llvm::report_fatal_error(
                    "REPL reset retained failed resources or history");
            hasPrevious = false;
            expected = 0;
            continue;
        }
        if (selector % 5U == 1U)
        {
            const auto history = session.History();
            if (session.Evaluate("return MissingFuzzName;").status
                    != Repl::CellStatus::Error
                || session.History() != history)
                llvm::report_fatal_error(
                    "REPL failed-cell rollback changed history");
            continue;
        }
        const auto increment = static_cast<std::int64_t>(selector % 11U);
        const auto expression = std::string("return ")
                                + (hasPrevious ? "taliPrevious + " : "")
                                + std::to_string(increment) + ";";
        const auto history = session.History();
        if (session.TypeOf(expression).status != Repl::CellStatus::Type
            || session.History() != history)
            llvm::report_fatal_error("REPL type query mutated session state");
        expected += increment;
        const auto value = session.Evaluate(expression);
        const auto *integer
            = value.value ? std::get_if<std::int64_t>(&value.value->payload)
                          : nullptr;
        if (value.status != Repl::CellStatus::Value || integer == nullptr
            || *integer != expected)
            llvm::report_fatal_error("persistent REPL session disagrees with "
                                     "independent arithmetic state");
        hasPrevious = true;
    }
    if (session.Reset())
        llvm::report_fatal_error("REPL fuzz resource teardown failed");
    return 0;
}
