// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

namespace Examples.MatrixTranspose;

public static class MatrixTranspose
{
    public static void Main()
    {
        const int rows = 2;
        const int columns = 3;
        int[] matrix = [1, 2, 3, 4, 5, 6];
        for (var outputRow = 0; outputRow < columns; outputRow++)
        {
            for (var outputColumn = 0; outputColumn < rows; outputColumn++)
            {
                var sourceIndex = outputColumn * columns + outputRow;
                Console.Write($"{matrix[sourceIndex]} ");
            }
            Console.WriteLine();
        }
    }
}
