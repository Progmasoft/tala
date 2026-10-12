<!--
SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
-->

# Template Frontend Architecture

This document describes the compiler implementation boundary for Tala
template declarations. The language contract remains in `Spec/`; this document
explains how the Haskell frontend preserves that contract for later compiler
stages.

## Scope

The current frontend recognizes template class declarations and carries their
semantic information through:

1. lexical analysis;
2. parsing;
3. renaming;
4. name resolution;
5. type checking;
6. application binding;
7. typed declaration instantiation;
8. explicit specialization batch planning;
9. concrete layout-demand discovery from checked declarations;
10. semantic alpha-renaming and structural internal-name assignment;
11. specialization-plan verification and closed Core lowering.

The frontend does not emit an open template declaration as Core. A template is
lowered only after a concrete application has selected a declaration and all
semantic type and value variables have been replaced. This rule prevents Core,
CorePrep, Xpp, and Xmm from acquiring unresolved source-language variables.

Constraint parsing and ordering, explicit instantiation declarations, template
function declarations, template aliases, template extensions, deduction, and
a stable public ABI remain separate work. Their
absence must not be hidden by manufacturing a generic runtime function. The
compiler now has a structural internal symbol spelling for closed template
types and selected members, but that spelling is deliberately not a public ABI
promise.

## Parsed representation

`TemplateTypeDeclaration` is distinct from `TypeDeclaration`. It records:

- the class declaration name and source span;
- the ordered template parameter list;
- the class members;
- the annotation assigned by each semantic pass.

Each parameter records one of three categories:

- a type parameter introduced by `typename`;
- a compile-time value parameter introduced by a type and name;
- a template-template parameter introduced by a nested template signature and
  `class`.

Pack status is stored independently from category. This permits a type pack, a
value pack, or a template-template pack without encoding three more unrelated
constructors. A default remains either type syntax or restricted compile-time
value syntax.

Nested template-template parameters use shape records rather than source names.
The source signature `template<typename> class Container` describes what
`Container` accepts; the unnamed inner `typename` does not introduce a binding
in the enclosing class.

The parser never stores a template prefix as text. Doing so would force later
passes to parse the declaration again and could make analyzer and compiler
behavior diverge.

## Lexical rules

`template` and `typename` are keywords. `...` is emitted as one maximal symbol
token. Treating an ellipsis as three period tokens would make pack syntax
dependent on whitespace and complicate diagnostics.

Template value defaults use the same restricted scalar expression tree as
value template arguments. Runtime calls, callable literals, and other
side-effecting expressions cannot enter a specialization identity.

## Renaming

The declaration name is introduced in the surrounding declaration environment.
Template parameter names receive fresh, positive semantic identities in source
order.

All template parameter names enter the template environment before member
bodies are renamed. This is necessary because a default may refer to a later
parameter, as in:

```tala
template<typename T = U, typename U = int>
class Pair {
}
```

The same environment is visible to member bodies. A value parameter referenced
by a method expression therefore resolves to the parameter's semantic identity,
not to a global with the same spelling.

Parameter environments do not leak between template declarations. Two classes
may both declare `T`, and the resulting symbols remain distinct.

## Name resolution

Name resolution converts every positive renamer identity into a `SymbolId`.
Template declarations and their parameters follow the same zero-sentinel rule
as functions, locals, and captures: zero is never a valid source declaration
identity.

Type syntax intentionally retains source spellings. The typed pass maintains a
template context that maps those spellings to resolved parameter identities.
This avoids putting partially resolved names into `TypeSyntax` while still
ensuring that semantic `Type` values use `ResolvedName`.

## Type checking

A type parameter occurrence becomes:

```text
TypeVariable ResolvedName
```

A value parameter occurrence in a template value position becomes:

```text
TemplateValueParameter ResolvedName
```

For example, the parameter type `[T; N]` produces a `System.Array` semantic
type with an ordered type argument for `T` and value argument for `N`. The
ordered sum is important: type and value arguments cannot be sorted into
separate lists without changing specialization identity.

Template-template parameters behave as type variables while a body is open.
Their parameter shapes are retained on the declaration so application binding
can distinguish them from ordinary type parameters.

Member signatures, local bindings, callable parameters, capture annotations,
and every expression annotation use the same template context. Substitution is
therefore not limited to method boundaries.

An open declaration's own semantic type contains one argument per parameter.
Type and template-template parameters appear as type variables. Value
parameters appear as template value parameters.

## Structural verification

The template verifier checks invariants expected by application binding:

- declaration, parameter, and member symbols are positive;
- parameter symbols and spellings are unique within one declaration;
- a typed parameter does not carry `ErrorType`;
- a parameter pack does not carry a default;
- a default's type/value category matches its parameter category;
- a template-template signature is not empty, including nested signatures.

Multiple declarations with the same qualified name are not a structural error.
Constraint-based specialization intentionally permits that public surface.
Until constraint ordering is implemented, catalog lookup reports such an
application as ambiguous instead of picking a declaration by source order.

## Template catalog

The catalog is built from `TypedAST`. Each descriptor contains:

- the namespace-qualified declaration name;
- the declaration symbol;
- ordered parameter descriptors;
- semantic member signatures.

Ordinary declarations are excluded. Catalog lookup requires an exact qualified
name and never falls back to suffix matching. This keeps namespace behavior
case-sensitive and deterministic.

The minimum arity counts non-pack parameters without defaults. The maximum
arity is exact when no pack exists and unbounded when a pack exists.

## Application binding

Application binding accepts an ordered list of semantic `TemplateArgument`
values. It checks each argument against the corresponding parameter category.

A type parameter accepts a type argument. A value parameter accepts a value
argument. A template-template parameter currently accepts a zero-argument
named type as the semantic reference to a declaration. First-class template
references will replace this temporary representation when constraint and
declaration lookup are connected.

A pack receives all arguments not required by parameters following it. This
allows the binder to preserve a required suffix rather than greedily consuming
the entire application.

Bindings preserve whether an argument was explicit or supplied by a default.
That distinction is useful for diagnostics and reproducible specialization
keys even when both paths produce the same semantic argument.

## Default arguments

Defaults are resolved as a dependency graph. They are not evaluated by a simple
left-to-right fold because the language permits a default to reference a later
parameter.

The resolver follows parameter references until it reaches an explicit binding
or a concrete default. A visited-symbol set rejects cycles such as `T = U` and
`U = T` deterministically.

Concrete integer, Boolean, and character defaults become canonical template
values. Type defaults preserve qualified and nested template argument
structure. Substitution-aware arithmetic folding remains owned by the future
specialization evaluator; the application binder does not silently guess it.

## Typed instantiation

Instantiation accepts a binding and the typed template declaration that
created its descriptor. A mismatched declaration symbol is rejected.

The traversal substitutes annotations in:

- the declaration type;
- member signatures;
- parameters;
- local bindings and assignments;
- returns and branches;
- calls, unary expressions, and binary expressions;
- callable signatures and bodies;
- explicit and implicit capture records.

Source spans, source type syntax, semantic value names, access modifiers,
static status, and statement termination are preserved. The result is an
ordinary `TypeDeclaration`, which makes the existing Core lowering boundary
usable without teaching Core about source templates.

Nested template declarations retain their own parameter ownership and are not
substituted blindly by an outer binding. They must be selected and instantiated
through their own descriptor.

## Core boundary

Desugaring returns no functions for an open `TemplateTypeDeclaration`. This is
intentional, not an empty implementation. Emitting its members would create
invalid Core containing unresolved type variables and would make every open
member appear eagerly instantiated.

After a closed declaration has been produced, ordinary member lowering is used.
The compiler driver exposes this boundary as an explicit specialization batch.
For the normal pipeline, a TypedAST traversal supplies concrete layout demands,
the planner materializes a closed typed view, the plan verifier checks the
result, and the existing Desugarer and Core verifier consume that view. The
planner never scans source text. For a member-scoped demand it builds a
resolved, `SymbolId`-keyed call graph within the selected template declaration
and expands the root to its transitive member closure. Calls to functions
outside that declaration remain evidence, but do not become template members.

Ordinary declarations and generated specializations are desugared separately.
Their verified Core functions are merged and verified again before the existing
Core monomorphization-demand graph, optimizer, and CorePrep stages run. Open
template declarations still emit no Core functions.

## Automatic layout-demand discovery

The normal compiler pipeline walks the checked `TypedAST`, not tokens or source
spellings. A concrete named type creates a demand only when its resolved target
matches a template descriptor in the current catalog. Exact qualified names
are preferred. An unqualified use inside a namespace may resolve relative to
that namespace; arbitrary suffix matching is not permitted.

Discovery covers type-bearing positions in ordinary declarations:

- function results and parameters;
- local bindings and assignments;
- return values and branch conditions;
- call, unary, binary, and callable expression annotations;
- callable parameters and captures;
- nested type arguments and callable parameter/result types.

The traversal deliberately skips the bodies of open template declarations.
Their parameter-dependent annotations describe definitions, not concrete uses.
Walking them as demands would either emit open types or eagerly instantiate
every template declaration before a caller needs it.

Every discovered use records a stable diagnostic origin containing the source
file, source position, owning class, optional member, and semantic type site.
Repeated uses remain repeated discovery evidence. Coalescing belongs to the
planner, which combines equivalent applications while retaining distinct
origins.

Discovery currently emits layout-only demands. It never upgrades an ordinary
type use to a method-body request. Explicit member demands select roots by
spelling or exact semantic identity; the reachability traversal then includes
only resolved same-template callees. Name roots deliberately select all
overloads, while symbol roots remain exact.

## Specialization demands

A demand contains a bound application, a diagnostic origin, and one of three
scopes:

- layout only;
- one or more member names;
- the complete declaration.

Layout-only demand does not instantiate method bodies. A member demand selects
every overload with the requested spelling, because overload identity is not a
source name alone. Complete demand is explicit and is never inferred by the
planner. These distinctions preserve the language's lazy-member rule: asking
for `Box<int>` does not by itself make every method body valid or required.

Repeated demands with the same canonical concrete type share one
specialization. Their distinct diagnostic origins are retained, and their
member scopes are combined. Complete demand dominates narrower scopes; member
demand dominates layout-only demand. A default argument and the equivalent
explicit argument therefore reach the same cache identity.

The planner applies configurable limits to unique specializations, retained
origins, and selected members. Crossing a limit fails the entire immutable
batch instead of silently truncating work. Unknown declarations, ambiguous
declarations, invalid argument categories, missing members, and open results
remain distinct failures.

## Semantic alpha-renaming

Substitution closes types but does not make copied definitions unique. Two
specializations cannot retain the source declaration's `SymbolId`, because
Core uses semantic identities to distinguish functions, parameters, locals,
captures, and references.

Each planned specialization is therefore alpha-renamed after substitution.
Allocation starts above the greatest symbol in the input `TypedAST` and follows
canonical specialization order. Declaration, member, parameter, local, and
capture definitions receive fresh positive symbols. Every corresponding type,
value, assignment, call, initializer, and body reference is rewritten through
the same map.

Spelling and source spans remain unchanged. Diagnostics can still say `Read`
at its original location while the compiler internally distinguishes
`Box<int>.Read` from `Box<String>.Read`. Separate specializations receive
disjoint symbol sets, and the plan exposes the old-to-new map for later native
mangling and debug metadata.

Initializer scope is preserved while freshening. A local or capture definition
becomes visible after its initializer has been rewritten, preventing a newly
allocated symbol from capturing an outer reference with the same spelling.
Nested templates keep their independent parameter environment and are not
blindly alpha-renamed as part of an outer specialization.

Template type member scopes are recursive. Every immediate member definition
is allocated before any member body is rewritten, so forward calls and mutual
recursion cannot retain source-template identities. This two-phase reservation
is required independently of source order.

## Structural internal names

Each planned specialization carries an internal ASCII spelling for its closed
type and every selected member. The encoding includes explicit tags, counts,
and length frames for qualified-name components, ordered type/value arguments,
callable parameters and result, member spelling, staticness, access, and the
semantic signature. Positive and negative integers, Boolean values, Unicode
characters, and type arguments occupy distinct structural domains.

Unicode identifier scalars are encoded as fixed-width hexadecimal values, so
the result contains only ASCII letters, digits, and underscores. Concatenated
source spellings such as `AB.C` and `A.BC` cannot collide. Overloads with the
same member spelling remain distinct because their semantic signatures are
part of their member symbols.

The encoder rejects open type variables, unresolved value parameters,
`ErrorType`, malformed qualified names, invalid Unicode scalars, excessive
nested depth, excessive argument or name counts, and excessive symbol length.
A version marker makes future private encodings distinguishable.

These names are compiler-internal coordination data. The format may change
before the native ABI is stabilized and must not be persisted by third-party
tools as a public link contract.

## Specialization-plan verification

Planning output crosses a trust boundary before Core lowering, even though the
planner itself is pure. The verifier rejects malformed hand-built plans and
future planner regressions before they become backend assumptions. It checks:

- positive and unique specialization identifiers;
- non-empty, unique canonical application identities;
- closed specialization and declaration types without `ErrorType`;
- exact agreement between the canonical type and cloned declaration;
- non-empty, unique diagnostic origins;
- existing, unique, non-self dependency edges;
- positive one-to-one fresh-symbol maps with disjoint targets across plans;
- coverage of every cloned definition by the fresh-symbol map;
- exact agreement between requested scope and retained members;
- valid and exactly recomputable type and member manglings;
- globally unique emitted mangled symbols;
- consistent statistics and complete dependency-first emission coverage.

Normal compilation and the explicit batch API both run this verifier. Failures
become TypeChecker-stage diagnostics rather than reaching Desugarer, Core, or
the native backend.

## Dependency and emission order

The selected closed declaration is walked for type-bearing positions in member
signatures, local annotations, expressions, callables, and captures. When such
a type is another specialization already present in the same batch, the plan
records a dependency edge.

Emission order is deterministic and dependency-first. Reference-recursive
template types are legal, so a cycle closes the active depth-first edge rather
than causing arbitrary recursion or rejection. Every specialization still
appears exactly once. Infinite value layout remains a separate type-layout
error and is not reclassified by the scheduler.

Dependencies are not manufactured into new demands. If semantic resolution
did not request a specialization, merely seeing a similarly spelled named type
does not authorize the planner to select a declaration or choose constraints.
This keeps declaration resolution, specialization scheduling, and Core
lowering as separate auditable decisions.

## Diagnostic principles

Template diagnostics must identify the qualified declaration, parameter name,
argument position, expected category, and received category where applicable.
They must not print host-language constructor names as the only explanation.

Unknown and ambiguous declarations are distinct. Too few and too many
arguments are distinct. An unresolved default is distinct from an explicit
argument category mismatch.

Errors are accumulated when multiple supplied arguments have category problems.
Arity errors stop binding because no stable parameter alignment exists.

## Testing strategy

The frontend suite covers lexical maximal munch, all three parameter kinds,
packs, defaults, nested template-template shapes, malformed delimiters,
renaming scope, stable positive identities, typed variables, arrays,
dictionaries, callable types, catalog lookup, arity, category mismatch,
forward defaults, cycles, packs, substitution, and typed-tree instantiation.

Tests inspect semantic constructors and SymbolIds. Merely accepting source text
is insufficient because a parser could accept a template while discarding the
information needed by later stages.

Non-template declarations remain in the same suite as a regression boundary.
Adding template support must not change ordinary class parsing, member
resolution, or Core lowering.

## Next integration slice

The next template compiler slice should connect ordinary source call sites to
member-scoped demand creation. It should then:

1. evaluate and order constraints;
2. distinguish overload/member identities beyond source spelling;
3. stabilize the internal spelling into a versioned native ABI only after its
   linkage requirements are complete;
4. merge declaration dependencies with the existing Core demand graph;
5. cache the closed result across incremental compilations.

Stable canonical keys, lazy member scopes, resolved member-call closure, batch
coalescing, fresh semantic symbols, dependency-first scheduling, and verified
Core lowering are already implemented. Later work should reuse them rather
than reconstructing argument matching in Core or the C++ backend.

The integration must also retain deterministic source-order diagnostics while
allowing independent specializations to be prepared concurrently. The current
immutable plan establishes the deterministic result that a concurrent executor
must preserve; concurrency must never change catalog selection, scope merging,
fresh symbol allocation, or emitted identity.
