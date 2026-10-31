-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Typing rules of value blocks, @match@, and @guard@.

The rules need the checker for expressions and statements, which the main
type checker owns together with its template and loop context. They receive
it through 'BranchChecker', already applied to that context, so this module
states the rules of the branching forms without knowing how names, templates,
or loops are tracked.
-}
module Progmasoft.Tala.TypeChecker.Branching
    ( BranchChecker (..)
    , BranchEnvironment
    , MatchUse (..)
    , checkValueBlock
    , checkMatch
    , guardBlockProblems
    , matchArmsAlwaysAccept
    , blockCannotComplete
    , doesNotComplete
    ) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Completion
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.NumericSemantics

-- | Type and mutability of every local in scope, innermost first.
type BranchEnvironment = [(SymbolId, (Type, Bool))]

-- | The parts of the main type checker that the branching rules are built on.
data BranchChecker loops = BranchChecker
    { branchExpression ::
        BranchEnvironment ->
        Maybe Type ->
        Expression ResolvedName () ->
        (Expression ResolvedName Type, Type, [Diagnostic])
    -- ^ Check an expression, optionally in the context of an expected type.
    , branchStatements ::
        BranchEnvironment ->
        loops ->
        [Statement ResolvedName ()] ->
        ([Statement ResolvedName Type], BranchEnvironment, [Type], [Diagnostic])
    {- ^ Check statements in order. The result also has the environment after
    them and the types of the values their @return@ statements carry.
    -}
    , branchType :: TypeSyntax -> (Type, [Diagnostic])
    -- ^ Resolve a type written in source.
    , branchLiteral :: SourceSpan -> Maybe Type -> Literal -> (Type, [Diagnostic])
    -- ^ Type a literal in the context of an expected type.
    , branchEnumMember :: Type -> Identifier -> Maybe Integer
    -- ^ The value of a member of the enum with the given type.
    , branchHasEffect :: Expression ResolvedName () -> Bool
    -- ^ Whether evaluating an expression can do more than produce a value.
    , branchValueLoops :: loops
    {- ^ The loop context inside a block used as a value: the loops around
    the expression the block belongs to, seen across the edge of the block.
    -}
    }

-- | How a @match@ is used, which decides what its arms must provide.
data MatchUse loops
    = {- | An expression: every arm yields a value of one type, and some arm
      accepts whatever the subjects are.
      -}
      MatchValue
    | {- | A statement inside the given loop context: the arms are statements
      and it is not an error when no arm accepts.
      -}
      MatchStatement loops

problem :: SourceSpan -> String -> String -> Diagnostic
problem spanValue code message = Diagnostic TypeCheckerStage Error code (Just spanValue) message

{- | Check a block used as a value.

Its value is its final expression, written without a semicolon, and that
expression is typed in the context that receives the value. A block may
instead leave: with @return@ it leaves the enclosing function, with @break@
or @continue@ the enclosing loop, under the rules those statements have
anywhere else. A block that cannot complete normally produces no value and
needs no final expression, and a block whose final expression never
completes produces none either. Whether a block completes is a fact about
its control flow, kept apart from its type: 'doesNotComplete' answers it from
the typed tree, the annotation of such a block is @void@, and the form that
holds it takes its type from the blocks that do complete. A block that can
complete normally must end with its value.

A @return@ in such a block is checked against the declared return type of
the enclosing function like any other. Where that type is inferred, the
returns of the body are read from its typed tree afterwards, through
expressions as well ("Progmasoft.Tala.TypeChecker.Returns").
-}
checkValueBlock ::
    BranchChecker loops ->
    BranchEnvironment ->
    Maybe Type ->
    SourceSpan ->
    Block ResolvedName () ->
    (Expression ResolvedName Type, Type, [Diagnostic])
checkValueBlock checker environment expected spanValue (Block statements) =
    let (leading, final) = case reverse statements of
            ExpressionStatement finalSpan value False : before -> (reverse before, Just (finalSpan, value))
            _ -> (statements, Nothing)
        (typedLeading, inner, _, leadingProblems) =
            branchStatements checker environment (branchValueLoops checker) leading
     in case final of
            Nothing
                | blockCannotComplete (Block typedLeading) ->
                    (BlockExpression spanValue (Block typedLeading) voidType, voidType, leadingProblems)
                | otherwise ->
                    ( BlockExpression spanValue (Block typedLeading) ErrorType
                    , ErrorType
                    , leadingProblems
                        ++ [ problem
                                spanValue
                                "TAT0046"
                                "a block used as a value must end with an expression that has no semicolon, or leave on every path"
                           ]
                    )
            Just (finalSpan, value) ->
                let (typedValue, valueType, valueProblems) = branchExpression checker inner expected value
                    -- A final expression that never completes gives the
                    -- block no value and therefore no type.
                    blockType = if doesNotComplete typedValue then voidType else valueType
                 in ( BlockExpression
                        spanValue
                        (Block (typedLeading ++ [ExpressionStatement finalSpan typedValue False]))
                        blockType
                    , valueType
                    , leadingProblems ++ valueProblems
                    )

{- | Check a @match@.

The subjects are typed first, without context. Every arm is then checked
against them: its patterns, its guard in the scope of the names the patterns
bind, and its body. The result also carries the types of the values returned
by @return@ statements in the arms of a statement match.
-}
checkMatch ::
    BranchChecker loops ->
    MatchUse loops ->
    BranchEnvironment ->
    Maybe Type ->
    SourceSpan ->
    [Expression ResolvedName ()] ->
    [MatchArm ResolvedName ()] ->
    (Expression ResolvedName Type, Type, [Type], [Diagnostic])
checkMatch checker use environment expected spanValue subjects arms =
    let checkedSubjects = [branchExpression checker environment Nothing subject | subject <- subjects]
        typedSubjects = [typed | (typed, _, _) <- checkedSubjects]
        subjectTypes = [valueType | (_, valueType, _) <- checkedSubjects]
        subjectProblems =
            concat [problems | (_, _, problems) <- checkedSubjects]
                ++ [ problem
                        (expressionSpanOf typed)
                        "TAT0058"
                        "match subjects currently support only bool, numeric, enum and string values"
                   | (typed, valueType) <- zip typedSubjects subjectTypes
                   , valueType /= ErrorType
                   , not (acceptsBooleanContext valueType)
                   , Nothing <- [enumUnderlyingType valueType]
                   , valueType /= stringType
                   ]
        (typedArms, armTypes, returns, armProblems) = checkArms subjectTypes expected arms
        -- An arm that does not complete produces no value; the arms that
        -- complete give the match its type. When none completes, the match
        -- never yields a value: it is annotated void, like the statement
        -- form it is lowered as, and what receives it is not held to a
        -- type, because that place is never reached.
        valueTypes = [armType | (arm, armType) <- zip typedArms armTypes, not (doesNotComplete (matchArmBody arm))]
        noArmCompletes = null valueTypes && not (null typedArms)
        (annotation, resultType, resultProblems) = case use of
            MatchStatement _ -> (voidType, voidType, [])
            MatchValue
                | noArmCompletes -> (voidType, ErrorType, [])
                | otherwise -> let (valueType, problems) = matchValueType spanValue valueTypes in (valueType, valueType, problems)
        coverageProblems = case use of
            MatchStatement _ -> []
            MatchValue ->
                [ problem
                    spanValue
                    "TAT0052"
                    "a match used as an expression must accept every value of its subjects; add a '_' arm"
                | not (matchArmsAlwaysAccept subjectTypes typedArms)
                ]
     in ( MatchExpression spanValue typedSubjects typedArms annotation
        , resultType
        , returns
        , subjectProblems ++ armProblems ++ unreachableArmProblems typedArms ++ resultProblems ++ coverageProblems
        )
    where
        -- An arm made only of untyped literals takes its type from the
        -- context, and without one from the first arm that has a type.
        checkArms _ _ [] = ([], [], [], [])
        checkArms subjectTypes context (arm : remaining) =
            let (typedArm, armType, armReturns, problems) = checkArm checker use environment context subjectTypes arm
                nextContext = case context of
                    Just _ -> context
                    Nothing -> if armType == ErrorType || armType == voidType then Nothing else Just armType
                (later, laterTypes, laterReturns, laterProblems) = checkArms subjectTypes nextContext remaining
             in (typedArm : later, armType : laterTypes, armReturns ++ laterReturns, problems ++ laterProblems)

checkArm ::
    BranchChecker loops ->
    MatchUse loops ->
    BranchEnvironment ->
    Maybe Type ->
    [Type] ->
    MatchArm ResolvedName () ->
    (MatchArm ResolvedName Type, Type, [Type], [Diagnostic])
checkArm checker use environment expected subjectTypes (MatchArm spanValue patterns guard body) =
    let arityProblems =
            [ problem
                spanValue
                "TAT0048"
                ( "a match arm needs one pattern for each subject: expected "
                    ++ show (length subjectTypes)
                    ++ ", found "
                    ++ show (length patterns)
                )
            | length patterns /= length subjectTypes
            ]
        -- A surplus pattern has no subject; it is checked against the error
        -- type so that it reports nothing beyond the arity problem.
        checkedPatterns = zipWith (checkMatchPattern checker) (subjectTypes ++ repeat ErrorType) patterns
        typedPatterns = map fst checkedPatterns
        patternProblems = concatMap snd checkedPatterns
        -- A pattern binding is an ordinary local: it may be assigned, like
        -- every binding that is not declared final.
        armEnvironment =
            [ (resolvedSymbol name, (matchPatternAnnotation patternValue, True))
            | patternValue <- reverse typedPatterns
            , Just name <- [matchPatternBinding patternValue]
            ]
                ++ environment
        (typedGuard, guardProblems) = case guard of
            Nothing -> (Nothing, [])
            Just condition ->
                let (typed, conditionType, problems) = branchExpression checker armEnvironment Nothing condition
                    mismatch =
                        [ problem (expressionSpanOf typed) "TAT0049" "match guard must be bool or numeric"
                        | conditionType /= ErrorType
                        , not (acceptsBooleanContext conditionType)
                        ]
                 in (Just typed, problems ++ mismatch)
        (typedBody, bodyType, returns, bodyProblems) = case (use, body) of
            -- The block of a statement arm is an ordinary statement block. A
            -- match in its last position was parsed as the value of the
            -- block; here nothing takes that value, so it is a statement.
            (MatchStatement loops, BlockExpression blockSpan (Block statements) _) ->
                let (typedStatements, _, blockReturns, problems) =
                        branchStatements checker armEnvironment loops (lastMatchAsStatement statements)
                 in (BlockExpression blockSpan (Block typedStatements) voidType, voidType, blockReturns, problems)
            (MatchStatement _, expression) ->
                let (typed, _, problems) = branchExpression checker armEnvironment Nothing expression
                    effectProblems =
                        [ problem (expressionSpanOf typed) "TAT0013" "pure value expression cannot be used as a statement"
                        | not (branchHasEffect checker expression)
                        ]
                 in (typed, voidType, [], problems ++ effectProblems)
            (MatchValue, expression) ->
                let (typed, valueType, problems) = branchExpression checker armEnvironment expected expression
                 in (typed, valueType, [], problems)
     in ( MatchArm spanValue typedPatterns typedGuard typedBody
        , bodyType
        , returns
        , arityProblems ++ patternProblems ++ guardProblems ++ bodyProblems
        )

lastMatchAsStatement :: [Statement name annotation] -> [Statement name annotation]
lastMatchAsStatement statements = case reverse statements of
    ExpressionStatement spanValue value@MatchExpression {} False : before ->
        reverse (ExpressionStatement spanValue value True : before)
    _ -> statements

{- | Check one pattern against the type of its subject.

A literal is typed as the other operand of a comparison with the subject, so
the lowering compares two values of one type. A type pattern can only name
the subject's own type: there are no class hierarchies to test against yet,
so its use is to bind the value. The annotation of a typed pattern is the
type of the value it accepts.
-}
checkMatchPattern ::
    BranchChecker loops -> Type -> MatchPattern ResolvedName () -> (MatchPattern ResolvedName Type, [Diagnostic])
checkMatchPattern checker subjectType patternValue = case patternValue of
    MatchWildcardPattern spanValue _ -> (MatchWildcardPattern spanValue subjectType, [])
    -- A string is matched by the characters it holds, like @==@ on two
    -- strings, and by nothing that is not a string.
    MatchLiteralPattern spanValue literal@(StringLiteral _) _
        | subjectType == stringType -> (MatchLiteralPattern spanValue literal stringType, [])
    MatchLiteralPattern spanValue literal _
        | subjectType == stringType ->
            ( MatchLiteralPattern spanValue literal ErrorType
            , [problem spanValue "TAT0054" "a pattern of a string subject is a string literal"]
            )
    MatchLiteralPattern spanValue literal _ ->
        let (literalType, literalProblems) = branchLiteral checker spanValue (contextOf subjectType) literal
            rule = binaryNumericRule Equal subjectType literalType
            ruleProblems = case numericRuleError rule of
                Just issue | subjectType /= ErrorType -> [problem spanValue "TAT0054" (renderNumericRuleError issue)]
                _ -> []
         in (MatchLiteralPattern spanValue literal literalType, literalProblems ++ ruleProblems)
    MatchNullPattern spanValue _ ->
        ( MatchNullPattern spanValue subjectType
        , [problem spanValue "TAT0055" "a null pattern requires a reference subject, which match does not support yet"]
        )
    -- @.Member@ names a member of the subject's enum. It accepts the value
    -- of that member, so it is kept as the literal pattern of that value:
    -- two members with one value are then one pattern, and the second of
    -- them can never be selected.
    MatchCasePattern spanValue name _ -> case (enumUnderlyingType subjectType, branchEnumMember checker subjectType name) of
        (Just _, Just value) -> (MatchLiteralPattern spanValue (IntegerLiteral value) subjectType, [])
        (Just _, Nothing) ->
            ( MatchCasePattern spanValue name subjectType
            , [problem spanValue "TAT0064" ("the enum of the subject has no member named " ++ identifierText name)]
            )
        (Nothing, _) ->
            ( MatchCasePattern spanValue name subjectType
            ,
                [ problem spanValue "TAT0056" "an enum case pattern requires a subject of an enum type"
                | subjectType /= ErrorType
                ]
            )
    MatchTypePattern spanValue syntax name _ ->
        let (namedTypeValue, syntaxProblems) = branchType checker syntax
            relationProblems =
                [ problem
                    spanValue
                    "TAT0057"
                    "a type pattern must name the type of its subject; class hierarchies are not implemented"
                | namedTypeValue /= ErrorType
                , subjectType /= ErrorType
                , namedTypeValue /= subjectType
                ]
         in (MatchTypePattern spanValue syntax name subjectType, syntaxProblems ++ relationProblems)
    where
        contextOf valueType = if valueType == ErrorType then Nothing else Just valueType

{- | Result type of a match expression from the types of its arms.

The value is materialized in one storage slot, like the result of a
conditional expression, so every arm has the same type. Bool, numeric, enum
and string results are lowered today.
-}
matchValueType :: SourceSpan -> [Type] -> (Type, [Diagnostic])
matchValueType spanValue armTypes = case filter (/= ErrorType) armTypes of
    [] -> (ErrorType, [])
    first : remaining
        | any (/= first) remaining ->
            (first, [problem spanValue "TAT0050" "the arms of a match used as an expression must have the same type"])
        | not (acceptsBooleanContext first)
        , Nothing <- enumUnderlyingType first
        , first /= stringType ->
            ( first
            , [problem spanValue "TAT0051" "match expressions currently support only bool, numeric, enum and string results"]
            )
        | otherwise -> (first, [])

{- | Arms that can never be selected because an earlier arm without a guard
accepts everything they accept: pattern by pattern, the earlier one accepts
every value or names the same literal.
-}
unreachableArmProblems :: [MatchArm name annotation] -> [Diagnostic]
unreachableArmProblems = go []
    where
        go _ [] = []
        go earlier (arm : remaining) =
            [ problem
                (matchArmSpan arm)
                "TAT0053"
                "this match arm can never be selected: an earlier arm accepts everything it accepts"
            | any (`shadows` arm) earlier
            ]
                ++ go (earlier ++ [arm]) remaining
        shadows first second =
            isUnguarded first
                && length (matchArmPatterns first) == length (matchArmPatterns second)
                && and (zipWith covers (matchArmPatterns first) (matchArmPatterns second))
        covers first second = case (first, second) of
            (MatchLiteralPattern _ left _, MatchLiteralPattern _ right _) -> left == right
            _ -> acceptsEveryValue first

{- | Problems of the else block of a @guard@.

The statements after a guard rely on its condition, so the block must not
complete normally on any path. That is decided from its control flow by
'blockCannotComplete', not from the spelling of its last statement.
-}
guardBlockProblems :: SourceSpan -> Block name Type -> [Diagnostic]
guardBlockProblems spanValue block =
    [ problem
        spanValue
        "TAT0061"
        "the else block of a guard can complete normally; every path through it must leave the enclosing scope"
    | not (blockCannotComplete block)
    ]

expressionSpanOf :: Expression name annotation -> SourceSpan
expressionSpanOf expression = case expression of
    NameExpression spanValue _ _ -> spanValue
    LiteralExpression spanValue _ _ -> spanValue
    MemberAccessExpression spanValue _ _ _ -> spanValue
    MethodReferenceExpression spanValue _ _ _ -> spanValue
    CallExpression spanValue _ _ _ -> spanValue
    UnaryExpression spanValue _ _ _ -> spanValue
    BinaryExpression spanValue _ _ _ _ -> spanValue
    IsPatternExpression spanValue _ _ _ -> spanValue
    ConditionalExpression spanValue _ _ _ _ -> spanValue
    CoalesceExpression spanValue _ _ _ -> spanValue
    AssignmentExpression spanValue _ _ _ _ -> spanValue
    IncrementExpression spanValue _ _ _ -> spanValue
    LoopExpression spanValue _ _ -> spanValue
    BlockExpression spanValue _ _ -> spanValue
    MatchExpression spanValue _ _ _ -> spanValue
    CallableExpression spanValue _ _ _ _ _ -> spanValue
