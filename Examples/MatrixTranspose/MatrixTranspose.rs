// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

fn main() {
    let (rows, columns) = (2, 3);
    let matrix = [1, 2, 3, 4, 5, 6];
    let mut transposed = vec![0; matrix.len()];

    for row in 0..rows {
        for column in 0..columns {
            transposed[column * rows + row] = matrix[row * columns + column];
        }
    }

    for row in 0..columns {
        let start = row * rows;
        println!("{:?}", &transposed[start..start + rows]);
    }
}
