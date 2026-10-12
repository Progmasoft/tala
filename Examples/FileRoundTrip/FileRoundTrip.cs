// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

using System;
using System.IO;

namespace Examples.FileRoundTrip;

public static class FileRoundTrip
{
    public static void Main()
    {
        const string path = "tala-example.txt";
        const string expected = "Lexer -> Parser -> Core -> Xpp -> Xmm";
        File.WriteAllText(path, expected);
        var actual = File.ReadAllText(path);
        Console.WriteLine(actual);
        Console.WriteLine($"Round trip preserved content: {actual == expected}");
    }
}
