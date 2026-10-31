// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <fmt/format.h>

namespace Examples::GCD
{

    class GCD
    {
    public:
        static int
        Compute(int left, int right)
        {
            int a = left;
            int b = right;
            while (b != 0)
            {
                const int remainder = a % b;
                a = b;
                b = remainder;
            }
            return a;
        }

        static void
        Main()
        {
            fmt::println("gcd(1071, 462) = {}", Compute(1071, 462));
        }
    };

} // namespace Examples::GCD

int
main()
{
    Examples::GCD::GCD::Main();
}
