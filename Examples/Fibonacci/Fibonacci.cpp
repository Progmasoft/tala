// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <cstdint>
#include <iostream>
#include <vector>

std::vector<std::int64_t>
Generate(const int count)
{
    std::vector<std::int64_t> values;
    values.reserve(static_cast<std::size_t>(count));
    std::int64_t previous = 0;
    std::int64_t current = 1;

    for (int index = 0; index < count; ++index)
    {
        values.push_back(previous);
        const auto next = previous + current;
        previous = current;
        current = next;
    }
    return values;
}

int
main()
{
    for (const auto value : Generate(12))
    {
        std::cout << value << '\n';
    }
}
