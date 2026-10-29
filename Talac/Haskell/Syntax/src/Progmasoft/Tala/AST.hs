-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Public syntax and phase-indexed tree model shared by the Tala
frontend. Parsed trees retain source spelling, renamed trees attach stable
identities, resolved trees attach declarations, and typed trees attach
semantic types without changing the syntax structure.
-}
module Progmasoft.Tala.AST
    ( Identifier (..)
    , QualifiedName (..)
    , SourcePosition (..)
    , SourceSpan (..)
    , SyntaxTree (..)
    , Declaration (..)
    , EnumCase (..)
    , FactAttribute (..)
    , enumType
    , enumUnderlyingType
    , enumMemberValues
    , TemplateParameter (..)
    , TemplateParameterKind (..)
    , TemplateParameterShape (..)
    , TemplateParameterShapeKind (..)
    , TemplateDefault (..)
    , Parameter (..)
    , Block (..)
    , Statement (..)
    , Expression (..)
    , Pattern (..)
    , RelationalPatternOperator (..)
    , MatchArm (..)
    , MatchPattern (..)
    , matchArmExpressions
    , matchPatternSpan
    , matchPatternAnnotation
    , matchPatternBinding
    , statementSourceSpan
    , expressionSourceSpan
    , traverseMatchArm
    , traverseMatchPattern
    , CallableBody (..)
    , Capture (..)
    , CaptureMode (..)
    , Literal (..)
    , UnaryOperator (..)
    , BinaryOperator (..)
    , TypeSyntax (..)
    , TemplateValueSyntax (..)
    , TemplateArgumentSyntax (..)
    , BindingKind (..)
    , Access (..)
    , ParsedAST (..)
    , RenamedName (..)
    , RenamedAST (..)
    , SymbolId (..)
    , ResolvedName (..)
    , ResolvedAST (..)
    , Type (..)
    , TemplateArgument (..)
    , TemplateValue (..)
    , TypedAST (..)
    , boolType
    , intType
    , unitType
    , voidType
    , stringType
    , namedType
    ) where

-- | One source-language identifier in its original spelling.
newtype Identifier = Identifier {identifierText :: String}
    deriving stock (Eq, Ord, Read, Show)

-- | Name split into ordered namespace, type, and member segments.
newtype QualifiedName = QualifiedName {qualifiedNameParts :: [Identifier]}
    deriving stock (Eq, Ord, Read, Show)

-- | Zero-based source coordinate used by parser and diagnostic spans.
data SourcePosition = SourcePosition {sourceLine :: Int, sourceColumn :: Int}
    deriving stock (Eq, Ord, Read, Show)

-- | Half-open source range with the identity of the source file.
data SourceSpan = SourceSpan
    {sourceFile :: FilePath, sourceStart :: SourcePosition, sourceEnd :: SourcePosition}
    deriving stock (Eq, Ord, Read, Show)

-- | Type expression written in source before semantic resolution.
data TypeSyntax
    = ExplicitType Identifier
    | QualifiedTypeSyntax QualifiedName [TemplateArgumentSyntax]
    | BuiltinArrayTypeSyntax TypeSyntax
    | ArrayTypeSyntax TypeSyntax
    | FixedArrayTypeSyntax TypeSyntax TemplateValueSyntax
    | DictionaryTypeSyntax TypeSyntax TypeSyntax
    | CallableTypeSyntax [TypeSyntax] TypeSyntax
    | AutoType
    deriving stock (Eq, Ord, Read, Show)

{- | Restricted compile-time expression used for generic value arguments.

It deliberately excludes calls, closures, and other runtime expressions,
preventing runtime behavior from leaking into a specialization identity.
The type checker evaluates this tree before constructing Core.
-}
data TemplateValueSyntax
    = TemplateIntegerSyntax SourceSpan Integer
    | TemplateCharacterSyntax SourceSpan Integer
    | TemplateBooleanSyntax SourceSpan Bool
    | TemplateNameSyntax SourceSpan QualifiedName
    | TemplateUnarySyntax SourceSpan UnaryOperator TemplateValueSyntax
    | TemplateBinarySyntax SourceSpan BinaryOperator TemplateValueSyntax TemplateValueSyntax
    deriving stock (Eq, Ord, Read, Show)

-- | One generic argument, preserving the distinction between types and values.
data TemplateArgumentSyntax
    = TemplateTypeSyntax TypeSyntax
    | TemplateValueArgumentSyntax TemplateValueSyntax
    deriving stock (Eq, Ord, Read, Show)

-- | Source access modifier recorded on a declaration.
data Access = DefaultAccess | PublicAccess | InternalAccess | ProtectedAccess | PrivateAccess
    deriving stock (Eq, Ord, Read, Show)

-- | Module-level namespace and ordered declarations, parameterized by phase.
data SyntaxTree name annotation = SyntaxTree
    { syntaxNamespace :: Maybe QualifiedName
    , syntaxDeclarations :: [Declaration name annotation]
    }
    deriving stock (Eq, Ord, Read, Show)

-- | Type, function, or generic type declaration in a syntax tree.
data Declaration name annotation
    = TypeDeclaration
        { declarationSpan :: SourceSpan
        , declarationName :: name
        , declarationAnnotation :: annotation
        , typeMembers :: [Declaration name annotation]
        }
    | FunctionDeclaration
        { declarationSpan :: SourceSpan
        , declarationName :: name
        , declarationAnnotation :: annotation
        , declarationReturnSyntax :: TypeSyntax
        , declarationParameters :: [Parameter name annotation]
        , declarationBody :: Block name annotation
        , declarationIsStatic :: Bool
        , declarationAccess :: Access
        , declarationFact :: Maybe FactAttribute
        -- ^ The @[Fact]@ attribute, which makes the method a test.
        }
    | TemplateTypeDeclaration
        { declarationSpan :: SourceSpan
        , declarationName :: name
        , declarationAnnotation :: annotation
        , declarationTemplateParameters :: [TemplateParameter name annotation]
        , typeMembers :: [Declaration name annotation]
        }
    | {- | A classic enum: a value type whose members are named integers.
      The underlying type is absent when the source does not write one.
      -}
      EnumDeclaration
        { declarationSpan :: SourceSpan
        , declarationName :: name
        , declarationAnnotation :: annotation
        , enumUnderlying :: Maybe TypeSyntax
        , enumCases :: [EnumCase]
        }
    deriving stock (Eq, Ord, Read, Show)

{- | The @[Fact]@ attribute of a method: the method is a test. The name is
the one @[Fact("...")]@ gives it in a report; without one a report names
the class and the method.
-}
data FactAttribute = FactAttribute
    { factSpan :: SourceSpan
    , factName :: Maybe String
    }
    deriving stock (Eq, Ord, Read, Show)

{- | A member of a classic enum. A member without a written value takes the
value after that of the member before it, and the first takes zero.

A written value is a constant integer expression. It is kept as it was
parsed in every stage: the names in it are earlier members of the same enum,
which are named by their spelling and take no symbols, so no later stage has
anything to add to it. The type checker computes its value.
-}
data EnumCase = EnumCase
    { enumCaseSpan :: SourceSpan
    , enumCaseName :: Identifier
    , enumCaseValue :: Maybe (Expression Identifier ())
    }
    deriving stock (Eq, Ord, Read, Show)

{- | Generic parameter with its declaration span, category, pack flag, and default.

Template metadata remains present through @TypedAST@: renaming assigns each
parameter a stable symbol and type checking uses it in bodies and array sizes.
-}
data TemplateParameter name annotation = TemplateParameter
    { templateParameterSpan :: SourceSpan
    , templateParameterName :: name
    , templateParameterAnnotation :: annotation
    , templateParameterKind :: TemplateParameterKind
    , templateParameterIsPack :: Bool
    , templateParameterDefault :: Maybe TemplateDefault
    }
    deriving stock (Eq, Ord, Read, Show)

-- | Generic parameter category: type, value, or nested template signature.
data TemplateParameterKind
    = TemplateTypeParameter
    | TemplateValueParameterKind TypeSyntax
    | TemplateTemplateParameter [TemplateParameterShape]
    deriving stock (Eq, Ord, Read, Show)

{- | Anonymous shape of one parameter in a template-template signature.

These shapes describe accepted argument categories without introducing
artificial names into lexical scope.
-}
data TemplateParameterShape = TemplateParameterShape
    { templateParameterShapeKind :: TemplateParameterShapeKind
    , templateParameterShapeIsPack :: Bool
    }
    deriving stock (Eq, Ord, Read, Show)

-- | Accepted argument category at one level of a template-template signature.
data TemplateParameterShapeKind
    = TemplateTypeParameterShape
    | TemplateValueParameterShape TypeSyntax
    | TemplateTemplateParameterShape [TemplateParameterShape]
    deriving stock (Eq, Ord, Read, Show)

-- | Default argument attached to a generic parameter.
data TemplateDefault
    = TemplateTypeDefault TypeSyntax
    | TemplateValueDefault TemplateValueSyntax
    deriving stock (Eq, Ord, Read, Show)

-- | Callable parameter with source location and unresolved type syntax.
data Parameter name annotation = Parameter
    { parameterSpan :: SourceSpan
    , parameterName :: name
    , parameterAnnotation :: annotation
    , parameterTypeSyntax :: TypeSyntax
    }
    deriving stock (Eq, Ord, Read, Show)

-- | Ordered statement sequence representing a lexical block.
newtype Block name annotation = Block {blockStatements :: [Statement name annotation]}
    deriving stock (Eq, Ord, Read, Show)

-- | Mutability requested for a local or foreach binding.
data BindingKind = ImmutableBinding | MutableBinding
    deriving stock (Eq, Ord, Read, Show)

{- | Ownership behavior requested for a callable capture.

'StrongCapture' is also the default for ordinary captures; type checking
refines storage according to the captured value category.
-}
data CaptureMode = StrongCapture | WeakCapture | UnownedCapture
    deriving stock (Eq, Ord, Read, Show)

{- | Captured binding with an inner name and an optional outer-scope initializer.

A shorthand capture initially has no initializer. The renamer materializes
its outer-name read so later phases do not need to recover source spelling.
-}
data Capture name annotation = Capture
    { captureSpan :: SourceSpan
    , captureMode :: CaptureMode
    , captureName :: name
    , captureAnnotation :: annotation
    , captureInitializer :: Maybe (Expression name annotation)
    }
    deriving stock (Eq, Ord, Read, Show)

-- | Expression-bodied or block-bodied callable body.
data CallableBody name annotation
    = CallableExpressionBody (Expression name annotation)
    | CallableBlockBody (Block name annotation)
    deriving stock (Eq, Ord, Read, Show)

-- | Statement forms supported by the parsed and typed Tala trees.
data Statement name annotation
    = BindingStatement SourceSpan BindingKind TypeSyntax name annotation (Expression name annotation)
    | AssignmentStatement SourceSpan name annotation (Expression name annotation)
    | ReturnStatement SourceSpan (Maybe (Expression name annotation))
    | IfStatement SourceSpan (Expression name annotation) (Block name annotation) (Maybe (Block name annotation))
    | WhileStatement SourceSpan (Expression name annotation) (Block name annotation)
    | DoWhileStatement SourceSpan (Block name annotation) (Expression name annotation)
    | ForStatement
        SourceSpan
        (Maybe (Statement name annotation))
        (Maybe (Expression name annotation))
        [Statement name annotation]
        (Block name annotation)
    | ForEachStatement
        SourceSpan
        BindingKind
        TypeSyntax
        name
        annotation
        (Expression name annotation)
        (Block name annotation)
    | -- @target++;@ or @++target;@. The language has no decrement operator.
      IncrementStatement SourceSpan name annotation
    | -- @target op= value@ reads and writes one named storage location. The
      -- annotation is the target type; the operator is the binary operation
      -- whose result is stored back.
      CompoundAssignmentStatement SourceSpan BinaryOperator name annotation (Expression name annotation)
    | -- @_ = value;@ evaluates its operand and drops the result. It is a
      -- statement of its own, not an assignment to a binding named @_@.
      DiscardStatement SourceSpan (Expression name annotation)
    | BreakStatement SourceSpan (Maybe (Expression name annotation))
    | ContinueStatement SourceSpan
    | -- @guard (condition) else { ... }@ runs its block only when the
      -- condition is false, and the block must leave the enclosing scope, so
      -- the statements after the guard run only when the condition held.
      GuardStatement SourceSpan (Expression name annotation) (Block name annotation)
    | -- A block written as a statement of its own. Its statements run in
      -- order, and the names it declares are in scope only inside it.
      BlockStatement SourceSpan (Block name annotation)
    | ExpressionStatement SourceSpan (Expression name annotation) Bool
    deriving stock (Eq, Ord, Read, Show)

-- | Expression forms retained from parsing through type checking.
data Expression name annotation
    = NameExpression SourceSpan name annotation
    | LiteralExpression SourceSpan Literal annotation
    | -- A member selector preserves the receiver and the member spelling until
      -- the checker knows whether the receiver denotes a type or a value. The
      -- current executable subset accepts only type-qualified method calls.
      MemberAccessExpression SourceSpan (Expression name annotation) Identifier annotation
    | -- @Receiver::Member@: the method of that name as a callable value,
      -- without a call of it. The checker replaces a reference it can
      -- resolve with the name of the method, so no later stage sees one.
      MethodReferenceExpression SourceSpan (Expression name annotation) Identifier annotation
    | CallExpression SourceSpan (Expression name annotation) [Expression name annotation] annotation
    | UnaryExpression SourceSpan UnaryOperator (Expression name annotation) annotation
    | BinaryExpression SourceSpan BinaryOperator (Expression name annotation) (Expression name annotation) annotation
    | IsPatternExpression SourceSpan (Expression name annotation) (Pattern name annotation) annotation
    | -- @condition ? first : second@ evaluates exactly one arm.
      ConditionalExpression
        SourceSpan
        (Expression name annotation)
        (Expression name annotation)
        (Expression name annotation)
        annotation
    | -- @left ?: fallback@ yields the left value when it is true in Boolean
      -- context and evaluates the fallback only otherwise. The left operand
      -- is evaluated once.
      CoalesceExpression SourceSpan (Expression name annotation) (Expression name annotation) annotation
    | -- @target = value@ or @target op= value@ used for its value. The
      -- operator is absent for simple assignment. The expression stores into
      -- the named location and yields the stored value; its annotation is
      -- the target type. The statement forms keep their own nodes, so this
      -- node appears only where an assignment is an operand.
      AssignmentExpression SourceSpan (Maybe BinaryOperator) name (Expression name annotation) annotation
    | -- @++target@ and @target++@ used for their value. The flag selects the
      -- prefix form, which yields the new value; the postfix form yields the
      -- previous one.
      IncrementExpression SourceSpan Bool name annotation
    | -- A loop used for its value. The statement is the loop itself, a
      -- 'WhileStatement' or a 'ForStatement'; the value is the operand of
      -- the @break value;@ that leaves it, and the annotation is the type of
      -- that value.
      LoopExpression SourceSpan (Statement name annotation) annotation
    | -- A block used for its value: the arms of an @if@ expression and the
      -- block bodies of @match@ arms. Its statements run in order and its
      -- value is the final expression, which has no terminating semicolon.
      -- The parser creates this node only in those two places; a block is
      -- not a primary expression of its own.
      BlockExpression SourceSpan (Block name annotation) annotation
    | -- @match (subject), ... { patterns -> body, ... }@. The subjects are
      -- evaluated once, left to right, and the first arm whose patterns and
      -- guard accept them supplies the result. The same node is the
      -- statement form; there its annotation is @void@, the arms yield no
      -- value, and no arm needs to accept.
      MatchExpression SourceSpan [Expression name annotation] [MatchArm name annotation] annotation
    | CallableExpression
        SourceSpan
        Bool
        [Capture name annotation]
        [Parameter name annotation]
        (CallableBody name annotation)
        annotation
    deriving stock (Eq, Ord, Read, Show)

{- | One arm of a @match@: one pattern per subject, an optional guard, and
the body that runs when all of them accept.

A block body is a 'BlockExpression'; any other body is the expression written
after the arrow.
-}
data MatchArm name annotation = MatchArm
    { matchArmSpan :: SourceSpan
    , matchArmPatterns :: [MatchPattern name annotation]
    , matchArmGuard :: Maybe (Expression name annotation)
    , matchArmBody :: Expression name annotation
    }
    deriving stock (Eq, Ord, Read, Show)

{- | Pattern of a @match@ arm for one subject.

These are the forms of the @match-pattern@ grammar rule. They are separate
from 'Pattern', the patterns of an @is@ expression, which have relational and
combined forms that a @match@ arm does not have, and no bindings.
-}
data MatchPattern name annotation
    = -- | @_@ accepts every value.
      MatchWildcardPattern SourceSpan annotation
    | -- | A literal accepts the value equal to it.
      MatchLiteralPattern SourceSpan Literal annotation
    | -- | @null@ accepts the null reference.
      MatchNullPattern SourceSpan annotation
    | {- | @Type name@ or @Type _@ accepts a value of the type and, with a
      name, binds it for the guard and the body.
      -}
      MatchTypePattern SourceSpan TypeSyntax (Maybe name) annotation
    | -- | @.Case@ names an enum case of the subject's type.
      MatchCasePattern SourceSpan Identifier annotation
    deriving stock (Eq, Ord, Read, Show)

-- | Source range of a statement.
statementSourceSpan :: Statement name annotation -> SourceSpan
statementSourceSpan statement = case statement of
    BindingStatement value _ _ _ _ _ -> value
    AssignmentStatement value _ _ _ -> value
    ReturnStatement value _ -> value
    IfStatement value _ _ _ -> value
    WhileStatement value _ _ -> value
    DoWhileStatement value _ _ -> value
    ForStatement value _ _ _ _ -> value
    ForEachStatement value _ _ _ _ _ _ -> value
    IncrementStatement value _ _ -> value
    CompoundAssignmentStatement value _ _ _ _ -> value
    DiscardStatement value _ -> value
    BreakStatement value _ -> value
    ContinueStatement value -> value
    GuardStatement value _ _ -> value
    BlockStatement value _ -> value
    ExpressionStatement value _ _ -> value

-- | Source range of an expression.
expressionSourceSpan :: Expression name annotation -> SourceSpan
expressionSourceSpan expression = case expression of
    NameExpression value _ _ -> value
    LiteralExpression value _ _ -> value
    MemberAccessExpression value _ _ _ -> value
    MethodReferenceExpression value _ _ _ -> value
    CallExpression value _ _ _ -> value
    UnaryExpression value _ _ _ -> value
    BinaryExpression value _ _ _ _ -> value
    IsPatternExpression value _ _ _ -> value
    ConditionalExpression value _ _ _ _ -> value
    CoalesceExpression value _ _ _ -> value
    AssignmentExpression value _ _ _ _ -> value
    IncrementExpression value _ _ _ -> value
    LoopExpression value _ _ -> value
    BlockExpression value _ _ -> value
    MatchExpression value _ _ _ -> value
    CallableExpression value _ _ _ _ _ -> value

-- | The guard, when present, and the body of an arm, in evaluation order.
matchArmExpressions :: MatchArm name annotation -> [Expression name annotation]
matchArmExpressions arm = maybe [] (: []) (matchArmGuard arm) ++ [matchArmBody arm]

-- | Source range of a match pattern.
matchPatternSpan :: MatchPattern name annotation -> SourceSpan
matchPatternSpan patternValue = case patternValue of
    MatchWildcardPattern value _ -> value
    MatchLiteralPattern value _ _ -> value
    MatchNullPattern value _ -> value
    MatchTypePattern value _ _ _ -> value
    MatchCasePattern value _ _ -> value

-- | Annotation of a match pattern: after type checking, the subject type.
matchPatternAnnotation :: MatchPattern name annotation -> annotation
matchPatternAnnotation patternValue = case patternValue of
    MatchWildcardPattern _ value -> value
    MatchLiteralPattern _ _ value -> value
    MatchNullPattern _ value -> value
    MatchTypePattern _ _ _ value -> value
    MatchCasePattern _ _ value -> value

-- | The name a match pattern binds, when it binds one.
matchPatternBinding :: MatchPattern name annotation -> Maybe name
matchPatternBinding patternValue = case patternValue of
    MatchTypePattern _ _ name _ -> name
    _ -> Nothing

{- | Rebuild an arm from rewrites of its patterns, its guard, and its body,
applied in source order.
-}
traverseMatchArm ::
    (Applicative effect) =>
    (MatchPattern name annotation -> effect (MatchPattern name' annotation')) ->
    (Expression name annotation -> effect (Expression name' annotation')) ->
    MatchArm name annotation ->
    effect (MatchArm name' annotation')
traverseMatchArm onPattern onExpression (MatchArm spanValue patterns guard body) =
    MatchArm spanValue <$> traverse onPattern patterns <*> traverse onExpression guard <*> onExpression body

-- | Rebuild a pattern from rewrites of the name it binds and its annotation.
traverseMatchPattern ::
    (Applicative effect) =>
    (name -> effect name') ->
    (annotation -> effect annotation') ->
    MatchPattern name annotation ->
    effect (MatchPattern name' annotation')
traverseMatchPattern onName onAnnotation patternValue = case patternValue of
    MatchWildcardPattern spanValue annotation -> MatchWildcardPattern spanValue <$> onAnnotation annotation
    MatchLiteralPattern spanValue literal annotation -> MatchLiteralPattern spanValue literal <$> onAnnotation annotation
    MatchNullPattern spanValue annotation -> MatchNullPattern spanValue <$> onAnnotation annotation
    MatchTypePattern spanValue syntax name annotation ->
        MatchTypePattern spanValue syntax <$> traverse onName name <*> onAnnotation annotation
    MatchCasePattern spanValue name annotation -> MatchCasePattern spanValue name <$> onAnnotation annotation

{- | Pattern tested by an @is@ expression.

Pattern @and@ and @or@ combine tests beneath @is@; they are distinct from
both eager and short-circuit Boolean operators in 'Expression'.
-}
data Pattern name annotation
    = WildcardPattern SourceSpan annotation
    | NullPattern SourceSpan annotation
    | LiteralPattern SourceSpan Literal annotation
    | TypePattern SourceSpan TypeSyntax annotation
    | RelationalPattern SourceSpan RelationalPatternOperator Literal annotation
    | NotPattern SourceSpan (Pattern name annotation) annotation
    | AndPattern SourceSpan (Pattern name annotation) (Pattern name annotation) annotation
    | OrPattern SourceSpan (Pattern name annotation) (Pattern name annotation) annotation
    deriving stock (Eq, Ord, Read, Show)

-- | Relational comparison used by a relational pattern.
data RelationalPatternOperator
    = PatternLessThan
    | PatternLessEqual
    | PatternGreaterThan
    | PatternGreaterEqual
    | PatternEqual
    | PatternNotEqual
    deriving stock (Eq, Ord, Read, Show)

-- | Literal token value after lexical escape decoding.
data Literal
    = IntegerLiteral Integer
    | FloatingLiteral String
    | CharacterLiteral Integer
    | BooleanLiteral Bool
    | StringLiteral String
    | UnitLiteral
    deriving stock (Eq, Ord, Read, Show)

-- | Unary operator recognized by the parser.
data UnaryOperator = UnaryPlus | UnaryNegate | LogicalNot | BitwiseNot
    deriving stock (Eq, Ord, Read, Show)

-- | Binary arithmetic, comparison, bitwise, or Boolean operator.
data BinaryOperator
    = Add
    | Subtract
    | Multiply
    | Divide
    | FloorDivide
    | Remainder
    | Power
    | ShiftLeft
    | ShiftRight
    | BitwiseAnd
    | BitwiseXor
    | BitwiseOr
    | LessThan
    | LessEqual
    | GreaterThan
    | GreaterEqual
    | Equal
    | NotEqual
    | LogicalAnd
    | LogicalOr
    deriving stock (Eq, Ord, Read, Show)

-- | Parser output with source identifiers and no semantic annotations.
newtype ParsedAST = ParsedAST {parsedSyntaxTree :: SyntaxTree Identifier ()}
    deriving stock (Eq, Ord, Read, Show)

{- | Renamed source name carrying its preserved spelling and unique identity.

Zero is reserved as the native/wire no-symbol sentinel. The renamer assigns
positive identities; negative identities exist only to diagnose unresolved
names during resolution.
-}
data RenamedName = RenamedName {renamedSpelling :: Identifier, renamedUnique :: Int}
    deriving stock (Eq, Ord, Read, Show)

-- | Syntax tree after declarations and references receive unique identities.
newtype RenamedAST = RenamedAST {renamedSyntaxTree :: SyntaxTree RenamedName ()}
    deriving stock (Eq, Ord, Read, Show)

-- | Stable numeric symbol identity used by resolved and native representations.
newtype SymbolId = SymbolId {symbolIdValue :: Int}
    deriving stock (Eq, Ord, Read, Show)

-- | Reference to a resolved declaration with its original spelling.
data ResolvedName = ResolvedName {resolvedSymbol :: SymbolId, resolvedSpelling :: Identifier}
    deriving stock (Eq, Ord, Read, Show)

-- | Syntax tree whose names point to declarations but are not yet type-checked.
newtype ResolvedAST = ResolvedAST {resolvedSyntaxTree :: SyntaxTree ResolvedName ()}
    deriving stock (Eq, Ord, Read, Show)

-- | Semantic type attached to resolved expressions and declarations.
data Type
    = NamedType QualifiedName [TemplateArgument]
    | FunctionType [Type] Type
    | TypeVariable ResolvedName
    | ErrorType
    deriving stock (Eq, Ord, Read, Show)

{- | Evaluated generic argument, retaining its original position in the list.

The ordered sum keeps @Example<int, 4, String>@ distinct from
@Example<int, String, 4>@ when forming specialization identities.
-}
data TemplateArgument
    = TypeTemplateArgument Type
    | ValueTemplateArgument TemplateValue
    deriving stock (Eq, Ord, Read, Show)

{- | Canonical value accepted as a generic argument after type checking.

Integers are unbounded so specialization does not depend on host word size.
Parameter references remain representable for generic bodies.
-}
data TemplateValue
    = IntegerTemplateValue Integer
    | BooleanTemplateValue Bool
    | CharacterTemplateValue Integer
    | TemplateValueParameter ResolvedName
    deriving stock (Eq, Ord, Read, Show)

-- | Resolved syntax tree with semantic types attached to its annotations.
newtype TypedAST = TypedAST {typedSyntaxTree :: SyntaxTree ResolvedName Type}
    deriving stock (Eq, Ord, Read, Show)

-- | Construct a one-segment nominal type without generic arguments.
namedType :: String -> Type
namedType value = NamedType (QualifiedName [Identifier value]) []

-- | Canonical built-in Boolean type.
boolType :: Type
boolType = namedType "bool"

{- | The type of a classic enum.

An enum is a type of its own, and it is a value of its underlying integer
type with a closed set of values. Both facts are needed after type checking:
the lowering stores an enum as its underlying type, and a @match@ over an
enum is complete when its arms name every value. The type therefore carries
them: its name under the reserved root @enum@, which no source can spell
because @enum@ is a keyword, then the underlying type, then the distinct
values of its members in ascending order.
-}
enumType :: Identifier -> Type -> [Integer] -> Type
enumType name underlying values =
    NamedType
        (QualifiedName [Identifier "enum", name])
        (TypeTemplateArgument underlying : map (ValueTemplateArgument . IntegerTemplateValue) values)

-- | The underlying integer type of an enum type, and nothing for any other type.
enumUnderlyingType :: Type -> Maybe Type
enumUnderlyingType valueType = case valueType of
    NamedType (QualifiedName [Identifier "enum", _]) (TypeTemplateArgument underlying : _) -> Just underlying
    _ -> Nothing

-- | The distinct member values of an enum type, and nothing for any other type.
enumMemberValues :: Type -> Maybe [Integer]
enumMemberValues valueType = case valueType of
    NamedType (QualifiedName [Identifier "enum", _]) (TypeTemplateArgument _ : values) ->
        Just [value | ValueTemplateArgument (IntegerTemplateValue value) <- values]
    _ -> Nothing

-- | Canonical built-in signed integer type used by the current frontend.
intType :: Type
intType = namedType "int"

-- | Canonical unit type for expressions that produce no value.
unitType :: Type
unitType = namedType "unit"

-- | Canonical void type for procedure declarations and return checking.
voidType :: Type
voidType = namedType "void"

-- | Canonical standard string type.
stringType :: Type
stringType = namedType "String"
