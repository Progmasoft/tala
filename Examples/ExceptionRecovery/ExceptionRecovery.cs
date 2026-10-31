// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

using System;

namespace Examples.ExceptionRecovery;

public static class ExceptionRecovery
{
    private static int RequirePositive(int value) => value > 0
        ? value
        : throw new ArgumentOutOfRangeException(nameof(value), "value must be positive");

    public static void Main()
    {
        int[] inputs = [3, 0, 7];
        foreach (var input in inputs)
        {
            try
            {
                Console.WriteLine(RequirePositive(input));
            }
            catch (ArgumentOutOfRangeException error)
            {
                Console.Error.WriteLine(error.Message);
            }
        }
    }
}
