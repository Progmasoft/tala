// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

fn main() {
    for value in 1..=100 {
        let output = match (value % 3, value % 5) {
            (0, 0) => "FizzBuzz".to_owned(),
            (0, _) => "Fizz".to_owned(),
            (_, 0) => "Buzz".to_owned(),
            _ => value.to_string(),
        };
        println!("{output}");
    }
}
