/* SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> */
/* SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 */
#ifndef TALA_FRONTEND_H
#define TALA_FRONTEND_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

    /** @brief Consume one borrowed output buffer produced by the Haskell
     * frontend.
     *
     * The producer owns @p bytes and keeps it valid only until this synchronous
     * callback returns. Consumers that need the data afterward must copy it.
     * Returning a nonzero value rejects the output and aborts the operation.
     *
     * @param context Opaque caller-owned state passed through unchanged.
     * @param kind One of `tala_frontend_output_kind`.
     * @param bytes Borrowed output bytes; null is valid only when @p size is
     * zero.
     * @param size Number of bytes available in @p bytes.
     * @return Zero to accept the buffer; nonzero to stop the frontend
     * operation.
     */
    typedef int32_t (*tala_frontend_output_callback)(void *context,
                                                     uint32_t kind,
                                                     const uint8_t *bytes,
                                                     size_t size);

    /** @brief Output categories transferred across the in-process ABI. */
    /* A C11 enumeration has no selectable base type. */
    /* NOLINTNEXTLINE(performance-enum-size) */
    enum tala_frontend_output_kind
    {
        /** Verified Core wire bytes ready for the native pipeline. */
        TALA_FRONTEND_CORE_WIRE = 0,
        /** NUL-delimited UTF-8 project source paths. */
        TALA_FRONTEND_PROJECT_SOURCE_LIST = 1,
        /** Structured diagnostics encoded by the diagnostic wire protocol. */
        TALA_FRONTEND_DIAGNOSTIC_WIRE = 2,
        /** Human-readable UTF-8 failure text. */
        TALA_FRONTEND_ERROR_TEXT = 3,
        /** The frontend's own CorePrep lowering; testing entries only. */
        TALA_FRONTEND_COREPREP_WIRE = 4,
        /** Human-readable UTF-8 warnings of a successful request.
         *
         * Delivered at most once and before the result payload. A rejected
         * request lists its warnings after its errors instead. */
        TALA_FRONTEND_WARNING_TEXT = 5
    };

    /** @brief Stable result codes returned by frontend ABI entry points. */
    /* A C11 enumeration has no selectable base type. */
    /* NOLINTNEXTLINE(performance-enum-size) */
    enum tala_frontend_status
    {
        /** The requested operation completed and delivered its output. */
        TALA_FRONTEND_OK = 0,
        /** The source was processed but produced user-facing diagnostics. */
        TALA_FRONTEND_DIAGNOSTICS = 1,
        /** The argument framing or request shape was invalid. */
        TALA_FRONTEND_INVALID_REQUEST = 2,
        /** The frontend encountered an internal failure. */
        TALA_FRONTEND_INTERNAL_ERROR = 3,
        /** The native callback rejected an output buffer. */
        TALA_FRONTEND_OUTPUT_REJECTED = 4
    };

    /** @brief Return the ABI version implemented by the loaded frontend.
     * @return ABI version 2 for this contract. Version 2 added
     * `TALA_FRONTEND_WARNING_TEXT`.
     */
    uint32_t
    tala_frontend_abi_version(void);

    /** @brief Start the process-wide GHC runtime before calling other entries.
     *
     * Initialization must be performed outside `DllMain`; a failed start is
     * permanent for the life of the current process.
     * @return Zero on success, otherwise a negative initialization status.
     */
    int32_t
    tala_frontend_initialize(void);

    /** @brief Stop the process-wide GHC runtime after all frontend calls
     * finish.
     *
     * Shutdown is idempotent. No callback buffer may remain borrowed when it is
     * called.
     */
    void
    tala_frontend_shutdown(void);

    /** @brief Execute one compiler-driver request without creating frontend
     * files.
     *
     * The argument blob is a sequence of non-empty, strict UTF-8 arguments,
     * each terminated by one NUL byte. It is private to the `talac` process;
     * paths and source contents are still validated by the Haskell source
     * loader. Each callback receives producer-owned bytes that expire when the
     * callback returns.
     *
     * @param argument_blob NUL-framed argument bytes; may be null only when
     * size is zero.
     * @param argument_size Number of bytes in @p argument_blob.
     * @param output Synchronous receiver for frontend output buffers.
     * @param context Opaque state passed to @p output.
     * @return One of `tala_frontend_status`.
     */
    int32_t
    tala_frontend_execute(const uint8_t *argument_blob,
                          size_t argument_size,
                          tala_frontend_output_callback output,
                          void *context);

    /** @brief Compile one in-memory source buffer into verified Core wire
     * bytes.
     *
     * The operation does not create a source, Core, or source-list file. A
     * normal language diagnostic is returned as `TALA_FRONTEND_DIAGNOSTICS`
     * with an `TALA_FRONTEND_ERROR_TEXT` callback; internal and ABI failures
     * use their corresponding status values.
     * @param source UTF-8 source bytes; malformed encoding is a diagnostic.
     * @param source_size Number of bytes in @p source.
     * @param output Synchronous receiver for Core bytes or diagnostic text.
     * @param context Opaque state passed to @p output.
     * @return One of `tala_frontend_status`.
     */
    int32_t
    tala_frontend_compile_source(const uint8_t *source,
                                 size_t source_size,
                                 tala_frontend_output_callback output,
                                 void *context);

    /** @brief Run production lexer or parser logic for one fuzz input.
     *
     * This testing entry point does not expose a parser AST over the ABI.
     * Invalid source is an ordinary rejected input; an internal failure is
     * reported with a negative status.
     * @param stage Zero selects lexing; one selects parsing after lexing.
     * @param source UTF-8 candidate source bytes; malformed input is permitted.
     * @param source_size Number of bytes in @p source.
     * @return Zero for a completed attempt, even when diagnostics reject input.
     */
    int32_t
    tala_frontend_fuzz_syntax(uint32_t stage,
                              const uint8_t *source,
                              size_t source_size);

    /** @brief Parse and compile a source fuzz input, delivering verified Core
     * and the frontend's CorePrep lowering of that Core.
     *
     * Lexical, syntax, and semantic diagnostics are expected for arbitrary fuzz
     * bytes. On success this testing entry invokes @p output twice: first with
     * `TALA_FRONTEND_CORE_WIRE`, then with `TALA_FRONTEND_COREPREP_WIRE`. Both
     * buffers come from one compilation, so a harness can compare the native
     * Core-to-CorePrep adapter with the frontend's lowering. Every other entry
     * point delivers exactly one buffer and never emits CorePrep.
     * @param source Candidate source bytes; malformed UTF-8 is permitted.
     * @param source_size Number of bytes in @p source.
     * @param output Synchronous receiver for the Core and CorePrep buffers.
     * @param context Opaque state passed to @p output.
     * @return `TALA_FRONTEND_DIAGNOSTICS` for rejected source, zero when both
     * buffers were delivered, or another `tala_frontend_status` on failure.
     */
    int32_t
    tala_frontend_fuzz_compile(const uint8_t *source,
                               size_t source_size,
                               tala_frontend_output_callback output,
                               void *context);

#ifdef __cplusplus
}
#endif

#endif /* TALA_FRONTEND_H */
