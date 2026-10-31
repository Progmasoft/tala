// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

use std::sync::mpsc;
use std::thread;

fn main() {
    let (sender, receiver) = mpsc::channel();
    let mut workers = Vec::new();

    for worker_id in 0..3 {
        let worker_sender = sender.clone();
        workers.push(thread::spawn(move || {
            for sequence in 0..3 {
                let message = format!("worker {worker_id}: message {sequence}");
                if worker_sender.send((worker_id, sequence, message)).is_err() {
                    return;
                }
            }
        }));
    }
    drop(sender);

    let mut messages = receiver.into_iter().collect::<Vec<_>>();
    for worker in workers {
        worker.join().expect("worker thread panicked");
    }
    messages.sort_by_key(|(worker, sequence, _)| (*worker, *sequence));
    for (_, _, message) in messages {
        println!("{message}");
    }
}
