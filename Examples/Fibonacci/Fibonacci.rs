// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

struct Fibonacci {
    current: u64,
    next: u64,
}

impl Fibonacci {
    fn new() -> Self {
        Self {
            current: 0,
            next: 1,
        }
    }
}

impl Iterator for Fibonacci {
    type Item = u64;

    fn next(&mut self) -> Option<Self::Item> {
        let value = self.current;
        (self.current, self.next) = (self.next, self.current + self.next);
        Some(value)
    }
}

fn main() {
    let values = Fibonacci::new()
        .take(12)
        .map(|value| value.to_string())
        .collect::<Vec<_>>();
    println!("{}", values.join(", "));
}
