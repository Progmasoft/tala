// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

public final class BankAccount {
    private BankAccount() {}

    private static final class Account {
        private final String owner;
        private long balance;

        Account(String owner, long openingBalance) {
            this.owner = owner;
            this.balance = openingBalance;
        }

        void deposit(long amount) {
            balance += amount;
        }

        boolean withdraw(long amount) {
            if (amount > balance) {
                return false;
            }
            balance -= amount;
            return true;
        }

        void print() {
            System.out.printf("%s: %d%n", owner, balance);
        }
    }

    public static void main(String[] args) {
        var account = new Account("Ada", 250);
        account.deposit(75);
        account.withdraw(40);
        account.print();
    }
}
