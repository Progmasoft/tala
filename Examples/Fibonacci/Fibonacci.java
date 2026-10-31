// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

import java.util.ArrayList;
import java.util.List;

public final class Fibonacci {
    private Fibonacci() {}

    private static List<Long> generate(int count) {
        var values = new ArrayList<Long>(count);
        long previous = 0;
        long current = 1;
        for (var index = 0; index < count; ++index) {
            values.add(previous);
            var next = previous + current;
            previous = current;
            current = next;
        }
        return List.copyOf(values);
    }

    public static void main(String[] args) {
        generate(12).forEach(System.out::println);
    }
}
