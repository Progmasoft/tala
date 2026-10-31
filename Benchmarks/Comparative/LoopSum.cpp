// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <charconv>
#include <cstdint>
#include <iostream>
#include <string_view>

namespace Benchmarks::Comparative
{

    constexpr std::int64_t kDefaultLimit = 50'000'000;
    constexpr std::int64_t kMaximumSafeLimit = 4'294'967'295;

    // Keep one dependent accumulator as the simple baseline loop.
    [[nodiscard]] auto
    SumBaseline(std::int64_t limit) -> std::int64_t
    {
        std::int64_t total = 0;
        for (std::int64_t value = 1; value <= limit; ++value)
        {
            total += value;
        }
        return total;
    }

    // Independent accumulators shorten the dependency chain while preserving
    // order.
    [[nodiscard]] auto
    SumUnrolled(std::int64_t limit) -> std::int64_t
    {
        std::int64_t first = 0;
        std::int64_t second = 0;
        std::int64_t third = 0;
        std::int64_t fourth = 0;
        std::int64_t value = 1;
        while (value + 3 <= limit)
        {
            first += value;
            second += value + 1;
            third += value + 2;
            fourth += value + 3;
            value += 4;
        }
        while (value <= limit)
        {
            first += value;
            ++value;
        }
        return first + second + third + fourth;
    }

    // Halving the even factor before multiplication keeps the triangular sum
    // exact throughout the full range whose result fits in a signed 64-bit
    // value.
    [[nodiscard]] auto
    SumFormula(std::int64_t limit) -> std::int64_t
    {
        if (limit % 2 == 0)
        {
            return (limit / 2) * (limit + 1);
        }
        return limit * ((limit + 1) / 2);
    }

} // namespace Benchmarks::Comparative

int
main(int argc, char **argv)
{
    std::int64_t limit = Benchmarks::Comparative::kDefaultLimit;
    auto algorithm = std::string_view("baseline");
    if (argc > 1 && std::string_view(argv[1]) != "baseline"
        && std::string_view(argv[1]) != "unrolled"
        && std::string_view(argv[1]) != "formula")
    {
        std::cerr << "usage: loop-sum [baseline|unrolled|formula] [count: "
                     "1..4294967295]\n";
        return 2;
    }
    if (argc > 1)
        algorithm = argv[1];
    if (argc > 2)
    {
        const std::string_view text(argv[2]);
        const auto parsed
            = std::from_chars(text.data(), text.data() + text.size(), limit);
        if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()
            || limit <= 0 || limit > Benchmarks::Comparative::kMaximumSafeLimit)
        {
            std::cerr << "count must be in the range 1..4294967295\n";
            return 2;
        }
    }
    if (argc > 3)
    {
        std::cerr << "too many arguments\n";
        return 2;
    }

    const auto checksum = algorithm == "baseline"
                              ? Benchmarks::Comparative::SumBaseline(limit)
                          : algorithm == "unrolled"
                              ? Benchmarks::Comparative::SumUnrolled(limit)
                              : Benchmarks::Comparative::SumFormula(limit);
    std::cout << "algorithm=" << algorithm << " count=" << limit
              << " checksum=" << checksum << '\n';
}
