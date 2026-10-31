// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#[derive(Debug)]
struct BankAccount {
    owner: String,
    balance: i64,
}

impl BankAccount {
    fn new(owner: impl Into<String>, opening_balance: i64) -> Result<Self, &'static str> {
        if opening_balance < 0 {
            return Err("opening balance cannot be negative");
        }
        Ok(Self {
            owner: owner.into(),
            balance: opening_balance,
        })
    }

    fn deposit(&mut self, amount: i64) -> Result<(), &'static str> {
        if amount <= 0 {
            return Err("deposit must be positive");
        }
        self.balance = self.balance.checked_add(amount).ok_or("balance overflow")?;
        Ok(())
    }

    fn withdraw(&mut self, amount: i64) -> Result<(), &'static str> {
        if amount <= 0 || amount > self.balance {
            return Err("withdrawal is invalid or exceeds the balance");
        }
        self.balance -= amount;
        Ok(())
    }
}

fn main() -> Result<(), &'static str> {
    let mut account = BankAccount::new("Ada", 100)?;
    account.deposit(50)?;
    account.withdraw(35)?;
    println!("{} has {} credits", account.owner, account.balance);
    Ok(())
}
