// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <iostream>
#include <string>
#include <utility>

class Account
{
public:
    Account(std::string owner, const int openingBalance)
        : owner_(std::move(owner))
        , balance_(openingBalance)
    {}

    void
    Deposit(const int amount)
    {
        balance_ += amount;
    }

    bool
    Withdraw(const int amount)
    {
        if (amount > balance_)
        {
            return false;
        }
        balance_ -= amount;
        return true;
    }

    void
    Print() const
    {
        std::cout << owner_ << ": " << balance_ << '\n';
    }

private:
    std::string owner_;
    int balance_;
};

int
main()
{
    Account account("Ada", 250);
    account.Deposit(75);
    account.Withdraw(40);
    account.Print();
}
