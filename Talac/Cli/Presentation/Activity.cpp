// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "Talac/Cli/Presentation/Activity.hpp"
#include "Talac/Cli/Presentation/ProgressLibrary.hpp"

#if defined(_WIN32)
#    include <io.h>
#else
#    include <unistd.h>
#endif

namespace Progmasoft::Tala::Cli
{
    namespace
    {
        [[nodiscard]] auto
        IsInteractiveErrorStream() -> bool
        {
            // Progress animation is a human-facing enhancement. Build logs and
            // pipes must remain stable input for tools, so environment and TTY
            // checks are both required before emitting a single carriage
            // return.
            // The environment is read on the calling thread before the
            // spinner thread exists, and this process never modifies it.
            // NOLINTNEXTLINE(concurrency-mt-unsafe)
            if (std::getenv("CI") != nullptr)
                return false;
            // NOLINTNEXTLINE(concurrency-mt-unsafe)
            if (const auto *term = std::getenv("TERM");
                term != nullptr && std::string_view(term) == "dumb")
                return false;
#if defined(_WIN32)
            return _isatty(_fileno(stderr)) != 0;
#else
            return isatty(fileno(stderr)) != 0;
#endif
        }
    } // namespace

    class Activity::Implementation final
    {
    public:
        explicit Implementation(std::string_view description)
            : spinner_(
                  indicators::option::PrefixText{ "talac" },
                  indicators::option::PostfixText{ std::string(description) },
                  indicators::option::ShowPercentage{ false },
                  indicators::option::ShowElapsedTime{ true },
                  indicators::option::SpinnerStates{
                      std::vector<std::string>{ "|", "/", "-", "\\" } },
                  indicators::option::Stream{ std::cerr })
            , worker_([this] {
                while (!stopRequested_.load(std::memory_order_relaxed))
                {
                    spinner_.tick();
                    std::this_thread::sleep_for(std::chrono::milliseconds(90));
                }
            })
        {}

        ~Implementation()
        {
            Finish("cancelled", indicators::Color::yellow);
        }

        void
        Update(std::string_view description)
        {
            spinner_.set_option(
                indicators::option::PostfixText{ std::string(description) });
        }

        void
        Finish(std::string_view description, indicators::Color color)
        {
            if (finished_)
                return;
            stopRequested_.store(true, std::memory_order_relaxed);
            worker_.join();
            spinner_.set_option(
                indicators::option::PostfixText{ std::string(description) });
            spinner_.set_option(indicators::option::ForegroundColor{ color });
            spinner_.mark_as_completed();
            finished_ = true;
        }

    private:
        indicators::ProgressSpinner spinner_;
        std::atomic_bool stopRequested_{};
        std::thread worker_;
        bool finished_{};
    };

    Activity::Activity(std::string_view description)
    {
        if (IsInteractiveErrorStream())
            implementation_ = std::make_unique<Implementation>(description);
    }

    Activity::~Activity() = default;

    void
    Activity::Update(std::string_view description)
    {
        if (implementation_)
            implementation_->Update(description);
    }

    void
    Activity::Complete(std::string_view description)
    {
        if (implementation_)
            implementation_->Finish(description, indicators::Color::green);
    }

    void
    Activity::Fail(std::string_view description)
    {
        if (implementation_)
            implementation_->Finish(description, indicators::Color::red);
    }
} // namespace Progmasoft::Tala::Cli
