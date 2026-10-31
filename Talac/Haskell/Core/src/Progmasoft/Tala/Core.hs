-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0
{-# LANGUAGE PatternSynonyms #-}

{- | Target-independent, verified compiler IR retained before CorePrep.
Expressions carry explicit result types and statements preserve source-level
control flow so later passes can introduce blocks without re-parsing source.
-}
module Progmasoft.Tala.Core
    ( CoreLiteral (..)
    , CorePrimitive (..)
    , CoreCapture (..)
    , CoreExpression (..)
    , CoreStatement (..)
    , CoreBinding (..)
    , CoreFunction (..)
    , CoreModule (.., CoreModule)
    , expressionType
    ) where

import Progmasoft.Tala.AST (CaptureMode, QualifiedName, ResolvedName, Type)

-- | Literal values representable in the typed Core expression graph.
data CoreLiteral
    = -- | Exact arbitrary-precision integer value.
      CoreInteger Integer
    | -- | Canonical floating-point spelling.
      CoreFloating String
    | -- | Unicode scalar sequence.
      CoreString String
    | -- | Boolean value.
      CoreBoolean Bool
    | -- | The unique unit value.
      CoreUnit
    | -- | Null reference literal.
      CoreNull
    deriving (Eq, Ord, Read, Show)

-- | Primitive operations with explicit operand and result nodes in Core.
data CorePrimitive
    = -- | Numeric addition.
      CoreAdd
    | -- | Numeric subtraction.
      CoreSubtract
    | -- | Numeric multiplication.
      CoreMultiply
    | -- | Truncating division.
      CoreDivide
    | {- | Rounded division @//@: nearest integer, halves away from zero. The
      constructor keeps its historical name; it never floors.
      -}
      CoreFloorDivide
    | -- | Remainder operation.
      CoreRemainder
    | -- | Ordered less-than comparison.
      CoreLessThan
    | -- | Ordered less-than-or-equal comparison.
      CoreLessEqual
    | -- | Ordered greater-than comparison.
      CoreGreaterThan
    | -- | Ordered greater-than-or-equal comparison.
      CoreGreaterEqual
    | -- | Value equality comparison.
      CoreEqual
    | -- | Value inequality comparison.
      CoreNotEqual
    | -- | Short-circuit logical conjunction.
      CoreLogicalAnd
    | -- | Short-circuit logical disjunction.
      CoreLogicalOr
    | -- | Numeric unary negation.
      CoreNegate
    | -- | Logical Boolean negation.
      CoreLogicalNot
    | -- | Integer or floating power operation.
      CorePower
    | -- | Integer left shift.
      CoreShiftLeft
    | -- | Integer right shift as defined by operand type.
      CoreShiftRight
    | -- | Integer bitwise conjunction.
      CoreBitwiseAnd
    | -- | Integer bitwise exclusive-or.
      CoreBitwiseXor
    | -- | Integer bitwise disjunction.
      CoreBitwiseOr
    | -- | Integer bitwise complement.
      CoreBitwiseNot
    | -- | Runtime type-membership predicate.
      CoreTypeIs
    | {- | A callable that remembers its result.

      The operand is a callable without parameters. The result is a callable
      of the same type that calls the operand the first time it is called,
      keeps what the operand returned, and returns that again on every later
      call without calling the operand. Every copy of the result shares the
      one remembered value. This is the suspended computation of evaluation
      by need: a value that is computed when it is first needed, at most
      once, wherever the need arises.
      -}
      CoreMemoize
    | {- | A call of a function of the runtime.

      The first operand is an integer literal, the identity of the function
      in the catalog of "Progmasoft.Tala.RuntimeCall"; the operands after it
      are the arguments. The function is fixed when the program is compiled:
      the first operand is never a value that is computed.
      -}
      CoreRuntimeCall
    deriving (Eq, Ord, Read, Show)

-- | Typed expression graph consumed by Core verification and optimization.
data CoreExpression
    = -- | Reference to a resolved local or function symbol.
      CoreVariable ResolvedName Type
    | -- | Literal payload with its semantic type.
      CoreLiteral CoreLiteral Type
    | -- | Callable application with ordered arguments.
      CoreApply CoreExpression [CoreExpression] Type
    | -- | Primitive operation and ordered operands.
      CorePrimitive CorePrimitive [CoreExpression] Type
    | -- CoreLet is expression-local sequencing. Pattern lowering uses it to
      -- evaluate a potentially effectful subject exactly once before testing
      -- several alternatives.

      -- | Bind one expression result before evaluating the continuation.
      CoreLet ResolvedName Type CoreExpression CoreExpression Type
    | {- | Conditional expression: test the condition in Boolean context, then
      evaluate exactly one of the two arms and yield its value. The arm that
      is not selected is never evaluated, so its calls, failures and
      non-termination do not happen. Both arms have the result type. This is
      the Core form of source @condition ? first : second@ and, combined
      with 'CoreLet', of @left ?: fallback@.
      -}
      CoreConditional CoreExpression CoreExpression CoreExpression Type
    | -- | Closure with captures, parameters, body, and callable type.
      CoreClosure
        [CoreCapture]
        [(ResolvedName, Type)]
        Type
        [CoreStatement]
        Type
    deriving (Eq, Ord, Read, Show)

-- | Captured source binding and the expression used to materialize its value.
data CoreCapture = CoreCapture
    { coreCaptureMode :: CaptureMode
    -- ^ Ownership mode selected by closure analysis.
    , coreCaptureName :: ResolvedName
    -- ^ Resolved identity of the captured binding.
    , coreCaptureType :: Type
    -- ^ Type expected by the closure environment.
    , coreCaptureValue :: CoreExpression
    -- ^ Expression evaluated at closure creation.
    }
    deriving (Eq, Ord, Read, Show)

{- | Structured, verified statements retained until CorePrep constructs the
control-flow graph. Loop forms remain explicit so that optimizers can preserve
condition, body, update, and innermost-transfer ordering without reconstructing
source semantics from basic blocks.
-}
data CoreStatement
    = CoreBind CoreBinding
    | CoreAssign ResolvedName CoreExpression
    | CoreReturn CoreExpression
    | CoreIf CoreExpression [CoreStatement] [CoreStatement]
    | CoreEvaluate CoreExpression
    | CoreWhile CoreExpression [CoreStatement]
    | CoreDoWhile [CoreStatement] CoreExpression
    | CoreFor CoreExpression [CoreStatement] [CoreStatement]
    | CoreBreak
    | CoreContinue
    deriving (Eq, Ord, Read, Show)

-- | Local declaration with resolved identity, mutability, and initializer.
data CoreBinding = CoreBinding
    { coreBindingName :: ResolvedName
    -- ^ Symbol introduced by the binding.
    , coreBindingType :: Type
    -- ^ Declared semantic type.
    , coreBindingMutable :: Bool
    -- ^ Whether later assignment is permitted.
    , coreBindingValue :: CoreExpression
    -- ^ Initial value expression.
    }
    deriving (Eq, Ord, Read, Show)

-- | Top-level or member callable lowered into target-independent Core.
data CoreFunction = CoreFunction
    { coreFunctionName :: ResolvedName
    -- ^ Resolved function symbol.
    , coreFunctionParameters :: [(ResolvedName, Type)]
    -- ^ Parameters in call order.
    , coreFunctionReturnType :: Type
    -- ^ Declared result type.
    , coreFunctionBody :: [CoreStatement]
    -- ^ Function statements in source order.
    }
    deriving (Eq, Ord, Read, Show)

{- | Source ownership is deliberately side metadata rather than syntax or
semantics.  Function identities remain stable while the optimizer rewrites
bodies, and the native backend can partition definitions without guessing
from declaration spelling or filesystem layout.
The named data constructor carries compiler provenance.  The two-argument
pattern below preserves the long-standing source-level construction API for
hand-written Core fixtures; project compilation uses CoreModuleWithSources.
-}

-- | Verified module plus source ownership metadata used by project builds.
data CoreModule = CoreModuleWithSources
    { coreModuleName :: QualifiedName
    -- ^ Fully qualified module name.
    , coreModuleFunctions :: [CoreFunction]
    -- ^ Functions emitted by this unit.
    , coreModuleSourceFiles :: [FilePath]
    -- ^ Source files included in the compilation.
    , coreModuleFunctionSources :: [(Int, FilePath)]
    -- ^ Function indices mapped to their source file.
    }
    deriving (Eq, Ord, Read, Show)

-- | Construct or match a Core module without explicit source ownership data.
pattern CoreModule :: QualifiedName -> [CoreFunction] -> CoreModule
pattern CoreModule name functions <- CoreModuleWithSources name functions _ _
    where
        CoreModule name functions = CoreModuleWithSources name functions [] []

{-# COMPLETE CoreModule #-}

-- | Read the explicit result type stored on any Core expression node.
expressionType :: CoreExpression -> Type
expressionType expression = case expression of
    CoreVariable _ value -> value
    CoreLiteral _ value -> value
    CoreApply _ _ value -> value
    CorePrimitive _ _ value -> value
    CoreLet _ _ _ _ value -> value
    CoreConditional _ _ _ value -> value
    CoreClosure _ _ _ _ value -> value
