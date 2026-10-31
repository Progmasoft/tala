// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <iostream>
#include <ranges>

int
main()
{
    for (const int number : std::views::iota(1, 31))
    {
        if (number % 15 == 0)
        {
            std::cout << "FizzBuzz\n";
        }
        else if (number % 3 == 0)
        {
            std::cout << "Fizz\n";
        }
        else if (number % 5 == 0)
        {
            std::cout << "Buzz\n";
        }
        else
        {
            std::cout << number << '\n';
        }
    }
}
