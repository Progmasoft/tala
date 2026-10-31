// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package Examples.MatrixTranspose;

public final class MatrixTranspose {
    private MatrixTranspose() {}

    public static void main(String[] args) {
        final int rows = 2;
        final int columns = 3;
        final int[] matrix = {1, 2, 3, 4, 5, 6};
        for (int outputRow = 0; outputRow < columns; outputRow++) {
            for (int outputColumn = 0; outputColumn < rows; outputColumn++) {
                int sourceIndex = outputColumn * columns + outputRow;
                System.out.printf("%d ", matrix[sourceIndex]);
            }
            System.out.println();
        }
    }
}
