// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

public final class ShapeAreas {
    private ShapeAreas() {}

    private sealed interface Shape permits Circle, Rectangle {}
    private record Circle(double radius) implements Shape {}
    private record Rectangle(double width, double height) implements Shape {}

    private static double area(Shape shape) {
        return switch (shape) {
            case Circle circle -> Math.PI * circle.radius() * circle.radius();
            case Rectangle rectangle -> rectangle.width() * rectangle.height();
        };
    }

    public static void main(String[] args) {
        Shape[] shapes = {new Circle(3), new Rectangle(4, 5)};
        for (var shape : shapes) {
            System.out.printf("%.2f%n", area(shape));
        }
    }
}
