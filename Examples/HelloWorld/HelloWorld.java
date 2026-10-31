// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

public final class HelloWorld {
    private HelloWorld() {}

    public static void main(String[] args) {
        var language = "Java 21";
        System.out.printf("Hello from %s!%n", language);
    }
}
