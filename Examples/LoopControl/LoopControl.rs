// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

fn main() {
    let mut total = 0;
    let mut value = 0;
    while value < 10 {
        value += 1;
        if value == 3 {
            continue;
        }
        if value == 8 {
            break;
        }
        total += value;
    }

    let mut countdown = 3;
    loop {
        countdown -= 1;
        if countdown == 1 {
            continue;
        }
        if countdown == 0 {
            break;
        }
        total += countdown;
    }

    for item in 0..5 {
        total += item;
    }
    println!("total={total}");
}
