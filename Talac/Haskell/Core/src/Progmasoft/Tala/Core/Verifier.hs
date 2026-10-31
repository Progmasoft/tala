-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Semantic trust boundary for target-independent Core.
Decoded artifacts and generated Core trees must pass this verifier before
CorePrep, optimization, or backend lowering consumes their identities and types.
-}
module Progmasoft.Tala.Core.Verifier (verifyCore) where

import Data.List (group, sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.Scalar
import Progmasoft.Tala.Core.Template
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.RuntimeCall

type Environment = Map.Map SymbolId (Type, Bool)

-- | Validate module, function, type, symbol, return, and source-ownership rules.
verifyCore :: CoreModule -> Either [Diagnostic] CoreModule
verifyCore moduleValue =
    case moduleProblems moduleValue of
        [] -> Right moduleValue
        problems -> Left problems

moduleProblems :: CoreModule -> [Diagnostic]
moduleProblems moduleValue =
    emptyName (coreModuleName moduleValue)
        ++ duplicates "TAC1002" "duplicate Core function symbol" functionSymbols
        ++ sourceCatalogProblems
        ++ concatMap (verifyFunction functionEnvironment) (coreModuleFunctions moduleValue)
    where
        functions = coreModuleFunctions moduleValue
        functionSymbols = map (resolvedSymbol . coreFunctionName) functions
        sourceFiles = coreModuleSourceFiles moduleValue
        sourceOwners = coreModuleFunctionSources moduleValue
        sourceCatalogProblems =
            duplicates "TAC1030" "duplicate Core source file" sourceFiles
                ++ [problem "TAC1031" "Core source file path is empty or contains NUL" | any invalidPath sourceFiles]
                ++ duplicates "TAC1032" "duplicate Core function source owner" (map fst sourceOwners)
                ++ [ problem "TAC1033" "Core function source owner is absent from the module source catalog"
                   | (_, path) <- sourceOwners
                   , path `Set.notMember` sourceFileSet
                   ]
                ++ [ problem "TAC1034" "Core function has no source owner"
                   | not (null sourceFiles)
                   , function <- functions
                   , let identifier = symbolIdValue (resolvedSymbol (coreFunctionName function))
                   , identifier `Set.notMember` ownedFunctions
                   ]
        -- Sets, because both checks run once for every function: against
        -- lists, a module of thousands of functions was verified in time
        -- with the square of their number.
        sourceFileSet = Set.fromList sourceFiles
        ownedFunctions = Set.fromList (map fst sourceOwners)
        invalidPath path = null path || '\0' `elem` path
        functionEnvironment =
            Map.fromList
                [ ( resolvedSymbol (coreFunctionName function)
                  , (FunctionType (map snd (coreFunctionParameters function)) (coreFunctionReturnType function), False)
                  )
                | function <- functions
                ]

verifyFunction :: Environment -> CoreFunction -> [Diagnostic]
verifyFunction functionEnvironment function =
    invalidSymbol "TAC1006" "Core function symbol must be positive" (coreFunctionName function)
        ++ unresolvedType "TAC1003" "Core function has an unresolved return type" (coreFunctionReturnType function)
        ++ duplicates "TAC1004" "duplicate Core parameter symbol" parameterSymbols
        ++ concatMap (uncurry verifyParameter) (coreFunctionParameters function)
        ++ fst (verifyStatements initialEnvironment (coreFunctionReturnType function) OutsideLoop (coreFunctionBody function))
        ++ missingReturn
    where
        parameterSymbols = map (resolvedSymbol . fst) (coreFunctionParameters function)
        initialEnvironment =
            Map.union
                (Map.fromList [(resolvedSymbol name, (valueType, False)) | (name, valueType) <- coreFunctionParameters function])
                functionEnvironment
        missingReturn =
            [ problem "TAC1005" "non-void Core function may complete without returning a value"
            | coreFunctionReturnType function /= unitType && not (statementsAlwaysReturn (coreFunctionBody function))
            ]

verifyParameter :: ResolvedName -> Type -> [Diagnostic]
verifyParameter name valueType =
    invalidSymbol "TAC1006" "Core parameter symbol must be positive" name
        ++ unresolvedType "TAC1007" "Core parameter has an unresolved type" valueType

{- | Where a @break@ or @continue@ would transfer to. A @for@ update region is
inside its loop for @break@, which leaves the loop, but it is the loop's
continuation point itself: a @continue@ there has no later point of the same
iteration to reach and would re-enter the update without testing the
condition. A loop nested in an update opens an ordinary body scope again.
-}
data TransferScope = OutsideLoop | InLoopBody | InForUpdate
    deriving (Eq)

verifyStatements :: Environment -> Type -> TransferScope -> [CoreStatement] -> ([Diagnostic], Environment)
verifyStatements environment _ _ [] = ([], environment)
verifyStatements environment returnType scope (statement : remaining) =
    let (currentProblems, nextEnvironment) = verifyStatement environment returnType scope statement
        (remainingProblems, finalEnvironment) = verifyStatements nextEnvironment returnType scope remaining
     in (currentProblems ++ remainingProblems, finalEnvironment)

verifyStatement :: Environment -> Type -> TransferScope -> CoreStatement -> ([Diagnostic], Environment)
verifyStatement environment returnType scope statement = case statement of
    CoreBind binding ->
        let name = coreBindingName binding
            symbol = resolvedSymbol name
            declaredType = coreBindingType binding
            expressionProblems = verifyExpression environment (coreBindingValue binding)
            bindingProblems =
                invalidSymbol "TAC1008" "Core binding symbol must be positive" name
                    ++ unresolvedType "TAC1009" "Core binding has an unresolved type" declaredType
                    ++ [problem "TAC1010" "Core binding symbol is already defined" | Map.member symbol environment]
                    ++ typeMismatch
                        "TAC1011"
                        "Core binding value type does not match its declaration"
                        declaredType
                        (expressionType (coreBindingValue binding))
            next = Map.insert symbol (declaredType, coreBindingMutable binding) environment
         in (bindingProblems ++ expressionProblems, next)
    CoreAssign name value ->
        let symbol = resolvedSymbol name
            target = Map.lookup symbol environment
            targetProblems = case target of
                Nothing -> [problem "TAC1012" "Core assignment targets an undefined symbol"]
                Just (_, False) -> [problem "TAC1013" "Core assignment targets an immutable symbol"]
                Just (targetType, True) ->
                    typeMismatch
                        "TAC1014"
                        "Core assignment value has the wrong type"
                        targetType
                        (expressionType value)
         in ( invalidSymbol "TAC1015" "Core assignment symbol must be positive" name
                ++ verifyExpression environment value
                ++ targetProblems
            , environment
            )
    CoreReturn value ->
        ( verifyExpression environment value
            ++ typeMismatch "TAC1016" "Core return value has the wrong type" returnType (expressionType value)
        , environment
        )
    CoreIf condition trueBranch falseBranch ->
        let conditionProblems =
                verifyExpression environment condition
                    ++ [ problem "TAC1017" "Core condition must be bool or numeric"
                       | expressionType condition /= boolType && not (isCoreNumericType (expressionType condition))
                       ]
            (trueProblems, _) = verifyStatements environment returnType scope trueBranch
            (falseProblems, _) = verifyStatements environment returnType scope falseBranch
         in (conditionProblems ++ trueProblems ++ falseProblems, environment)
    CoreEvaluate value -> (verifyExpression environment value, environment)
    CoreWhile condition body ->
        let conditionProblems = verifyLoopCondition environment "while" condition
            (bodyProblems, _) = verifyStatements environment returnType InLoopBody body
         in (conditionProblems ++ bodyProblems, environment)
    CoreDoWhile body condition ->
        let (bodyProblems, _) = verifyStatements environment returnType InLoopBody body
            conditionProblems = verifyLoopCondition environment "do/while" condition
         in (bodyProblems ++ conditionProblems, environment)
    CoreFor condition body update ->
        let conditionProblems = verifyLoopCondition environment "for" condition
            (bodyProblems, _) = verifyStatements environment returnType InLoopBody body
            (updateProblems, _) = verifyStatements environment returnType InForUpdate update
         in (conditionProblems ++ bodyProblems ++ updateProblems, environment)
    CoreBreak ->
        ( [problem "TAC1045" "Core break is not nested in a loop" | scope == OutsideLoop]
        , environment
        )
    CoreContinue ->
        ( [problem "TAC1046" "Core continue is not nested in a loop" | scope == OutsideLoop]
            ++ [problem "TAC1066" "Core continue appears in a for update region" | scope == InForUpdate]
        , environment
        )

verifyLoopCondition :: Environment -> String -> CoreExpression -> [Diagnostic]
verifyLoopCondition environment kind condition =
    verifyExpression environment condition
        ++ [ problem "TAC1047" ("Core " ++ kind ++ " condition must be bool or numeric")
           | expressionType condition /= boolType && not (isCoreNumericType (expressionType condition))
           ]

verifyExpression :: Environment -> CoreExpression -> [Diagnostic]
verifyExpression environment expression =
    unresolvedType "TAC1018" "Core expression has an unresolved type" (expressionType expression)
        ++ case expression of
            CoreVariable name valueType ->
                invalidSymbol "TAC1019" "Core variable symbol must be positive" name
                    ++ case Map.lookup (resolvedSymbol name) environment of
                        Nothing -> [problem "TAC1020" "Core expression references an undefined symbol"]
                        Just (declaredType, _) ->
                            typeMismatch
                                "TAC1021"
                                "Core variable type disagrees with its definition"
                                declaredType
                                valueType
            CoreLiteral literal valueType -> literalProblems literal valueType
            CoreApply callee arguments valueType ->
                verifyExpression environment callee
                    ++ concatMap (verifyExpression environment) arguments
                    ++ callProblems callee arguments valueType
            CorePrimitive primitive arguments valueType ->
                concatMap (verifyExpression environment) arguments ++ primitiveProblems primitive arguments valueType
            CoreLet name bindingType value body valueType ->
                invalidSymbol "TAC1040" "Core let symbol must be positive" name
                    ++ unresolvedType "TAC1041" "Core let binding has an unresolved type" bindingType
                    ++ verifyExpression environment value
                    ++ typeMismatch "TAC1042" "Core let value has the wrong type" bindingType (expressionType value)
                    ++ verifyExpression (Map.insert (resolvedSymbol name) (bindingType, False) environment) body
                    ++ typeMismatch "TAC1043" "Core let result type disagrees with its body" valueType (expressionType body)
            CoreConditional condition whenTrue whenFalse valueType ->
                verifyExpression environment condition
                    ++ [ problem "TAC1067" "Core conditional test must be bool or numeric"
                       | expressionType condition /= boolType && not (isCoreNumericType (expressionType condition))
                       ]
                    ++ verifyExpression environment whenTrue
                    ++ verifyExpression environment whenFalse
                    ++ typeMismatch
                        "TAC1068"
                        "Core conditional result type disagrees with its first arm"
                        valueType
                        (expressionType whenTrue)
                    ++ typeMismatch
                        "TAC1069"
                        "Core conditional result type disagrees with its second arm"
                        valueType
                        (expressionType whenFalse)
                    -- The result is materialized in a plain storage slot. Owned
                    -- values would need move and release rules for that slot.
                    ++ [ problem "TAC1070" "Core conditional result must be bool or numeric"
                       | valueType /= boolType && not (isCoreNumericType valueType)
                       ]
            CoreClosure captures parameters returnType body valueType ->
                verifyClosure environment captures parameters returnType body valueType

verifyClosure ::
    Environment -> [CoreCapture] -> [(ResolvedName, Type)] -> Type -> [CoreStatement] -> Type -> [Diagnostic]
verifyClosure environment captures parameters returnType body valueType =
    duplicates "TAC1030" "duplicate Core closure capture symbol" (map (resolvedSymbol . coreCaptureName) captures)
        ++ duplicates "TAC1031" "duplicate Core closure parameter symbol" (map (resolvedSymbol . fst) parameters)
        ++ concatMap verifyCapture captures
        ++ concatMap (uncurry verifyParameter) parameters
        ++ callableTypeProblems
        ++ fst (verifyStatements closureEnvironment returnType OutsideLoop body)
        ++ [ problem "TAC1032" "non-void Core closure may complete without returning"
           | returnType /= unitType && not (statementsAlwaysReturn body)
           ]
    where
        captureEnvironment =
            Map.fromList
                [(resolvedSymbol (coreCaptureName capture), (coreCaptureType capture, True)) | capture <- captures]
        parameterEnvironment =
            Map.fromList
                [(resolvedSymbol name, (parameterType, False)) | (name, parameterType) <- parameters]
        closureEnvironment = Map.unions [parameterEnvironment, captureEnvironment, environment]
        callableTypeProblems = case valueType of
            FunctionType parameterTypes result ->
                concat
                    ( zipWith
                        (typeMismatch "TAC1033" "closure parameter type disagrees with callable type")
                        parameterTypes
                        (map snd parameters)
                    )
                    ++ [problem "TAC1034" "closure callable type has the wrong arity" | length parameterTypes /= length parameters]
                    ++ typeMismatch "TAC1035" "closure return type disagrees with callable type" result returnType
            _ -> [problem "TAC1036" "Core closure expression must have a callable type"]
        verifyCapture capture =
            invalidSymbol "TAC1037" "Core capture symbol must be positive" (coreCaptureName capture)
                ++ unresolvedType "TAC1038" "Core capture has an unresolved type" (coreCaptureType capture)
                ++ verifyExpression environment (coreCaptureValue capture)
                ++ typeMismatch
                    "TAC1039"
                    "Core capture value has the wrong type"
                    (coreCaptureType capture)
                    (expressionType (coreCaptureValue capture))

callProblems :: CoreExpression -> [CoreExpression] -> Type -> [Diagnostic]
callProblems callee arguments resultType = case expressionType callee of
    FunctionType parameterTypes declaredResult ->
        [problem "TAC1022" "Core call has the wrong argument count" | length parameterTypes /= length arguments]
            ++ concat
                (zipWith (typeMismatch "TAC1023" "Core call argument has the wrong type") parameterTypes (map expressionType arguments))
            ++ typeMismatch "TAC1024" "Core call result type disagrees with the callee" declaredResult resultType
    _ -> [problem "TAC1025" "Core call target is not a function"]

primitiveProblems :: CorePrimitive -> [CoreExpression] -> Type -> [Diagnostic]
primitiveProblems CoreRuntimeCall arguments resultType =
    -- The first operand names the function and the rest are checked against
    -- the row of the catalog that function has.
    case runtimeCallDefect named (map expressionType (drop 1 arguments)) resultType of
        Just defect -> [problem "TAC1075" ("Core " ++ runtimeDefectText defect)]
        Nothing -> []
    where
        named = case arguments of
            CoreLiteral (CoreInteger identity) valueType : _ | valueType == intType -> runtimeFunctionOf identity
            _ -> Nothing
primitiveProblems primitive arguments resultType =
    [problem "TAC1026" "Core primitive has the wrong operand count" | length arguments /= arity]
        ++ operandProblems
        ++ typeMismatch "TAC1028" "Core primitive result has the wrong type" expectedResult resultType
    where
        unary = primitive `elem` [CoreNegate, CoreLogicalNot, CoreBitwiseNot, CoreMemoize]
        logical = primitive `elem` [CoreLogicalAnd, CoreLogicalOr, CoreLogicalNot]
        integerOnly = primitive `elem` [CoreShiftLeft, CoreShiftRight, CoreBitwiseAnd, CoreBitwiseXor, CoreBitwiseOr, CoreBitwiseNot]
        comparison = primitive `elem` [CoreLessThan, CoreLessEqual, CoreGreaterThan, CoreGreaterEqual, CoreEqual, CoreNotEqual]
        arity = if unary then 1 else 2
        argumentTypes = map expressionType arguments
        firstType = case argumentTypes of first : _ -> first; [] -> ErrorType
        operandsAgree = all (== firstType) argumentTypes
        operandsNumeric = all isCoreNumericType argumentTypes
        operandsInteger = all isCoreIntegerType argumentTypes
        operandsBoolean = all (\valueType -> valueType == boolType || isCoreNumericType valueType) argumentTypes
        operandProblems
            | primitive == CoreTypeIs = case argumentTypes of
                [subjectType, identityType]
                    | isReferenceLike subjectType && identityType == namedType "uint" -> []
                    | otherwise -> [problem "TAC1044" "Core type test requires a reference subject and uint identity"]
                _ -> []
            -- A remembered result lives in the callable itself, in a slot
            -- that owns nothing: only a result without ownership is kept.
            | primitive == CoreMemoize = case argumentTypes of
                [FunctionType [] result]
                    | result == boolType || isCoreNumericType result -> []
                    | otherwise -> [memoizeProblem]
                [_] -> [memoizeProblem]
                _ -> []
            | logical && not operandsBoolean = [problem "TAC1027" "Core logical primitive requires bool or numeric operands"]
            | integerOnly && not operandsInteger = [problem "TAC1027" "Core bitwise primitive requires integer operands"]
            | primitive `elem` [CoreEqual, CoreNotEqual]
            , operandsAgree
            , firstType == boolType || isReferenceLike firstType =
                []
            | not logical && not operandsNumeric = [problem "TAC1027" "Core numeric primitive requires numeric operands"]
            | not logical && not operandsAgree = [problem "TAC1027" "Core numeric primitive operands must have the same type"]
            | otherwise = []
        expectedResult
            | logical || comparison || primitive == CoreTypeIs = boolType
            | primitive == CoreFloorDivide && isCoreFloatingType firstType = intType
            | otherwise = firstType
        memoizeProblem =
            problem "TAC1073" "Core memoization requires a callable without parameters whose result is bool or numeric"
        isReferenceLike valueType = case valueType of
            FunctionType _ _ -> True
            NamedType _ _ -> not (isCoreNumericType valueType) && valueType /= unitType
            _ -> False

literalProblems :: CoreLiteral -> Type -> [Diagnostic]
literalProblems literal valueType =
    [problem "TAC1029" "Core literal payload does not match its type or scalar range" | not matches]
    where
        matches = case literal of
            CoreInteger value -> integerFitsCoreType valueType value
            CoreFloating spelling -> isCoreFloatingType valueType && validCoreFloatingSpelling spelling
            CoreString _ -> valueType == stringType
            CoreBoolean _ -> valueType == boolType
            CoreUnit -> valueType == unitType
            CoreNull -> isReferenceLike valueType
        isReferenceLike value = case value of
            FunctionType _ _ -> True
            NamedType _ _ -> not (isCoreNumericType value) && value /= unitType
            _ -> False

{- | Whether control can never fall off the end of the statements.

That is so when they return on every path, and also when they hold a loop
that cannot be left: its condition is the literal true and no @break@
leaves it. Such a loop ends only through a @return@ inside it, or not at
all, so nothing after it is reached.
-}
statementsAlwaysReturn :: [CoreStatement] -> Bool
statementsAlwaysReturn [] = False
statementsAlwaysReturn (statement : remaining) = case statement of
    CoreReturn _ -> True
    CoreIf _ trueBranch falseBranch ->
        (not (null falseBranch) && statementsAlwaysReturn trueBranch && statementsAlwaysReturn falseBranch)
            || statementsAlwaysReturn remaining
    CoreWhile condition body
        | cannotBeLeft condition body -> True
    CoreDoWhile body condition
        | cannotBeLeft condition body -> True
    CoreFor condition body update
        | cannotBeLeft condition (body ++ update) -> True
    _ -> statementsAlwaysReturn remaining
    where
        cannotBeLeft condition body = isLiteralTrue condition && not (leftByBreak body)
        isLiteralTrue expression = case expression of
            CoreLiteral (CoreBoolean True) _ -> True
            _ -> False
        -- A break in a nested loop leaves that loop.
        leftByBreak = any breaks
        breaks nested = case nested of
            CoreBreak -> True
            CoreIf _ trueBranch falseBranch -> leftByBreak trueBranch || leftByBreak falseBranch
            _ -> False

emptyName :: QualifiedName -> [Diagnostic]
emptyName (QualifiedName parts) =
    [ problem "TAC1001" "Core module name must contain at least one non-empty part"
    | null parts || any (null . identifierText) parts
    ]

invalidSymbol :: String -> String -> ResolvedName -> [Diagnostic]
invalidSymbol code message name = [problem code message | symbolIdValue (resolvedSymbol name) <= 0]

unresolvedType :: String -> String -> Type -> [Diagnostic]
unresolvedType code message valueType =
    [problem code message | containsError valueType]
        ++ map templateProblem (validateTemplateType 128 valueType)

-- Template validation belongs at the Core boundary rather than only in the
-- artifact writer. Keeping malformed specialization keys out of verified Core
-- ensures optimization caches and every later stage observe the same type
-- identity, even when no artifact is emitted for the compilation.
templateProblem :: TemplateIssue -> Diagnostic
templateProblem issue =
    problem
        "TAC1040"
        ( "invalid Core template type at "
            ++ renderTemplatePath (templateIssuePath issue)
            ++ ": "
            ++ templateIssueMessage issue
        )

renderTemplatePath :: [Int] -> String
renderTemplatePath [] = "the type root"
renderTemplatePath indexes = "argument " ++ concatMap renderIndex indexes
    where
        renderIndex index = "[" ++ show index ++ "]"

containsError :: Type -> Bool
containsError valueType = case valueType of
    ErrorType -> True
    NamedType _ arguments -> any templateArgumentContainsError arguments
    FunctionType parameters result -> any containsError parameters || containsError result
    TypeVariable _ -> False

templateArgumentContainsError :: TemplateArgument -> Bool
templateArgumentContainsError argument = case argument of
    TypeTemplateArgument nested -> containsError nested
    ValueTemplateArgument _ -> False

typeMismatch :: String -> String -> Type -> Type -> [Diagnostic]
typeMismatch code message expected actual = [problem code message | expected /= actual]

duplicates :: (Ord a) => String -> String -> [a] -> [Diagnostic]
duplicates code message values = [problem code message | groupValue <- group (sort values), length groupValue > 1]

problem :: String -> String -> Diagnostic
problem code message = Diagnostic CoreStage Error code Nothing message
