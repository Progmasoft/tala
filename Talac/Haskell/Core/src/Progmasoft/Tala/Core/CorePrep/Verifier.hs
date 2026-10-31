-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Structural verifier for lowered CorePrep control flow and storage.
Verification is required after decoding artifacts and before native lowering.
-}
module Progmasoft.Tala.Core.CorePrep.Verifier (verifyCorePrep) where

import Data.IntSet qualified as IntSet
import Data.Set qualified as Set
import Progmasoft.Tala.AST
import Progmasoft.Tala.Core qualified as Core
import Progmasoft.Tala.Core.CorePrep
import Progmasoft.Tala.Core.Template
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.RuntimeCall

-- | Return the unchanged module when valid, or every discovered invariant error.
verifyCorePrep :: CorePrepModule -> Either [Diagnostic] CorePrepModule
verifyCorePrep moduleValue =
    let problems =
            duplicateFunctions (corePrepModuleFunctions moduleValue)
                ++ concatMap verifyFunction (corePrepModuleFunctions moduleValue)
     in if null problems then Right moduleValue else Left problems

duplicateFunctions :: [CorePrepFunction] -> [Diagnostic]
duplicateFunctions functions = duplicateIds "TAC0001" "duplicate CorePrep function symbol" (map (resolvedSymbol . corePrepFunctionName) functions)

verifyFunction :: CorePrepFunction -> [Diagnostic]
verifyFunction function =
    let blocks = corePrepFunctionBlocks function
        blockIds = map corePrepBlockId blocks
        parameterIds = map (resolvedSymbol . fst) (corePrepFunctionParameters function)
        definitionIds = concatMap blockDefinitions blocks
     in missingEntry blockIds
            ++ verifyType "function result" (corePrepFunctionReturnType function)
            ++ concatMap (verifyParameterType . snd) (corePrepFunctionParameters function)
            ++ duplicateIds "TAC0003" "duplicate CorePrep block id" blockIds
            ++ duplicateIds "TAC0004" "duplicate CorePrep parameter symbol" parameterIds
            ++ duplicateIds "TAC0005" "CorePrep symbol is defined more than once" (parameterIds ++ definitionIds)
            ++ concatMap (verifyBlock (IntSet.fromList blockIds)) blocks
    where
        verifyParameterType = verifyType "function parameter"
        missingEntry ids =
            if corePrepFunctionEntry function `elem` ids
                then []
                else [problem "TAC0002" "CorePrep function entry block does not exist"]

blockDefinitions :: CorePrepBlock -> [SymbolId]
blockDefinitions block = [resolvedSymbol name | CorePrepBind name _ _ _ <- corePrepBlockInstructions block]

verifyBlock :: IntSet.IntSet -> CorePrepBlock -> [Diagnostic]
verifyBlock blockIds block =
    concatMap verifyInstruction (corePrepBlockInstructions block)
        ++ verifyTerminator blockIds (corePrepBlockTerminator block)

verifyInstruction :: CorePrepInstruction -> [Diagnostic]
verifyInstruction instruction = case instruction of
    CorePrepBind _ valueType _ operation -> verifyType "binding" valueType ++ verifyOperation valueType operation
    CorePrepAssign _ atom -> verifyAtom atom
    CorePrepEvaluate operation -> verifyOperation ErrorType operation

verifyOperation :: Type -> CorePrepOperation -> [Diagnostic]
verifyOperation resultType operation = case operation of
    CorePrepCopy atom -> verifyAtom atom ++ resultMismatch (atomType atom)
    CorePrepCall callee arguments -> verifyAtom callee ++ concatMap verifyAtom arguments
    CorePrepPrimitive primitive atoms -> concatMap verifyAtom atoms ++ verifyPrimitive primitive atoms resultType
    CorePrepMakeClosure function captures ->
        invalidFunction function
            ++ concatMap verifyCapture captures
            ++ closureResultMismatch resultType
    where
        resultMismatch valueType =
            if resultType == ErrorType || resultType == valueType
                then []
                else [problem "TAC0006" "CorePrep copy result type does not match its atom"]
        invalidFunction name = [problem "TAC0013" "CorePrep closure function symbol must be positive" | symbolIdValue (resolvedSymbol name) <= 0]
        closureResultMismatch valueType = case valueType of
            FunctionType _ _ -> []
            ErrorType -> []
            _ -> [problem "TAC0014" "CorePrep closure result must have a callable type"]

verifyCapture :: CorePrepCapture -> [Diagnostic]
verifyCapture (CorePrepCapture mode name valueType atom) =
    [problem "TAC0015" "CorePrep capture symbol must be positive" | symbolIdValue (resolvedSymbol name) <= 0]
        ++ [problem "TAC0016" "CorePrep capture has an unresolved type" | valueType == ErrorType]
        ++ [problem "TAC0017" "CorePrep capture atom type does not match its slot" | atomType atom /= valueType]
        ++ [ problem "TAC0018" "non-owning capture requires an AARC reference value"
           | mode /= StrongCapture && not (aarcReference valueType)
           ]
        ++ verifyType "capture" valueType
        ++ verifyAtom atom
    where
        -- Core currently lacks nominal-declaration metadata, so every resolved
        -- named type remains conservatively reference-like at this boundary.
        aarcReference value = case value of
            FunctionType _ _ -> True
            NamedType _ _ -> value /= unitType && value /= boolType && value /= intType
            _ -> False

verifyPrimitive :: Core.CorePrimitive -> [CorePrepAtom] -> Type -> [Diagnostic]
verifyPrimitive Core.CoreRuntimeCall atoms resultType =
    -- The first atom names the function; the rest are its arguments.
    case runtimeCallDefect named (map atomType (drop 1 atoms)) resultType of
        Just defect -> [problem "TAC0026" ("CorePrep " ++ runtimeDefectText defect)]
        Nothing -> []
    where
        named = case atoms of
            CorePrepLiteral (Core.CoreInteger identity) valueType : _ | valueType == intType -> runtimeFunctionOf identity
            _ -> Nothing
verifyPrimitive primitive atoms resultType
    | length atoms /= expectedArity = [problem "TAC0007" "CorePrep primitive has the wrong arity"]
    | any ((== ErrorType) . atomType) atoms = [problem "TAC0008" "CorePrep primitive contains an unresolved type"]
    | otherwise = operandProblems ++ resultProblems
    where
        expectedArity =
            if primitive `elem` [Core.CoreNegate, Core.CoreLogicalNot, Core.CoreBitwiseNot, Core.CoreMemoize] then 1 else 2
        comparisonOrLogical =
            if primitive
                `elem` [ Core.CoreLessThan
                       , Core.CoreLessEqual
                       , Core.CoreGreaterThan
                       , Core.CoreGreaterEqual
                       , Core.CoreEqual
                       , Core.CoreNotEqual
                       , Core.CoreLogicalAnd
                       , Core.CoreLogicalOr
                       , Core.CoreLogicalNot
                       , Core.CoreTypeIs
                       ]
                then True
                else False
        operandTypes = map atomType atoms
        firstType = case operandTypes of valueType : _ -> valueType; [] -> ErrorType
        operandsAgree = all (== firstType) operandTypes
        logical = primitive `elem` [Core.CoreLogicalAnd, Core.CoreLogicalOr, Core.CoreLogicalNot]
        integerOnly =
            primitive
                `elem` [ Core.CoreShiftLeft
                       , Core.CoreShiftRight
                       , Core.CoreBitwiseAnd
                       , Core.CoreBitwiseXor
                       , Core.CoreBitwiseOr
                       , Core.CoreBitwiseNot
                       ]
        numeric = all isNumericType operandTypes
        integer = all isIntegerType operandTypes
        booleanContext = all (\valueType -> valueType == boolType || isNumericType valueType) operandTypes
        negatable = isSignedIntegerType firstType || isFloatingType firstType
        operandProblems
            | primitive == Core.CoreTypeIs = case operandTypes of
                [subjectType, identityType]
                    | referenceLike subjectType && typeSpelling identityType == "uint" -> []
                    | otherwise -> [problem "TAC0024" "CorePrep type test requires a reference subject and uint identity"]
                _ -> []
            | primitive == Core.CoreMemoize = case operandTypes of
                [FunctionType [] result] | result == boolType || isNumericType result -> []
                _ ->
                    [ problem
                        "TAC0025"
                        "CorePrep memoization requires a callable without parameters whose result is bool or numeric"
                    ]
            | not operandsAgree = [problem "TAC0019" "CorePrep primitive operand types do not agree"]
            | logical && not booleanContext = [problem "TAC0020" "CorePrep logical primitive requires bool or numeric operands"]
            | integerOnly && not integer = [problem "TAC0022" "CorePrep bitwise primitive requires integer operands"]
            | primitive == Core.CoreNegate && not negatable =
                [problem "TAC0021" "CorePrep negation requires a signed integer or floating operand"]
            | not logical && not numeric && primitive `notElem` [Core.CoreEqual, Core.CoreNotEqual] =
                [problem "TAC0022" "CorePrep arithmetic or ordering primitive requires numeric operands"]
            | otherwise = []
        expectedResult
            | comparisonOrLogical = boolType
            | primitive == Core.CoreFloorDivide && isFloatingType firstType = intType
            | otherwise = firstType
        -- Evaluate deliberately discards a primitive's value, so it carries
        -- the ErrorType sentinel instead of the primitive's result type.
        resultProblems
            | resultType == ErrorType = []
            | resultType == expectedResult = []
            | otherwise = [problem "TAC0009" "CorePrep primitive result type is inconsistent"]
        referenceLike valueType = case valueType of
            FunctionType _ _ -> True
            NamedType _ _ -> not (isNumericType valueType) && valueType /= unitType
            _ -> False

verifyTerminator :: IntSet.IntSet -> CorePrepTerminator -> [Diagnostic]
verifyTerminator blockIds terminator = case terminator of
    CorePrepReturn atom -> verifyAtom atom
    CorePrepBranch atom trueTarget falseTarget -> verifyAtom atom ++ requireBool atom ++ targets [trueTarget, falseTarget]
    CorePrepJump target -> targets [target]
    CorePrepUnreachable -> []
    where
        targets values =
            [ problem "TAC0010" "CorePrep terminator targets a missing block"
            | any (`IntSet.notMember` blockIds) values
            ]
        requireBool atom = [problem "TAC0011" "CorePrep branch condition must be bool" | atomType atom /= boolType]

verifyAtom :: CorePrepAtom -> [Diagnostic]
verifyAtom atom =
    [problem "TAC0012" "CorePrep atom has an unresolved type" | atomType atom == ErrorType]
        ++ verifyType "atom" (atomType atom)
        ++ case atom of
            CorePrepLiteral literal valueType -> verifyLiteral literal valueType
            CorePrepVariable _ _ -> []

verifyLiteral :: Core.CoreLiteral -> Type -> [Diagnostic]
verifyLiteral literal valueType =
    [problem "TAC0023" "CorePrep literal payload does not match its declared scalar type" | not matches]
    where
        matches = case literal of
            Core.CoreInteger value -> integerFits valueType value
            Core.CoreFloating spelling -> isFloatingType valueType && validFloatingSpelling spelling
            Core.CoreString _ -> valueType == stringType
            Core.CoreBoolean _ -> valueType == boolType
            Core.CoreUnit -> valueType == unitType
            Core.CoreNull -> referenceLike valueType
        referenceLike value = case value of
            FunctionType _ _ -> True
            NamedType _ _ -> not (isNumericType value) && value /= unitType
            _ -> False

typeSpelling :: Type -> String
typeSpelling (NamedType (QualifiedName [Identifier name]) []) = name
typeSpelling _ = ""

integerWidths :: [(String, Bool, Int)]
integerWidths =
    [ ("char", False, 32)
    , ("byte", True, 8)
    , ("short", True, 16)
    , ("long", True, 32)
    , ("int", True, 64)
    , ("longint", True, 128)
    , ("ubyte", False, 8)
    , ("ushort", False, 16)
    , ("ulong", False, 32)
    , ("uint", False, 64)
    , ("ulongint", False, 128)
    ]

integerFits :: Type -> Integer -> Bool
integerFits valueType value = case [(signed, width) | (name, signed, width) <- integerWidths, name == typeSpelling valueType] of
    [(True, width)] -> value >= negate (2 ^ (width - 1)) && value <= 2 ^ (width - 1) - 1
    [(False, width)] -> value >= 0 && value <= 2 ^ width - 1
    _ -> False

isIntegerType :: Type -> Bool
isIntegerType valueType = any (\(name, _, _) -> name == typeSpelling valueType) integerWidths

isSignedIntegerType :: Type -> Bool
isSignedIntegerType valueType = any (\(name, signed, _) -> signed && name == typeSpelling valueType) integerWidths

isFloatingType :: Type -> Bool
isFloatingType valueType = typeSpelling valueType `elem` ["sfloat", "lfloat", "float", "double"]

isNumericType :: Type -> Bool
isNumericType valueType = isIntegerType valueType || isFloatingType valueType

validFloatingSpelling :: String -> Bool
validFloatingSpelling spelling
    | spelling `elem` ["nan", "+nan", "-nan", "inf", "+inf", "-inf"] = True
    | otherwise = case stripSign spelling of
        [] -> False
        unsignedSpelling ->
            let (mantissa, exponentPart) = break (`elem` "eE") unsignedSpelling
             in validSignificand mantissa && validExponent exponentPart
    where
        stripSign ('+' : remaining) = remaining
        stripSign ('-' : remaining) = remaining
        stripSign value = value
        validSignificand value = case break (== '.') value of
            (whole, []) -> not (null whole) && all digit whole
            (whole, _ : fraction) -> (not (null whole) || not (null fraction)) && all digit whole && all digit fraction
        validExponent [] = True
        validExponent (_ : remaining) = case stripSign remaining of
            [] -> False
            digits -> all digit digits
        digit character = character >= '0' && character <= '9'

atomType :: CorePrepAtom -> Type
atomType atom = case atom of CorePrepVariable _ valueType -> valueType; CorePrepLiteral _ valueType -> valueType

-- CorePrep may be constructed directly by tests and tooling, so it cannot
-- rely on the Core verifier having run. Revalidating structural template keys
-- here makes the stage boundary self-contained and protects Xpp lowering from
-- malformed fixed-array and value-parameter payloads.
verifyType :: String -> Type -> [Diagnostic]
verifyType context valueType = map templateProblem (validateTemplateType 128 valueType)
    where
        templateProblem issue =
            problem
                "TAC0024"
                ( "invalid CorePrep "
                    ++ context
                    ++ " template type at "
                    ++ renderPath (templateIssuePath issue)
                    ++ ": "
                    ++ templateIssueMessage issue
                )
        renderPath [] = "the type root"
        renderPath indexes = "argument " ++ concatMap (\index -> "[" ++ show index ++ "]") indexes

-- A function may have tens of thousands of blocks and symbols, so the
-- distinct values are counted through a set rather than by comparing every
-- pair.
duplicateIds :: (Ord a) => String -> String -> [a] -> [Diagnostic]
duplicateIds code message values = [problem code message | length values /= Set.size (Set.fromList values)]

problem :: String -> String -> Diagnostic
problem code message = Diagnostic CorePrepStage Error code Nothing message
