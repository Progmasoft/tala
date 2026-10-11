// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

package crossplatform

import "time"

// pause waits between two questions to GitHub about a run that has not
// appeared yet. Tests replace it so that they do not wait.
var pause = func() { time.Sleep(2 * time.Second) }
