// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#[derive(Debug, Default)]
struct Stack<T> {
    values: Vec<T>,
}

impl<T> Stack<T> {
    fn push(&mut self, value: T) {
        self.values.push(value);
    }

    fn pop(&mut self) -> Option<T> {
        self.values.pop()
    }

    fn is_empty(&self) -> bool {
        self.values.is_empty()
    }
}

fn main() {
    let mut stack = Stack::default();
    for value in ["first", "second", "third"] {
        stack.push(value);
    }
    while let Some(value) = stack.pop() {
        println!("{value}");
    }
    assert!(stack.is_empty());
}
