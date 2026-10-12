// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

// This adapter contains only an upstream include, never owned implementation.
// Preserve the library's own diagnostics and flags while strict warnings stay
// enabled in Activity.cpp. Windows Bazel passes dependency headers as /I.
#ifdef __clang__
#    pragma clang system_header
#endif
#include <indicators/progress_spinner.hpp>
