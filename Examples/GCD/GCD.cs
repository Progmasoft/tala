// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

namespace Examples.GCD;

public static class GCD
{
    public static int Compute(int left, int right)
    {
        var a = left;
        var b = right;
        while (b != 0)
        {
            var remainder = a % b;
            a = b;
            b = remainder;
        }
        return a;
    }

    public static void Main() => Console.WriteLine($"gcd(1071, 462) = {Compute(1071, 462)}");
}
