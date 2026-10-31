// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

import java.util.ArrayList;
import java.util.List;

public final class GenericStack {
    private GenericStack() {}

    private static final class Stack<T> {
        private final List<T> items = new ArrayList<>();

        void push(T value) { items.add(value); }
        T peek() { return items.getLast(); }
        T pop() { return items.removeLast(); }
        int count() { return items.size(); }
    }

    public static void main(String[] args) {
        var names = new Stack<String>();
        names.push("Lexer");
        names.push("Parser");
        names.push("Core");
        System.out.println(names.peek());
        while (names.count() > 0) {
            System.out.println(names.pop());
        }
    }
}
