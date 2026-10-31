// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

import java.util.concurrent.LinkedBlockingQueue;

public final class ConcurrentMessages {
    private ConcurrentMessages() {}

    public static void main(String[] args) throws InterruptedException {
        var channel = new LinkedBlockingQueue<String>();
        var lexer = Thread.ofVirtual().start(() -> channel.add("Lexer finished"));
        var parser = Thread.ofVirtual().start(() -> channel.add("Parser finished"));
        System.out.println(channel.take());
        System.out.println(channel.take());
        lexer.join();
        parser.join();
    }
}
