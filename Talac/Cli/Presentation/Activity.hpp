// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#pragma once

#include <memory>
#include <string_view>

namespace Progmasoft::Tala::Cli
{
    // Activity owns a terminal-only spinner. Redirected output and CI logs stay
    // deterministic: those environments receive ordinary diagnostics without
    // carriage returns, animation frames, or ANSI styling.
    class Activity final
    {
    public:
        explicit Activity(std::string_view description);
        ~Activity();

        Activity(const Activity &) = delete;
        Activity(Activity &&) = delete;
        auto
        operator=(const Activity &) -> Activity & = delete;
        auto
        operator=(Activity &&) -> Activity & = delete;

        void
        Update(std::string_view description);
        void
        Complete(std::string_view description);
        void
        Fail(std::string_view description);

    private:
        class Implementation;
        std::unique_ptr<Implementation> implementation_;
    };
} // namespace Progmasoft::Tala::Cli
