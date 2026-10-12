<!-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com> -->
<!-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1 -->

# Static member calls and method overloads

This document describes the implemented compiler path for the declaration and call forms already shown in
[`Spec/Language/Decls.tala`](../Spec/Language/Decls.tala), especially Examples 187–189. It records implementation coverage;
it does not redefine Tala syntax or claim that every declaration feature in the Spec is implemented.

## Supported source form

The current executable subset accepts a call written as a type name followed by one member name and an argument list:

```talac
class Counter {
    public static int Current() {
        42
    }
}

class Program {
    public static int Read() {
        Counter.Current()
    }
}
```

Methods with one source spelling may form an overload set when their ordered parameter-type lists differ:

```talac
class Formatter {
    public static String Format(int value) {
        "integer"
    }

    public static String Format(String value) {
        value
    }
}

class Program {
    public static String FormatNumber(int value) {
        Formatter.Format(value)
    }
}
```

The parser preserves the receiver and selected spelling separately. It does not flatten `Counter.Current()` into a single
identifier such as `Counter_Current`, and it does not decide whether `Counter` denotes a type. That decision depends on
the renamed and resolved program.

## Implemented boundary

The current path handles a direct selector whose receiver resolves to a top-level type declaration in the current
semantic namespace. It handles a direct type-qualified static method call and an unqualified call to an overload family
owned by the current type. The following forms are deliberately not implied by this support:

| Form | Current status | Reason |
| --- | --- | --- |
| `Counter.Current()` | Supported | Direct type-qualified method call. |
| `Current()` inside `Counter` | Supported for the current type's method family | The lexical method spelling is associated with its declaring type before overload selection. |
| `counter.Current()` | Rejected | The receiver denotes a value; instance-member dispatch and its ABI are not part of this vertical slice. |
| `Counter.Create().Current()` | Rejected | A call-result receiver is a value expression, not a type name. |
| `Counter.Current` | Rejected | A selector with a dot is not a method reference; the reference is written `Counter::Current`. |
| `Counter::Current` | Supported | The static method as a callable value. With overloads, the type the place expects selects one. |
| `counter::Current` | Rejected | A reference through a value is a bound method, which needs instance members. |
| `Demo.Counter.Current()` inside namespace `Demo` | Supported | A declaration of the namespace being compiled may be named through that namespace, as a receiver of `.` and of `::`. |
| `Demo.Counter value` | Not connected | A type written through its namespace in a type position is not yet the same type as its bare name. |
| `System.Math.Math.Sqrt(x)` | Not connected | Cross-namespace type lookup is a separate frontend seam; only the namespace being compiled is known. |
| `Counter.Nested.Current()` | Not connected | Nested-type catalog lookup is not part of this top-level type catalog. |
| `counter.Field` or `counter.Property` | Not connected | Field/property resolution and instance layout are separate from static method binding. |
| Extension member lookup | Not connected | Extension discovery and real-member precedence remain separate work. |

This table is an implementation boundary, not a change to the Spec. The language examples continue to describe intended
language behavior even where the frontend does not yet implement the corresponding path.

## Pipeline ownership

### Parser

`Progmasoft.Tala.Parser` consumes the dot and member identifier as postfix syntax. The resulting `MemberAccessExpression`
stores:

1. the full selector span;
2. the receiver expression;
3. the source-spelled member identifier; and
4. a stage-local annotation.

A following argument list creates a `CallExpression` whose callee is that selector node. Repeated postfixes associate
left-to-right. This representation keeps ordinary calls and member calls distinguishable until semantic analysis.

The parser accepts member selection in the same expression positions where a postfix expression is legal, including
returns, call arguments, local initializers, unary/binary expressions, and conditions. It does not accept a member
selection as an assignment target. That rejection is intentional until assignment through a resolved field/property is
implemented.

Malformed selectors remain parser errors: a leading dot, trailing dot, repeated empty path component, non-identifier
member token, missing closing parenthesis, or missing argument fails before name resolution. Comments and literal
payloads do not create member punctuation.

### Renamer

Every declaration receives an identity before semantic lookup. A method overload family therefore has multiple
`RenamedName` values with the same spelling and different `SymbolId` values. The ordered list of declaration bindings
is carried beside the source declaration list while the Renamer rewrites each declaration. The lexical environment may
still use a spelling lookup for a source call, but it is not reused to assign the identity of every declaration that has
that spelling.

This distinction is critical. If declaration rewriting looked up each method by spelling, all methods in an overload set
would acquire whichever overload happened to be last in the environment. That would silently collapse function
identities, make source-owner records collide, and cause the Core verifier to reject the result as duplicate functions.
The declaration-binding sequence avoids that failure while retaining deterministic source-order allocation.

The Renamer permits repeated method spellings in a type, but it does not permit a method to silently share a name with a
field-like or nested declaration. The shared declaration-name collision rule remains in force. Signature duplicates
are validated later, where parameter syntax is available in the owning type context.

### Name Resolution

Name Resolution resolves the selector's receiver as a normal expression. It leaves the selected member spelling intact
because member lookup depends on receiver category and the complete method catalog. A missing receiver name is reported
as an ordinary unresolved-name diagnostic; a known local or parameter is not mistaken for a type merely because its
spelling matches one.

The current type catalog is constructed from type declarations in the semantic compilation unit. It uses declaration
`SymbolId`, not a text comparison, to establish ownership. Project compilation first merges physical source files that
belong to the same namespace, so declarations in that merged namespace can participate in the same catalog. Different
namespaces are still compiled as separate frontend units.

### Type Checker

The Type Checker owns the candidate catalog and the call decision. A method's overload identity is its source spelling
plus the ordered parameter-type sequence. The following do not create a distinct overload:

- a different return type;
- a different access modifier; or
- changing only `static` to instance or instance to `static`.

This follows the declaration rules in `Spec/Language/Decls.tala`, including Example 188. A duplicate signature is
reported once at the later declaration as `TAT0028`.

For a type-qualified call, resolution proceeds in this order:

1. Resolve the receiver expression to a type declaration in the current catalog.
2. Gather declarations owned by that exact type `SymbolId` and matching the member spelling.
3. Restrict the candidate set to static methods because the call uses the type surface.
4. Restrict candidates to those visible from the current declaration.
5. Compare argument count and argument types against each candidate's ordered parameter list.
6. Require an exact compatible type for every argument; no implicit numeric widening or narrowing is introduced.
7. Require exactly one viable candidate. Zero candidates is an error; multiple viable candidates are ambiguous.
8. Rewrite the typed call callee to a `NameExpression` carrying the selected method's resolved symbol and function type.

For an unqualified call inside a type, the Renamer's resolved method identity identifies the owner and spelling. The
Type Checker then considers the complete same-owner overload family instead of treating the one lexical seed identity as
the final target.

### Core and CorePrep

The Type Checker emits a resolved function reference, not a runtime member lookup. The Desugarer lowers that reference
to a typed `CoreApply` whose callee is a `CoreVariable` with the selected method `SymbolId`. Overloads with equal source
spelling remain distinct functions in Core. The source owner table likewise records one unique owner for each method
symbol.

The existing Core verifier remains the final invariant check for unique function identities, defined call targets,
parameter/result compatibility, and valid source ownership. CorePrep preserves function and call identities when it
introduces explicit blocks and atom-only operations. The method name is no longer used to guess a target after typed
resolution.

## Exact type matching

Overload selection intentionally uses the Type Checker's existing exact compatibility rule. It is not a conversion
ranking algorithm. For example, if a caller has a `long` parameter, an `int` overload is not selected just because the
values might fit:

```talac
class Numbers {
    public static int Read(int value) {
        value
    }
}

class Program {
    public static int Read(long value) {
        Numbers.Read(value) -- rejected: no implicit narrowing
    }
}
```

The examples above use named, already-typed parameters to isolate overload selection from literal inference. Numeric
literals can be typed from a candidate parameter context by the existing literal rules; a computed expression is not
converted just because one candidate would accept a different type. Return context does not select an overload because
return type is not part of overload identity.

The compiler does not use declaration order as a tie-breaker. When more than one candidate accepts a contextual literal
under the current exact typing rules, the call is ambiguous and reports `TAT0030`. Adding conversion preference rules
would require a separately specified Tala ranking rule; this implementation does not invent one.

## Access and static surface

`PrivateAccess` and `ProtectedAccess` are callable only from the same declaring type in the currently implemented
member-resolution slice. Other access levels are visible within the current compilation unit, which is the present
frontend unit boundary. Inheritance-aware protected access and assembly/file boundaries beyond a single semantic unit
remain future resolution work; this implementation does not claim to complete all access semantics in the Spec.

Calling an instance method through a type name reports `TAT0031`. Calling a selector through a value, call result, or
other non-type receiver reports `TAT0032`; the frontend does not synthesize dynamic dispatch. A private/protected-only
candidate family that is not visible reports `TAT0033`. A same-name visible static overload remains usable even when an
inaccessible sibling overload exists; inaccessible declarations do not poison the public candidate set.

## Diagnostics

All diagnostics below originate in the Type Checker unless otherwise noted.

| Code | Meaning |
| --- | --- |
| `TAN0001` | The receiver is an unresolved name; emitted by Name Resolution before member lookup. |
| `TAT0008` | No accessible candidate has the supplied argument count. |
| `TAT0009` | Candidate arity is available, but no candidate accepts the typed argument list exactly. |
| `TAT0028` | A declaration repeats an overload signature already owned by the same type and spelling. |
| `TAT0029` | No member with the requested spelling exists on the selected type. |
| `TAT0030` | More than one candidate remains viable. |
| `TAT0031` | The requested family exists only as instance methods when invoked through a type. |
| `TAT0032` | The selector receiver is not a declared type name. |
| `TAT0033` | Matching candidates exist but are not accessible from the call site. |
| `TAT0034` | A member selector is used without a supported direct method call. |
| `TAT0080` | A method reference names a method with several overloads, and the place does not expect the type of exactly one of them. |
| `TAT0081` | A method reference whose receiver is not a type: bound method references need instance members. |

The checker preserves a source span on member-call diagnostics. An unresolved receiver remains a Name Resolution failure
instead of being replaced by a fabricated Type Checker error. This makes the phase boundary visible to the CLI, analyzer,
and editor tooling.

## Regression coverage

The compiler test suite separates syntax, semantics, and lowering assertions:

- `Talac/Haskell/Driver/test/StaticMemberParserTests.hs` checks AST shape, source spelling, postfix association,
  selector spans, malformed inputs, and use in surrounding expression contexts.
- `Talac/Haskell/Driver/test/StaticMemberSemanticTests.hs` checks candidate filtering, access, static/instance
  distinctions, exact type matching, wrong arity, duplicate signatures, diagnostic stage/span/severity, the scalar
  pairwise overload matrix, and selected `SymbolId` values.
- `Talac/Haskell/Driver/test/StaticMemberOverloadTests.hs` exercises ordered two- and three-parameter type vectors,
  reversed declaration order, per-position mismatch diagnostics, and the declaration identity behind each typed call.
- `Talac/Haskell/Driver/test/StaticMemberCoreTests.hs` checks that selected declaration identities survive into Core
  and CorePrep, including source ownership, repeated calls, argument order, and lowering of owner-local calls.
- `Talac/Haskell/Driver/test/StaticMemberProjectTests.hs` checks physical source order, per-namespace catalogs,
  source ownership, and cross-file binding using the project entry contract.
- `Talac/Haskell/Driver/test/Main.hs` runs all four suites with the existing compiler and Core tests.
- `Talac/Haskell/Driver/tala-compiler.cabal` lists each test module explicitly; new modules must not rely
  on implicit source globs.

The pairwise scalar matrix tries every distinct ordered pair from the current scalar catalog as a two-overload family,
then calls each requested type through a value already declared with that type. Additional matrices reject duplicate
signatures and wrong argument count for every scalar parameter type. Those cases guard against an accidental special
case for only `int`, `long`, or `String`.

Run the focused compiler suite from `Talac/Haskell/Driver`:

```powershell
cabal test tala-compiler-tests --test-show-details=direct
```

The repository-wide Haskell suite is run from `Compiler` with `cabal test all`. The focused suite must pass before the
complete suite is considered. A green parser-only test is not sufficient: a member-call change must also pass semantic
resolution, Core verification, CorePrep verification, existing closure/template traversal, and the complete Haskell
package set.

### Ordered parameter-vector matrix

One-parameter tests can confirm only that a candidate family distinguishes two scalar types. They do not catch an
implementation that sorts parameter types, checks only the first argument, compares a set instead of a vector, or
accidentally reuses a previous candidate's context for later arguments. The overload suite therefore constructs calls
with multiple already-typed parameters.

For distinct scalar types `A` and `B`, it declares both signatures:

```text
Select(A first, B second)
Select(B left, A right)
```

The call `Select(first, second)` must select the first signature. The matrix repeats this case for every ordered pair
from the current scalar catalog except equal-type pairs, which would correctly be duplicate declarations rather than
a meaningful overload distinction. It repeats each vector with the overload declarations reversed, ensuring the
result is determined by the argument vector and not source order.

Three-parameter cases complement the exhaustive pair matrix. The candidate and distractor agree in two positions and
differ in the remaining position; separate generated cases put that difference in position zero, one, and two. A
second matrix perturbs the caller's static argument type at each position while holding the one candidate signature
fixed. Each such program must produce a type-mismatch diagnostic. Its method bodies return an integer literal rather
than returning a parameter, so an unrelated return-conversion error cannot make the negative test pass accidentally.

The fixture generator deliberately keeps parameter identifiers distinct from method names. It also uses named formal
parameters and positional call arguments only; named-argument binding is a separate feature and is not implicitly
claimed by this test suite. The generated source still goes through the production Parser, Renamer, Name Resolution,
and Type Checker path. Assertions inspect the typed declaration selected by the callee's `SymbolId`, not a helper that
reimplements the candidate-ranking algorithm.

### Type-vector identity

For the implemented non-generic method subset, a signature key is formed from:

1. the owning nominal type identity;
2. the source-spelled member name (case-sensitive); and
3. the ordered parameter type vector.

The following properties do not create a second signature in the same owner:

| Property | Overload-distinguishing? | Check |
| --- | --- | --- |
| Parameter type | Yes | Ordered pair and triple selection matrices. |
| Parameter order | Yes | Distinct `(A, B)` and `(B, A)` vectors. |
| Return type | No | Duplicate-signature diagnostic fixture. |
| Access modifier | No | Private/public declarations with the same vector collide. |
| Static versus instance | No | Same vector cannot be split only by staticness. |
| Owner type | Yes | Same spelling and vector on independent owners remain separate. |
| Source-file location | No | One namespace catalog spans its physical source files. |
| Declaration order | No | Pairwise tests reverse candidate declaration order. |

This key describes the current methods handled by the vertical slice. Constructors, operators, default parameters,
varargs, generic substitution, aliases, and extension candidates have additional identity and applicability rules in
the Spec; they must not be routed through this subset merely because they also have parameter lists.

### Candidate decision sequence

The current Type Checker uses a deliberately small sequence so that an error names the failed decision rather than
falling back to an arbitrary declaration:

1. The parser must provide a `CallExpression` whose callee is a `MemberAccessExpression`.
2. A direct `NameExpression` receiver is interpreted as a type only if its `SymbolId` exists in the current
   type catalog. A local parameter with the same spelling shadows that type interpretation.
3. Methods are collected from the resolved owner and exact member spelling. There is no case folding.
4. A type-qualified call removes instance declarations; an unqualified call is limited to the current owner family.
5. The access filter removes private/protected declarations outside their declaring type in this slice.
6. Candidate arity must equal the actual argument count.
7. Each argument is checked in that candidate parameter's expected context. Compatibility is tested without inventing
   numeric, string, or user-defined conversions.
8. Exactly one viable candidate supplies the callee `ResolvedName`, function annotation, and result type.
9. No viable candidate produces the diagnostic selected by the first failed stage; multiple viable candidates produce
   `TAT0030` rather than being resolved by source order.

The checker currently supports contextual typing already defined for literals. If a literal is viable for two
different parameter types, that creates two viable candidates and is reported as ambiguity. A named local or
parameter is not retyped to make an overload fit. This difference is why matrix tests use declared values for the
exhaustive scalar assertions: they isolate overload matching from literal-context rules.

### Diagnostic precedence and preserved syntax

The failure classification intentionally distinguishes these situations:

| Condition after receiver resolution | Result |
| --- | --- |
| No declaration owns the selected spelling | `TAT0029`. |
| The type has the spelling but only instance methods are present | `TAT0031`. |
| The method family exists but is inaccessible | `TAT0033`. |
| The accessible family has no matching argument count | `TAT0008`. |
| At least one accessible candidate has matching arity, but none accepts the typed arguments | `TAT0009`. |
| More than one candidate is viable | `TAT0030`. |
| The receiver is an unresolved name | `TAN0001` from Name Resolution. |
| The receiver is a value, call, or other unsupported expression | `TAT0032`. |
| A valid selector is used without the currently supported call shape | `TAT0034`. |

When a member call is rejected, its selector remains visible in the typed tree with an error annotation rather than
being rewritten as a global identifier. That preserves source spelling and position for diagnostics and prevents
downstream code from mistaking a failed member lookup for a successful ordinary call. Before Core lowering, every
successful selector must have become a call to the exact `ResolvedName` belonging to its selected declaration.

### Symbol identity across the pipeline

The call-target contract is identity-based, not spelling-based:

| Boundary | Invariant |
| --- | --- |
| Renamer output | Every overload declaration has a distinct positive `SymbolId`, even though spelling is shared. |
| Name Resolution | Receiver identity is resolved independently from the member spelling. |
| Typed AST | The selected callee carries the overload declaration's own identity and full function type. |
| Core | The call is a `CoreApply` targeting the selected symbol; no selector-derived pseudo-name is synthesized. |
| Core source catalog | Each function identity has one physical-source owner. |
| CorePrep | Atomization retains the call target and function identity. |

An earlier failure mode looked correct at the type level but used a name-only environment lookup when rewriting method
declarations. Since every overload had identical spelling, the last binding replaced earlier declaration identities
and multiple methods reached Core under one `SymbolId`. Renamer now carries source-ordered declaration bindings next
to syntax nodes. The Core and project tests assert identity uniqueness and ownership, rather than only comparing names.

The optimizer is allowed to inline or erase a pure call. Consequently, identity tests that inspect optimized Core use
nontrivial branch bodies where the call must remain observable; semantic selection tests inspect the typed tree
directly. Tests do not treat an absent optimized call as proof that overload resolution failed.

### Extending the implementation safely

Before adding a new receiver or candidate category, preserve the same stage separation:

1. extend the syntax AST with a node that preserves receiver, member spelling, and source span;
2. update every AST visitor, including closure analysis, template discovery/freshening/verification, diagnostics, and
   desugaring;
3. resolve the receiver's owner identity before collecting member candidates;
4. define the new candidate's signature identity and applicability in the normative Spec before implementing ranking;
5. make the access and static/instance rules explicit, including candidate-filter order;
6. bind the selected declaration's real `SymbolId` instead of manufacturing names from source text;
7. add parser, semantic, project, Core, and CorePrep tests for both accepted and rejected forms; and
8. update the support table only after the end-to-end path exists.

In particular, an instance call cannot reuse the type-qualified branch with a receiver type guessed from an identifier.
It needs a typed receiver, actual member lookup, object layout/dispatch decisions, and eventually the corresponding
runtime representation. Likewise a namespace-qualified type path needs a namespace catalog and import/qualification
semantics; splitting a dotted selector and trying names until one matches would make shadowing order-dependent.

The current implementation is therefore a narrow, identity-safe foundation: it supports direct static calls and
owner-local overload calls whose candidate set and argument types are already known. It intentionally reports an
explicit unsupported-resolution diagnostic rather than silently approximating adjacent language features.

### Change-review checklist

Use this checklist when changing any stage touched by member selection. It is intentionally compiler-facing: a change
is not complete merely because one `Catalog.Method(value)` sample compiles.

- Does the parser retain the complete receiver tree instead of concatenating identifier text?
- Does the selector retain its own source span and the exact source-spelled member identifier?
- Do repeated postfix selectors still associate from left to right?
- Are comments, strings, raw strings, and character literals protected from accidental dot parsing?
- Does a bare selector remain distinct from a method call with an argument list?
- Can the receiver be a local that shadows a type, and is that case rejected as a value receiver?
- Are forward-declared top-level types available through the completed catalog?
- Are methods on a different owner excluded even when both owner and member spellings match?
- Are overloads in another physical source file visible only after project namespace merging?
- Are identically named types in other namespaces excluded from the current namespace catalog?
- Does the overload key compare the parameter vector in order?
- Are parameter names excluded from overload identity?
- Are return type, access, and staticness prevented from manufacturing a second overload identity?
- Are aliased type equivalence rules kept separate until the Spec's alias semantics are implemented?
- Does each overload declaration preserve the `SymbolId` allocated for that exact source declaration?
- Does name resolution preserve normal lexical shadowing before any member candidate lookup?
- Are only type-qualified static candidates considered through a type receiver?
- Are instance candidates rejected without inventing a dispatch slot or runtime object operation?
- Are inaccessible declarations excluded without poisoning a viable public sibling overload?
- Is argument arity checked before the candidate is considered viable?
- Is each argument checked independently against the candidate's parameter type?
- Does the implementation avoid numeric widening or narrowing not specified for overload ranking?
- Is a computed expression kept at its already determined type rather than coerced to rescue a candidate?
- Is literal contextual typing tested separately from typed-local overload selection?
- Does return context avoid selecting among overloads?
- Are ambiguous candidate sets reported rather than resolved by declaration order?
- Does every failure retain a useful source span at the actual selector or call site?
- Does an unresolved receiver remain a Name Resolution diagnostic?
- Does a known but unsupported receiver form receive an explicit Type Checker diagnostic?
- Does rejected syntax remain representable in a typed error tree without a fake global call target?
- Does a successful typed callee carry the selected declaration's identity and function type?
- Does Core contain one function identity per overload declaration?
- Does every Core call target resolve to exactly one Core function?
- Does project source ownership map each overload identity to its defining physical source file?
- Does CorePrep retain that same identity after call arguments are atomized?
- Are identity tests robust to optimizations that inline a pure function call?
- Do tests inspect semantic selection at the typed-tree boundary where appropriate?
- Do parser, semantic, project, Core, and CorePrep cases each cover their own phase contract?
- Are every new Haskell test module and package dependency listed explicitly in Cabal metadata?
- Does the documentation continue to distinguish implemented behavior from the normative Spec?
- Are unsupported follow-on features still marked as unsupported until their full semantic and ABI path exists?

When a change alters any row above, update the corresponding test suite and implementation-boundary table in the same
change. This makes a review identify whether the feature is an AST, name-resolution, type-checking, lowering, or
project-catalog change instead of treating all compiler failures as parser bugs.

## Follow-on work kept separate

This work does not implement the remaining pieces merely because member-call syntax can now represent them:

1. instance field/property lookup, storage layout, and assignment through a receiver;
2. receiver-aware instance method calls and virtual dispatch;
3. type-qualified namespace paths, `using` imports, and cross-namespace symbol catalogs;
4. nested-type lookup and constructed generic type receivers;
5. extension discovery, real-member precedence, and generic extension constraints;
6. inheritance-aware `protected` access and accessibility across file/assembly boundaries;
7. default arguments, named arguments, parameter packs, and fixed-versus-vararg overload ranking; and
8. overload-specific mangling/linkage requirements for a native multi-module build.

These are deliberately independent semantic and ABI decisions. The current lowering makes one statically selected method
call explicit and identity-safe; it does not imply those adjacent subsystems are complete.
