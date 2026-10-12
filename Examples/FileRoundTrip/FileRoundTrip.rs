// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

use std::error::Error;
use std::fs;

fn main() -> Result<(), Box<dyn Error>> {
    let path = std::env::temp_dir().join("tala-roundtrip.txt");
    let expected = "Tala round-trip: Καλημέρα, 世界";

    fs::write(&path, expected)?;
    let actual = fs::read_to_string(&path)?;
    fs::remove_file(&path)?;

    if actual != expected {
        return Err("read-back content does not match the input".into());
    }
    println!("{}", actual);
    Ok(())
}
