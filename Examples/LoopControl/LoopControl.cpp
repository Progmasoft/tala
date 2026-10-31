// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <fmt/format.h>

namespace Examples::LoopControl
{

    class LoopControl
    {
    public:
        static void
        Main()
        {
            int total = 0;
            int value = 0;
            while (value < 9)
            {
                ++value;
                if (value == 2)
                    continue;
                if (value == 8)
                    break;
                total += value;
            }

            int countdown = 3;
            do
            {
                total += countdown--;
            } while (countdown > 0);

            for (int index = 0; index < 4; ++index)
                total += index;
            fmt::println("loop total: {}", total);
        }
    };

} // namespace Examples::LoopControl

int
main()
{
    Examples::LoopControl::LoopControl::Main();
}
