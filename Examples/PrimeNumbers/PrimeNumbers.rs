// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

fn is_prime(candidate: u64) -> bool {
    if candidate < 2 {
        return false;
    }
    let mut divisor = 2;
    while divisor <= candidate / divisor {
        if candidate % divisor == 0 {
            return false;
        }
        divisor += 1;
    }
    true
}

fn main() {
    const LIMIT: u64 = 100;
    let primes = (2..=LIMIT)
        .filter(|value| is_prime(*value))
        .map(|value| value.to_string())
        .collect::<Vec<_>>();
    println!("{}", primes.join(", "));
}
