// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

public final class FileRoundTrip {
    private FileRoundTrip() {}

    public static void main(String[] args) throws IOException {
        var path = Path.of("tala-example.txt");
        var expected = "Lexer -> Parser -> Core -> Xpp -> Xmm";
        Files.writeString(path, expected);
        var actual = Files.readString(path);
        System.out.println(actual);
        System.out.printf("Round trip preserved content: %b%n", actual.equals(expected));
    }
}
