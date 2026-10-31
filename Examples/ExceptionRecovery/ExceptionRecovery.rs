// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

fn parse_measurement(text: &str) -> Result<i64, &'static str> {
    let value = text.parse::<i64>().map_err(|_| "not an integer")?;
    if value < 0 {
        return Err("measurement cannot be negative");
    }
    Ok(value)
}

fn main() {
    let records = ["12", "bad", "7", "-4", "19"];
    let mut accepted_total = 0_i64;
    let mut rejected = 0;

    for record in records {
        match parse_measurement(record) {
            Ok(value) => accepted_total += value,
            Err(reason) => {
                rejected += 1;
                eprintln!("skipping {record:?}: {reason}");
            }
        }
    }
    println!("accepted_total={accepted_total} rejected={rejected}");
}
