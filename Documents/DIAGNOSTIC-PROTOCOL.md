<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
-->

# Structured Diagnostic Protocol

Tala tools consume compiler diagnostics through the versioned TADG protocol. The protocol is a private process
boundary between the compiler and trusted local tools such as Xide. It is not a source artifact, a user-selectable emit
format, or a replacement for readable terminal diagnostics.

TADG version 1 carries enough structure for an editor to present an error list, navigate to related declarations, and
offer explicitly described edits without parsing English text. The public `talac` command remains the only compiler
executable users invoke. The native driver starts the Haskell frontend and passes the side-channel path privately.

## Design rules

The protocol follows these rules:

- terminal text and protocol records are independent outputs;
- every document declares a protocol version before any record;
- positions are zero-based line and Unicode-scalar columns;
- text is encoded as counted Unicode scalar values, not UTF-8 or JVM UTF-16 code units;
- collection and text limits are checked before allocation;
- unknown tags, invalid Unicode scalars, truncation, and trailing bytes are errors;
- diagnostic codes remain stable machine identifiers while messages may improve;
- a successful compilation writes an empty document, preventing stale diagnostic reuse;
- protocol files are per-process temporary files and are removed by the consumer.

The protocol does not expose CorePrep. CorePrep remains an internal adapter between optimized Core and Xpp, and
diagnostics produced there use the ordinary `CorePrep` stage tag.

## Transport

A trusted local consumer sets `TALA_DIAGNOSTICS_FILE` on the native `talac` process when it requests structured diagnostics.
The native driver preserves that private variable for its child frontend, which writes one complete document before it
exits. In the absence of the environment variable, the frontend performs no extra I/O and preserves existing CLI behavior.

Consumers must create a unique path for every compiler invocation. They must not reuse a fixed file, and they must not
accept a file that predates the child process. The recommended sequence is:

1. Create a unique temporary filename using an operating-system facility.
2. Remove the placeholder file while retaining the unpredictable filename.
3. Start `talac <absolute-source-path> --entry=<entry> --emit=metadata` with `TALA_DIAGNOSTICS_FILE` set.
4. Wait for the compiler process and drain stdout and stderr concurrently.
5. Read and validate the complete TADG document.
6. Delete the temporary file in a guaranteed cleanup path.

If a non-timed-out process does not create a document, the consumer reports a compiler integration failure. It must not
scrape stderr as a fallback. A timeout may legitimately have no document because the frontend might not have reached
its final write.

## Primitive encoding

All integers use little-endian byte order.

| Value | Encoding |
| --- | --- |
| Byte | one unsigned byte |
| Boolean | byte `0` for false or byte `1` for true |
| U16 | two-byte unsigned integer |
| U32 | four-byte unsigned integer |
| Count | U32 checked against the field-specific limit |
| Text | scalar count followed by that many U32 Unicode scalar values |

Surrogate code points `U+D800` through `U+DFFF` and values above `U+10FFFF` are invalid. A consumer must reject them;
replacement characters would hide corruption and make source positions ambiguous.

## Document header

Every document starts with this 12-byte header:

| Offset | Size | Meaning |
| ---: | ---: | --- |
| 0 | 4 | ASCII magic `TADG` |
| 4 | 2 | protocol version, currently `1` |
| 6 | 2 | reserved flags, currently zero |
| 8 | 4 | diagnostic record count |

The canonical empty document is therefore:

```text
56 58 44 47 01 00 00 00 00 00 00 00
```

Reserved fields must be zero. Writers must not use a reserved bit before a protocol revision assigns semantics to it.
Readers must reject nonzero reserved bits rather than silently changing behavior.

## Diagnostic record

Records follow the header count in source-independent emission order. Each record contains:

1. stage tag as a byte;
2. severity tag as a byte;
3. diagnostic code as Text;
4. human-readable message as Text;
5. argument count and name/value argument pairs;
6. primary-location presence Boolean and optional location;
7. related-location count and related locations;
8. fix count and fixes.

A code contains 1–64 ASCII uppercase letters, digits, or hyphens. For example, `TAP100` and `TAT-204` are valid;
`parser100` is not. Codes identify diagnostic categories and must not be synthesized from translated messages.

The message is ready for display but does not need to contain enough information for a tool to reconstruct structured
values. Arguments preserve named values such as `actual=String` and `expected=int`. Argument names must be nonempty and
unique within one record.

## Stage tags

Stage ordinals are append-only:

| Tag | Stage |
| ---: | --- |
| 0 | Source loader |
| 1 | Lexer |
| 2 | Parser |
| 3 | Renamer |
| 4 | Name resolution |
| 5 | Type checker |
| 6 | Desugarer |
| 7 | Core |
| 8 | Core optimizer |
| 9 | CorePrep |
| 10 | Xpp lowering |
| 11 | Xpp optimizer |
| 12 | Xmm lowering |
| 13 | Xmm optimizer |
| 14 | LLVM backend |

Existing values must never be reordered. A future compiler may append a stage only with an appropriate versioning and
compatibility decision.

## Severity tags

| Tag | Severity |
| ---: | --- |
| 0 | Error |
| 1 | Warning |
| 2 | Information |
| 3 | Hint |

The current Haskell frontend emits errors and warnings. The wider catalog lets native stages and tools represent
non-failing information without abusing warning codes.

## Locations and ranges

A location contains:

1. source identity as Text;
2. start line as U32;
3. start column as U32;
4. end line as U32;
5. end column as U32.

The range is half-open and its end must not precede its start. Source identity is currently an absolute or
driver-resolved path. Consumers should normalize identity for comparison but preserve the received spelling for
diagnostic details.

Compiler syntax structures use one-based source positions. The protocol writer converts them to zero-based values at
the process boundary. This avoids leaking frontend conventions into Xide while preserving scalar-column semantics.

JVM strings use UTF-16 indexes. Xide must use its document line map when converting a protocol scalar column into an
editor offset; directly adding the column to a JVM string offset is incorrect for supplementary characters.

## Related locations

A related location is a complete location followed by a nonempty message. It describes declarations, earlier uses, or
other context needed to understand the primary problem. Related locations do not independently determine process
failure and do not carry severity.

The order is meaningful presentation order. A consumer may render the entries below the primary diagnostic but must
not sort them by filename or position unless the user explicitly requests that view.

## Fixes and edits

A fix contains a nonempty title and one or more text edits. Each edit contains a location and replacement Text. An
empty replacement is valid and represents deletion. An empty edit list is invalid because it would present an action
that cannot change the program.

The protocol describes edits; it does not grant permission to apply them. Before applying a fix, an editor must:

- verify that every referenced document still has the version for which diagnostics were produced;
- convert scalar positions through the document model;
- reject overlapping edits unless the fix contract explicitly gains overlap semantics in a later version;
- apply multi-file changes as one user-visible transaction;
- keep the operation undoable.

Version 1 does not carry document hashes or versions because the compiler reads an on-disk snapshot. Xide associates the
result with its own document version at invocation time and discards it when that version is no longer current.

## Resource limits

The default limits are intentionally finite:

| Resource | Default limit |
| --- | ---: |
| complete document | 16 MiB |
| diagnostics | 65,535 |
| scalars in one text field | 1,048,576 |
| arguments per diagnostic | 256 |
| related locations per diagnostic | 256 |
| fixes per diagnostic | 128 |
| edits per fix | 4,096 |

Readers may choose tighter limits. Writers must validate the semantic model before encoding and must also validate the
final byte length. Limits are part of defensive parsing, not a promise that the user interface will display every
accepted record at once.

## Error behavior

Malformed protocol input is an integration error. A reader reports the byte offset and field context, then rejects the
whole document. Partial diagnostic lists are never returned. Specifically, readers reject:

- incomplete headers or records;
- wrong magic;
- unsupported versions;
- reserved flags;
- unknown stage or severity tags;
- Boolean values other than zero and one;
- counts above configured limits;
- invalid Unicode scalar values;
- empty required strings;
- duplicate argument names;
- reversed ranges;
- empty fixes;
- trailing bytes.

Returning a partial list would make a broken compiler appear healthier than it is and could hide the most important
error. Xide should show the integration failure separately from source diagnostics.

## Compatibility

Version 1 is shared by the Haskell frontend, native C++ compiler libraries, and Xide's Kotlin client. Their golden empty
header and rich-record tests pin the same byte layout. Any change to field order, tags, primitive encoding, or validation
that changes accepted bytes requires coordinated tests across all three implementations.

Compatible work within version 1 includes improving messages, adding new diagnostic codes, adding argument values,
providing more related locations, and attaching fixes to an existing record. Consumers must not assume that a specific
code always lacks those optional collections.

Incompatible changes include reordering tags, changing position units, altering text encoding, changing required field
order, or assigning reserved flags. Such work requires a protocol-version decision and a migration path before code is
merged.
