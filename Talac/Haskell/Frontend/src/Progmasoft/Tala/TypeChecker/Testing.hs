-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | The test runtime in the type checker.

@#expect@ and the runner of a test build call methods of @$Test@, a name
that no source can spell. This module checks those calls and rewrites them
into calls of the runtime, as "Progmasoft.Tala.TypeChecker.Console" does
for the console:

* @$Test.Fail(header, text, value, ...)@ records a failed expectation. The
  report is the header, and below it one line for each operand, its text
  and its value: @count is 2@. An operand whose type has no text form is
  left out of the report rather than refused, because the expectation
  itself is well formed.
* @$Test.End(name)@ closes the test of that name.
* @$Test.Finish()@ writes the totals of the run.
-}
module Progmasoft.Tala.TypeChecker.Testing
    ( testReceiver
    , checkTestCall
    ) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.RuntimeCall
import Progmasoft.Tala.TypeChecker.Console (CheckExpression, asText, runtimeCall)

type Checked = (Expression ResolvedName Type, Type, [Diagnostic])

-- | Whether the receiver of a member call is @$Test@.
testReceiver :: Expression ResolvedName () -> Bool
testReceiver receiver = case receiver of
    NameExpression _ name _ -> resolvedSymbol name == builtinTestSymbol
    _ -> False

-- | Check a call of a method of @$Test@ and rewrite it into runtime calls.
checkTestCall :: CheckExpression -> SourceSpan -> Identifier -> [Expression ResolvedName ()] -> Checked
checkTestCall check callSpan member arguments = case (identifierText member, arguments) of
    ("Fail", LiteralExpression headerSpan (StringLiteral header) () : operands) ->
        case operandLines operands of
            Right (pieces, problems) ->
                let report = foldl join (text headerSpan header) pieces
                 in (runtimeCall callSpan TestFail [report], voidType, problems)
            Left problems -> failed problems
    ("End", [LiteralExpression nameSpan (StringLiteral name) ()]) ->
        (runtimeCall callSpan TestEnd [text nameSpan name], voidType, [])
    ("Finish", []) -> (runtimeCall callSpan TestFinish [], voidType, [])
    (name, _) -> failed [problem ("the test runtime has no call " ++ name ++ " of this form")]
    where
        join whole part = runtimeCall callSpan TextConcat [whole, part]

        -- Each operand as a line of the report: the line terminator, an
        -- indent, the operand's text, and its value.
        operandLines values = case values of
            [] -> Right ([], [])
            LiteralExpression textSpan (StringLiteral written) () : value : rest -> do
                (later, laterProblems) <- operandLines rest
                let (typed, valueType, problems) = check Nothing value
                    line = case asText (expressionSourceSpan typed) typed valueType of
                        Right shown ->
                            [ runtimeCall textSpan TextNewline []
                            , text textSpan ("    " ++ written ++ " is ")
                            , shown
                            ]
                        Left _ -> []
                Right (line ++ later, problems ++ laterProblems)
            _ -> Left [problem "the operands of a failed expectation come in pairs of text and value"]

        text spanValue value = LiteralExpression spanValue (StringLiteral value) stringType
        failed problems = (LiteralExpression callSpan UnitLiteral ErrorType, ErrorType, problems)
        problem message = Diagnostic TypeCheckerStage Error "TAT0083" (Just callSpan) message
