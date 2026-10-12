// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>

#include "Talac/Cli/Commands/ExecutionStatus.hpp"

namespace Status = Progmasoft::Tala::Cli::ExecutionStatus;

TEST_CASE("source command status separates compilation from execution")
{
    CHECK(Status::Resolve({ false, std::nullopt }) == 1);
    CHECK(Status::Resolve({ true, std::nullopt }) == 0);
    CHECK(Status::Resolve({ true, 0 }) == 0);
}

TEST_CASE("source command status preserves the native program result")
{
    CHECK(Status::Resolve({ true, 1 }) == 1);
    CHECK(Status::Resolve({ true, 37 }) == 37);
    CHECK(Status::Resolve({ true, 255 }) == 255);
}
