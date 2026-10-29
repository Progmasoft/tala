"""Link options of a program that hosts generated code.

A compiled program calls the Tala runtime: a closure allocates through
it, an argument that is passed by need does, a string is one of its objects,
and console output is one of its functions. The JIT resolves a runtime symbol
in the process that hosts it, so every program that runs compiled programs
links the runtime libraries and exports their entry points.

The list is the C ABI of `Tala/Runtime/AARC.h` and
`Tala/Runtime/Text.h`. A function added to either header is added
here, or a program that calls it fails to resolve it under the JIT on
Windows, where nothing is exported that is not named.
"""

RUNTIME_HOST_DEPS = [
    "//Talac/Headers/Progmasoft/Tala/Runtime:aarc_api",
    "//Talac/Headers/Progmasoft/Tala/Runtime:text_api",
    "//Talac/Runtime/AARC:aarc",
    "//Talac/Runtime/Text:text",
]

_ENTRY_POINTS = [
    "tala_aarc_abi_version",
    "tala_aarc_allocate",
    "tala_aarc_copy_unowned",
    "tala_aarc_copy_weak",
    "tala_aarc_is_exact_type",
    "tala_aarc_load_unowned",
    "tala_aarc_lock_weak",
    "tala_aarc_make_unowned",
    "tala_aarc_make_weak",
    "tala_aarc_release_strong",
    "tala_aarc_release_unowned",
    "tala_aarc_release_weak",
    "tala_aarc_retain_strong",
    "tala_aarc_string_literal",
    "tala_console_write",
    "tala_test_end",
    "tala_test_fail",
    "tala_test_finish",
    "tala_test_status",
    "tala_text_concat",
    "tala_text_equals",
    "tala_text_format_char",
    "tala_text_format_floating",
    "tala_text_format_signed",
    "tala_text_format_string",
    "tala_text_format_unsigned",
    "tala_text_from_bool",
    "tala_text_from_char",
    "tala_text_from_signed",
    "tala_text_from_unsigned",
    "tala_text_newline",
]

RUNTIME_HOST_LINKOPTS = select({
    "@platforms//os:windows": ["/EXPORT:" + name for name in _ENTRY_POINTS],
    "@platforms//os:macos": [],
    "//conditions:default": ["-rdynamic"],
})
