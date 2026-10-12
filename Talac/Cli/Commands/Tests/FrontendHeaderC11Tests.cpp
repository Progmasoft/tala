// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>

extern "C" int
tala_frontend_header_c11_contract(void);

TEST_CASE("frontend ABI header remains valid C11")
{
    CHECK(tala_frontend_header_c11_contract() == 0);
}
