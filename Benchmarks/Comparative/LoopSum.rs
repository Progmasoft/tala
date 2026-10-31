// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

use std::error::Error;
use std::hint::black_box;

const DEFAULT_LIMIT: i64 = 50_000_000;
const MAXIMUM_SAFE_LIMIT: i64 = 4_294_967_295;

fn sum_baseline(limit: i64) -> i64 {
    let limit = black_box(limit);
    let mut total = 0_i64;
    for value in 1..=limit {
        total += value;
    }
    black_box(total)
}

fn sum_unrolled(limit: i64) -> i64 {
    let limit = black_box(limit);
    let (mut first, mut second, mut third, mut fourth) = (0_i64, 0_i64, 0_i64, 0_i64);
    let mut value = 1_i64;
    while value <= limit - 3 {
        first += value;
        second += value + 1;
        third += value + 2;
        fourth += value + 3;
        value += 4;
    }
    let mut tail = 0_i64;
    while value <= limit {
        tail += value;
        value += 1;
    }
    black_box(first + second + third + fourth + tail)
}

// This is an algorithmic upper bound, not a loop-codegen comparison.
fn sum_formula(limit: i64) -> i64 {
    if limit % 2 == 0 {
        (limit / 2) * (limit + 1)
    } else {
        limit * ((limit + 1) / 2)
    }
}

fn main() -> Result<(), Box<dyn Error>> {
    let arguments = std::env::args().skip(1).collect::<Vec<_>>();
    if arguments.len() > 2 {
        return Err(
            "usage: loop-sum-rust [baseline|unrolled|formula] [count: 1..4294967295]".into(),
        );
    }
    let algorithm = arguments.first().map(String::as_str).unwrap_or("baseline");
    let limit = arguments
        .get(1)
        .map(|value| value.parse::<i64>())
        .transpose()?
        .unwrap_or(DEFAULT_LIMIT);
    if !(1..=MAXIMUM_SAFE_LIMIT).contains(&limit) {
        return Err("count must be in the range 1..4294967295".into());
    }

    let checksum = match algorithm {
        "baseline" => sum_baseline(limit),
        "unrolled" => sum_unrolled(limit),
        "formula" => sum_formula(limit),
        _ => return Err("unknown algorithm; choose baseline, unrolled, or formula".into()),
    };
    println!("algorithm={algorithm} count={limit} checksum={checksum}");
    Ok(())
}
