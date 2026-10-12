// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

using System;
using System.Collections.Generic;
using System.Linq;

namespace Examples.WordFrequency;

public static class WordFrequency
{
    public static void Main()
    {
        string[] words = ["visual", "tala", "visual", "compiler", "tala", "visual"];
        Dictionary<string, int> counts = [];

        foreach (var word in words)
        {
            counts[word] = counts.GetValueOrDefault(word) + 1;
        }

        foreach (var (word, count) in counts.OrderBy(pair => pair.Key))
        {
            Console.WriteLine($"{word}: {count}");
        }
    }
}
