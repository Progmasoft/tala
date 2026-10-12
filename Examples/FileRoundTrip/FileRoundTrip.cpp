// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <string_view>

int
main()
{
    constexpr std::string_view path = "tala-example.txt";
    constexpr std::string_view expected
        = "Lexer -> Parser -> Core -> Xpp -> Xmm";
    {
        std::ofstream output(path.data(), std::ios::binary);
        output << expected;
    }
    std::ifstream input(path.data(), std::ios::binary);
    const std::string actual(std::istreambuf_iterator<char>{ input }, {});
    std::cout << actual << '\n';
    std::cout << "Round trip preserved content: " << std::boolalpha
              << (actual == expected) << '\n';
}
