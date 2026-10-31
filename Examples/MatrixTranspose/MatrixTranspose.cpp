// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <array>
#include <fmt/format.h>

namespace Examples::MatrixTranspose
{

    class MatrixTranspose
    {
    public:
        static void
        Main()
        {
            constexpr int rows = 2;
            constexpr int columns = 3;
            constexpr std::array matrix{ 1, 2, 3, 4, 5, 6 };
            for (int outputRow = 0; outputRow < columns; ++outputRow)
            {
                for (int outputColumn = 0; outputColumn < rows; ++outputColumn)
                {
                    const int sourceIndex = outputColumn * columns + outputRow;
                    fmt::print("{} ",
                               matrix[static_cast<std::size_t>(sourceIndex)]);
                }
                fmt::println("");
            }
        }
    };

} // namespace Examples::MatrixTranspose

int
main()
{
    Examples::MatrixTranspose::MatrixTranspose::Main();
}
