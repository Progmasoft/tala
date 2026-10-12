-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Semantic checker for trees whose references already have stable identities.

The checker attaches types and returns diagnostics without rewriting unresolved
names. It runs after Renamer and Name Resolution so lexical spelling is never
used as a substitute for symbol identity.
-}
module Progmasoft.Tala.TypeChecker (TypeChecker (..), defaultTypeChecker, runTypeChecker) where

import Data.Map.Strict qualified as Map
import Progmasoft.Tala.AST
import Progmasoft.Tala.BuiltinTypes
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.NumericSemantics
import Progmasoft.Tala.TypeChecker.Branching
import Progmasoft.Tala.TypeChecker.Console
import Progmasoft.Tala.TypeChecker.Context
import Progmasoft.Tala.TypeChecker.Enums
import Progmasoft.Tala.TypeChecker.Literals
import Progmasoft.Tala.TypeChecker.Loops
import Progmasoft.Tala.TypeChecker.Returns

-- | A resolved-tree checker that produces a typed tree only when checking succeeds.
newtype TypeChecker = TypeChecker {checkResolvedAST :: ResolvedAST -> Either [Diagnostic] TypedAST}

-- | Apply a checker to the output of Name Resolution.
runTypeChecker :: TypeChecker -> ResolvedAST -> Either [Diagnostic] TypedAST
runTypeChecker = checkResolvedAST

-- | The production checker for the currently implemented Tala subset.
defaultTypeChecker :: TypeChecker
defaultTypeChecker = TypeChecker checkTree

{- | Type-check every top-level declaration and collect independent diagnostics.
No partially typed AST escapes when any declaration has an error.
-}
checkTree :: ResolvedAST -> Either [Diagnostic] TypedAST
checkTree (ResolvedAST (SyntaxTree namespace declarations)) =
    let catalog = inferAutoReturns declarations (catalogDeclarations declarations)
        checked = map (checkTopDeclaration catalog) declarations
        problems = concatMap snd checked
     in if null problems then Right (TypedAST (SyntaxTree namespace (map fst checked))) else Left problems

catalogDeclarations :: [Declaration ResolvedName ()] -> TypeCatalog
catalogDeclarations declarations =
    TypeCatalog
        [ (resolvedSymbol (declarationName declaration), declarationName declaration)
        | declaration <- declarations
        , isTypeDeclaration declaration
        ]
        [ MethodCandidate (resolvedSymbol (declarationName owner)) member
        | owner <- declarations
        , isTypeDeclaration owner
        , member <- typeMembersOf owner
        , case member of FunctionDeclaration {} -> True; _ -> False
        ]
        (enumInfos declarations)
        []
    where
        isTypeDeclaration TypeDeclaration {} = True
        isTypeDeclaration TemplateTypeDeclaration {} = True
        isTypeDeclaration _ = False
        typeMembersOf TypeDeclaration {typeMembers = members} = members
        typeMembersOf TemplateTypeDeclaration {typeMembers = members} = members
        typeMembersOf _ = []

{- | Infer the return types of the methods declared with @auto@ before any
caller is checked against them.

A method's return type comes from its own returns, and those may be calls of
other such methods, in any class and declared later. The bodies are therefore
checked in rounds. In a round, a call of a method whose type is not known yet
has no type and takes no part in the inference, so a method is inferred as
soon as one of its returns is independent of the methods still unknown: a
recursive method from its base case, and a chain of methods from its end
towards its start. A round that learns nothing ends the inference; every
round before it resolves at least one method, so there are at most as many
rounds as methods. A method that is still unknown then has no independent
result, which is reported when its declaration is checked. The diagnostics
of the rounds are dropped: every body is checked once more against the
final catalog.
-}
inferAutoReturns :: [Declaration ResolvedName ()] -> TypeCatalog -> TypeCatalog
inferAutoReturns declarations = rounds (length inferable)
    where
        inferable =
            [ (owner, member)
            | owner <- declarations
            , member <- membersOf owner
            , FunctionDeclaration {declarationReturnSyntax = AutoType} <- [member]
            ]
        membersOf declaration = case declaration of
            TypeDeclaration {typeMembers = members} -> members
            TemplateTypeDeclaration {typeMembers = members} -> members
            _ -> []
        rounds :: Int -> TypeCatalog -> TypeCatalog
        rounds remaining catalog
            | remaining <= 0 || learned == catalogInferredReturns catalog = catalog
            | otherwise = rounds (remaining - 1) catalog {catalogInferredReturns = learned}
            where
                learned =
                    [ (inferredReturnKey member, result)
                    | (owner, member) <- inferable
                    , let (context, globals) = memberScope catalog owner
                    , FunctionDeclaration {declarationAnnotation = FunctionType _ result} <-
                        [fst (checkDeclarationWith context globals member)]
                    , result /= ErrorType
                    ]

-- | What identifies a method declaration among its overloads.
inferredReturnKey :: Declaration ResolvedName annotation -> (SymbolId, SourceSpan)
inferredReturnKey declaration = (resolvedSymbol (declarationName declaration), declarationSpan declaration)

{- | The context and the names in scope of the members of a type: the
signatures of its members and, for a template, its value parameters.
-}
memberScope :: TypeCatalog -> Declaration ResolvedName () -> (TemplateContext, TypeEnvironment)
memberScope catalog declaration = case declaration of
    TemplateTypeDeclaration _ name _ parameters members ->
        let context = templateContext catalog (Just (resolvedSymbol name)) parameters
            templateValues =
                [ (resolvedSymbol (templateParameterName parameter), (templateParameterAnnotation parameter, False))
                | parameter <- map (typeTemplateParameter context) parameters
                , case templateParameterKind parameter of TemplateValueParameterKind _ -> True; _ -> False
                ]
         in (context, templateValues ++ signaturesOf context members)
    TypeDeclaration _ name _ members ->
        let context = emptyTemplateContext catalog (Just (resolvedSymbol name))
         in (context, signaturesOf context members)
    _ -> (emptyTemplateContext catalog Nothing, [])
    where
        signaturesOf context members =
            [(resolvedSymbol (declarationName member), (signature context member, False)) | member <- members]

signature :: TemplateContext -> Declaration ResolvedName () -> Type
signature context declaration = case declaration of
    FunctionDeclaration _ _ _ returnSyntax parameters _ _ _ ->
        FunctionType
            (map (syntaxTypeIn context . parameterTypeSyntax) parameters)
            ( case returnSyntax of
                AutoType ->
                    maybe ErrorType id (lookup (inferredReturnKey declaration) (catalogInferredReturns (templateCatalog context)))
                _ -> syntaxTypeIn context returnSyntax
            )
    TypeDeclaration _ name _ _ -> NamedType (QualifiedName [resolvedSpelling name]) []
    TemplateTypeDeclaration _ name _ parameters _ ->
        NamedType
            (QualifiedName [resolvedSpelling name])
            (map templateParameterAsArgument parameters)
    EnumDeclaration _ name _ _ _ -> enumTypeOf (templateCatalog context) name

-- | The type of the values of a declared enum.
enumTypeOf :: TypeCatalog -> ResolvedName -> Type
enumTypeOf catalog name = maybe ErrorType enumInfoType (enumBySymbol (catalogEnums catalog) (resolvedSymbol name))

checkTopDeclaration :: TypeCatalog -> Declaration ResolvedName () -> (Declaration ResolvedName Type, [Diagnostic])
checkTopDeclaration catalog declaration = case declaration of
    TypeDeclaration spanValue name _ members ->
        let (context, signatures) = memberScope catalog declaration
            checked = map (checkDeclarationWith context signatures) members
            overloadProblems = duplicateOverloadProblems context members
            valueType = NamedType (QualifiedName [resolvedSpelling name]) []
         in (TypeDeclaration spanValue name valueType (map fst checked), overloadProblems ++ concatMap snd checked)
    TemplateTypeDeclaration spanValue name _ parameters members ->
        let (context, scope) = memberScope catalog declaration
            typedTemplateParameters = map (typeTemplateParameter context) parameters
            checked = map (checkDeclarationWith context scope) members
            parameterProblems = validateTemplateParameters context parameters
            overloadProblems = duplicateOverloadProblems context members
            valueType =
                NamedType
                    (QualifiedName [resolvedSpelling name])
                    (map templateParameterAsArgument typedTemplateParameters)
         in ( TemplateTypeDeclaration spanValue name valueType typedTemplateParameters (map fst checked)
            , parameterProblems ++ overloadProblems ++ concatMap snd checked
            )
    FunctionDeclaration {} -> checkDeclarationWith (emptyTemplateContext catalog Nothing) [] declaration
    EnumDeclaration spanValue name _ underlying cases ->
        ( EnumDeclaration spanValue name (enumTypeOf catalog name) underlying cases
        , enumDeclarationProblems declaration
        )

checkDeclarationWith ::
    TemplateContext -> TypeEnvironment -> Declaration ResolvedName () -> (Declaration ResolvedName Type, [Diagnostic])
checkDeclarationWith context globals declaration@FunctionDeclaration {} =
    let parameters =
            [ (resolvedSymbol (parameterName parameter), (syntaxTypeIn context (parameterTypeSyntax parameter), False))
            | parameter <- declarationParameters declaration
            ]
        expected = syntaxTypeIn context (declarationReturnSyntax declaration)
        (body, _, _, problems) = checkBlockWith context (parameters ++ globals) expected outsideLoops (declarationBody declaration)
        finalReturn = finalExpressionType body
        -- Every return of the body counts, also one reached through an
        -- expression; the returns of a nested callable are its own.
        returns = blockReturnTypes body ++ maybe [] (: []) finalReturn
        inferred = inferReturn expected returns
        isInferred = case declarationReturnSyntax declaration of AutoType -> True; _ -> False
        returnProblems
            | expected /= ErrorType && any (not . compatible expected) returns =
                [ Diagnostic
                    TypeCheckerStage
                    Error
                    "TAT0001"
                    (Just (declarationSpan declaration))
                    "return expression does not match the declared function type"
                ]
            | isInferred && any (not . compatible inferred) returns =
                [ problem
                    (declarationSpan declaration)
                    "TAT0062"
                    "the return statements of this method carry values of different types"
                ]
            -- Every result of the method is a call that depends on the
            -- method itself: nothing gives it a type.
            | isInferred && inferred == ErrorType && null problems =
                [ problem
                    (declarationSpan declaration)
                    "TAT0063"
                    "the return type of this method cannot be inferred: no result is independent of the method itself"
                ]
            | otherwise = []
        typedParameters = map (typeParameterWith context) (declarationParameters declaration)
        signatureProblems =
            typeSyntaxProblemsIn context (declarationReturnSyntax declaration)
                ++ concatMap (typeSyntaxProblemsIn context . parameterTypeSyntax) (declarationParameters declaration)
        functionType = FunctionType (map parameterAnnotation typedParameters) inferred
     in ( FunctionDeclaration
            (declarationSpan declaration)
            (declarationName declaration)
            functionType
            (declarationReturnSyntax declaration)
            typedParameters
            body
            (declarationIsStatic declaration)
            (declarationAccess declaration)
        , signatureProblems ++ problems ++ returnProblems
        )
checkDeclarationWith context _ declaration@TypeDeclaration {} = checkTopDeclaration (templateCatalog context) declaration
checkDeclarationWith context _ declaration@TemplateTypeDeclaration {} = checkTopDeclaration (templateCatalog context) declaration
checkDeclarationWith context _ declaration@EnumDeclaration {} = checkTopDeclaration (templateCatalog context) declaration

-- A method overload is distinguished only by its ordered parameter types.
-- Access, return type, and static-ness intentionally do not rescue duplicate
-- signatures; that matches the declaration rules in Spec/Language/Decls.tala.
duplicateOverloadProblems :: TemplateContext -> [Declaration ResolvedName ()] -> [Diagnostic]
duplicateOverloadProblems context members = reverse problems
    where
        -- The signatures seen so far are kept by method name, so that a
        -- method is compared with its own overloads only. Comparing it with
        -- every earlier member made a type with thousands of methods take
        -- time with the square of their number.
        (_, problems) = foldl inspect (Map.empty, []) members
        inspect (seen, diagnostics) declaration@FunctionDeclaration {} =
            let spelling = resolvedSpelling (declarationName declaration)
                parameterTypes = methodParameterTypes declaration
                duplicate = parameterTypes `elem` Map.findWithDefault [] spelling seen
                currentDiagnostics =
                    if duplicate
                        then
                            [ problem
                                (declarationSpan declaration)
                                "TAT0028"
                                ("method overload has a duplicate parameter signature: " ++ identifierText spelling)
                            ]
                        else []
             in (Map.insertWith (++) spelling [parameterTypes] seen, reverse currentDiagnostics ++ diagnostics)
        inspect state _ = state
        methodParameterTypes FunctionDeclaration {declarationParameters = parameters} =
            map (syntaxTypeIn context . parameterTypeSyntax) parameters
        methodParameterTypes _ = []

typeParameterWith :: TemplateContext -> Parameter ResolvedName () -> Parameter ResolvedName Type
typeParameterWith context parameter =
    Parameter
        (parameterSpan parameter)
        (parameterName parameter)
        (syntaxTypeIn context (parameterTypeSyntax parameter))
        (parameterTypeSyntax parameter)

inferReturn :: Type -> [Type] -> Type
inferReturn declared _ | declared /= ErrorType = declared
inferReturn _ [] = voidType
inferReturn _ values = case filter (/= ErrorType) values of [] -> ErrorType; first : _ -> first

compatible :: Type -> Type -> Bool
compatible ErrorType _ = True
compatible _ ErrorType = True
compatible left right = left == right

-- | The context inside a block used as a value at the given place.
insideValueBlock :: TemplateContext -> LoopContext
insideValueBlock context = LoopContext StatementLoop (ValueBlockEdge : enclosingLoops (contextLoops context))

{- | The context of the condition of the loop that is about to be checked in
the given context: a transfer there reaches that loop.
-}
inLoopCondition :: LoopContext -> TemplateContext -> TemplateContext
inLoopCondition loops context = context {contextLoops = loopCondition loops}

{- | The checker for expressions and statements as the branching rules of
"Progmasoft.Tala.TypeChecker.Branching" receive it: applied to the template
context and to the type that a @return@ must have.
-}
branchChecker :: TemplateContext -> Type -> BranchChecker LoopContext
branchChecker context expected =
    BranchChecker
        { branchExpression = checkExpressionExpectedWith context
        , branchStatements = \environment loops statements ->
            let (Block typed, final, returns, problems) = checkBlockWith context environment expected loops (Block statements)
             in (typed, final, returns, problems)
        , branchType = \syntax -> (syntaxTypeIn context syntax, typeSyntaxProblemsIn context syntax)
        , branchLiteral = literalTypeInContext
        , branchEnumMember = enumMemberValue (catalogEnums (templateCatalog context))
        , branchHasEffect = effectCapable
        , branchValueLoops = insideValueBlock context
        }

-- | The context of a statement that belongs to a loop header, not its body.
settledLoops :: LoopContext -> LoopContext
settledLoops loops = loops {pendingLoop = StatementLoop}

checkBlockWith ::
    TemplateContext ->
    TypeEnvironment ->
    Type ->
    LoopContext ->
    Block ResolvedName () ->
    (Block ResolvedName Type, TypeEnvironment, [Type], [Diagnostic])
checkBlockWith context environment expected loops (Block statements) =
    let (checked, final, returns, problems) = go environment statements in (Block checked, final, returns, problems)
    where
        go env [] = ([], env, [], [])
        go env (statement : rest) =
            let (typed, next, returned, firstProblems) = checkStatementWith context env expected loops statement
                (remaining, final, laterReturns, laterProblems) = go next rest
             in (typed : remaining, final, returned ++ laterReturns, firstProblems ++ laterProblems)

checkStatementWith ::
    TemplateContext ->
    TypeEnvironment ->
    Type ->
    LoopContext ->
    Statement ResolvedName () ->
    (Statement ResolvedName Type, TypeEnvironment, [Type], [Diagnostic])
checkStatementWith outer environment expected loops =
    checkStatementIn (outer {contextReturn = expected, contextLoops = loops}) environment expected loops

-- The context already names the return type and the loops of the statement.
checkStatementIn ::
    TemplateContext ->
    TypeEnvironment ->
    Type ->
    LoopContext ->
    Statement ResolvedName () ->
    (Statement ResolvedName Type, TypeEnvironment, [Type], [Diagnostic])
checkStatementIn context environment expected loops statement = case statement of
    BindingStatement spanValue kind syntax name _ value ->
        let declared = syntaxTypeIn context syntax
            target = if declared == ErrorType then Nothing else Just declared
            (typedValue, valueType, problems) = checkExpressionExpectedWith context environment target value
            bindingType = if declared == ErrorType then valueType else declared
            mismatch =
                if compatible bindingType valueType then [] else [problem spanValue "TAT0002" "binding initializer has the wrong type"]
            constantProblems = constantRangeProblems spanValue bindingType typedValue
            mutable = kind == MutableBinding
         in ( BindingStatement spanValue kind syntax name bindingType typedValue
            , (resolvedSymbol name, (bindingType, mutable)) : environment
            , []
            , typeSyntaxProblemsIn context syntax ++ problems ++ mismatch ++ constantProblems
            )
    AssignmentStatement spanValue name _ value ->
        -- The target type is context for the value, as a declared type is
        -- for a binding initializer: it types an otherwise untyped literal.
        let target = lookup (resolvedSymbol name) environment
            targetType = maybe ErrorType fst target
            valueExpected = if targetType == ErrorType then Nothing else Just targetType
            (typedValue, valueType, problems) = checkExpressionExpectedWith context environment valueExpected value
            immutable = case target of Just (_, False) -> [problem spanValue "TAT0003" "cannot assign to an immutable binding"]; _ -> []
            mismatch = if compatible targetType valueType then [] else [problem spanValue "TAT0004" "assignment value has the wrong type"]
         in (AssignmentStatement spanValue name targetType typedValue, environment, [], problems ++ immutable ++ mismatch)
    ReturnStatement spanValue value ->
        let (typedValue, valueType, problems) = checkOptionalExpectedWith context environment (Just expected) value
            mismatch = if compatible expected valueType then [] else [problem spanValue "TAT0005" "return value has the wrong type"]
         in (ReturnStatement spanValue typedValue, environment, [valueType], problems ++ mismatch)
    IfStatement spanValue condition trueBlock falseBlock ->
        let (typedCondition, conditionType, conditionProblems) = checkExpressionWith context environment condition
            conditionMismatch =
                if booleanContextType conditionType
                    then []
                    else [problem spanValue "TAT0006" "if condition must be bool or numeric"]
            (typedTrue, _, trueReturns, trueProblems) = checkBlockWith context environment expected loops trueBlock
            (typedFalse, falseReturns, falseProblems) = case falseBlock of
                Nothing -> (Nothing, [], [])
                Just value ->
                    let (block, _, returns, problems) = checkBlockWith context environment expected loops value
                     in (Just block, returns, problems)
         in ( IfStatement spanValue typedCondition typedTrue typedFalse
            , environment
            , trueReturns ++ falseReturns
            , conditionProblems ++ conditionMismatch ++ trueProblems ++ falseProblems
            )
    WhileStatement spanValue condition body ->
        let (typedCondition, conditionType, conditionProblems) = checkExpressionWith (inLoopCondition loops context) environment condition
            conditionProblems' =
                if booleanContextType conditionType
                    then []
                    else [problem spanValue "TAT0020" "while condition must be bool or numeric"]
            (typedBody, _, returns, bodyProblems) = checkBlockWith context environment expected (enterLoop loops) body
         in ( WhileStatement spanValue typedCondition typedBody
            , environment
            , returns
            , conditionProblems ++ conditionProblems' ++ bodyProblems
            )
    DoWhileStatement spanValue body condition ->
        let (typedBody, _, returns, bodyProblems) = checkBlockWith context environment expected (enterLoop loops) body
            (typedCondition, conditionType, conditionProblems) = checkExpressionWith (inLoopCondition loops context) environment condition
            conditionProblems' =
                if booleanContextType conditionType
                    then []
                    else [problem spanValue "TAT0020" "do/while condition must be bool or numeric"]
         in ( DoWhileStatement spanValue typedBody typedCondition
            , environment
            , returns
            , bodyProblems ++ conditionProblems ++ conditionProblems'
            )
    ForStatement spanValue initializer condition updates body ->
        let (typedInitializer, loopEnvironment, initializerProblems) = case initializer of
                Nothing -> (Nothing, environment, [])
                Just value ->
                    let (typed, nested, _, problems) = checkStatementWith context environment expected (settledLoops loops) value
                     in (Just typed, nested, problems)
            (typedCondition, conditionType, conditionProblems) = case condition of
                Nothing -> (Nothing, boolType, [])
                Just value ->
                    let (typed, valueType, problems) = checkExpressionWith (inLoopCondition loops context) loopEnvironment value
                     in (Just typed, valueType, problems)
            conditionProblems' =
                if booleanContextType conditionType
                    then []
                    else [problem spanValue "TAT0020" "for condition must be bool or numeric"]
            (typedBody, _, returns, bodyProblems) = checkBlockWith context loopEnvironment expected (enterLoop loops) body
            (typedUpdates, updateProblems) = checkStatementsWith context loopEnvironment expected (loopUpdate loops) updates
         in ( ForStatement spanValue typedInitializer typedCondition typedUpdates typedBody
            , environment
            , returns
            , initializerProblems ++ conditionProblems ++ conditionProblems' ++ bodyProblems ++ updateProblems
            )
    ForEachStatement spanValue kind syntax name _ source body ->
        let valueType = syntaxTypeIn context syntax
            (typedSource, _, sourceProblems) = checkExpressionWith context environment source
            (typedBody, _, returns, bodyProblems) =
                checkBlockWith
                    context
                    ((resolvedSymbol name, (valueType, kind == MutableBinding)) : environment)
                    expected
                    (enterLoop loops)
                    body
            unsupported = problem spanValue "TAT0021" "enumerable for loops require the generator and Enumerable ABI, which is not implemented"
         in ( ForEachStatement spanValue kind syntax name valueType typedSource typedBody
            , environment
            , returns
            , unsupported : typeSyntaxProblemsIn context syntax ++ sourceProblems ++ bodyProblems
            )
    IncrementStatement spanValue name _ ->
        let target = lookup (resolvedSymbol name) environment
            targetType = maybe ErrorType fst target
            writableProblems = case target of
                Just (_, False) -> [problem spanValue "TAT0022" "increment cannot modify an immutable binding"]
                Nothing -> [problem spanValue "TAT0023" "increment target is not defined"]
                _ -> []
            numericProblems =
                if isNumericType targetType && targetType /= boolType
                    then []
                    else [problem spanValue "TAT0024" "increment target must have a numeric type"]
         in (IncrementStatement spanValue name targetType, environment, [], writableProblems ++ numericProblems)
    CompoundAssignmentStatement spanValue Add name _ value
        | Just (targetType, writable) <- lookup (resolvedSymbol name) environment
        , targetType == stringType ->
            -- `text += value` is `text = text + value`: the value is
            -- written as text and joined to what the target holds.
            let (typedValue, valueType, problems) = checkExpressionWith context environment value
                (joined, _, joinProblems) =
                    concatenation spanValue (NameExpression spanValue name stringType, stringType) (typedValue, valueType)
                immutable = [problem spanValue "TAT0003" "cannot assign to an immutable binding" | not writable]
             in ( AssignmentStatement spanValue name stringType joined
                , environment
                , []
                , problems ++ immutable ++ joinProblems
                )
    CompoundAssignmentStatement spanValue operator name _ value ->
        -- `target op= value` has the typing of `target = target op value`:
        -- the operator rule is applied to the target type and the result
        -- must be storable without a conversion.
        let target = lookup (resolvedSymbol name) environment
            targetType = maybe ErrorType fst target
            operandExpected = if targetType == ErrorType then Nothing else Just targetType
            (typedValue, valueType, problems) = checkExpressionExpectedWith context environment operandExpected value
            immutable = case target of
                Just (_, False) -> [problem spanValue "TAT0003" "cannot assign to an immutable binding"]
                _ -> []
            rule = binaryNumericRule operator targetType valueType
            known = targetType /= ErrorType && valueType /= ErrorType
            operatorProblems = if known then ruleProblems spanValue "TAT0012" rule else []
            resultProblems =
                if known && null operatorProblems && numericRuleType rule /= targetType
                    then [problem spanValue "TAT0035" "compound assignment result does not have the target type"]
                    else []
         in ( CompoundAssignmentStatement spanValue operator name targetType typedValue
            , environment
            , []
            , problems ++ immutable ++ operatorProblems ++ resultProblems
            )
    DiscardStatement spanValue value ->
        let (typedValue, _, problems) = checkExpressionWith context environment value
         in (DiscardStatement spanValue typedValue, environment, [], problems)
    BreakStatement spanValue value ->
        -- A break leaves the innermost loop. Whether it may, or must, carry
        -- a value is decided by how that loop is used; the value takes its
        -- context from the place that receives the loop's value.
        let target = transferTarget loops
            valueExpected = case target of
                Just (ExpressionLoop expectedValue) -> expectedValue
                Just (LoopCondition (ExpressionLoop expectedValue)) -> expectedValue
                Just (LoopUpdate (ExpressionLoop expectedValue)) -> expectedValue
                _ -> Nothing
            (typedValue, _, valueProblems) = checkOptionalExpectedWith context environment valueExpected value
            placement kind = case (kind, value) of
                (StatementLoop, Just _) ->
                    [problem spanValue "TAT0026" "a value-carrying break is only valid in a loop used as an expression"]
                (ExpressionLoop _, Nothing) ->
                    [problem spanValue "TAT0040" "a loop used as an expression must be left by a break that carries a value"]
                -- A break in the condition or the update clause of a loop
                -- leaves that loop.
                (LoopCondition loop, _) -> placement loop
                (LoopUpdate loop, _) -> placement loop
                _ -> []
            placementProblems = case target of
                Nothing -> [problem spanValue "TAT0025" "break is only valid inside a loop"]
                Just kind -> placement kind
         in (BreakStatement spanValue typedValue, environment, [], placementProblems ++ valueProblems)
    ContinueStatement spanValue ->
        -- A continue in the condition of a loop evaluates that condition
        -- again, and one in the update clause ends the update: the
        -- condition of the loop is tested next.
        let problems = case transferTarget loops of
                Nothing -> [problem spanValue "TAT0027" "continue is only valid inside a loop"]
                _ -> []
         in (ContinueStatement spanValue, environment, [], problems)
    GuardStatement spanValue condition block ->
        let (typedCondition, conditionType, conditionProblems) = checkExpressionWith context environment condition
            conditionMismatch =
                [ problem spanValue "TAT0060" "guard condition must be bool or numeric"
                | conditionType /= ErrorType
                , not (booleanContextType conditionType)
                ]
            (typedBlock, _, returns, blockProblems) = checkBlockWith context environment expected loops block
         in ( GuardStatement spanValue typedCondition typedBlock
            , environment
            , returns
            , conditionProblems ++ conditionMismatch ++ blockProblems ++ guardBlockProblems spanValue typedBlock
            )
    -- A nested block is checked in the scope it starts in; what it declares
    -- does not reach the statements after it.
    BlockStatement spanValue block ->
        let (typedBlock, _, returns, problems) = checkBlockWith context environment expected loops block
         in (BlockStatement spanValue typedBlock, environment, returns, problems)
    -- A match that is a statement of its own: its arms are statements, they
    -- may return and may leave the enclosing loop, and no arm has to accept.
    ExpressionStatement spanValue (MatchExpression matchSpan subjects arms _) terminated
        | terminated ->
            let (typedMatch, _, returns, problems) =
                    checkMatch (branchChecker context expected) (MatchStatement loops) environment Nothing matchSpan subjects arms
             in (ExpressionStatement spanValue typedMatch terminated, environment, returns, problems)
    ExpressionStatement spanValue value terminated ->
        let (typedValue, _, problems) = checkExpressionWith context environment value
            effectProblems =
                if terminated && not (effectCapable value)
                    then [problem spanValue "TAT0013" "pure value expression cannot be used as a statement"]
                    else []
         in (ExpressionStatement spanValue typedValue terminated, environment, [], problems ++ effectProblems)

checkStatementsWith ::
    TemplateContext ->
    TypeEnvironment ->
    Type ->
    LoopContext ->
    [Statement ResolvedName ()] ->
    ([Statement ResolvedName Type], [Diagnostic])
checkStatementsWith context environment expected loops = go environment
    where
        go _ [] = ([], [])
        go current (statement : remaining) =
            let (typed, next, _, problems) = checkStatementWith context current expected loops statement
                (later, laterProblems) = go next remaining
             in (typed : later, problems ++ laterProblems)

finalExpressionType :: Block ResolvedName Type -> Maybe Type
finalExpressionType (Block statements) = case reverse statements of
    ExpressionStatement _ expression False : _ -> Just (typedExpressionType expression)
    _ -> Nothing

effectCapable :: Expression name annotation -> Bool
effectCapable CallExpression {} = True
effectCapable (IsPatternExpression _ subject _ _) = effectCapable subject
effectCapable (ConditionalExpression _ condition first second _) = any effectCapable [condition, first, second]
effectCapable (CoalesceExpression _ left fallback _) = effectCapable left || effectCapable fallback
effectCapable AssignmentExpression {} = True
effectCapable IncrementExpression {} = True
effectCapable LoopExpression {} = True
effectCapable (BlockExpression _ (Block statements) _) = not (null statements)
effectCapable (MatchExpression _ subjects arms _) =
    any effectCapable (subjects ++ concatMap matchArmExpressions arms)
effectCapable CallableExpression {} = False
effectCapable _ = False

checkOptionalWith ::
    TemplateContext ->
    TypeEnvironment ->
    Maybe (Expression ResolvedName ()) ->
    (Maybe (Expression ResolvedName Type), Type, [Diagnostic])
checkOptionalWith _ _ Nothing = (Nothing, voidType, [])
checkOptionalWith context environment (Just value) =
    let (typed, valueType, problems) = checkExpressionWith context environment value
     in (Just typed, valueType, problems)

checkOptionalExpectedWith ::
    TemplateContext ->
    TypeEnvironment ->
    Maybe Type ->
    Maybe (Expression ResolvedName ()) ->
    (Maybe (Expression ResolvedName Type), Type, [Diagnostic])
checkOptionalExpectedWith _ _ _ Nothing = (Nothing, voidType, [])
checkOptionalExpectedWith context environment expected (Just value) =
    let (typed, valueType, problems) = checkExpressionExpectedWith context environment expected value
     in (Just typed, valueType, problems)

checkExpressionWith ::
    TemplateContext ->
    TypeEnvironment ->
    Expression ResolvedName () ->
    (Expression ResolvedName Type, Type, [Diagnostic])
checkExpressionWith context environment = checkExpressionExpectedWith context environment Nothing

-- Expected types are semantic context, not conversions.  They choose the
-- representation of an otherwise untyped numeric literal and allow the
-- boolean numeric rule, but never silently convert a computed value.
checkExpressionExpectedWith ::
    TemplateContext ->
    TypeEnvironment ->
    Maybe Type ->
    Expression ResolvedName () ->
    (Expression ResolvedName Type, Type, [Diagnostic])
checkExpressionExpectedWith context environment expected expression = case expression of
    NameExpression spanValue name _ ->
        let valueType = maybe ErrorType fst (lookup (resolvedSymbol name) environment)
            problems = if valueType == ErrorType then [problem spanValue "TAT0007" "name has no known type"] else []
         in (NameExpression spanValue name valueType, valueType, problems)
    LiteralExpression spanValue literal _ ->
        let (valueType, problems) = literalTypeInContext spanValue expected literal
         in (LiteralExpression spanValue literal valueType, valueType, problems)
    -- @Enum.Member@ is the value of that member. It is a constant of the
    -- enum's type, and it is kept as the integer literal it stands for.
    MemberAccessExpression spanValue (NameExpression _ name _) member _
        | Just info <- enumBySymbol (catalogEnums (templateCatalog context)) (resolvedSymbol name) ->
            let valueType = enumInfoType info
             in case lookup member (enumInfoMembers info) of
                    Just value -> (LiteralExpression spanValue (IntegerLiteral value) valueType, valueType, [])
                    Nothing ->
                        ( LiteralExpression spanValue (IntegerLiteral 0) valueType
                        , ErrorType
                        ,
                            [ problem
                                spanValue
                                "TAT0064"
                                ( "the enum "
                                    ++ identifierText (resolvedSpelling name)
                                    ++ " has no member named "
                                    ++ identifierText member
                                )
                            ]
                        )
    -- @.Member@ is the member of that name of the enum the place expects.
    -- Without an expected enum type there is nothing to select from.
    MemberAccessExpression spanValue (LiteralExpression _ UnitLiteral _) member _ ->
        let enums = catalogEnums (templateCatalog context)
         in case [valueType | Just valueType <- [expected], isEnumType valueType] of
                valueType : _ -> case enumMemberValue enums valueType member of
                    Just value -> (LiteralExpression spanValue (IntegerLiteral value) valueType, valueType, [])
                    Nothing ->
                        ( LiteralExpression spanValue (IntegerLiteral 0) valueType
                        , ErrorType
                        , [problem spanValue "TAT0064" ("the expected enum has no member named " ++ identifierText member)]
                        )
                [] ->
                    ( LiteralExpression spanValue (IntegerLiteral 0) ErrorType
                    , ErrorType
                    ,
                        [ problem
                            spanValue
                            "TAT0069"
                            "a target-typed .Member needs a place whose type is known to be an enum"
                        ]
                    )
    MemberAccessExpression spanValue receiver member _ ->
        let (typedReceiver, _, receiverProblems) = checkExpressionWith context environment receiver
            memberProblems = [problem spanValue "TAT0034" "member selection is currently supported only as a type-qualified method call"]
         in (MemberAccessExpression spanValue typedReceiver member ErrorType, ErrorType, receiverProblems ++ memberProblems)
    -- @Type::Method@ is the static method as a callable value.
    MethodReferenceExpression spanValue (NameExpression _ name _) member _
        | resolvedSymbol name `elem` map fst (catalogTypes (templateCatalog context)) ->
            methodValue context expected spanValue (resolvedSymbol name) member
    -- A reference through a value is a method bound to that value, which
    -- needs the methods of values.
    MethodReferenceExpression spanValue receiver member _ ->
        let (typedReceiver, _, receiverProblems) = checkExpressionWith context environment receiver
            memberProblems =
                [ problem
                    spanValue
                    "TAT0081"
                    "a method reference is currently supported only for a static method named through its type"
                ]
         in (MethodReferenceExpression spanValue typedReceiver member ErrorType, ErrorType, receiverProblems ++ memberProblems)
    CallExpression spanValue callee arguments _ ->
        case callee of
            MemberAccessExpression _ receiver member _ ->
                checkTypeQualifiedCall context environment expected spanValue receiver member arguments
            NameExpression calleeSpan name _
                | Just owner <- memberOwnerForSymbol context (resolvedSymbol name)
                , Just owner == templateCurrentType context ->
                    checkMemberOverloadCall
                        context
                        environment
                        expected
                        spanValue
                        calleeSpan
                        (overloadsFor context owner (resolvedSpelling name))
                        arguments
                        False
            _ -> checkOrdinaryCall context environment spanValue callee arguments
    UnaryExpression spanValue operator value _ ->
        let operandExpected = if operator == LogicalNot then Nothing else expected
            (typedValue, valueType, problems) = checkExpressionExpectedWith context environment operandExpected value
            rule = unaryNumericRule operator valueType
            -- An operand without a type was reported already, or never
            -- yields a value; either way the operator has nothing to check.
            (resultType, mismatch) =
                if valueType == ErrorType
                    then (ErrorType, [])
                    else (numericRuleType rule, ruleProblems spanValue "TAT0011" rule)
         in (UnaryExpression spanValue operator typedValue resultType, resultType, problems ++ mismatch)
    BinaryExpression spanValue operator left right _ ->
        -- A Boolean result does not imply Boolean operands: pushing the return
        -- context into 1 == 2 would convert both literals to true. Comparisons
        -- infer their operand domain; logical operands may use distinct numeric
        -- types and therefore do not borrow each other's expected type.
        let leftResult = case (operator, expected) of
                (FloorDivide, Just target)
                    | isIntegerType target ->
                        let inferred@(_, inferredType, _) = checkExpressionWith context environment left
                         in if isIntegerType inferredType
                                then checkExpressionExpectedWith context environment (Just target) left
                                else inferred
                (FloorDivide, _) -> checkExpressionWith context environment left
                _ -> checkExpressionExpectedWith context environment (if booleanResult operator then Nothing else expected) left
            (typedLeft, leftType, leftProblems) = leftResult
            -- The other side of a string is whatever it is by itself: `+`
            -- writes it as text, so it does not borrow the string's type.
            rightExpected =
                if operator `elem` [LogicalAnd, LogicalOr] || leftType == stringType then Nothing else Just leftType
            (typedRight, rightType, rightProblems) = checkExpressionExpectedWith context environment rightExpected right
            rule = binaryNumericRule operator leftType rightType
            typed = leftType /= ErrorType && rightType /= ErrorType
            -- `+` with a string on either side joins the two as text, and
            -- `==` and `\=` on two strings compare their characters.
            joins = typed && operator == Add && (leftType == stringType || rightType == stringType)
            comparesText = typed && operator `elem` [Equal, NotEqual] && leftType == stringType && rightType == stringType
            -- An operand without a type was reported already, or never
            -- yields a value; either way the operator has nothing to check.
            -- Values of an enum are compared for equality with values of
            -- the same enum, and take part in no other operation.
            (resultType, mismatch)
                | leftType == ErrorType || rightType == ErrorType =
                    (if booleanResult operator then boolType else ErrorType, [])
                | isEnumType leftType || isEnumType rightType =
                    if operator `elem` [Equal, NotEqual] && leftType == rightType
                        then (boolType, [])
                        else
                            ( if booleanResult operator then boolType else ErrorType
                            ,
                                [ problem
                                    spanValue
                                    "TAT0065"
                                    "values of an enum are only compared, with == and \\=, with values of the same enum"
                                ]
                            )
                | otherwise = (numericRuleType rule, ruleProblems spanValue "TAT0012" rule)
            withOperands (value, valueType, problems) = (value, valueType, leftProblems ++ rightProblems ++ problems)
         in if joins
                then withOperands (concatenation spanValue (typedLeft, leftType) (typedRight, rightType))
                else
                    if comparesText
                        then withOperands (textEquality spanValue (operator == Equal) typedLeft typedRight)
                        else
                            ( BinaryExpression spanValue operator typedLeft typedRight resultType
                            , resultType
                            , leftProblems ++ rightProblems ++ mismatch
                            )
    IsPatternExpression spanValue subject patternValue _ ->
        let (typedSubject, subjectType, subjectProblems) = checkExpressionWith context environment subject
            (typedPattern, patternProblems) = checkPatternWith context subjectType patternValue
         in ( IsPatternExpression spanValue typedSubject typedPattern boolType
            , boolType
            , subjectProblems ++ patternProblems
            )
    ConditionalExpression spanValue condition first second _ ->
        let (typedCondition, conditionType, conditionProblems) = checkExpressionWith context environment condition
            conditionMismatch =
                [ problem (sourceSpanOf condition) "TAT0036" "conditional test must be bool or numeric"
                | conditionType /= ErrorType
                , not (booleanContextType conditionType)
                ]
            ((typedFirst, firstType, firstProblems), (typedSecond, secondType, secondProblems)) =
                checkOperandPair context environment expected first second
            -- A block that leaves instead of completing has no value, so
            -- the other block alone gives the expression its type.
            -- When neither completes, the expression never yields a value:
            -- it is annotated void, and what receives it is not held to a
            -- type, because that place is never reached.
            (annotation, resultType, resultProblems) = case (doesNotComplete typedFirst, doesNotComplete typedSecond) of
                (True, True) -> (voidType, ErrorType, [])
                (True, False) -> (secondType, secondType, [])
                (False, True) -> (firstType, firstType, [])
                -- A string is selected like a scalar: one of the two is
                -- the value, and the other is never made.
                (False, False)
                    | firstType == stringType && secondType == stringType -> (stringType, stringType, [])
                    | otherwise ->
                        let (valueType, problems) =
                                selectedValueType spanValue "TAT0037" "conditional results must have the same type" firstType secondType
                         in (valueType, valueType, problems)
         in ( ConditionalExpression spanValue typedCondition typedFirst typedSecond annotation
            , resultType
            , conditionProblems ++ conditionMismatch ++ firstProblems ++ secondProblems ++ resultProblems
            )
    CoalesceExpression spanValue left fallback _ ->
        let ((typedLeft, leftType, leftProblems), (typedFallback, fallbackType, fallbackProblems)) =
                checkOperandPair context environment expected left fallback
            (resultType, resultProblems) =
                selectedValueType
                    spanValue
                    "TAT0038"
                    "truthy coalescing operands must have the same type"
                    leftType
                    fallbackType
         in ( CoalesceExpression spanValue typedLeft typedFallback resultType
            , resultType
            , leftProblems ++ fallbackProblems ++ resultProblems
            )
    -- An assignment used as a value has the typing of its statement form and
    -- yields the stored value, so its type is the target type. The context
    -- that receives the value does not flow into the right operand: the
    -- target alone decides what may be stored.
    AssignmentExpression spanValue Nothing name value _ ->
        let target = lookup (resolvedSymbol name) environment
            targetType = maybe ErrorType fst target
            valueExpected = if targetType == ErrorType then Nothing else Just targetType
            (typedValue, valueType, problems) = checkExpressionExpectedWith context environment valueExpected value
            immutable = immutableTargetProblems spanValue target
            mismatch =
                [problem spanValue "TAT0004" "assignment value has the wrong type" | not (compatible targetType valueType)]
         in ( AssignmentExpression spanValue Nothing name typedValue targetType
            , targetType
            , problems ++ immutable ++ mismatch
            )
    AssignmentExpression spanValue (Just Add) name value _
        | target@(Just (targetType, _)) <- lookup (resolvedSymbol name) environment
        , targetType == stringType ->
            let (typedValue, valueType, problems) = checkExpressionWith context environment value
                (joined, _, joinProblems) =
                    concatenation spanValue (NameExpression spanValue name stringType, stringType) (typedValue, valueType)
             in ( AssignmentExpression spanValue Nothing name joined stringType
                , stringType
                , problems ++ immutableTargetProblems spanValue target ++ joinProblems
                )
    AssignmentExpression spanValue (Just operator) name value _ ->
        let target = lookup (resolvedSymbol name) environment
            targetType = maybe ErrorType fst target
            operandExpected = if targetType == ErrorType then Nothing else Just targetType
            (typedValue, valueType, problems) = checkExpressionExpectedWith context environment operandExpected value
            immutable = immutableTargetProblems spanValue target
            rule = binaryNumericRule operator targetType valueType
            known = targetType /= ErrorType && valueType /= ErrorType
            operatorProblems = if known then ruleProblems spanValue "TAT0012" rule else []
            resultProblems =
                [ problem spanValue "TAT0035" "compound assignment result does not have the target type"
                | known
                , null operatorProblems
                , numericRuleType rule /= targetType
                ]
         in ( AssignmentExpression spanValue (Just operator) name typedValue targetType
            , targetType
            , problems ++ immutable ++ operatorProblems ++ resultProblems
            )
    IncrementExpression spanValue isPrefix name _ ->
        let target = lookup (resolvedSymbol name) environment
            targetType = maybe ErrorType fst target
            writableProblems = case target of
                Just (_, False) -> [problem spanValue "TAT0022" "increment cannot modify an immutable binding"]
                Nothing -> [problem spanValue "TAT0023" "increment target is not defined"]
                _ -> []
            numericProblems =
                [ problem spanValue "TAT0024" "increment target must have a numeric type"
                | not (isNumericType targetType && targetType /= boolType)
                ]
         in ( IncrementExpression spanValue isPrefix name targetType
            , targetType
            , writableProblems ++ numericProblems
            )
    -- A loop used as an expression yields the operand of the break that
    -- leaves it. It must not be able to end any other way, so its condition
    -- is the constant true, or absent in a `for`, and every break that
    -- leaves it carries a value.
    LoopExpression spanValue loop _ ->
        let loops = LoopContext (ExpressionLoop expected) []
            (typedLoop, _, _, loopProblems) = checkStatementWith context environment (contextReturn context) loops loop
            breakTypes = loopBreakTypes typedLoop
            -- A loop that no break leaves never yields a value; it leaves
            -- through a return or does not end. That is a fact about its
            -- control flow, so it is annotated void and what receives it is
            -- not held to a type.
            -- A loop that only runs forever is still reported as lacking
            -- a value: it is far more likely a forgotten break.
            neverYields =
                null breakTypes
                    && not (null (blockReturnTypes (Block [typedLoop])))
                    && doesNotComplete (LoopExpression spanValue typedLoop voidType)
            (annotation, resultType, resultProblems)
                | neverYields = (voidType, ErrorType, [])
                | otherwise = let (valueType, problems) = loopValueType spanValue breakTypes in (valueType, valueType, problems)
            endProblems =
                [ problem
                    spanValue
                    "TAT0041"
                    "a loop used as an expression can end without a value; its condition must be the constant true"
                | loopMayEndWithoutValue typedLoop
                ]
         in ( LoopExpression spanValue typedLoop annotation
            , resultType
            , loopProblems ++ endProblems ++ resultProblems
            )
    BlockExpression spanValue block _ ->
        checkValueBlock (branchChecker context (contextReturn context)) environment expected spanValue block
    MatchExpression spanValue subjects arms _ ->
        let (typedMatch, resultType, _, problems) =
                checkMatch (branchChecker context (contextReturn context)) MatchValue environment expected spanValue subjects arms
         in (typedMatch, resultType, problems)
    CallableExpression spanValue explicit captures parameters body _ ->
        let checkedCaptures = checkCapturesWith context environment captures
            captureEnvironment =
                [ (resolvedSymbol (captureName capture), (captureAnnotation capture, True))
                | capture <- map firstCapture checkedCaptures
                ]
            typedParameters = map (typeCallableParameterWith context) parameters
            parameterEnvironment =
                [ (resolvedSymbol (parameterName parameter), (parameterAnnotation parameter, False))
                | parameter <- typedParameters
                ]
            callableEnvironment = parameterEnvironment ++ captureEnvironment ++ environment
            (typedBody, resultType, bodyProblems) = checkCallableBodyWith context callableEnvironment body
            callableType = FunctionType (map parameterAnnotation typedParameters) resultType
            -- The result type is inferred from the returns of the body,
            -- which are read through expressions as well; they must agree,
            -- or the callable has no one type to return.
            returnProblems = case typedBody of
                CallableBlockBody block ->
                    [ problem
                        spanValue
                        "TAT0062"
                        "the return statements of this callable carry values of different types"
                    | any (not . compatible resultType) (blockReturnTypes block)
                    ]
                CallableExpressionBody _ -> []
            captureProblems = concatMap captureDiagnostics checkedCaptures
            parameterProblems = concatMap (typeSyntaxProblemsIn context . parameterTypeSyntax) parameters
         in ( CallableExpression
                spanValue
                explicit
                (map firstCapture checkedCaptures)
                typedParameters
                typedBody
                callableType
            , callableType
            , captureProblems ++ parameterProblems ++ bodyProblems ++ returnProblems
            )

{- | Result type of a loop expression from the types of its break values.

The value is materialized in one storage slot, like the result of a
conditional expression, so all break values have one type. Bool, numeric,
enum and string results are lowered today.
-}
loopValueType :: SourceSpan -> [Type] -> (Type, [Diagnostic])
loopValueType spanValue breakTypes = case filter (/= ErrorType) breakTypes of
    [] ->
        ( ErrorType
        , [problem spanValue "TAT0042" "a loop used as an expression has no break that carries a value" | null breakTypes]
        )
    first : remaining
        | any (/= first) remaining ->
            (first, [problem spanValue "TAT0043" "the break values of a loop used as an expression must have the same type"])
        | not (booleanContextType first)
        , not (isEnumType first)
        , first /= stringType ->
            ( first
            , [problem spanValue "TAT0044" "loop expressions currently support only bool, numeric, enum and string results"]
            )
        | otherwise -> (first, [])

-- | Whether the loop can finish by its condition becoming false.
loopMayEndWithoutValue :: Statement ResolvedName Type -> Bool
loopMayEndWithoutValue loop = case loop of
    WhileStatement _ condition _ -> not (isConstantTrue condition)
    ForStatement _ _ condition _ _ -> maybe False (not . isConstantTrue) condition
    _ -> True
    where
        isConstantTrue expression = case expression of
            LiteralExpression _ (BooleanLiteral True) _ -> True
            _ -> False

immutableTargetProblems :: SourceSpan -> Maybe (Type, Bool) -> [Diagnostic]
immutableTargetProblems spanValue target = case target of
    Just (_, False) -> [problem spanValue "TAT0003" "cannot assign to an immutable binding"]
    _ -> []

{- | Check the two value operands of a conditional form exactly once each.

An operand made only of untyped numeric literals takes its type from the
other operand, in either direction, so @flag ? 1 : wide@ selects the type of
@wide@ just as @flag ? wide : 1@ does. The order is chosen from syntax
before either operand is checked; checking an operand twice would make the
cost exponential in the nesting depth of chained conditionals.
-}
checkOperandPair ::
    TemplateContext ->
    TypeEnvironment ->
    Maybe Type ->
    Expression ResolvedName () ->
    Expression ResolvedName () ->
    ( (Expression ResolvedName Type, Type, [Diagnostic])
    , (Expression ResolvedName Type, Type, [Diagnostic])
    )
checkOperandPair context environment expected first second
    | expected == Nothing && takesContextualType first && not (takesContextualType second) =
        let secondResult@(_, secondType, _) = checkExpressionWith context environment second
         in (checkExpressionExpectedWith context environment (contextFrom secondType) first, secondResult)
    | otherwise =
        let firstResult@(_, firstType, _) = checkExpressionExpectedWith context environment expected first
            secondExpected = maybe (contextFrom firstType) Just expected
         in (firstResult, checkExpressionExpectedWith context environment secondExpected second)
    where
        contextFrom valueType = if valueType == ErrorType then Nothing else Just valueType

-- | Whether an expression consists only of numeric literals and arithmetic.
takesContextualType :: Expression name annotation -> Bool
takesContextualType expression = case expression of
    LiteralExpression _ (IntegerLiteral _) _ -> True
    LiteralExpression _ (FloatingLiteral _) _ -> True
    UnaryExpression _ operator value _ -> operator /= LogicalNot && takesContextualType value
    BinaryExpression _ operator left right _ ->
        not (booleanResult operator) && takesContextualType left && takesContextualType right
    _ -> False

{- | Result type shared by the two value operands of a conditional form.

The result is materialized in one storage slot, so both operands must have
the same type. Only bool and numeric results are lowered today; owned values
need move and release rules for the slot that the backend does not have yet.
-}
selectedValueType :: SourceSpan -> String -> String -> Type -> Type -> (Type, [Diagnostic])
selectedValueType spanValue mismatchCode mismatchMessage firstType secondType
    | firstType == ErrorType = (secondType, [])
    | secondType == ErrorType = (firstType, [])
    | firstType /= secondType = (firstType, [problem spanValue mismatchCode mismatchMessage])
    | not (booleanContextType firstType)
    , not (isEnumType firstType) =
        ( firstType
        , [problem spanValue "TAT0039" "conditional expressions currently support only bool, numeric and enum results"]
        )
    | otherwise = (firstType, [])

checkOrdinaryCall ::
    TemplateContext ->
    TypeEnvironment ->
    SourceSpan ->
    Expression ResolvedName () ->
    [Expression ResolvedName ()] ->
    (Expression ResolvedName Type, Type, [Diagnostic])
checkOrdinaryCall context environment spanValue callee arguments =
    let (typedCallee, calleeType, calleeProblems) = checkExpressionExpectedWith context environment Nothing callee
        parameterTypes = case calleeType of FunctionType parameters _ -> parameters; _ -> []
        checkedArguments =
            zipWith
                (\index argument -> checkExpressionExpectedWith context environment (safeIndex parameterTypes index) argument)
                [0 ..]
                arguments
        argumentTypes = map (\(_, valueType, _) -> valueType) checkedArguments
        (resultType, callProblems) = case calleeType of
            FunctionType parameters result
                | length parameters /= length argumentTypes ->
                    (result, [problem spanValue "TAT0008" "call argument count does not match"])
                | and (zipWith compatible parameters argumentTypes) -> (result, [])
                | otherwise -> (result, [problem spanValue "TAT0009" "call argument type does not match"])
            ErrorType -> (ErrorType, [])
            _ -> (ErrorType, [problem spanValue "TAT0010" "expression is not callable"])
     in ( CallExpression spanValue typedCallee (map (\(value, _, _) -> value) checkedArguments) resultType
        , resultType
        , calleeProblems ++ concatMap (\(_, _, ps) -> ps) checkedArguments ++ callProblems
        )

{- | A static method referred to through its type, @Type::Method@: the
method as a callable value, like its bare name inside the type.

A name with one static method that is accessible is that method. A name
with several is the one whose signature the place expects; where the place
expects none of them, or nothing, the reference does not say which is meant.
-}
methodValue ::
    TemplateContext -> Maybe Type -> SourceSpan -> SymbolId -> Identifier -> (Expression ResolvedName Type, Type, [Diagnostic])
methodValue context expected spanValue owner member = case chosen of
    [declaration] ->
        let valueType = signature context declaration
         in (NameExpression spanValue (declarationName declaration) valueType, valueType, [])
    _ -> (NameExpression spanValue (ResolvedName (SymbolId (-1)) member) ErrorType, ErrorType, [failure])
    where
        candidates = overloadsFor context owner member
        static = [candidate | candidate@(MethodCandidate _ FunctionDeclaration {declarationIsStatic = True}) <- candidates]
        visible = map candidateDeclaration (filter (candidateVisibleFrom context) static)
        chosen = case visible of
            [_] -> visible
            _ -> [declaration | declaration <- visible, Just (signature context declaration) == expected]
        failure
            | null candidates = problem spanValue "TAT0029" "no method with this name is declared on the selected type"
            | null static = problem spanValue "TAT0031" "an instance method cannot be referred to through a type name"
            | null visible = problem spanValue "TAT0033" "the selected method is not accessible from this declaration"
            | otherwise =
                problem
                    spanValue
                    "TAT0080"
                    "the method name has several overloads and the place does not expect the type of one of them"

typeQualifiedReceiver :: Expression ResolvedName () -> Maybe ResolvedName
typeQualifiedReceiver (NameExpression _ name _) = Just name
typeQualifiedReceiver _ = Nothing

memberOwnerForSymbol :: TemplateContext -> SymbolId -> Maybe SymbolId
memberOwnerForSymbol context symbol =
    candidateOwner <$> firstMatch
    where
        firstMatch = findCandidate (catalogMethods (templateCatalog context))
        findCandidate [] = Nothing
        findCandidate (candidate : remaining)
            | resolvedSymbol (declarationName (candidateDeclaration candidate)) == symbol = Just candidate
            | otherwise = findCandidate remaining

overloadsFor :: TemplateContext -> SymbolId -> Identifier -> [MethodCandidate]
overloadsFor context owner name =
    [ candidate
    | candidate <- catalogMethods (templateCatalog context)
    , candidateOwner candidate == owner
    , resolvedSpelling (declarationName (candidateDeclaration candidate)) == name
    ]

checkTypeQualifiedCall ::
    TemplateContext ->
    TypeEnvironment ->
    Maybe Type ->
    SourceSpan ->
    Expression ResolvedName () ->
    Identifier ->
    [Expression ResolvedName ()] ->
    (Expression ResolvedName Type, Type, [Diagnostic])
checkTypeQualifiedCall context environment _ callSpan receiver member arguments
    | consoleReceiver receiver =
        checkConsoleCall (checkExpressionExpectedWith context environment) callSpan member arguments
checkTypeQualifiedCall context environment expected callSpan receiver member arguments =
    case typeQualifiedReceiver receiver of
        Just typeName
            | let owner = resolvedSymbol typeName
            , owner `elem` map fst (catalogTypes (templateCatalog context)) ->
                checkMemberOverloadCall
                    context
                    environment
                    expected
                    callSpan
                    (sourceSpanOf receiver)
                    (overloadsFor context owner member)
                    arguments
                    True
        _ ->
            let (typedReceiver, _, receiverProblems) = checkExpressionWith context environment receiver
                argumentsChecked = map (checkExpressionWith context environment) arguments
                typedArguments = [value | (value, _, _) <- argumentsChecked]
                diagnostics =
                    receiverProblems
                        ++ concat [problems | (_, _, problems) <- argumentsChecked]
                        ++ [problem callSpan "TAT0032" "the left side of a static member call must name a declared type"]
             in ( CallExpression
                    callSpan
                    (MemberAccessExpression callSpan typedReceiver member ErrorType)
                    typedArguments
                    ErrorType
                , ErrorType
                , diagnostics
                )

sourceSpanOf :: Expression name annotation -> SourceSpan
sourceSpanOf expression = case expression of
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

checkMemberOverloadCall ::
    TemplateContext ->
    TypeEnvironment ->
    Maybe Type ->
    SourceSpan ->
    SourceSpan ->
    [MethodCandidate] ->
    [Expression ResolvedName ()] ->
    Bool ->
    (Expression ResolvedName Type, Type, [Diagnostic])
checkMemberOverloadCall context environment _ callSpan calleeSpan candidates arguments requireStatic =
    let callableCandidates = if requireStatic then filter candidateIsStatic candidates else candidates
        visibleCandidates = filter (candidateVisibleFrom context) callableCandidates
        candidateAttempts = map attempt visibleCandidates
        viable = [value | value@(_, _, _, True) <- candidateAttempts]
        arityMatches = filter candidateArityMatches visibleCandidates
        failureCode
            | null candidates = "TAT0029"
            | requireStatic && null callableCandidates = "TAT0031"
            | null visibleCandidates = "TAT0033"
            | null arityMatches = "TAT0008"
            | otherwise = "TAT0009"
        failureMessage
            | null candidates = "no method with this name is declared on the selected type"
            | requireStatic && null callableCandidates = "an instance method cannot be called through a type name"
            | null visibleCandidates = "the selected method is not accessible from this declaration"
            | null arityMatches = "call argument count does not match any overload"
            | otherwise = "call argument types do not match any overload"
        (selected, resultType, typedArguments, diagnostics) = case viable of
            [(candidate, valueType, checked, _)] -> (Just candidate, valueType, checked, [])
            [] ->
                ( Nothing
                , ErrorType
                , map (\argument -> fst3 (checkExpressionWith context environment argument)) arguments
                , [problem callSpan failureCode failureMessage]
                )
            _ ->
                ( Nothing
                , ErrorType
                , map (\argument -> fst3 (checkExpressionWith context environment argument)) arguments
                , [problem callSpan "TAT0030" "the call is ambiguous between multiple equally viable overloads"]
                )
        typedCallee = case selected of
            Just candidate ->
                let declaration = candidateDeclaration candidate
                 in NameExpression calleeSpan (declarationName declaration) (signature context declaration)
            Nothing -> case visibleCandidates of
                candidate : _ ->
                    let declaration = candidateDeclaration candidate
                     in NameExpression calleeSpan (declarationName declaration) (signature context declaration)
                [] -> NameExpression calleeSpan (ResolvedName (SymbolId (-1)) (Identifier "<unresolved-member>")) ErrorType
     in (CallExpression callSpan typedCallee typedArguments resultType, resultType, diagnostics)
    where
        attempt candidate =
            let declaration = candidateDeclaration candidate
                functionType = signature context declaration
                (parameters, resultType) = case functionType of
                    FunctionType types result -> (types, result)
                    _ -> ([], ErrorType)
                checkedArguments =
                    zipWith
                        (\index argument -> checkExpressionExpectedWith context environment (safeIndex parameters index) argument)
                        [0 ..]
                        arguments
                argumentTypes = [valueType | (_, valueType, _) <- checkedArguments]
                problems = concat [nested | (_, _, nested) <- checkedArguments]
                matching = length parameters == length arguments && null problems && and (zipWith compatible parameters argumentTypes)
             in (candidate, resultType, [value | (value, _, _) <- checkedArguments], matching)
        candidateIsStatic (MethodCandidate _ FunctionDeclaration {declarationIsStatic = isStatic}) = isStatic
        candidateIsStatic _ = False
        candidateArityMatches candidate = case candidateDeclaration candidate of
            FunctionDeclaration {declarationParameters = parameters} -> length parameters == length arguments
            _ -> False

candidateVisibleFrom :: TemplateContext -> MethodCandidate -> Bool
candidateVisibleFrom context (MethodCandidate owner FunctionDeclaration {declarationAccess = access}) =
    case access of
        PrivateAccess -> templateCurrentType context == Just owner
        ProtectedAccess -> templateCurrentType context == Just owner
        _ -> True
candidateVisibleFrom _ _ = False

fst3 :: (a, b, c) -> a
fst3 (first, _, _) = first

-- A pattern is checked against the already typed subject. This keeps literal
-- inference deterministic and makes the later decision-tree lowering free of
-- source-level conversion guesses.
checkPatternWith :: TemplateContext -> Type -> Pattern ResolvedName () -> (Pattern ResolvedName Type, [Diagnostic])
checkPatternWith context subjectType patternValue = case patternValue of
    WildcardPattern spanValue _ -> (WildcardPattern spanValue subjectType, [])
    NullPattern spanValue _ ->
        let problems =
                if isReferenceType subjectType
                    then []
                    else [problem spanValue "TAT0020" "null pattern requires an AARC reference subject"]
         in (NullPattern spanValue subjectType, problems)
    LiteralPattern spanValue literal _ ->
        let (literalType, literalProblems) = literalTypeInContext spanValue (Just subjectType) literal
            rule = binaryNumericRule Equal subjectType literalType
            problems = literalProblems ++ ruleProblems spanValue "TAT0021" rule
         in (LiteralPattern spanValue literal literalType, problems)
    TypePattern spanValue syntax _ ->
        let targetType = syntaxTypeIn context syntax
            syntaxProblems = typeSyntaxProblemsIn context syntax
            possible =
                targetType /= ErrorType
                    && subjectType /= ErrorType
                    && (compatible subjectType targetType || isReferenceType subjectType && isReferenceType targetType)
            relationProblems =
                if possible
                    then []
                    else [problem spanValue "TAT0022" "type pattern can never match the subject type"]
         in (TypePattern spanValue syntax targetType, syntaxProblems ++ relationProblems)
    RelationalPattern spanValue operator literal _ ->
        let (literalType, literalProblems) = literalTypeInContext spanValue (Just subjectType) literal
            binary = relationalPatternBinary operator
            rule = binaryNumericRule binary subjectType literalType
            problems = literalProblems ++ ruleProblems spanValue "TAT0023" rule
         in (RelationalPattern spanValue operator literal literalType, problems)
    NotPattern spanValue nested _ ->
        let (typed, problems) = checkPatternWith context subjectType nested
         in (NotPattern spanValue typed boolType, problems)
    AndPattern spanValue left right _ -> checkPatternPair AndPattern spanValue left right
    OrPattern spanValue left right _ -> checkPatternPair OrPattern spanValue left right
    where
        checkPatternPair constructor spanValue left right =
            let (typedLeft, leftProblems) = checkPatternWith context subjectType left
                (typedRight, rightProblems) = checkPatternWith context subjectType right
             in (constructor spanValue typedLeft typedRight boolType, leftProblems ++ rightProblems)

relationalPatternBinary :: RelationalPatternOperator -> BinaryOperator
relationalPatternBinary operator = case operator of
    PatternLessThan -> LessThan
    PatternLessEqual -> LessEqual
    PatternGreaterThan -> GreaterThan
    PatternGreaterEqual -> GreaterEqual
    PatternEqual -> Equal
    PatternNotEqual -> NotEqual

type CheckedCapture = (Capture ResolvedName Type, [Diagnostic])

booleanResult :: BinaryOperator -> Bool
booleanResult operator =
    operator `elem` [LogicalAnd, LogicalOr, Equal, NotEqual, LessThan, LessEqual, GreaterThan, GreaterEqual]

firstCapture :: CheckedCapture -> Capture ResolvedName Type
firstCapture = fst

captureDiagnostics :: CheckedCapture -> [Diagnostic]
captureDiagnostics = snd

checkCapturesWith :: TemplateContext -> TypeEnvironment -> [Capture ResolvedName ()] -> [CheckedCapture]
checkCapturesWith context environment = map checkCapture
    where
        checkCapture (Capture spanValue mode name _ initializer) =
            let (typedInitializer, valueType, problems) = checkOptionalWith context environment initializer
                ownershipProblems = case mode of
                    StrongCapture -> []
                    _ | isReferenceType valueType -> []
                    WeakCapture -> [problem spanValue "TAT0014" "weak capture requires an AARC reference value"]
                    UnownedCapture -> [problem spanValue "TAT0015" "unowned capture requires an AARC reference value"]
             in (Capture spanValue mode name valueType typedInitializer, problems ++ ownershipProblems)

-- String and callable values are AARC references. Every canonical scalar is a
-- value, not merely the handful historically accepted by closure tests. Named
-- user and library types remain conservative until resolved declaration
-- metadata connects the ownership catalog to this check.
isReferenceType :: Type -> Bool
isReferenceType valueType = case valueType of
    FunctionType _ _ -> True
    _ | typeToScalarType valueType /= Nothing -> False
    NamedType _ _ -> valueType /= unitType && valueType /= voidType
    _ -> False

typeCallableParameterWith :: TemplateContext -> Parameter ResolvedName () -> Parameter ResolvedName Type
typeCallableParameterWith context parameter =
    let valueType = case parameterTypeSyntax parameter of
            AutoType -> TypeVariable (parameterName parameter)
            syntax -> syntaxTypeIn context syntax
     in Parameter
            (parameterSpan parameter)
            (parameterName parameter)
            valueType
            (parameterTypeSyntax parameter)

checkCallableBodyWith ::
    TemplateContext ->
    TypeEnvironment ->
    CallableBody ResolvedName () ->
    (CallableBody ResolvedName Type, Type, [Diagnostic])
checkCallableBodyWith outer environment body = case body of
    CallableExpressionBody expression ->
        -- A callable is a function of its own: nothing in its body returns
        -- from, or leaves a loop of, the function that creates it.
        let context = outer {contextReturn = ErrorType, contextLoops = outsideLoops}
            (typed, valueType, problems) = checkExpressionWith context environment expression
         in (CallableExpressionBody typed, valueType, problems)
    CallableBlockBody block ->
        let (typed, _, _, problems) = checkBlockWith outer environment ErrorType outsideLoops block
            finalType = maybe (inferReturn ErrorType (blockReturnTypes typed)) id (finalExpressionType typed)
         in (CallableBlockBody typed, finalType, problems)

-- An expression without a type was reported already, or never yields a
-- value; a condition of either kind has nothing to check.
booleanContextType :: Type -> Bool
booleanContextType valueType = valueType == ErrorType || acceptsBooleanContext valueType

safeIndex :: [a] -> Int -> Maybe a
safeIndex values index
    | index < 0 = Nothing
    | otherwise = case drop index values of value : _ -> Just value; [] -> Nothing
