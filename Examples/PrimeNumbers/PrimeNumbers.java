// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package Examples.PrimeNumbers;

public final class PrimeNumbers {
    private PrimeNumbers() {}

    private static boolean isPrime(int candidate) {
        if (candidate < 2) return false;
        for (int divisor = 2; divisor * divisor <= candidate; divisor++) {
            if (candidate % divisor == 0) return false;
        }
        return true;
    }

    public static void main(String[] args) {
        for (int candidate = 2; candidate <= 50; candidate++) {
            if (isPrime(candidate)) System.out.println(candidate);
        }
    }
}
