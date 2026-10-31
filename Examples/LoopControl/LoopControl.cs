// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

namespace Examples.LoopControl;

public static class LoopControl
{
    public static void Main()
    {
        var total = 0;
        var value = 0;
        while (value < 9)
        {
            value++;
            if (value == 2) continue;
            if (value == 8) break;
            total += value;
        }

        var countdown = 3;
        do
        {
            total += countdown--;
        } while (countdown > 0);

        for (var index = 0; index < 4; index++) total += index;
        Console.WriteLine($"loop total: {total}");
    }
}
