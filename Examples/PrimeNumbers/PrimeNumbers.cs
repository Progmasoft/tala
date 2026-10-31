// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

namespace Examples.PrimeNumbers;

public static class PrimeNumbers
{
    private static bool IsPrime(int candidate)
    {
        if (candidate < 2) return false;
        for (var divisor = 2; divisor * divisor <= candidate; divisor++)
            if (candidate % divisor == 0) return false;
        return true;
    }

    public static void Main()
    {
        for (var candidate = 2; candidate <= 50; candidate++)
            if (IsPrime(candidate)) Console.WriteLine(candidate);
    }
}
