// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

use std::f64::consts::PI;

enum Shape {
    Circle { radius: f64 },
    Rectangle { width: f64, height: f64 },
    Square { side: f64 },
}

impl Shape {
    fn area(&self) -> f64 {
        match self {
            Self::Circle { radius } => PI * radius * radius,
            Self::Rectangle { width, height } => width * height,
            Self::Square { side } => side * side,
        }
    }
}

fn main() {
    let shapes = [
        Shape::Circle { radius: 2.0 },
        Shape::Rectangle {
            width: 3.0,
            height: 4.0,
        },
        Shape::Square { side: 5.0 },
    ];
    for shape in &shapes {
        println!("area={:.2}", shape.area());
    }
}
