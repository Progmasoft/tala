-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | The runner of a test build.

A test build has no @Main@ of its own. The driver finds the methods with
the @[Fact]@ attribute in the parsed sources and adds a class to their
namespace whose @Main@ calls each of them in source order, closes each with
@$Test.End@ under its name, and ends with @$Test.Finish@. The class is
ordinary source to every later stage. Its name, @$Tests@, starts with @$@,
which no identifier does, so it cannot meet a class of the program.

A test is a static method without parameters that returns @void@. Facts of
instance methods need objects, and facts in several namespaces need the
multi-module link unit; both are refused as not implemented yet.
-}
module Progmasoft.Tala.TestRunner
    ( TestCase (..)
    , runnerClassName
    , findTestCases
    , testRunner
    ) where

import Data.List (nub)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Diagnostic

-- | One @[Fact]@ method, as the runner calls and names it.
data TestCase = TestCase
    { testNamespace :: QualifiedName
    , testClass :: Identifier
    , testMethod :: Identifier
    , testDisplayName :: String
    , testSpan :: SourceSpan
    }
    deriving stock (Eq, Ord, Read, Show)

-- | The name of the class the driver adds to a test build.
runnerClassName :: Identifier
runnerClassName = Identifier "$Tests"

{- | The tests of parsed source units, each given by its namespace and its
declarations, in source order; and the problems of facts that cannot run.
-}
findTestCases :: [(Maybe QualifiedName, [Declaration Identifier ()])] -> Either [Diagnostic] [TestCase]
findTestCases units = case concat [problems | Left problems <- found] of
    [] -> Right [testCase | Right testCase <- found]
    problems -> Left problems
    where
        found = concatMap unitCases units
        unitCases (namespace, declarations) = concatMap (declarationCases namespace) declarations
        declarationCases namespace declaration = case declaration of
            TypeDeclaration {declarationName = className, typeMembers = members} ->
                [ classify namespace className (method, isStatic, parameters, returnSyntax) fact
                | FunctionDeclaration
                    { declarationName = method
                    , declarationIsStatic = isStatic
                    , declarationParameters = parameters
                    , declarationReturnSyntax = returnSyntax
                    , declarationFact = Just fact
                    } <-
                    members
                ]
            TemplateTypeDeclaration {typeMembers = members} ->
                [ Left [problem (factSpan fact) "TAE0016" "a [Fact] method of a template class is not compiled yet"]
                | FunctionDeclaration {declarationFact = Just fact} <- members
                ]
            _ -> []
        classify namespace className (method, isStatic, parameters, returnSyntax) fact = case namespace of
            Nothing -> Left [problem (factSpan fact) "TAE0019" "a [Fact] method must stand in a namespace, which names the test build"]
            Just name
                | not isStatic ->
                    Left [problem (factSpan fact) "TAE0016" "an instance [Fact] method is not compiled yet; declare the test static"]
                | not (null parameters) -> Left [problem (factSpan fact) "TAE0017" "a [Fact] method takes no parameters"]
                | not (spellsVoid returnSyntax) -> Left [problem (factSpan fact) "TAE0018" "a [Fact] method returns void"]
                | otherwise ->
                    Right
                        ( TestCase
                            name
                            className
                            method
                            (maybe (identifierText className ++ "." ++ identifierText method) id (factName fact))
                            (factSpan fact)
                        )

{- | The namespace of a test build, its entry and the declaration of its
runner class. The tests must stand in one namespace, and there must be at
least one.
-}
testRunner :: [TestCase] -> Either [Diagnostic] (QualifiedName, QualifiedName, Declaration Identifier ())
testRunner cases = case (cases, nub (map testNamespace cases)) of
    ([], _) ->
        Left [Diagnostic TypeCheckerStage Error "TAE0015" Nothing "no [Fact] method was found; a test build needs at least one"]
    (first : _, [namespace@(QualifiedName parts)]) ->
        Right (namespace, QualifiedName (parts ++ [runnerClassName]), runner (testSpan first))
    (_, namespaces) ->
        Left
            [ Diagnostic
                TypeCheckerStage
                Error
                "TAE0020"
                Nothing
                ( "[Fact] methods stand in several namespaces ("
                    ++ unwords (map render namespaces)
                    ++ "); a test build of several namespaces is not compiled yet"
                )
            ]
    where
        render (QualifiedName parts) = foldr1 (\part rest -> part ++ "." ++ rest) (map identifierText parts)
        runner spanValue =
            let statement expression = ExpressionStatement spanValue expression True
                call receiver method arguments =
                    CallExpression
                        spanValue
                        (MemberAccessExpression spanValue (NameExpression spanValue receiver ()) (Identifier method) ())
                        arguments
                        ()
                text value = LiteralExpression spanValue (StringLiteral value) ()
                testReceiver = Identifier "$Test"
                body =
                    concat
                        [ [ statement (call (testClass testCase) (identifierText (testMethod testCase)) [])
                          , statement (call testReceiver "End" [text (testDisplayName testCase)])
                          ]
                        | testCase <- cases
                        ]
                        ++ [statement (call testReceiver "Finish" [])]
                main =
                    FunctionDeclaration
                        spanValue
                        (Identifier "Main")
                        ()
                        (ExplicitType (Identifier "void"))
                        []
                        (Block body)
                        True
                        PublicAccess
                        Nothing
             in TypeDeclaration spanValue runnerClassName () [main]

spellsVoid :: TypeSyntax -> Bool
spellsVoid syntax = case syntax of
    ExplicitType (Identifier "void") -> True
    QualifiedTypeSyntax (QualifiedName [Identifier "void"]) [] -> True
    _ -> False

problem :: SourceSpan -> String -> String -> Diagnostic
problem spanValue code message = Diagnostic TypeCheckerStage Error code (Just spanValue) message
