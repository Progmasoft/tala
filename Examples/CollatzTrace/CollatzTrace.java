// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

package Examples.CollatzTrace;

public final class CollatzTrace {
    private CollatzTrace() {}

    public static void main(String[] args) {
        int value = 19;
        int steps = 0;
        System.out.print(value);
        while (value != 1 && steps < 100) {
            value = value % 2 == 0 ? value / 2 : value * 3 + 1;
            System.out.print(" -> " + value);
            steps++;
        }
        System.out.printf("%nsteps: %d%n", steps);
    }
}
