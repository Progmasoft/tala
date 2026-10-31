// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <array>
#include <iostream>
#include <stdexcept>

int
RequirePositive(const int value)
{
    if (value <= 0)
    {
        throw std::invalid_argument("value must be positive");
    }
    return value;
}

int
main()
{
    constexpr std::array inputs = { 3, 0, 7 };
    for (const int input : inputs)
    {
        try
        {
            std::cout << RequirePositive(input) << '\n';
        }
        catch (const std::invalid_argument &error)
        {
            std::cerr << error.what() << '\n';
        }
    }
}
