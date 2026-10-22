<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Specification guide

## Purpose

`Spec/` contains 25 topic-oriented `.tala` example suites. They explain current language design intent using independent,
numbered fragments.

The catalog is grouped by ownership rather than kept as one flat directory:

- `Spec/Language/` contains declarations, attributes, operators, strings, optionals, exceptions, iteration, and unsafe
  behavior;
- `Spec/StandardLibrary/` contains Core, collections, I/O, text, numerics, concurrency, temporal, and query surfaces;
- `Spec/Libraries/Databases/` contains database-provider APIs; and
- `Spec/Interop/` contains FFI and inline-assembly boundaries.

The complete linked catalog is maintained in [`Spec/README.md`](../Spec/README.md).

## Topic catalog

| Area | Current suites |
| --- | --- |
| declarations and type forms | `Language/Decls.tala` |
| attributes | `Language/Attributes.tala` |
| evaluation by need and effects | `Language/Evaluation.tala` |
| operators and precedence | `Language/Operators.tala` |
| optionals and null behavior | `Language/Optional.tala` |
| strings, scalars, escapes, and source text | `Language/String.tala` |
| exceptions | `Language/Exceptions.tala` |
| iteration and generators | `Language/Iteration.tala` |
| unsafe operations | `Language/Unsafe.tala` |
| core and collections | `StandardLibrary/Core/*.tala` |
| console, file, and command I/O | `StandardLibrary/IO/*.tala` |
| text formats | `StandardLibrary/Text/*.tala` |
| numeric algorithms | `StandardLibrary/Numerics/Math.tala` |
| concurrency | `StandardLibrary/Concurrency/*.tala` |
| date and time | `StandardLibrary/Temporal/*.tala` |
| BLINQ | `StandardLibrary/Query/BLINQ.tala` |
| database providers | `Libraries/Databases/*.tala` |
| FFI and inline assembly | `Interop/*.tala` |

When a broad system overview and a focused language topic overlap, the focused topic is more specific. For example,
`Language/String.tala` governs `String` representation and syntax over an older/general core-system example. Resolve a real
conflict explicitly rather than blending incompatible rules.

## How to read an example

Each example should identify:

- the rule being demonstrated;
- whether the fragment is valid or invalid;
- whether declarations are omitted for context; and
- the expected compiler or runtime behavior.

Examples in one file are not concatenated. Repeated names and intentionally invalid fragments are normal.

Numbered examples should be understandable in isolation. Context may be omitted when the example says so, but omitted
declarations must not silently change the rule being demonstrated. An invalid example should identify the exact invalid
property instead of relying on several unrelated errors in one fragment.

Use Tala syntax even when describing a backend concept. Native C++ implementation details do not introduce `switch`,
`case`, C-style top-level entry functions, semicolon rules, or C scalar widths into the language catalog.

## Design versus implementation

The examples are a language-design catalog, not a statement that every feature is implemented. The compiler test suite is the
source of truth for current implementation coverage. A design example should gain a focused compiler test when its behavior is
implemented.

Use these layers when comparing design and code:

1. `Spec/` defines the intended public language/library behavior.
2. Compiler models show which parts can currently be represented.
3. Focused tests show which behavior is implemented at an owning stage.
4. Connected CLI tests show which behavior is usable through Talac.
5. Backend tests show which represented values can produce native artifacts.

A parser test alone does not prove runtime behavior. An LLVM test alone does not authorize new source syntax. A registered
artifact name does not prove a codec exists.

## Public language rules

Current cross-cutting rules include:

- source files use `.tala`;
- an executable takes the usual extension of the host (`.exe` on Windows, none elsewhere);
- runtime `String` is a sequence of Unicode code points rather than a UTF-8 byte container;
- project entry is a namespace-qualified class with `public static void Main()`;
- top-level runtime functions are not permitted;
- public intermediate artifact names are `.core`, `.xpp`, and `.xmm`; and
- normal compilation does not write intermediate representations unless emission is explicitly requested.

## Maintenance

- Public prose is written in en-US English.
- Correct spelling is required even when an earlier draft treated a misspelling as an API name.
- New examples must not expose repository-internal planning paths.
- Historical fixtures must not override the current language design.
- Ambiguous or contradictory rules must be resolved before implementation; they must not be silently guessed by compiler code.

### Adding or moving a suite

1. Select the narrowest language, standard-library, library, or interop owner.
2. Add it to `Spec/README.md` in the same change.
3. Preserve independent numbering and valid/invalid labels.
4. Search related focused topics for contradictions.
5. Add implementation tests only for the behavior actually connected in this change.
6. Update [Implementation status](IMPLEMENTATION.md) when the new examples expose a material coverage gap or newly connected
   surface.

Reorganization must not imply that directories are namespaces. It is valid for an example's namespace and filesystem path
to differ, just as it is for normal project sources.

### Terminology

- `String` is a Unicode-scalar sequence, not a UTF-8 byte container.
- `System.Array` is the standard collection surface; do not invent `System.Utils.ArrayList` or `HashMap` when absent from the
  collections catalog.
- `System.Worlds` entries are compiler-special library surfaces, not language built-ins.
- `Core`, `Xpp`, and `Xmm` are the current intermediate artifact vocabulary.
- CorePrep is internal and has no public extension.
- Tala packages are `.vipkg`.

Historical implementation names can remain in legacy source that is deliberately retained, but they do not enter the public
catalog as current language or artifact names.
