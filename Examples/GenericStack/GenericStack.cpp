// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <iostream>
#include <string>
#include <utility>
#include <vector>

template<typename T>
class Stack
{
public:
    void
    Push(T value)
    {
        items_.push_back(std::move(value));
    }
    const T &
    Peek() const
    {
        return items_.back();
    }

    T
    Pop()
    {
        T value = std::move(items_.back());
        items_.pop_back();
        return value;
    }

    std::size_t
    Count() const
    {
        return items_.size();
    }

private:
    std::vector<T> items_;
};

int
main()
{
    Stack<std::string> names;
    names.Push("Lexer");
    names.Push("Parser");
    names.Push("Core");
    std::cout << names.Peek() << '\n';
    while (names.Count() > 0)
    {
        std::cout << names.Pop() << '\n';
    }
}
