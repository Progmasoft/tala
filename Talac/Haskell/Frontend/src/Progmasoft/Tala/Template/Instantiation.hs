-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- |
Typed declaration instantiation after template application binding.

This pass does not choose overloads, constraints, or a native symbol spelling.
It has one narrow responsibility: replace the semantic template variables in
an already typed declaration tree.  The output is an ordinary type declaration
that the existing Desugarer can lower without learning template syntax.
-}
module Progmasoft.Tala.Template.Instantiation
    ( TemplateInstantiationError (..)
    , instantiateTemplateType
    , instantiateMember
    , instantiateParameter
    , instantiateBlock
    , instantiateStatement
    , instantiateExpression
    , instantiateCallableBody
    , renderTemplateInstantiationError
    ) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Template.Application

-- | Failure to instantiate a typed template declaration or one of its nodes.
data TemplateInstantiationError
    = -- | The supplied declaration is not a template type.
      ExpectedTemplateTypeDeclaration
    | -- | Binding and declaration identities differ.
      TemplateBindingTargetsDifferentDeclaration SymbolId SymbolId
    | -- | A bound type or value could not be substituted.
      TemplateTypeSubstitutionFailed TemplateApplicationError
    deriving (Eq, Ord, Read, Show)

-- | Close a template type declaration using its previously validated binding.
instantiateTemplateType ::
    TemplateBinding ->
    Declaration ResolvedName Type ->
    Either TemplateInstantiationError (Declaration ResolvedName Type)
instantiateTemplateType binding declaration = case declaration of
    TemplateTypeDeclaration spanValue name annotation _ members
        | resolvedSymbol name /= templateDeclarationSymbol descriptor ->
            Left
                ( TemplateBindingTargetsDifferentDeclaration
                    (templateDeclarationSymbol descriptor)
                    (resolvedSymbol name)
                )
        | otherwise -> do
            closedAnnotation <- instantiateType binding annotation
            closedMembers <- traverse (instantiateMember binding) members
            pure (TypeDeclaration spanValue name closedAnnotation closedMembers)
    _ -> Left ExpectedTemplateTypeDeclaration
    where
        descriptor = templateBindingDeclaration binding

-- | Substitute template variables in one member declaration recursively.
instantiateMember ::
    TemplateBinding ->
    Declaration ResolvedName Type ->
    Either TemplateInstantiationError (Declaration ResolvedName Type)
instantiateMember binding declaration = case declaration of
    FunctionDeclaration spanValue name annotation returnSyntax parameters body isStatic access fact -> do
        closedAnnotation <- instantiateType binding annotation
        closedParameters <- traverse (instantiateParameter binding) parameters
        closedBody <- instantiateBlock binding body
        pure
            ( FunctionDeclaration
                spanValue
                name
                closedAnnotation
                returnSyntax
                closedParameters
                closedBody
                isStatic
                access
                fact
            )
    TypeDeclaration spanValue name annotation members -> do
        closedAnnotation <- instantiateType binding annotation
        closedMembers <- traverse (instantiateMember binding) members
        pure (TypeDeclaration spanValue name closedAnnotation closedMembers)
    TemplateTypeDeclaration {} ->
        -- Nested templates own a distinct parameter environment. Applying the
        -- outer binding blindly would capture same-spelled inner parameters.
        -- Nested instantiation will be selected independently by the planner.
        pure declaration
    EnumDeclaration {} -> pure declaration

-- | Instantiate one parameter annotation while preserving its source syntax.
instantiateParameter ::
    TemplateBinding ->
    Parameter ResolvedName Type ->
    Either TemplateInstantiationError (Parameter ResolvedName Type)
instantiateParameter binding parameter = do
    closedType <- instantiateType binding (parameterAnnotation parameter)
    pure
        ( Parameter
            (parameterSpan parameter)
            (parameterName parameter)
            closedType
            (parameterTypeSyntax parameter)
        )

-- | Instantiate every statement in a block without changing statement order.
instantiateBlock ::
    TemplateBinding ->
    Block ResolvedName Type ->
    Either TemplateInstantiationError (Block ResolvedName Type)
instantiateBlock binding (Block statements) = Block <$> traverse (instantiateStatement binding) statements

-- | Substitute all types nested in one statement and its expressions.
instantiateStatement ::
    TemplateBinding ->
    Statement ResolvedName Type ->
    Either TemplateInstantiationError (Statement ResolvedName Type)
instantiateStatement binding statement = case statement of
    BindingStatement spanValue kind syntax name annotation value -> do
        closedAnnotation <- instantiateType binding annotation
        closedValue <- instantiateExpression binding value
        pure (BindingStatement spanValue kind syntax name closedAnnotation closedValue)
    AssignmentStatement spanValue name annotation value -> do
        closedAnnotation <- instantiateType binding annotation
        closedValue <- instantiateExpression binding value
        pure (AssignmentStatement spanValue name closedAnnotation closedValue)
    ReturnStatement spanValue value ->
        ReturnStatement spanValue <$> traverse (instantiateExpression binding) value
    IfStatement spanValue condition trueBlock falseBlock -> do
        closedCondition <- instantiateExpression binding condition
        closedTrue <- instantiateBlock binding trueBlock
        closedFalse <- traverse (instantiateBlock binding) falseBlock
        pure (IfStatement spanValue closedCondition closedTrue closedFalse)
    WhileStatement spanValue condition body -> do
        closedCondition <- instantiateExpression binding condition
        closedBody <- instantiateBlock binding body
        pure (WhileStatement spanValue closedCondition closedBody)
    DoWhileStatement spanValue body condition -> do
        closedBody <- instantiateBlock binding body
        closedCondition <- instantiateExpression binding condition
        pure (DoWhileStatement spanValue closedBody closedCondition)
    ForStatement spanValue initializer condition updates body -> do
        closedInitializer <- traverse (instantiateStatement binding) initializer
        closedCondition <- traverse (instantiateExpression binding) condition
        closedUpdates <- traverse (instantiateStatement binding) updates
        closedBody <- instantiateBlock binding body
        pure (ForStatement spanValue closedInitializer closedCondition closedUpdates closedBody)
    ForEachStatement spanValue kind syntax name annotation source body -> do
        closedAnnotation <- instantiateType binding annotation
        closedSource <- instantiateExpression binding source
        closedBody <- instantiateBlock binding body
        pure (ForEachStatement spanValue kind syntax name closedAnnotation closedSource closedBody)
    IncrementStatement spanValue name annotation ->
        IncrementStatement spanValue name <$> instantiateType binding annotation
    CompoundAssignmentStatement spanValue operator name annotation value -> do
        closedAnnotation <- instantiateType binding annotation
        closedValue <- instantiateExpression binding value
        pure (CompoundAssignmentStatement spanValue operator name closedAnnotation closedValue)
    DiscardStatement spanValue value ->
        DiscardStatement spanValue <$> instantiateExpression binding value
    BreakStatement spanValue value ->
        BreakStatement spanValue <$> traverse (instantiateExpression binding) value
    ContinueStatement spanValue -> pure (ContinueStatement spanValue)
    GuardStatement spanValue condition block ->
        GuardStatement spanValue <$> instantiateExpression binding condition <*> instantiateBlock binding block
    BlockStatement spanValue block -> BlockStatement spanValue <$> instantiateBlock binding block
    ExpressionStatement spanValue value terminated ->
        ExpressionStatement spanValue <$> instantiateExpression binding value <*> pure terminated

-- | Substitute every type annotation in an expression tree.
instantiateExpression ::
    TemplateBinding ->
    Expression ResolvedName Type ->
    Either TemplateInstantiationError (Expression ResolvedName Type)
instantiateExpression binding expression = case expression of
    NameExpression spanValue name annotation ->
        NameExpression spanValue name <$> instantiateType binding annotation
    LiteralExpression spanValue literal annotation ->
        LiteralExpression spanValue literal <$> instantiateType binding annotation
    MemberAccessExpression spanValue receiver member annotation -> do
        closedReceiver <- instantiateExpression binding receiver
        closedAnnotation <- instantiateType binding annotation
        pure (MemberAccessExpression spanValue closedReceiver member closedAnnotation)
    MethodReferenceExpression spanValue receiver member annotation -> do
        closedReceiver <- instantiateExpression binding receiver
        closedAnnotation <- instantiateType binding annotation
        pure (MethodReferenceExpression spanValue closedReceiver member closedAnnotation)
    CallExpression spanValue callee arguments annotation -> do
        closedCallee <- instantiateExpression binding callee
        closedArguments <- traverse (instantiateExpression binding) arguments
        closedAnnotation <- instantiateType binding annotation
        pure (CallExpression spanValue closedCallee closedArguments closedAnnotation)
    UnaryExpression spanValue operator value annotation -> do
        closedValue <- instantiateExpression binding value
        closedAnnotation <- instantiateType binding annotation
        pure (UnaryExpression spanValue operator closedValue closedAnnotation)
    BinaryExpression spanValue operator left right annotation -> do
        closedLeft <- instantiateExpression binding left
        closedRight <- instantiateExpression binding right
        closedAnnotation <- instantiateType binding annotation
        pure (BinaryExpression spanValue operator closedLeft closedRight closedAnnotation)
    IsPatternExpression spanValue subject patternValue annotation -> do
        closedSubject <- instantiateExpression binding subject
        closedPattern <- instantiatePattern binding patternValue
        closedAnnotation <- instantiateType binding annotation
        pure (IsPatternExpression spanValue closedSubject closedPattern closedAnnotation)
    ConditionalExpression spanValue condition first second annotation -> do
        closedCondition <- instantiateExpression binding condition
        closedFirst <- instantiateExpression binding first
        closedSecond <- instantiateExpression binding second
        closedAnnotation <- instantiateType binding annotation
        pure (ConditionalExpression spanValue closedCondition closedFirst closedSecond closedAnnotation)
    CoalesceExpression spanValue left fallback annotation -> do
        closedLeft <- instantiateExpression binding left
        closedFallback <- instantiateExpression binding fallback
        closedAnnotation <- instantiateType binding annotation
        pure (CoalesceExpression spanValue closedLeft closedFallback closedAnnotation)
    AssignmentExpression spanValue operator name value annotation -> do
        closedValue <- instantiateExpression binding value
        closedAnnotation <- instantiateType binding annotation
        pure (AssignmentExpression spanValue operator name closedValue closedAnnotation)
    IncrementExpression spanValue isPrefix name annotation ->
        IncrementExpression spanValue isPrefix name <$> instantiateType binding annotation
    LoopExpression spanValue loop annotation ->
        LoopExpression spanValue <$> instantiateStatement binding loop <*> instantiateType binding annotation
    BlockExpression spanValue block annotation ->
        BlockExpression spanValue <$> instantiateBlock binding block <*> instantiateType binding annotation
    MatchExpression spanValue subjects arms annotation ->
        MatchExpression spanValue
            <$> traverse (instantiateExpression binding) subjects
            <*> traverse
                (traverseMatchArm (traverseMatchPattern pure (instantiateType binding)) (instantiateExpression binding))
                arms
            <*> instantiateType binding annotation
    CallableExpression spanValue explicit captures parameters body annotation -> do
        closedCaptures <- traverse (instantiateCapture binding) captures
        closedParameters <- traverse (instantiateParameter binding) parameters
        closedBody <- instantiateCallableBody binding body
        closedAnnotation <- instantiateType binding annotation
        pure
            ( CallableExpression
                spanValue
                explicit
                closedCaptures
                closedParameters
                closedBody
                closedAnnotation
            )

instantiatePattern ::
    TemplateBinding ->
    Pattern ResolvedName Type ->
    Either TemplateInstantiationError (Pattern ResolvedName Type)
instantiatePattern binding patternValue = case patternValue of
    WildcardPattern spanValue annotation ->
        WildcardPattern spanValue <$> instantiateType binding annotation
    NullPattern spanValue annotation -> NullPattern spanValue <$> instantiateType binding annotation
    LiteralPattern spanValue literal annotation ->
        LiteralPattern spanValue literal <$> instantiateType binding annotation
    TypePattern spanValue syntax annotation ->
        TypePattern spanValue syntax <$> instantiateType binding annotation
    RelationalPattern spanValue operator literal annotation ->
        RelationalPattern spanValue operator literal <$> instantiateType binding annotation
    NotPattern spanValue nested annotation ->
        NotPattern spanValue
            <$> instantiatePattern binding nested
            <*> instantiateType binding annotation
    AndPattern spanValue left right annotation ->
        AndPattern spanValue
            <$> instantiatePattern binding left
            <*> instantiatePattern binding right
            <*> instantiateType binding annotation
    OrPattern spanValue left right annotation ->
        OrPattern spanValue
            <$> instantiatePattern binding left
            <*> instantiatePattern binding right
            <*> instantiateType binding annotation

instantiateCapture ::
    TemplateBinding ->
    Capture ResolvedName Type ->
    Either TemplateInstantiationError (Capture ResolvedName Type)
instantiateCapture binding capture = do
    closedAnnotation <- instantiateType binding (captureAnnotation capture)
    closedInitializer <- traverse (instantiateExpression binding) (captureInitializer capture)
    pure
        ( Capture
            (captureSpan capture)
            (captureMode capture)
            (captureName capture)
            closedAnnotation
            closedInitializer
        )

-- | Instantiate the expression or block body of a callable.
instantiateCallableBody ::
    TemplateBinding ->
    CallableBody ResolvedName Type ->
    Either TemplateInstantiationError (CallableBody ResolvedName Type)
instantiateCallableBody binding body = case body of
    CallableExpressionBody expression ->
        CallableExpressionBody <$> instantiateExpression binding expression
    CallableBlockBody block -> CallableBlockBody <$> instantiateBlock binding block

instantiateType :: TemplateBinding -> Type -> Either TemplateInstantiationError Type
instantiateType binding valueType = case substituteType binding valueType of
    Right closed -> Right closed
    Left issue -> Left (TemplateTypeSubstitutionFailed issue)

-- | Render a declaration mismatch or template substitution failure.
renderTemplateInstantiationError :: TemplateInstantiationError -> String
renderTemplateInstantiationError issue = case issue of
    ExpectedTemplateTypeDeclaration -> "template instantiation requires a typed template type declaration"
    TemplateBindingTargetsDifferentDeclaration expected actual ->
        "template binding targets symbol "
            ++ show (symbolIdValue expected)
            ++ ", but the declaration has symbol "
            ++ show (symbolIdValue actual)
    TemplateTypeSubstitutionFailed problem -> renderTemplateApplicationError problem
