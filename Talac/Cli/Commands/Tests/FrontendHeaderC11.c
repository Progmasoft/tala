/* SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> */
/* SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 */

#include "Progmasoft/Tala/Frontend.h"

int
tala_frontend_header_c11_contract(void)
{
    const tala_frontend_output_callback callback = 0;
    return callback == 0 && TALA_FRONTEND_CORE_WIRE == 0
                   && TALA_FRONTEND_OUTPUT_REJECTED == 4
               ? 0
               : 1;
}
