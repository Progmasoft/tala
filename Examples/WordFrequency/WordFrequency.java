// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

import java.util.List;
import java.util.TreeMap;

public final class WordFrequency {
    private WordFrequency() {}

    public static void main(String[] args) {
        var words = List.of("visual", "tala", "visual", "compiler", "tala", "visual");
        var counts = new TreeMap<String, Integer>();
        words.forEach(word -> counts.merge(word, 1, Integer::sum));
        counts.forEach((word, count) -> System.out.printf("%s: %d%n", word, count));
    }
}
