// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <fmt/format.h>

namespace Examples::PrimeNumbers
{

    class PrimeNumbers
    {
        static bool
        IsPrime(int candidate)
        {
            if (candidate < 2)
                return false;
            for (int divisor = 2; divisor * divisor <= candidate; ++divisor)
            {
                if (candidate % divisor == 0)
                    return false;
            }
            return true;
        }

    public:
        static void
        Main()
        {
            for (int candidate = 2; candidate <= 50; ++candidate)
            {
                if (IsPrime(candidate))
                    fmt::println("{}", candidate);
            }
        }
    };

} // namespace Examples::PrimeNumbers

int
main()
{
    Examples::PrimeNumbers::PrimeNumbers::Main();
}
