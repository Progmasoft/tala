// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

public final class ExceptionRecovery {
    private ExceptionRecovery() {}

    private static int requirePositive(int value) {
        if (value <= 0) {
            throw new IllegalArgumentException("value must be positive");
        }
        return value;
    }

    public static void main(String[] args) {
        int[] inputs = {3, 0, 7};
        for (var input : inputs) {
            try {
                System.out.println(requirePositive(input));
            } catch (IllegalArgumentException error) {
                System.err.println(error.getMessage());
            }
        }
    }
}
