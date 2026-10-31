// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <array>
#include <iostream>
#include <numbers>
#include <type_traits>
#include <variant>

struct Circle
{
    double radius;
};

struct Rectangle
{
    double width;
    double height;
};

using Shape = std::variant<Circle, Rectangle>;

double
Area(const Shape &shape)
{
    return std::visit(
        [](const auto &value) {
            using T = std::decay_t<decltype(value)>;
            if constexpr (std::is_same_v<T, Circle>)
            {
                return std::numbers::pi * value.radius * value.radius;
            }
            else
            {
                return value.width * value.height;
            }
        },
        shape);
}

int
main()
{
    const std::array<Shape, 2> shapes
        = { Circle{ 3.0 }, Rectangle{ 4.0, 5.0 } };
    for (const auto &shape : shapes)
    {
        std::cout << Area(shape) << '\n';
    }
}
