// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

using System;
using System.Collections.Generic;

namespace Examples.Fibonacci;

public static class Fibonacci
{
    private static IEnumerable<long> Generate(int count)
    {
        long previous = 0;
        long current = 1;

        for (var index = 0; index < count; ++index)
        {
            yield return previous;
            (previous, current) = (current, previous + current);
        }
    }

    public static void Main()
    {
        foreach (var value in Generate(12))
        {
            Console.WriteLine(value);
        }
    }
}
