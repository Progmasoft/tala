// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include <cstddef>
#include <cstdlib>
#include <optional>
#include <type_traits>
#include <utility>

namespace Progmasoft::Tala::Support
{
    /**
     * @brief Stack size, in bytes, of a thread that runs the compiler.
     *
     * The stages that walk Core recurse once per level of nesting in the
     * program, so how deep a program may nest is decided by the stack of the
     * thread that compiles it. The stack a process starts with differs by
     * platform: one megabyte on Windows, eight on Linux and macOS, and half
     * a megabyte for secondary threads on macOS. A limit that is safe on
     * one of them would be either a crash on another or needlessly small
     * everywhere. The compiler therefore runs on a thread whose stack it
     * chooses itself, and the nesting limits of the frontend are stated
     * against this size.
     *
     * Only address space is reserved; pages are committed as they are
     * touched, so an ordinary program pays for the stack it uses.
     */
    inline constexpr std::size_t kCompilerStackBytes
        = std::size_t{ 256U } * 1024U * 1024U;

    /**
     * @brief Run a function on a new thread with the compiler stack and
     * wait for it.
     *
     * The stack is reserved, not committed. The process is terminated with
     * a report when the thread cannot be created: there is no smaller stack
     * on which the caller's limits would still hold.
     *
     * @param function Called once on the new thread with `argument`.
     * @param argument Passed through unchanged.
     */
    void
    RunOnCompilerStackRaw(void (*function)(void *), void *argument);

    /**
     * @brief Run a function on a new thread with a stack of the given size
     * and wait for it.
     *
     * This is the general form of RunOnCompilerStackRaw. Measuring tools use
     * it to find how much stack a stage needs; nothing else should choose a
     * stack size of its own.
     *
     * @param bytes Stack size to reserve; the platform may round it up.
     * @param function Called once on the new thread with `argument`.
     * @param argument Passed through unchanged.
     */
    void
    RunOnStackRaw(std::size_t bytes, void (*function)(void *), void *argument);

    /**
     * @brief The stack the calling thread has committed so far, in bytes.
     *
     * A stack is reserved as address space and committed page by page as
     * it is first touched. The committed part is therefore an upper bound on
     * what the thread has used, rounded up to pages and including the guard
     * page; it is not the exact number of bytes in use, and it does not
     * include frames that a sanitizer keeps on a heap-allocated fake stack.
     * Measuring tools call this at the end of the work they measure.
     *
     * On Windows the figure is the committed part of the stack allocation.
     * On Linux and macOS it is the resident pages of the stack mapping,
     * which are the pages the thread has touched; there it has no guard
     * page in it, and it is zero for the initial thread of a process, whose
     * stack is not one mapping.
     *
     * @return The committed bytes, or zero where this is not determined.
     */
    [[nodiscard]] auto
    CommittedStackBytes() -> std::size_t;

    /// Run a callable that returns nothing on a thread with a stack of the
    /// given size. See RunOnStackRaw.
    template<typename Callable>
    void
    RunOnStack(std::size_t bytes, Callable &&callable)
    {
        RunOnStackRaw(
            bytes,
            [](void *context) {
                (*static_cast<std::remove_reference_t<Callable> *>(context))();
            },
            &callable);
    }

    /**
     * @brief Run a callable on a thread with the compiler stack and return
     * its result.
     *
     * The caller waits for the thread, so the callable may refer to the
     * caller's locals. The callable must not throw; first-party code is
     * built without exceptions.
     */
    template<typename Callable>
    auto
    RunOnCompilerStack(Callable &&callable) -> std::invoke_result_t<Callable &>
    {
        using Result = std::invoke_result_t<Callable &>;
        if constexpr (std::is_void_v<Result>)
        {
            RunOnCompilerStackRaw(
                [](void *context) {
                    (*static_cast<std::remove_reference_t<Callable> *>(
                        context))();
                },
                &callable);
        }
        else
        {
            struct Call final
            {
                std::remove_reference_t<Callable> *callable;
                std::optional<Result> result;
            };
            Call call{ &callable, std::nullopt };
            RunOnCompilerStackRaw(
                [](void *context) {
                    auto *self = static_cast<Call *>(context);
                    self->result.emplace((*self->callable)());
                },
                &call);
            // The thread was joined, so the callable has run and stored
            // its result; anything else is a defect of the raw entry.
            if (!call.result)
                std::abort();
            return std::move(*call.result);
        }
    }
} // namespace Progmasoft::Tala::Support
