// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <iostream>
#include <string_view>

int
main()
{
    constexpr std::string_view language = "C++20";
    std::cout << "Hello from " << language << "!\n";
}
