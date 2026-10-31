// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

using System;
using System.Collections.Generic;

namespace Examples.GenericStack;

public sealed class Stack<T>
{
    private readonly List<T> items = [];

    public int Count => items.Count;
    public void Push(T value) => items.Add(value);
    public T Peek() => items[^1];

    public T Pop()
    {
        var value = items[^1];
        items.RemoveAt(items.Count - 1);
        return value;
    }
}

public static class GenericStack
{
    public static void Main()
    {
        var names = new Stack<string>();
        names.Push("Lexer");
        names.Push("Parser");
        names.Push("Core");
        Console.WriteLine(names.Peek());
        while (names.Count > 0)
        {
            Console.WriteLine(names.Pop());
        }
    }
}
