// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

fn main() {
    const MAX_STEPS: usize = 128;
    let mut value = 27_u64;
    let mut trace = vec![value];

    for _ in 0..MAX_STEPS {
        if value == 1 {
            break;
        }
        value = if value % 2 == 0 {
            value / 2
        } else {
            value
                .checked_mul(3)
                .and_then(|next| next.checked_add(1))
                .unwrap_or(0)
        };
        if value == 0 {
            eprintln!("sequence overflowed; stopping safely");
            break;
        }
        trace.push(value);
    }

    println!(
        "{}",
        trace
            .iter()
            .map(u64::to_string)
            .collect::<Vec<_>>()
            .join(" -> ")
    );
    if value != 1 {
        eprintln!("sequence did not reach one within {MAX_STEPS} steps");
    }
}
