-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Conditional compiler directives and regions.

The pass stands between the lexer and the parser. It reads the directive
lines of one source unit, chooses the branch of every @#if@ group that the
target selects, and hands the parser the tokens of the chosen branches
without the directive lines. It is not macro preprocessing: no token is
rewritten or substituted, and a directive stands only at a boundary between
declarations, members or statements, where removing a branch cannot leave a
fragment of an expression behind.

A condition is built from @Fact@, which holds when tests are compiled, the
predicates @os(...)@ and @family(...)@ of the target, @true@, @false@,
@not@, @&&@, @||@ and parentheses. Directive symbols, which @#define@ would
declare, are not implemented yet, and neither are the diagnostic directives;
both are refused by name.

The pass also decides where @#expect@ may stand. It is test code: the body
of a method with the @[Fact]@ attribute, or a branch that only a test build
selects, such as the body of @#if Fact@.
-}
module Progmasoft.Tala.Directives
    ( OperatingSystem (..)
    , DirectiveEnvironment (..)
    , hostDirectiveEnvironment
    , operatingSystemNamed
    , operatingSystemName
    , resolveDirectives
    ) where

import Data.List (intercalate)
import Progmasoft.Tala.AST (SourcePosition (..), SourceSpan (..))
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Parser.Token
import System.Info qualified

-- | The operating systems @os(...)@ names. Any other target matches none.
data OperatingSystem = Windows | Linux | MacOS | FreeBSD | OpenBSD | NetBSD | OtherSystem
    deriving stock (Bounded, Enum, Eq, Ord, Read, Show)

-- | What the conditions of a compilation are evaluated against.
data DirectiveEnvironment = DirectiveEnvironment
    { directiveSystem :: OperatingSystem
    -- ^ The operating system of the target.
    , directiveTesting :: Bool
    -- ^ Whether tests are compiled; @Fact@ holds exactly then.
    }
    deriving stock (Eq, Ord, Read, Show)

-- | A compilation for the machine the compiler runs on, without tests.
hostDirectiveEnvironment :: DirectiveEnvironment
hostDirectiveEnvironment = DirectiveEnvironment hostSystem False
    where
        hostSystem = case System.Info.os of
            "mingw32" -> Windows
            "linux" -> Linux
            "darwin" -> MacOS
            "freebsd" -> FreeBSD
            "openbsd" -> OpenBSD
            "netbsd" -> NetBSD
            _ -> OtherSystem

-- | The spelling @os(...)@ takes for a system, and @other@ for the rest.
operatingSystemName :: OperatingSystem -> String
operatingSystemName system = case system of
    Windows -> "Windows"
    Linux -> "Linux"
    MacOS -> "macOS"
    FreeBSD -> "FreeBSD"
    OpenBSD -> "OpenBSD"
    NetBSD -> "NetBSD"
    OtherSystem -> "other"

-- | The system a spelling of 'operatingSystemName' names.
operatingSystemNamed :: String -> Maybe OperatingSystem
operatingSystemNamed name = lookup name [(operatingSystemName system, system) | system <- [minBound .. maxBound]]

familyMembers :: String -> Maybe [OperatingSystem]
familyMembers name = case name of
    "Windows" -> Just [Windows]
    "Unix" -> Just [Linux, MacOS, FreeBSD, OpenBSD, NetBSD]
    "BSD" -> Just [FreeBSD, OpenBSD, NetBSD]
    _ -> Nothing

-- | A condition after it has been read.
data Condition
    = Constant Bool
    | Testing
    | System OperatingSystem
    | Family [OperatingSystem]
    | Not Condition
    | Both Condition Condition
    | Either Condition Condition

holds :: DirectiveEnvironment -> Condition -> Bool
holds environment condition = case condition of
    Constant value -> value
    Testing -> directiveTesting environment
    System system -> directiveSystem environment == system
    Family members -> directiveSystem environment `elem` members
    Not inner -> not (holds environment inner)
    Both left right -> holds environment left && holds environment right
    Either left right -> holds environment left || holds environment right

{- | One open @#if@ group or @#region@.

A group is followed under two environments at once, the one compiled for
and the same one with @Fact@ flipped, so that a branch is known to be test
code when the test build selects it and the other build does not.
-}
data Frame = GroupFrame Group | RegionFrame SourceSpan String

-- | An open @#if@ group and its current branch.
data Group = Group
    { groupOpening :: SourceSpan
    , frameChosen :: (Bool, Bool)
    {- ^ Whether the current branch is chosen under the testing and the
    other environment.
    -}
    , frameTest :: Bool
    -- ^ Whether the current branch is test code.
    , frameTaken :: (Bool, Bool)
    {- ^ Whether an earlier branch was chosen under the testing and the
    other environment.
    -}
    , frameOuter :: (Bool, Bool)
    -- ^ Whether the enclosing code is chosen under the two.
    , frameOuterTest :: Bool
    , frameSeenElse :: Bool
    , frameBrackets :: [String]
    -- ^ The brackets open when the group began.
    }

frameOpening :: Frame -> SourceSpan
frameOpening frame = case frame of
    GroupFrame group -> groupOpening group
    RegionFrame opening _ -> opening

data State = State
    { stateFrames :: [Frame]
    , stateBrackets :: [String]
    -- ^ Brackets open at this point, innermost first, in every branch.
    , statePrevious :: Maybe Token
    -- ^ The last token that is not part of a directive line.
    , stateFact :: FactState
    , stateOutput :: [Token]
    }

-- | Where the pass stands with respect to the body of a @[Fact]@ method.
data FactState
    = OutsideFact
    | -- | After a @[Fact]@ attribute, before the body opens.
      FactPending
    | -- | Inside a body; the number is the bracket depth outside it.
      InsideFact Int

{- | Choose the branches the environment selects, and drop the directive
lines. The result keeps the end-of-file token.
-}
resolveDirectives :: DirectiveEnvironment -> [Token] -> Either [Diagnostic] [Token]
resolveDirectives environment = run (State [] [] Nothing OutsideFact [])
    where
        run state tokens = case tokens of
            [] -> finish state
            token : rest
                | tokenKind token == EndOfFileToken -> case stateFrames state of
                    frame : _ -> Left [problem (frameOpening frame) "TAP0051" (unclosed frame)]
                    [] -> finish (state {stateOutput = token : stateOutput state}) >>= \done -> Right (done ++ rest)
                | tokenKind token == DirectiveToken && tokenText token /= "#expect" -> do
                    let (line, after) = span (onLine token) rest
                    checkFirstOnLine state token
                    next <- directive state token line
                    run next after
                | otherwise -> step state token >>= (`run` rest)
        finish state = Right (reverse (stateOutput state))

        onLine token next =
            tokenKind next /= EndOfFileToken
                && sourceLine (sourceStart (tokenSpan next)) == sourceLine (sourceStart (tokenSpan token))

        checkFirstOnLine state token = case statePrevious state of
            Just previous
                | sourceLine (sourceEnd (tokenSpan previous)) == sourceLine (sourceStart (tokenSpan token)) ->
                    Left [problem (tokenSpan token) "TAP0042" (tokenText token ++ " must begin its line")]
            _ -> Right ()

        -- The innermost group decides; a region changes nothing.
        innermost frames = case frames of
            GroupFrame group : _ -> Just group
            RegionFrame {} : more -> innermost more
            [] -> Nothing
        chosen state = maybe (True, True) frameChosen (innermost (stateFrames state))
        active state =
            let (testing, other) = chosen state
             in if directiveTesting environment then testing else other
        testCode state = maybe False frameTest (innermost (stateFrames state))

        -- An ordinary token: kept when its branch is compiled, and counted
        -- for the brackets in every branch.
        step state token = do
            brackets <- bracket state token
            let isActive = active state
            fact <- if isActive then factStep state token else Right (stateFact state)
            if tokenKind token == DirectiveToken && isActive && not (testCode state) && not (insideFact fact)
                then
                    Left
                        [ problem
                            (tokenSpan token)
                            "TAP0044"
                            "#expect belongs to test code: write it in a [Fact] method or in a branch of #if Fact"
                        ]
                else
                    Right
                        state
                            { stateBrackets = brackets
                            , statePrevious = Just token
                            , stateFact = fact
                            , stateOutput = if isActive then token : stateOutput state else stateOutput state
                            }

        insideFact fact = case fact of
            InsideFact _ -> True
            _ -> False

        bracket state token
            | tokenKind token /= SymbolToken = Right (stateBrackets state)
            | tokenText token `elem` ["(", "[", "{"] = Right (tokenText token : stateBrackets state)
            | tokenText token `elem` [")", "]", "}"] = case stateBrackets state of
                opened : outer
                    | length (stateBrackets state) > groupFloor state -> Right outer
                    | otherwise -> Left [problem (tokenSpan token) "TAP0043" (closes opened token)]
                [] -> Right []
            | otherwise = Right (stateBrackets state)
        closes opened token =
            "this " ++ show (tokenText token) ++ " closes the " ++ show opened ++ " that stands before the directive group it is in"
        groupFloor state = case [frameBrackets group | GroupFrame group <- stateFrames state] of
            floorBrackets : _ -> length floorBrackets
            [] -> 0

        -- The body of a [Fact] method: the attribute is followed by the
        -- signature, and the first brace after it opens the body.
        factStep state token = case stateFact state of
            InsideFact depth
                | tokenText token == "}" && tokenKind token == SymbolToken && length (stateBrackets state) == depth + 1 ->
                    Right OutsideFact
                | otherwise -> Right (InsideFact depth)
            FactPending
                | tokenText token == "{" && tokenKind token == SymbolToken -> Right (InsideFact (length (stateBrackets state)))
                | tokenText token == ";" && tokenKind token == SymbolToken -> Right OutsideFact
                | otherwise -> Right FactPending
            OutsideFact
                | tokenKind token == IdentifierToken
                , tokenText token == "Fact"
                , Just previous <- statePrevious state
                , tokenKind previous == SymbolToken
                , tokenText previous == "[" ->
                    Right FactPending
                | otherwise -> Right OutsideFact

        directive state token line = case tokenText token of
            "#if" -> do
                checkBoundary state token
                condition <- readCondition token line
                Right (branch state token condition Nothing)
            "#elseif" -> do
                group <- currentGroup state token
                if frameSeenElse group
                    then Left [problem (tokenSpan token) "TAP0049" "#elseif cannot follow #else in the same group"]
                    else Right ()
                checkBoundary state token
                checkBalanced state group token
                condition <- readCondition token line
                Right (branch (popFrame state group) token condition (Just group))
            "#else" -> do
                group <- currentGroup state token
                if frameSeenElse group
                    then Left [problem (tokenSpan token) "TAP0049" "a group has at most one #else"]
                    else Right ()
                noOperands token line
                checkBoundary state token
                checkBalanced state group token
                let next = branch (popFrame state group) token (Constant True) (Just group)
                Right (markElse next)
            "#endif" -> do
                group <- currentGroup state token
                noOperands token line
                checkBoundary state token
                checkBalanced state group token
                Right (popFrame state group)
            "#region" -> Right state {stateFrames = RegionFrame (tokenSpan token) (unwords (map tokenText line)) : stateFrames state}
            "#endregion" -> case stateFrames state of
                RegionFrame _ name : outer
                    | null line || unwords (map tokenText line) == name -> Right state {stateFrames = outer}
                    | otherwise ->
                        Left
                            [ problem
                                (tokenSpan token)
                                "TAP0052"
                                ("#endregion names " ++ show (unwords (map tokenText line)) ++ ", but the open region is " ++ show name)
                            ]
                GroupFrame _ : _ -> Left [problem (tokenSpan token) "TAP0050" "#endregion closes a region, but the innermost open directive is #if"]
                [] -> Left [problem (tokenSpan token) "TAP0050" "#endregion has no #region to close"]
            name
                | name `elem` ["#define", "#setdef", "#undef"] ->
                    Left [problem (tokenSpan token) "TAP0053" (name ++ " and directive symbols are not implemented yet")]
                | name `elem` ["#error", "#warn", "#info", "#message"] ->
                    Left [problem (tokenSpan token) "TAP0053" ("the diagnostic directive " ++ name ++ " is not implemented yet")]
                | otherwise -> Left [problem (tokenSpan token) "TAP0054" ("unknown directive " ++ name)]

        markElse state = case stateFrames state of
            GroupFrame group : outer -> state {stateFrames = GroupFrame group {frameSeenElse = True} : outer}
            _ -> state

        currentGroup state token = case stateFrames state of
            GroupFrame group : _ -> Right group
            RegionFrame {} : _ ->
                Left
                    [ problem
                        (tokenSpan token)
                        "TAP0050"
                        (tokenText token ++ " cannot stand inside a #region that the branch opened; close the region first")
                    ]
            [] -> Left [problem (tokenSpan token) "TAP0050" (tokenText token ++ " has no #if to belong to")]

        popFrame state group = state {stateFrames = drop 1 (stateFrames state), stateBrackets = frameBrackets group}

        -- Open the next branch of a group: the first that holds is chosen,
        -- under the environment compiled for and under the other one.
        -- The state passed for a later branch has its group popped, so the
        -- enclosing code is the same for every branch of one group.
        branch state token condition previous =
            let (outerTesting, outerOther) = maybe (chosen state) frameOuter previous
                outerTest = maybe (testCode state) frameOuterTest previous
                (takenTesting, takenOther) = maybe (False, False) frameTaken previous
                chosenTesting = outerTesting && not takenTesting && holds environment {directiveTesting = True} condition
                chosenOther = outerOther && not takenOther && holds environment {directiveTesting = False} condition
                frame =
                    Group
                        { groupOpening = maybe (tokenSpan token) groupOpening previous
                        , frameChosen = (chosenTesting, chosenOther)
                        , frameTest = outerTest || chosenTesting && not chosenOther
                        , frameTaken = (takenTesting || chosenTesting, takenOther || chosenOther)
                        , frameOuter = (outerTesting, outerOther)
                        , frameOuterTest = outerTest
                        , frameSeenElse = maybe False frameSeenElse previous
                        , frameBrackets = stateBrackets state
                        }
             in state {stateFrames = GroupFrame frame : stateFrames state}

        -- A directive stands where a declaration, a member or a statement
        -- may begin: outside parentheses and brackets, after a semicolon or
        -- a brace, or at the start of the unit.
        checkBoundary state token = do
            case stateBrackets state of
                opened : _
                    | opened /= "{" ->
                        Left
                            [ problem
                                (tokenSpan token)
                                "TAP0043"
                                (tokenText token ++ " cannot stand inside " ++ show opened ++ "; a directive may not split an expression")
                            ]
                _ -> Right ()
            case statePrevious state of
                Just previous
                    | not (tokenKind previous == SymbolToken && tokenText previous `elem` [";", "{", "}"]) ->
                        Left
                            [ problem
                                (tokenSpan token)
                                "TAP0043"
                                ( tokenText token
                                    ++ " follows "
                                    ++ show (tokenText previous)
                                    ++ "; a directive stands between declarations, members or statements and may not split one"
                                )
                            ]
                _ -> Right ()

        checkBalanced state group token =
            case stateBrackets state of
                opened : _
                    | length (stateBrackets state) /= length (frameBrackets group) ->
                        Left
                            [ problem
                                (tokenSpan token)
                                "TAP0043"
                                ("the branch before " ++ tokenText token ++ " leaves " ++ show opened ++ " open; every branch closes what it opens")
                            ]
                _ -> Right ()

        noOperands token line = case line of
            [] -> Right ()
            extra : _ -> Left [problem (tokenSpan extra) "TAP0048" (tokenText token ++ " takes no condition")]

        unclosed frame = case frame of
            GroupFrame _ -> "#if has no #endif"
            RegionFrame _ name -> "#region " ++ name ++ " has no #endregion"

-- | Read the condition of @#if@ or @#elseif@ from the rest of its line.
readCondition :: Token -> [Token] -> Either [Diagnostic] Condition
readCondition directiveToken line = case line of
    [] -> Left [problem (tokenSpan directiveToken) "TAP0045" (tokenText directiveToken ++ " needs a condition")]
    _ -> do
        (condition, rest) <- disjunction line
        case rest of
            [] -> Right condition
            extra : _ -> Left [problem (tokenSpan extra) "TAP0045" ("unexpected " ++ show (tokenText extra) ++ " in the condition")]
    where
        disjunction tokens = do
            (left, rest) <- conjunction tokens
            case rest of
                operator : more | isSymbol "||" operator -> do
                    (right, after) <- disjunction more
                    Right (Either left right, after)
                _ -> Right (left, rest)
        conjunction tokens = do
            (left, rest) <- unary tokens
            case rest of
                operator : more | isSymbol "&&" operator -> do
                    (right, after) <- conjunction more
                    Right (Both left right, after)
                _ -> Right (left, rest)
        unary tokens = case tokens of
            token : rest | tokenKind token == KeywordToken && tokenText token == "not" -> do
                (inner, after) <- unary rest
                Right (Not inner, after)
            _ -> primary tokens
        primary tokens = case tokens of
            token : rest
                | isSymbol "(" token -> do
                    (inner, after) <- disjunction rest
                    case after of
                        close : more | isSymbol ")" close -> Right (inner, more)
                        _ -> Left [problem (tokenSpan token) "TAP0045" "this parenthesis of the condition is not closed"]
                | tokenKind token == KeywordToken && tokenText token `elem` ["true", "false"] ->
                    Right (Constant (tokenText token == "true"), rest)
                | tokenKind token == IdentifierToken && tokenText token == "Fact" -> Right (Testing, rest)
                | tokenKind token == IdentifierToken && tokenText token `elem` ["os", "family"] -> predicate token rest
                | tokenKind token == IdentifierToken ->
                    Left
                        [ problem
                            (tokenSpan token)
                            "TAP0047"
                            ("unknown directive symbol " ++ tokenText token ++ "; #define and directive symbols are not implemented yet")
                        ]
                | otherwise ->
                    Left [problem (tokenSpan token) "TAP0045" ("unexpected " ++ show (tokenText token) ++ " in the condition")]
            [] -> Left [problem (tokenSpan directiveToken) "TAP0045" "the condition ends too early"]
        predicate token rest = case rest of
            open : name : close : after
                | isSymbol "(" open && isSymbol ")" close && tokenKind name `elem` [IdentifierToken, KeywordToken] ->
                    case (tokenText token, tokenText name) of
                        ("os", spelling) | Just system <- operatingSystemNamed spelling, system /= OtherSystem -> Right (System system, after)
                        ("family", spelling) | Just members <- familyMembers spelling -> Right (Family members, after)
                        (kind, spelling) ->
                            Left
                                [ problem
                                    (tokenSpan name)
                                    "TAP0046"
                                    ( kind
                                        ++ "("
                                        ++ spelling
                                        ++ ") names no known "
                                        ++ (if kind == "os" then "operating system" else "family")
                                        ++ "; known: "
                                        ++ known kind
                                    )
                                ]
            _ ->
                Left
                    [ problem
                        (tokenSpan token)
                        "TAP0045"
                        (tokenText token ++ " takes one name in parentheses, as " ++ tokenText token ++ "(Windows)")
                    ]
        known kind
            | kind == "os" = intercalate ", " [operatingSystemName system | system <- [minBound .. maxBound], system /= OtherSystem]
            | otherwise = "Windows, Unix, BSD"

isSymbol :: String -> Token -> Bool
isSymbol text token = tokenKind token == SymbolToken && tokenText token == text

problem :: SourceSpan -> String -> String -> Diagnostic
problem spanValue code message = Diagnostic ParserStage Error code (Just spanValue) message
