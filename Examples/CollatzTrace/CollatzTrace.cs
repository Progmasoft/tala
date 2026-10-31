// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

namespace Examples.CollatzTrace;

public static class CollatzTrace
{
    public static void Main()
    {
        var value = 19;
        var steps = 0;
        Console.Write(value);
        while (value != 1 && steps < 100)
        {
            value = value % 2 == 0 ? value / 2 : value * 3 + 1;
            Console.Write($" -> {value}");
            steps++;
        }
        Console.WriteLine();
        Console.WriteLine($"steps: {steps}");
    }
}
