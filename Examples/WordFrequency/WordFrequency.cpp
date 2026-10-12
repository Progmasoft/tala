// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <array>
#include <iostream>
#include <map>
#include <string>

int
main()
{
    constexpr std::array words
        = { "visual", "tala", "visual", "compiler", "tala", "visual" };
    std::map<std::string, int> counts;
    for (const auto *word : words)
    {
        ++counts[word];
    }
    for (const auto &[word, count] : counts)
    {
        std::cout << word << ": " << count << '\n';
    }
}
