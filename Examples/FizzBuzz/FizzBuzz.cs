// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

using System;
using System.Linq;

namespace Examples.FizzBuzz;

public static class FizzBuzz
{
    public static void Main()
    {
        foreach (var number in Enumerable.Range(1, 30))
        {
            Console.WriteLine(number switch
            {
                _ when number % 15 == 0 => "FizzBuzz",
                _ when number % 3 == 0 => "Fizz",
                _ when number % 5 == 0 => "Buzz",
                _ => number.ToString(),
            });
        }
    }
}
