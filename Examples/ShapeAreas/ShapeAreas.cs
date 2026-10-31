// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

using System;

namespace Examples.ShapeAreas;

public abstract record Shape;
public sealed record Circle(double Radius) : Shape;
public sealed record Rectangle(double Width, double Height) : Shape;

public static class ShapeAreas
{
    private static double Area(Shape shape) => shape switch
    {
        Circle circle => Math.PI * circle.Radius * circle.Radius,
        Rectangle rectangle => rectangle.Width * rectangle.Height,
        _ => throw new ArgumentOutOfRangeException(nameof(shape)),
    };

    public static void Main()
    {
        Shape[] shapes = [new Circle(3), new Rectangle(4, 5)];
        foreach (var shape in shapes)
        {
            Console.WriteLine($"{Area(shape):F2}");
        }
    }
}
