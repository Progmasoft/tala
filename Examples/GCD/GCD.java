// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package Examples.GCD;

public final class GCD {
    private GCD() {}

    public static int compute(int left, int right) {
        int a = left;
        int b = right;
        while (b != 0) {
            int remainder = a % b;
            a = b;
            b = remainder;
        }
        return a;
    }

    public static void main(String[] args) {
        System.out.printf("gcd(1071, 462) = %d%n", compute(1071, 462));
    }
}
