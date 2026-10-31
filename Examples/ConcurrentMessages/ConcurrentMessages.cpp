// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <condition_variable>
#include <iostream>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <utility>

class Channel
{
public:
    void
    Send(std::string value)
    {
        {
            std::lock_guard lock(mutex_);
            values_.push(std::move(value));
        }
        ready_.notify_one();
    }

    std::string
    Receive()
    {
        std::unique_lock lock(mutex_);
        ready_.wait(lock, [this] {
            return !values_.empty();
        });
        auto value = std::move(values_.front());
        values_.pop();
        return value;
    }

private:
    std::mutex mutex_;
    std::condition_variable ready_;
    std::queue<std::string> values_;
};

int
main()
{
    Channel channel;
    std::jthread lexer([&channel] {
        channel.Send("Lexer finished");
    });
    std::jthread parser([&channel] {
        channel.Send("Parser finished");
    });
    std::cout << channel.Receive() << '\n';
    std::cout << channel.Receive() << '\n';
}
