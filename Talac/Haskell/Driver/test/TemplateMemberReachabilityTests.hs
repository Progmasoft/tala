-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

module TemplateMemberReachabilityTests (templateMemberReachabilityTests) where

import Data.List (isInfixOf)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Frontend
import Progmasoft.Tala.Template.Application
import Progmasoft.Tala.Template.Mangling
import Progmasoft.Tala.Template.MemberReachability
import Progmasoft.Tala.Template.Specialization

templateMemberReachabilityTests :: [(String, Bool)]
templateMemberReachabilityTests =
    [ ("member graph retains direct semantic calls", graphRetainsDirectCalls)
    , ("member graph classifies declaration-external calls", graphClassifiesExternalCalls)
    , ("name roots select a transitive member closure", nameRootSelectsClosure)
    , ("symbol roots select a transitive member closure", symbolRootSelectsClosure)
    , ("selection output preserves declaration order", selectionPreservesSourceOrder)
    , ("selection roots preserve declaration order", rootsPreserveSourceOrder)
    , ("unreachable members remain lazy", unreachableMembersStayLazy)
    , ("self-recursive calls terminate", selfRecursionTerminates)
    , ("mutually recursive calls terminate", mutualRecursionTerminates)
    , ("repeated calls retain evidence but share an edge", repeatedCallsShareEdge)
    , ("calls nested in arguments remain reachable", nestedArgumentCallsAreFound)
    , ("calls nested in conditions remain reachable", conditionCallsAreFound)
    , ("calls nested in callable bodies remain reachable", callableBodyCallsAreFound)
    , ("calls nested in capture initializers remain reachable", captureInitializerCallsAreFound)
    , ("nested type bodies do not enter the enclosing graph", nestedTypeBodiesAreIsolated)
    , ("overload name roots select every matching symbol", overloadNameSelectsEveryMatch)
    , ("symbol roots distinguish same-spelling overloads", overloadSymbolSelectionIsExact)
    , ("internal dependency selection remains overload-exact", dependencySelectionIsExact)
    , ("missing member names are diagnosed", missingNameIsRejected)
    , ("missing member symbols are diagnosed", missingSymbolIsRejected)
    , ("zero member symbols are diagnosed", zeroSymbolIsRejected)
    , ("duplicate member symbols are diagnosed", duplicateSymbolIsRejected)
    , ("empty roots produce an empty closure", emptyRootsProduceEmptyClosure)
    , ("reachability statistics count all graph nodes", statisticsCountNodes)
    , ("reachability statistics distinguish call classes", statisticsCountCalls)
    , ("reachability verifier accepts an authentic result", verifierAcceptsResult)
    , ("reachability verifier rejects an omitted dependency", verifierRejectsOmittedDependency)
    , ("reachability verifier rejects an invented edge", verifierRejectsInventedEdge)
    , ("reachability verifier rejects stale member payload", verifierRejectsStaleMembers)
    , ("reachability verifier rejects stale statistics", verifierRejectsStaleStatistics)
    , ("reachability error rendering identifies names", errorRenderingIdentifiesName)
    , ("reachability issue rendering identifies edges", issueRenderingIdentifiesEdge)
    , ("planner expands a member demand through resolved calls", plannerExpandsMemberDemand)
    , ("planner records the expanded effective scope", plannerRecordsExpandedScope)
    , ("planner leaves unrelated members unmaterialized", plannerLeavesUnrelatedLazy)
    , ("planner member limit includes reachable callees", plannerLimitIncludesCallees)
    , ("planner freshens reachable call targets coherently", plannerFreshensCallTargets)
    , ("planner mangles every reachable member", plannerManglesReachableMembers)
    , ("compiler bridge lowers the reachable closure", compilerBridgeLowersClosure)
    , ("planner surfaces an invalid member graph", plannerRejectsInvalidGraph)
    , ("planner call-graph error rendering is actionable", plannerGraphErrorRenders)
    ]

chainSource :: String
chainSource =
    unwords
        [ "template<typename T> class Chain {"
        , "T Entry(_ T value) { return Normalize(value); }"
        , "T Normalize(_ T value) { return Finish(value); }"
        , "T Finish(_ T value) { return value; }"
        , "T Unused(_ T value) { return value; }"
        , "}"
        ]

selfRecursiveSource :: String
selfRecursiveSource =
    "template<typename T> class Loop { T Repeat(_ T value) { return Repeat(value); } T Idle(_ T value) { return value; } }"

mutualRecursiveSource :: String
mutualRecursiveSource =
    "template<typename T> class Loop { T Left(_ T value) { return Right(value); } T Right(_ T value) { return Left(value); } }"

branchSource :: String
branchSource =
    unwords
        [ "template<typename T> class Branch {"
        , "int Entry() { if (Gate()) { return Convert(Leaf()); } return 0; }"
        , "bool Gate() { return true; }"
        , "int Convert(_ int value) { return value; }"
        , "int Leaf() { return 7; }"
        , "int Unused() { return 9; }"
        , "}"
        ]

analyzeMembers :: String -> Maybe [Declaration ResolvedName Type]
analyzeMembers source = do
    typed <- case analyzeSemantics (CompilerInput "member-reachability-test.tala" source) of
        Right artifacts -> Just (semanticTypedAST artifacts)
        Left _ -> Nothing
    templateMembers typed

templateMembers :: TypedAST -> Maybe [Declaration ResolvedName Type]
templateMembers (TypedAST tree) = case syntaxDeclarations tree of
    [TemplateTypeDeclaration {typeMembers = members}] -> Just members
    _ -> Nothing

reachByName :: String -> [String] -> Maybe TemplateMemberReachability
reachByName source names = do
    members <- analyzeMembers source
    rightValue (selectReachableMembersByName (map Identifier names) members)

reachBySymbol :: [Declaration ResolvedName Type] -> [SymbolId] -> Maybe TemplateMemberReachability
reachBySymbol members symbols = rightValue (selectReachableMembersBySymbol symbols members)

memberNames :: [Declaration ResolvedName annotation] -> [String]
memberNames = map (identifierText . resolvedSpelling . declarationName)

reachabilityNames :: TemplateMemberReachability -> [String]
reachabilityNames = memberNames . memberReachabilityMembers

memberNamed :: String -> [Declaration ResolvedName annotation] -> Maybe (Declaration ResolvedName annotation)
memberNamed name = first ((== name) . identifierText . resolvedSpelling . declarationName)

memberSymbolNamed :: String -> [Declaration ResolvedName annotation] -> Maybe SymbolId
memberSymbolNamed name members = resolvedSymbol . declarationName <$> memberNamed name members

graphRetainsDirectCalls :: Bool
graphRetainsDirectCalls = case analyzeMembers chainSource >>= rightValue . buildTemplateMemberGraph of
    Just graph ->
        length (templateGraphInternalCalls graph) == 2
            && edgeNames graph == [("Entry", "Normalize"), ("Normalize", "Finish")]
    Nothing -> False

edgeNames :: TemplateMemberGraph -> [(String, String)]
edgeNames graph =
    [ (nameOf (templateCallOwner call), nameOf (templateCallTarget call))
    | call <- templateGraphInternalCalls graph
    ]
    where
        nameOf symbol = case first ((== symbol) . templateMemberSymbol) (templateGraphNodes graph) of
            Just node -> identifierText (templateMemberName node)
            Nothing -> "<external>"

graphClassifiesExternalCalls :: Bool
graphClassifiesExternalCalls = case analyzeMembers chainSource of
    Just members -> case memberNamed "Entry" members of
        Just entry ->
            let changed = replaceMember "Entry" (appendExternalCall entry) members
             in case buildTemplateMemberGraph changed of
                    Right graph ->
                        length (templateGraphInternalCalls graph) == 2
                            && length (templateGraphExternalCalls graph) == 1
                            && any ((== SymbolId 9000) . templateCallTarget) (templateGraphExternalCalls graph)
                    Left _ -> False
        Nothing -> False
    Nothing -> False

appendExternalCall :: Declaration ResolvedName Type -> Declaration ResolvedName Type
appendExternalCall declaration@FunctionDeclaration {declarationBody = Block statements} =
    declaration
        { declarationBody =
            Block
                ( ExpressionStatement
                    testSpan
                    ( CallExpression
                        testSpan
                        (NameExpression testSpan (resolved 9000 "External") (FunctionType [] voidType))
                        []
                        voidType
                    )
                    True
                    : statements
                )
        }
appendExternalCall declaration = declaration

nameRootSelectsClosure :: Bool
nameRootSelectsClosure = case reachByName chainSource ["Entry"] of
    Just result -> reachabilityNames result == ["Entry", "Normalize", "Finish"]
    Nothing -> False

symbolRootSelectsClosure :: Bool
symbolRootSelectsClosure = case analyzeMembers chainSource of
    Just members -> case memberSymbolNamed "Entry" members >>= \symbol -> reachBySymbol members [symbol] of
        Just result -> reachabilityNames result == ["Entry", "Normalize", "Finish"]
        Nothing -> False
    Nothing -> False

selectionPreservesSourceOrder :: Bool
selectionPreservesSourceOrder = case reachByName chainSource ["Finish", "Entry"] of
    Just result -> reachabilityNames result == ["Entry", "Normalize", "Finish"]
    Nothing -> False

rootsPreserveSourceOrder :: Bool
rootsPreserveSourceOrder = case analyzeMembers chainSource of
    Just members -> case selectReachableMembersByName [Identifier "Finish", Identifier "Entry"] members of
        Right result -> memberReachabilityRoots result == symbolsNamed ["Entry", "Finish"] members
        Left _ -> False
    Nothing -> False

unreachableMembersStayLazy :: Bool
unreachableMembersStayLazy = maybe False (notElem "Unused" . reachabilityNames) (reachByName chainSource ["Entry"])

selfRecursionTerminates :: Bool
selfRecursionTerminates = case reachByName selfRecursiveSource ["Repeat"] of
    Just result ->
        reachabilityNames result == ["Repeat"]
            && memberReachabilityEdges result == [(onlySymbol result, onlySymbol result)]
    Nothing -> False

mutualRecursionTerminates :: Bool
mutualRecursionTerminates = case reachByName mutualRecursiveSource ["Left"] of
    Just result ->
        reachabilityNames result == ["Left", "Right"]
            && length (memberReachabilityEdges result) == 2
    Nothing -> False

repeatedCallsShareEdge :: Bool
repeatedCallsShareEdge = case analyzeMembers chainSource of
    Just members -> case (memberNamed "Entry" members, memberSymbolNamed "Normalize" members) of
        (Just entry, Just target) ->
            let changed = replaceMember "Entry" (appendCall target entry) members
             in case selectReachableMembersByName [Identifier "Entry"] changed of
                    Right result ->
                        internalTemplateMemberCalls (memberReachabilityStatistics result) == 3
                            && length (memberReachabilityEdges result) == 2
                    Left _ -> False
        _ -> False
    Nothing -> False

nestedArgumentCallsAreFound :: Bool
nestedArgumentCallsAreFound = case reachByName branchSource ["Entry"] of
    Just result -> all (`elem` reachabilityNames result) ["Convert", "Leaf"]
    Nothing -> False

conditionCallsAreFound :: Bool
conditionCallsAreFound = case reachByName branchSource ["Entry"] of
    Just result -> "Gate" `elem` reachabilityNames result
    Nothing -> False

callableBodyCallsAreFound :: Bool
callableBodyCallsAreFound = case analyzeMembers chainSource of
    Just members -> case (memberNamed "Entry" members, memberSymbolNamed "Finish" members) of
        (Just entry, Just target) ->
            let changed = replaceMember "Entry" (prependCallable target entry) members
             in maybe False (elem "Finish" . reachabilityNames) (rightValue (selectReachableMembersByName [Identifier "Entry"] changed))
        _ -> False
    Nothing -> False

captureInitializerCallsAreFound :: Bool
captureInitializerCallsAreFound = case analyzeMembers chainSource of
    Just members -> case (memberNamed "Entry" members, memberSymbolNamed "Finish" members) of
        (Just entry, Just target) ->
            let changed = replaceMember "Entry" (prependCapture target entry) members
             in maybe False (elem "Finish" . reachabilityNames) (rightValue (selectReachableMembersByName [Identifier "Entry"] changed))
        _ -> False
    Nothing -> False

nestedTypeBodiesAreIsolated :: Bool
nestedTypeBodiesAreIsolated = case analyzeMembers chainSource of
    Just members -> case memberSymbolNamed "Finish" members of
        Just target ->
            let nestedMethod = simpleCallingMember 8101 "NestedCall" target
                nested = TypeDeclaration testSpan (resolved 8100 "Nested") (namedType "Nested") [nestedMethod]
                changed = nested : members
             in case selectReachableMembersByName [Identifier "Nested"] changed of
                    Right result -> reachabilityNames result == ["Nested"]
                    Left _ -> False
        Nothing -> False
    Nothing -> False

overloadNameSelectsEveryMatch :: Bool
overloadNameSelectsEveryMatch = case overloadedMembers of
    Just members -> case selectReachableMembersByName [Identifier "Finish"] members of
        Right result -> reachabilityNames result == ["Finish", "Finish"]
        Left _ -> False
    Nothing -> False

overloadSymbolSelectionIsExact :: Bool
overloadSymbolSelectionIsExact = case overloadedMembers of
    Just members -> case [resolvedSymbol (declarationName member) | member <- members, memberName member == "Finish"] of
        _ : second : _ -> case selectReachableMembersBySymbol [second] members of
            Right result -> map (resolvedSymbol . declarationName) (memberReachabilityMembers result) == [second]
            Left _ -> False
        _ -> False
    Nothing -> False

dependencySelectionIsExact :: Bool
dependencySelectionIsExact = case overloadedMembers of
    Just members -> case (memberSymbolNamed "Entry" members, memberSymbolNamed "Finish" members) of
        (Just entry, Just originalFinish) -> case selectReachableMembersBySymbol [entry] members of
            Right result ->
                originalFinish `elem` memberReachabilitySymbols result
                    && length [() | member <- memberReachabilityMembers result, memberName member == "Finish"] == 1
            Left _ -> False
        _ -> False
    Nothing -> False

missingNameIsRejected :: Bool
missingNameIsRejected = case analyzeMembers chainSource of
    Just members -> selectReachableMembersByName [Identifier "Absent"] members == Left [MissingTemplateMemberName (Identifier "Absent")]
    Nothing -> False

missingSymbolIsRejected :: Bool
missingSymbolIsRejected = case analyzeMembers chainSource of
    Just members -> selectReachableMembersBySymbol [SymbolId 9999] members == Left [MissingTemplateMemberSymbol (SymbolId 9999)]
    Nothing -> False

zeroSymbolIsRejected :: Bool
zeroSymbolIsRejected = case analyzeMembers chainSource of
    Just (firstMember : remaining) -> case buildTemplateMemberGraph (setMemberSymbol (SymbolId 0) firstMember : remaining) of
        Left [InvalidTemplateMemberSymbol _ (SymbolId 0)] -> True
        _ -> False
    _ -> False

duplicateSymbolIsRejected :: Bool
duplicateSymbolIsRejected = case analyzeMembers chainSource of
    Just (firstMember : secondMember : remaining) ->
        let symbol = resolvedSymbol (declarationName firstMember)
         in case buildTemplateMemberGraph (firstMember : setMemberSymbol symbol secondMember : remaining) of
                Left problems -> any isDuplicate problems
                Right _ -> False
    _ -> False
    where
        isDuplicate (DuplicateTemplateMemberSymbol _ _) = True
        isDuplicate _ = False

emptyRootsProduceEmptyClosure :: Bool
emptyRootsProduceEmptyClosure = case reachByName chainSource [] of
    Just result -> null (memberReachabilityMembers result) && null (memberReachabilityEdges result)
    Nothing -> False

statisticsCountNodes :: Bool
statisticsCountNodes = case reachByName chainSource ["Entry"] of
    Just result ->
        let statistics = memberReachabilityStatistics result
         in totalTemplateMembers statistics == 4
                && callableTemplateMembers statistics == 4
                && requestedTemplateMemberRoots statistics == 1
                && reachableTemplateMembers statistics == 3
    Nothing -> False

statisticsCountCalls :: Bool
statisticsCountCalls = case reachByName branchSource ["Entry"] of
    Just result ->
        let statistics = memberReachabilityStatistics result
         in observedTemplateMemberCalls statistics == 3
                && internalTemplateMemberCalls statistics == 3
                && externalTemplateMemberCalls statistics == 0
                && uniqueTemplateMemberEdges statistics == 3
    Nothing -> False

verifierAcceptsResult :: Bool
verifierAcceptsResult = case analyzeMembers chainSource of
    Just members -> case selectReachableMembersByName [Identifier "Entry"] members of
        Right result -> verifyTemplateMemberReachability members result == Right []
        Left _ -> False
    Nothing -> False

verifierRejectsOmittedDependency :: Bool
verifierRejectsOmittedDependency = case reachabilityFixture of
    Just (members, result) -> case memberReachabilitySymbols result of
        root : _ ->
            let changed = result {memberReachabilitySymbols = [root], memberReachabilityMembers = take 1 (memberReachabilityMembers result)}
             in hasIssue isDependency (verifyTemplateMemberReachability members changed)
        [] -> False
    Nothing -> False
    where
        isDependency ReachabilityDependencyNotSelected {} = True
        isDependency _ = False

verifierRejectsInventedEdge :: Bool
verifierRejectsInventedEdge = case reachabilityFixture of
    Just (members, result) ->
        let changed = result {memberReachabilityEdges = memberReachabilityEdges result ++ [(SymbolId 8000, SymbolId 8001)]}
         in hasIssue isUnexpected (verifyTemplateMemberReachability members changed)
    Nothing -> False
    where
        isUnexpected (UnexpectedReachabilityEdge (SymbolId 8000) (SymbolId 8001)) = True
        isUnexpected _ = False

verifierRejectsStaleMembers :: Bool
verifierRejectsStaleMembers = case reachabilityFixture of
    Just (members, result) ->
        let changed = result {memberReachabilityMembers = take 1 (memberReachabilityMembers result)}
         in hasIssue isDifferent (verifyTemplateMemberReachability members changed)
    Nothing -> False
    where
        isDifferent ReachabilityMembersDiffer {} = True
        isDifferent _ = False

verifierRejectsStaleStatistics :: Bool
verifierRejectsStaleStatistics = case reachabilityFixture of
    Just (members, result) ->
        let statistics = memberReachabilityStatistics result
            changed = result {memberReachabilityStatistics = statistics {reachableTemplateMembers = 99}}
         in hasIssue isIncorrect (verifyTemplateMemberReachability members changed)
    Nothing -> False
    where
        isIncorrect IncorrectReachabilityStatistics {} = True
        isIncorrect _ = False

errorRenderingIdentifiesName :: Bool
errorRenderingIdentifiesName =
    "Absent" `isInfixOf` renderTemplateMemberReachabilityError (MissingTemplateMemberName (Identifier "Absent"))

issueRenderingIdentifiesEdge :: Bool
issueRenderingIdentifiesEdge =
    "SymbolId 10 -> SymbolId 11"
        `isInfixOf` renderTemplateMemberReachabilityIssue (MissingReachabilityEdge (SymbolId 10) (SymbolId 11))

plannerExpandsMemberDemand :: Bool
plannerExpandsMemberDemand = case chainPlan defaultTemplateSpecializationLimits of
    Right planValue -> maybe False ((== ["Entry", "Normalize", "Finish"]) . selectedNames) (onlySpecialization planValue)
    Left _ -> False

plannerRecordsExpandedScope :: Bool
plannerRecordsExpandedScope = case chainPlan defaultTemplateSpecializationLimits >>= requireOnly of
    Right specialization ->
        templateSpecializationScope specialization
            == TemplateMemberDemand (map Identifier ["Entry", "Normalize", "Finish"])
    Left _ -> False

plannerLeavesUnrelatedLazy :: Bool
plannerLeavesUnrelatedLazy = case chainPlan defaultTemplateSpecializationLimits >>= requireOnly of
    Right specialization -> "Unused" `notElem` selectedNames specialization
    Left _ -> False

plannerLimitIncludesCallees :: Bool
plannerLimitIncludesCallees = case chainPlan limits of
    Left [TemplateMemberLimitExceeded _ 2 3] -> True
    _ -> False
    where
        limits = defaultTemplateSpecializationLimits {maximumMembersPerSpecialization = 2}

plannerFreshensCallTargets :: Bool
plannerFreshensCallTargets = case chainPlan defaultTemplateSpecializationLimits >>= requireOnly of
    Right specialization -> case selectedMembers specialization of
        members -> case (memberNamed "Entry" members, memberSymbolNamed "Normalize" members) of
            (Just entry, Just normalize) -> directTargets entry == [normalize]
            _ -> False
    Left _ -> False

plannerManglesReachableMembers :: Bool
plannerManglesReachableMembers = case chainPlan defaultTemplateSpecializationLimits >>= requireOnly of
    Right specialization ->
        length (templateSpecializationMangledMembers specialization) == 3
            && all (not . null . mangledMemberText) (templateSpecializationMangledMembers specialization)
    Left _ -> False

compilerBridgeLowersClosure :: Bool
compilerBridgeLowersClosure = case analyzeTyped chainSource of
    Just typed -> case compileTemplateSpecializations defaultTemplateSpecializationLimits typed [entryDemand] of
        Right (_, core) -> memberNamesFromCore core == ["Entry", "Normalize", "Finish"]
        Left _ -> False
    Nothing -> False

plannerRejectsInvalidGraph :: Bool
plannerRejectsInvalidGraph = case analyzeTyped chainSource >>= withZeroFirstMember of
    Just typed -> case planTemplateSpecializations defaultTemplateSpecializationLimits typed [entryDemand] of
        Left [TemplateMemberReachabilityFailed _ failures] -> any isInvalid failures
        _ -> False
    Nothing -> False
    where
        isInvalid InvalidTemplateMemberSymbol {} = True
        isInvalid _ = False

plannerGraphErrorRenders :: Bool
plannerGraphErrorRenders =
    "invalid member call graph"
        `isInfixOf` renderTemplateSpecializationError
            ( TemplateMemberReachabilityFailed
                (QualifiedName [Identifier "Chain"])
                [InvalidTemplateMemberSymbol (Identifier "Entry") (SymbolId 0)]
            )

chainPlan :: TemplateSpecializationLimits -> Either [TemplateSpecializationError] TemplateSpecializationPlan
chainPlan limits = case analyzeTyped chainSource of
    Just typed -> planTemplateSpecializations limits typed [entryDemand]
    Nothing -> Left []

entryDemand :: TemplateSpecializationDemand
entryDemand =
    TemplateSpecializationDemand
        (TemplateApplication (QualifiedName [Identifier "Chain"]) [TypeTemplateArgument stringType])
        (TemplateMemberDemand [Identifier "Entry"])
        "member-reachability-test"

analyzeTyped :: String -> Maybe TypedAST
analyzeTyped source = case analyzeSemantics (CompilerInput "member-reachability-test.tala" source) of
    Right artifacts -> Just (semanticTypedAST artifacts)
    Left _ -> Nothing

withZeroFirstMember :: TypedAST -> Maybe TypedAST
withZeroFirstMember (TypedAST tree) = case syntaxDeclarations tree of
    [declaration@TemplateTypeDeclaration {typeMembers = firstMember : remaining}] ->
        Just
            (TypedAST tree {syntaxDeclarations = [declaration {typeMembers = setMemberSymbol (SymbolId 0) firstMember : remaining}]})
    _ -> Nothing

overloadedMembers :: Maybe [Declaration ResolvedName Type]
overloadedMembers = do
    members <- analyzeMembers chainSource
    finish <- memberNamed "Finish" members
    let SymbolId maximumValue = maximumSymbolInDeclarations members
        duplicate = setMemberSymbol (SymbolId (maximumValue + 1)) finish
    pure (insertAfter "Finish" duplicate members)

maximumSymbolInDeclarations :: [Declaration ResolvedName Type] -> SymbolId
maximumSymbolInDeclarations members =
    SymbolId (maximum (0 : map (symbolIdValue . resolvedSymbol . declarationName) members))

insertAfter ::
    String -> Declaration ResolvedName Type -> [Declaration ResolvedName Type] -> [Declaration ResolvedName Type]
insertAfter _ _ [] = []
insertAfter name addition (member : remaining)
    | memberName member == name = member : addition : remaining
    | otherwise = member : insertAfter name addition remaining

replaceMember ::
    String -> Declaration ResolvedName Type -> [Declaration ResolvedName Type] -> [Declaration ResolvedName Type]
replaceMember name replacement = map (\member -> if memberName member == name then replacement else member)

setMemberSymbol :: SymbolId -> Declaration ResolvedName annotation -> Declaration ResolvedName annotation
setMemberSymbol symbol declaration =
    declaration {declarationName = (declarationName declaration) {resolvedSymbol = symbol}}

memberName :: Declaration ResolvedName annotation -> String
memberName = identifierText . resolvedSpelling . declarationName

appendCall :: SymbolId -> Declaration ResolvedName Type -> Declaration ResolvedName Type
appendCall target declaration@FunctionDeclaration {declarationBody = Block statements} =
    declaration
        { declarationBody =
            Block
                ( statements
                    ++ [ ExpressionStatement
                            testSpan
                            ( CallExpression
                                testSpan
                                (NameExpression testSpan (ResolvedName target (Identifier "Normalize")) (FunctionType [] voidType))
                                []
                                voidType
                            )
                            True
                       ]
                )
        }
appendCall _ declaration = declaration

prependCallable :: SymbolId -> Declaration ResolvedName Type -> Declaration ResolvedName Type
prependCallable target declaration@FunctionDeclaration {declarationBody = Block statements} =
    let call =
            CallExpression
                testSpan
                (NameExpression testSpan (ResolvedName target (Identifier "Finish")) (FunctionType [] voidType))
                []
                voidType
        callable = CallableExpression testSpan False [] [] (CallableExpressionBody call) (FunctionType [] voidType)
     in declaration {declarationBody = Block (ExpressionStatement testSpan callable False : statements)}
prependCallable _ declaration = declaration

prependCapture :: SymbolId -> Declaration ResolvedName Type -> Declaration ResolvedName Type
prependCapture target declaration@FunctionDeclaration {declarationBody = Block statements} =
    let call =
            CallExpression
                testSpan
                (NameExpression testSpan (ResolvedName target (Identifier "Finish")) (FunctionType [] voidType))
                []
                voidType
        capture = Capture testSpan StrongCapture (resolved 8200 "captured") voidType (Just call)
        callable = CallableExpression testSpan True [capture] [] (CallableBlockBody (Block [])) (FunctionType [] voidType)
     in declaration {declarationBody = Block (ExpressionStatement testSpan callable False : statements)}
prependCapture _ declaration = declaration

simpleCallingMember :: Int -> String -> SymbolId -> Declaration ResolvedName Type
simpleCallingMember symbol name target =
    FunctionDeclaration
        testSpan
        (resolved symbol name)
        (FunctionType [] voidType)
        (ExplicitType (Identifier "void"))
        []
        ( Block
            [ ExpressionStatement
                testSpan
                ( CallExpression
                    testSpan
                    (NameExpression testSpan (ResolvedName target (Identifier "Finish")) (FunctionType [] voidType))
                    []
                    voidType
                )
                True
            , ReturnStatement testSpan Nothing
            ]
        )
        False
        PublicAccess
        Nothing

directTargets :: Declaration ResolvedName Type -> [SymbolId]
directTargets FunctionDeclaration {declarationBody = Block statements} = concatMap statementTargets statements
directTargets _ = []

statementTargets :: Statement ResolvedName Type -> [SymbolId]
statementTargets statement = case statement of
    BindingStatement _ _ _ _ _ value -> expressionTargets value
    AssignmentStatement _ _ _ value -> expressionTargets value
    ReturnStatement _ value -> maybe [] expressionTargets value
    IfStatement _ condition trueBlock falseBlock ->
        expressionTargets condition ++ blockTargets trueBlock ++ maybe [] blockTargets falseBlock
    WhileStatement _ condition body -> expressionTargets condition ++ blockTargets body
    DoWhileStatement _ body condition -> blockTargets body ++ expressionTargets condition
    ForStatement _ initializer condition updates body ->
        maybe [] statementTargets initializer
            ++ maybe [] expressionTargets condition
            ++ concatMap statementTargets updates
            ++ blockTargets body
    ForEachStatement _ _ _ _ _ source body -> expressionTargets source ++ blockTargets body
    IncrementStatement {} -> []
    CompoundAssignmentStatement _ _ _ _ value -> expressionTargets value
    DiscardStatement _ value -> expressionTargets value
    BreakStatement _ value -> maybe [] expressionTargets value
    ContinueStatement {} -> []
    GuardStatement _ condition block -> expressionTargets condition ++ blockTargets block
    BlockStatement _ block -> blockTargets block
    ExpressionStatement _ value _ -> expressionTargets value

blockTargets :: Block ResolvedName Type -> [SymbolId]
blockTargets (Block statements) = concatMap statementTargets statements

expressionTargets :: Expression ResolvedName Type -> [SymbolId]
expressionTargets expression = case expression of
    CallExpression _ (NameExpression _ name _) arguments _ -> resolvedSymbol name : concatMap expressionTargets arguments
    CallExpression _ callee arguments _ -> expressionTargets callee ++ concatMap expressionTargets arguments
    UnaryExpression _ _ value _ -> expressionTargets value
    ConditionalExpression _ condition whenTrue whenFalse _ -> concatMap expressionTargets [condition, whenTrue, whenFalse]
    CoalesceExpression _ left fallback _ -> expressionTargets left ++ expressionTargets fallback
    BinaryExpression _ _ left right _ -> expressionTargets left ++ expressionTargets right
    CallableExpression _ _ captures _ body _ ->
        concatMap (maybe [] expressionTargets . captureInitializer) captures
            ++ case body of
                CallableExpressionBody value -> expressionTargets value
                CallableBlockBody block -> blockTargets block
    BlockExpression _ block _ -> blockTargets block
    MatchExpression _ subjects arms _ -> concatMap expressionTargets (subjects ++ concatMap matchArmExpressions arms)
    _ -> []

selectedMembers :: TemplateSpecialization -> [Declaration ResolvedName Type]
selectedMembers specialization = case templateSpecializationDeclaration specialization of
    TypeDeclaration {typeMembers = members} -> members
    _ -> []

selectedNames :: TemplateSpecialization -> [String]
selectedNames = memberNames . selectedMembers

memberNamesFromCore :: CoreModule -> [String]
memberNamesFromCore = map (identifierText . resolvedSpelling . coreFunctionName) . coreModuleFunctions

onlySpecialization :: TemplateSpecializationPlan -> Maybe TemplateSpecialization
onlySpecialization planValue = case plannedTemplateSpecializations planValue of
    [specialization] -> Just specialization
    _ -> Nothing

requireOnly :: TemplateSpecializationPlan -> Either [TemplateSpecializationError] TemplateSpecialization
requireOnly planValue = maybe (Left []) Right (onlySpecialization planValue)

symbolsNamed :: [String] -> [Declaration ResolvedName Type] -> [SymbolId]
symbolsNamed names members =
    [ resolvedSymbol (declarationName member)
    | member <- members
    , memberName member `elem` names
    ]

onlySymbol :: TemplateMemberReachability -> SymbolId
onlySymbol result = case memberReachabilitySymbols result of
    [symbol] -> symbol
    _ -> SymbolId 0

reachabilityFixture :: Maybe ([Declaration ResolvedName Type], TemplateMemberReachability)
reachabilityFixture = do
    members <- analyzeMembers chainSource
    result <- rightValue (selectReachableMembersByName [Identifier "Entry"] members)
    pure (members, result)

hasIssue :: (TemplateMemberReachabilityIssue -> Bool) -> Either failure [TemplateMemberReachabilityIssue] -> Bool
hasIssue predicate result = case result of
    Right issues -> any predicate issues
    Left _ -> False

resolved :: Int -> String -> ResolvedName
resolved symbol name = ResolvedName (SymbolId symbol) (Identifier name)

testSpan :: SourceSpan
testSpan = SourceSpan "member-reachability-test.tala" (SourcePosition 1 1) (SourcePosition 1 2)

first :: (value -> Bool) -> [value] -> Maybe value
first _ [] = Nothing
first predicate (value : remaining)
    | predicate value = Just value
    | otherwise = first predicate remaining

rightValue :: Either failure value -> Maybe value
rightValue result = case result of
    Right value -> Just value
    Left _ -> Nothing
