-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Grammar-boundary tests for member selectors. These assert the parsed tree,
not merely successful token consumption, so later stages receive an explicit
receiver and a separately preserved member spelling.
-}
module StaticMemberParserTests (staticMemberParserTests) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Lexer
import Progmasoft.Tala.Parser

staticMemberParserTests :: [(String, Bool)]
staticMemberParserTests =
    [ ("one-level member call has a selector node", oneLevelCall)
    , ("member call keeps its receiver as a name", receiverIsPreserved)
    , ("member selector keeps the source member spelling", memberSpellingIsPreserved)
    , ("method call wraps the selector rather than flattening its name", callWrapsSelector)
    , ("qualified selectors associate from the left", selectorsAssociateLeft)
    , ("qualified selector chain preserves all path components", selectorPathIsPreserved)
    , ("ordinary call remains an ordinary call", ordinaryCallHasNoSelector)
    , ("selector may be the receiver of an outer call", selectorCanBeNested)
    , ("selector call may appear as a binding initializer", selectorBindingInitializer)
    , ("selector call may appear in a return expression", selectorReturnExpression)
    , ("selector call may appear below arithmetic", selectorArithmeticOperand)
    , ("selector call may appear below a comparison", selectorComparisonOperand)
    , ("selector call may appear in a condition", selectorCondition)
    , ("selector call may appear in a callable expression", selectorCallableExpression)
    , ("selector spelling is case-sensitive", selectorCaseIsPreserved)
    , ("selector span begins at its receiver", selectorSpanBeginsAtReceiver)
    , ("selector span ends at the selected name", selectorSpanEndsAtMember)
    , ("call span includes its closing parenthesis", callSpanIncludesClose)
    , ("selector after a parenthesized receiver parses", parenthesizedReceiver)
    , ("a trailing dot without a member is rejected", trailingDotRejected)
    , ("a dot without a receiver is a target-typed member selection", leadingDotIsTargetTyped)
    , ("two dots without a component are rejected", repeatedDotRejected)
    , ("a numeric token cannot be a member name", numericMemberRejected)
    , ("a keyword cannot be a member name", keywordMemberRejected)
    , ("a missing call close remains a parser diagnostic", missingCloseRejected)
    , ("a missing call argument remains a parser diagnostic", missingArgumentRejected)
    , ("a second selector after a call is retained", selectorAfterCall)
    , ("a selector after a nested call is retained", nestedCallSelector)
    , ("comment punctuation does not create a selector", commentIsNotSelector)
    , ("string punctuation does not create a selector", stringIsNotSelector)
    , ("raw string punctuation does not create a selector", rawStringIsNotSelector)
    , ("character punctuation does not create a selector", characterIsNotSelector)
    , ("selector expression is not an assignment target", selectorAssignmentRejected)
    , ("selector expression can be grouped without flattening", groupedSelector)
    , ("a selector is not confused with a namespace declaration", namespaceAndSelector)
    , ("a selector can be nested in a second argument", secondArgumentSelector)
    , ("multiple selector calls retain argument order", selectorArgumentsPreserved)
    , ("zero-argument selector call has an empty argument list", zeroArgumentCall)
    , ("member selector without a call is syntactically representable", bareSelector)
    , ("selector paths can contain many components", longSelectorPath)
    , ("member access remains available after unary grouping", unaryGroupedSelector)
    , ("member access remains available under Boolean negation", negatedSelector)
    , ("member access remains available under bitwise negation", bitwiseNegatedSelector)
    , ("member access remains available in a nested block", nestedBlockSelector)
    , ("member access remains available in an else block", elseBlockSelector)
    , ("member access remains available in a while condition", whileConditionSelector)
    , ("member access remains available in a loop body", loopBodySelector)
    , ("a malformed selector reports the parser stage", malformedSelectorHasStage)
    , ("a malformed selector keeps a source position", malformedSelectorHasSpan)
    , ("a selector's member name is not resolved by the parser", selectorIsUnresolvedSyntax)
    ]

oneLevelCall :: Bool
oneLevelCall = case parseSource "class Program { void Run() { Counter.Current(); return; } }" of
    Right
        ( ParsedAST
                ( SyntaxTree
                        _
                        [ TypeDeclaration
                                { typeMembers =
                                    [ FunctionDeclaration
                                            { declarationBody = Block (ExpressionStatement _ (CallExpression _ (MemberAccessExpression {}) [] _) True : _)
                                            }
                                        ]
                                }
                            ]
                    )
            ) -> True
    _ -> False

receiverIsPreserved :: Bool
receiverIsPreserved = case firstCall "class Program { void Run() { Counter.Current(); return; } }" of
    Just
        (CallExpression _ (MemberAccessExpression _ (NameExpression _ (Identifier "Counter") _) (Identifier "Current") _) _ _) -> True
    _ -> False

memberSpellingIsPreserved :: Bool
memberSpellingIsPreserved = case firstCall "class Program { void Run() { Math.Sqrt(4.0); return; } }" of
    Just (CallExpression _ (MemberAccessExpression _ _ (Identifier "Sqrt") _) _ _) -> True
    _ -> False

callWrapsSelector :: Bool
callWrapsSelector = case firstCall "class Program { void Run() { Service.Start(); return; } }" of
    Just CallExpression {} -> case firstCallCallee "class Program { void Run() { Service.Start(); return; } }" of
        Just (MemberAccessExpression {}) -> True
        _ -> False
    _ -> False

selectorsAssociateLeft :: Bool
selectorsAssociateLeft = case firstCallCallee "class Program { void Run() { A.B.C(); return; } }" of
    Just
        ( MemberAccessExpression
                _
                (MemberAccessExpression _ (NameExpression _ (Identifier "A") _) (Identifier "B") _)
                (Identifier "C")
                _
            ) -> True
    _ -> False

selectorPathIsPreserved :: Bool
selectorPathIsPreserved = case firstCallCallee "class Program { void Run() { One.Two.Three.Four(); return; } }" of
    Just callee -> selectorPath callee == map Identifier ["One", "Two", "Three", "Four"]
    _ -> False

ordinaryCallHasNoSelector :: Bool
ordinaryCallHasNoSelector = case firstCallCallee "class Program { void Run() { Execute(); return; } }" of
    Just NameExpression {} -> True
    _ -> False

selectorCanBeNested :: Bool
selectorCanBeNested = case firstCall "class Program { void Run() { Consume(Counter.Current()); return; } }" of
    Just (CallExpression _ _ [CallExpression _ (MemberAccessExpression {}) [] _] _) -> True
    _ -> False

selectorBindingInitializer :: Bool
selectorBindingInitializer = case bindingInitializer "class Program { void Run() { int value = Counter.Current(); return; } }" of
    Just CallExpression {} -> True
    _ -> False

selectorReturnExpression :: Bool
selectorReturnExpression = case firstExpression "class Program { int Run() { return Counter.Current(); } }" of
    Just (CallExpression _ (MemberAccessExpression {}) [] _) -> True
    _ -> False

selectorArithmeticOperand :: Bool
selectorArithmeticOperand = case firstExpression "class Program { int Run() { return Counter.Current() + 1; } }" of
    Just (BinaryExpression _ Add CallExpression {} _ _) -> True
    _ -> False

selectorComparisonOperand :: Bool
selectorComparisonOperand = case firstExpression "class Program { bool Run() { return Counter.Current() < 1; } }" of
    Just (BinaryExpression _ LessThan CallExpression {} _ _) -> True
    _ -> False

selectorCondition :: Bool
selectorCondition = case firstExpression "class Program { void Run() { if (Counter.Ready()) { return; } return; } }" of
    Just CallExpression {} -> True
    _ -> False

selectorCallableExpression :: Bool
selectorCallableExpression = case bindingInitializer "class Program { void Run() { auto action = \\() -> Counter.Current(); return; } }" of
    Just CallableExpression {} -> True
    _ -> False

selectorCaseIsPreserved :: Bool
selectorCaseIsPreserved =
    selectorPathFor "class Program { void Run() { Counter.cUrReNt(); return; } }"
        == Just [Identifier "Counter", Identifier "cUrReNt"]

selectorSpanBeginsAtReceiver :: Bool
selectorSpanBeginsAtReceiver = case firstCallCallee "class Program { void Run() { Counter.Current(); return; } }" of
    Just expression -> sourceStart (spanOf expression) == SourcePosition 1 30
    _ -> False

selectorSpanEndsAtMember :: Bool
selectorSpanEndsAtMember = case firstCallCallee "class Program { void Run() { Counter.Current(); return; } }" of
    Just expression -> sourceEnd (spanOf expression) == SourcePosition 1 45
    _ -> False

callSpanIncludesClose :: Bool
callSpanIncludesClose = case firstCall "class Program { void Run() { Counter.Current(); return; } }" of
    Just expression -> sourceEnd (spanOf expression) == SourcePosition 1 47
    _ -> False

parenthesizedReceiver :: Bool
parenthesizedReceiver =
    selectorPathFor "class Program { void Run() { (Counter).Current(); return; } }"
        == Just [Identifier "Counter", Identifier "Current"]

trailingDotRejected :: Bool
trailingDotRejected = parseSource "class Program { void Run() { Counter.; return; } }" `isLeft` True

-- `.Member` selects from the enum that the context expects. The parser keeps
-- the missing receiver as the unit literal, which no source can write; whether
-- there is an enum to select from is the type checker's question.
leadingDotIsTargetTyped :: Bool
leadingDotIsTargetTyped = case firstExpression "class Program { void Run() { .Current(); return; } }" of
    Just (CallExpression _ (MemberAccessExpression _ (LiteralExpression _ UnitLiteral _) (Identifier "Current") _) [] _) -> True
    _ -> False

repeatedDotRejected :: Bool
repeatedDotRejected = parseSource "class Program { void Run() { Counter..Current(); return; } }" `isLeft` True

numericMemberRejected :: Bool
numericMemberRejected = parseSource "class Program { void Run() { Counter.7(); return; } }" `isLeft` True

keywordMemberRejected :: Bool
keywordMemberRejected = parseSource "class Program { void Run() { Counter.return(); return; } }" `isLeft` True

missingCloseRejected :: Bool
missingCloseRejected = parseSource "class Program { void Run() { Counter.Current(1; return; } }" `isLeft` True

missingArgumentRejected :: Bool
missingArgumentRejected = parseSource "class Program { void Run() { Counter.Current(, 1); return; } }" `isLeft` True

selectorAfterCall :: Bool
selectorAfterCall =
    selectorPathFor "class Program { void Run() { Counter.Factory().Current(); return; } }"
        == Just [Identifier "Counter", Identifier "Factory", Identifier "Current"]

nestedCallSelector :: Bool
nestedCallSelector =
    selectorPathFor "class Program { void Run() { Counter.Factory(Next()).Current(); return; } }"
        == Just [Identifier "Counter", Identifier "Factory", Identifier "Current"]

commentIsNotSelector :: Bool
commentIsNotSelector = case parseSource "class Program { void Run() { Execute(); -- Fake.Member()\n return; } }" of
    Right _ -> True
    _ -> False

stringIsNotSelector :: Bool
stringIsNotSelector = firstCall "class Program { void Run() { Print(\"Fake.Member()\"); return; } }" `hasArguments` 1

rawStringIsNotSelector :: Bool
rawStringIsNotSelector = firstCall "class Program { void Run() { Print([[Fake.Member()]]); return; } }" `hasArguments` 1

characterIsNotSelector :: Bool
characterIsNotSelector = firstCall "class Program { void Run() { Print('.'); return; } }" `hasArguments` 1

selectorAssignmentRejected :: Bool
selectorAssignmentRejected = parseSource "class Program { void Run() { Counter.Current = 1; return; } }" `isLeft` True

groupedSelector :: Bool
groupedSelector =
    selectorPathFor "class Program { void Run() { (Counter.Current)(); return; } }"
        == Just [Identifier "Counter", Identifier "Current"]

namespaceAndSelector :: Bool
namespaceAndSelector = case parseSource "namespace Demo.Core; class Program { void Run() { Counter.Current(); return; } }" of
    Right (ParsedAST (SyntaxTree (Just (QualifiedName [Identifier "Demo", Identifier "Core"])) _)) -> True
    _ -> False

secondArgumentSelector :: Bool
secondArgumentSelector = firstCall "class Program { void Run() { Pair(1, Counter.Current()); return; } }" `hasArguments` 2

selectorArgumentsPreserved :: Bool
selectorArgumentsPreserved = case firstCall "class Program { void Run() { Counter.Sum(1, 2); return; } }" of
    Just
        ( CallExpression
                _
                (MemberAccessExpression {})
                [LiteralExpression _ (IntegerLiteral 1) _, LiteralExpression _ (IntegerLiteral 2) _]
                _
            ) -> True
    _ -> False

zeroArgumentCall :: Bool
zeroArgumentCall = case firstCall "class Program { void Run() { Counter.Current(); return; } }" of
    Just (CallExpression _ _ [] _) -> True
    _ -> False

bareSelector :: Bool
bareSelector = case firstExpression "class Program { void Run() { Counter.Current; return; } }" of
    Just (MemberAccessExpression {}) -> True
    _ -> False

longSelectorPath :: Bool
longSelectorPath =
    selectorPathFor "class Program { void Run() { A.B.C.D.E.F.G.H.I.J(); return; } }"
        == Just (map Identifier ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J"])

unaryGroupedSelector :: Bool
unaryGroupedSelector = case firstExpression "class Program { int Run() { return -(Counter.Current()); } }" of
    Just (UnaryExpression _ UnaryNegate CallExpression {} _) -> True
    _ -> False

negatedSelector :: Bool
negatedSelector = case firstExpression "class Program { bool Run() { return not Counter.Ready(); } }" of
    Just (UnaryExpression _ LogicalNot CallExpression {} _) -> True
    _ -> False

bitwiseNegatedSelector :: Bool
bitwiseNegatedSelector = case firstExpression "class Program { int Run() { return !Counter.Mask(); } }" of
    Just (UnaryExpression _ BitwiseNot CallExpression {} _) -> True
    _ -> False

nestedBlockSelector :: Bool
nestedBlockSelector = case parseSource "class Program { void Run() { if (true) { if (true) { Counter.Current(); } } return; } }" of
    Right _ -> True
    _ -> False

elseBlockSelector :: Bool
elseBlockSelector = case parseSource "class Program { void Run() { if (true) { return; } else { Counter.Current(); } return; } }" of
    Right _ -> True
    _ -> False

whileConditionSelector :: Bool
whileConditionSelector = case parseSource "class Program { void Run() { while (Counter.Ready()) { break; } return; } }" of
    Right _ -> True
    _ -> False

loopBodySelector :: Bool
loopBodySelector = case parseSource "class Program { void Run() { while (true) { Counter.Step(); break; } return; } }" of
    Right _ -> True
    _ -> False

malformedSelectorHasStage :: Bool
malformedSelectorHasStage = case parseSource "class Program { void Run() { Counter.; return; } }" of
    Left (diagnostic : _) -> diagnosticStage diagnostic == ParserStage
    _ -> False

malformedSelectorHasSpan :: Bool
malformedSelectorHasSpan = case parseSource "class Program { void Run() { Counter.; return; } }" of
    Left diagnostics -> any ((/= Nothing) . diagnosticSpan) diagnostics
    _ -> False

selectorIsUnresolvedSyntax :: Bool
selectorIsUnresolvedSyntax = case parseSource "class Program { void Run() { Counter.Current(); return; } }" of
    Right (ParsedAST (SyntaxTree _ [TypeDeclaration {typeMembers = [FunctionDeclaration {declarationBody = body}]}])) ->
        case blockStatements body of
            ExpressionStatement _ (CallExpression _ (MemberAccessExpression _ _ (Identifier "Current") ()) _ ()) True : _ -> True
            _ -> False
    _ -> False

parseSource :: String -> Either [Diagnostic] ParsedAST
parseSource source = do
    tokens <- runLexer defaultLexer (LexerInput "static-member-parser.tala" source)
    runParser defaultParser (ParserInput "static-member-parser.tala" tokens)

firstCall :: String -> Maybe (Expression Identifier ())
firstCall source = case firstExpression source of
    Just expression -> case expression of
        call@CallExpression {} -> Just call
        _ -> nestedCall expression
    Nothing -> Nothing
    where
        nestedCall (CallExpression _ _ arguments _) = firstJust [firstCallIn value | value <- arguments]
        nestedCall (MemberAccessExpression _ receiver _ _) = nestedCall receiver
        nestedCall (UnaryExpression _ _ value _) = nestedCall value
        nestedCall (BinaryExpression _ _ left right _) = firstJust [nestedCall left, nestedCall right]
        nestedCall _ = Nothing

firstCallIn :: Expression Identifier () -> Maybe (Expression Identifier ())
firstCallIn expression = case expression of
    call@CallExpression {} -> Just call
    MemberAccessExpression _ receiver _ _ -> firstCallIn receiver
    MethodReferenceExpression _ receiver _ _ -> firstCallIn receiver
    UnaryExpression _ _ value _ -> firstCallIn value
    BinaryExpression _ _ left right _ -> firstJust [firstCallIn left, firstCallIn right]
    _ -> Nothing

firstCallCallee :: String -> Maybe (Expression Identifier ())
firstCallCallee source = do
    CallExpression _ callee _ _ <- firstCall source
    pure callee

firstExpression :: String -> Maybe (Expression Identifier ())
firstExpression source = do
    ParsedAST (SyntaxTree _ declarations) <- either (const Nothing) Just (parseSource source)
    declaration <- firstMember declarations
    case declaration of
        FunctionDeclaration {declarationBody = Block statements} -> firstExpressionStatement statements
        _ -> Nothing

firstMember :: [Declaration name annotation] -> Maybe (Declaration name annotation)
firstMember declarations =
    firstJust [firstMember members | TypeDeclaration {typeMembers = members} <- declarations]
        `orElse` firstFunction declarations
    where
        firstFunction values = firstJust [Just declaration | declaration@FunctionDeclaration {} <- values]

firstExpressionStatement :: [Statement name annotation] -> Maybe (Expression name annotation)
firstExpressionStatement statements = firstJust (map direct statements) `orElse` firstJust (map nested statements)
    where
        direct statement = case statement of
            ExpressionStatement _ expression _ -> Just expression
            ReturnStatement _ value -> value
            IfStatement _ condition _ _ -> Just condition
            WhileStatement _ condition _ -> Just condition
            DoWhileStatement _ _ condition -> Just condition
            ForStatement _ _ condition _ _ -> condition
            ForEachStatement _ _ _ _ _ source _ -> Just source
            BreakStatement _ value -> value
            _ -> Nothing
        nested (IfStatement _ _ yes no) = firstExpressionStatement (blockStatements yes ++ maybe [] blockStatements no)
        nested (WhileStatement _ _ body) = firstExpressionStatement (blockStatements body)
        nested (DoWhileStatement _ body _) = firstExpressionStatement (blockStatements body)
        nested (ForStatement _ _ _ _ body) = firstExpressionStatement (blockStatements body)
        nested (ForEachStatement _ _ _ _ _ _ body) = firstExpressionStatement (blockStatements body)
        nested _ = Nothing

bindingInitializer :: String -> Maybe (Expression Identifier ())
bindingInitializer source = do
    ParsedAST (SyntaxTree _ declarations) <- either (const Nothing) Just (parseSource source)
    findBinding declarations
    where
        findBinding declarations =
            firstJust
                [ findBlock body
                | TypeDeclaration {typeMembers = members} <- declarations
                , FunctionDeclaration {declarationBody = body} <- members
                ]
        findBlock (Block statements) = firstJust [Just value | BindingStatement _ _ _ _ _ value <- statements] `orElse` firstJust (map nested statements)
        nested (IfStatement _ _ yes no) = findBlock (Block (blockStatements yes ++ maybe [] blockStatements no))
        nested _ = Nothing

selectorPath :: Expression Identifier annotation -> [Identifier]
selectorPath expression = case expression of
    NameExpression _ name _ -> [name]
    MemberAccessExpression _ receiver member _ -> selectorPath receiver ++ [member]
    MethodReferenceExpression _ receiver member _ -> selectorPath receiver ++ [member]
    CallExpression _ callee _ _ -> selectorPath callee
    _ -> []

selectorPathFor :: String -> Maybe [Identifier]
selectorPathFor source = selectorPath <$> firstCallCallee source

hasArguments :: Maybe (Expression Identifier ()) -> Int -> Bool
hasArguments (Just (CallExpression _ _ arguments _)) expected = length arguments == expected
hasArguments _ _ = False

spanOf :: Expression name annotation -> SourceSpan
spanOf expression = case expression of
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

isLeft :: Either [a] b -> Bool -> Bool
isLeft value expected = case value of
    Left _ -> expected
    Right _ -> not expected

firstJust :: [Maybe value] -> Maybe value
firstJust values = case values of
    Just value : _ -> Just value
    Nothing : remaining -> firstJust remaining
    [] -> Nothing

orElse :: Maybe value -> Maybe value -> Maybe value
orElse first second = case first of Just _ -> first; Nothing -> second
