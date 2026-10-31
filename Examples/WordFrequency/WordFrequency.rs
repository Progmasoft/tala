// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

use std::collections::BTreeMap;

fn main() {
    let text = "Ownership makes sharing explicit; ownership makes values safe.";
    let mut frequencies = BTreeMap::<String, usize>::new();

    for word in text.split_whitespace() {
        let normalized = word
            .trim_matches(|character: char| !character.is_alphanumeric())
            .to_lowercase();
        if !normalized.is_empty() {
            *frequencies.entry(normalized).or_default() += 1;
        }
    }

    for (word, count) in frequencies {
        println!("{word}: {count}");
    }
}
