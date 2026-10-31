// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

using System;

namespace Examples.BankAccount;

public sealed class Account(string owner, decimal openingBalance)
{
    public string Owner { get; } = owner;
    public decimal Balance { get; private set; } = openingBalance;

    public void Deposit(decimal amount) => Balance += amount;

    public bool Withdraw(decimal amount)
    {
        if (amount > Balance)
        {
            return false;
        }
        Balance -= amount;
        return true;
    }
}

public static class BankAccount
{
    public static void Main()
    {
        var account = new Account("Ada", 250m);
        account.Deposit(75m);
        account.Withdraw(40m);
        Console.WriteLine($"{account.Owner}: {account.Balance}");
    }
}
