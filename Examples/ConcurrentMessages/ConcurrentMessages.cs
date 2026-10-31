// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

using System;
using System.Threading.Tasks;
using System.Threading.Channels;

namespace Examples.ConcurrentMessages;

public static class ConcurrentMessages
{
    public static async Task Main()
    {
        var channel = Channel.CreateUnbounded<string>();
        var lexer = Task.Run(() => channel.Writer.WriteAsync("Lexer finished").AsTask());
        var parser = Task.Run(() => channel.Writer.WriteAsync("Parser finished").AsTask());

        Console.WriteLine(await channel.Reader.ReadAsync());
        Console.WriteLine(await channel.Reader.ReadAsync());
        await Task.WhenAll(lexer, parser);
    }
}
