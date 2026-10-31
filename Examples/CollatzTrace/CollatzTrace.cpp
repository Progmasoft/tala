// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <fmt/format.h>

namespace Examples::CollatzTrace
{

    class CollatzTrace
    {
    public:
        static void
        Main()
        {
            int value = 19;
            int steps = 0;
            fmt::print("{}", value);
            while (value != 1 && steps < 100)
            {
                value = value % 2 == 0 ? value / 2 : value * 3 + 1;
                fmt::print(" -> {}", value);
                ++steps;
            }
            fmt::println("\nsteps: {}", steps);
        }
    };

} // namespace Examples::CollatzTrace

int
main()
{
    Examples::CollatzTrace::CollatzTrace::Main();
}
