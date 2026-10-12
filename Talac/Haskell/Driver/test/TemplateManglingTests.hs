-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module TemplateManglingTests (templateManglingTests) where

import Data.Char (isAscii)
import Data.List (isInfixOf, isPrefixOf)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Template.Mangling

templateManglingTests :: [(String, Bool)]
templateManglingTests =
    [ ("type mangling uses the private versioned prefix", hasPrivatePrefix)
    , ("type mangling is deterministic", typeManglingIsDeterministic)
    , ("type mangling emits only portable ASCII", typeManglingIsAscii)
    , ("type mangling emits linker-safe characters", typeManglingIsLinkerSafe)
    , ("qualified names retain structural boundaries", qualifiedNamesHaveBoundaries)
    , ("qualified-name joins cannot collide", qualifiedNameJoinsCannotCollide)
    , ("type arguments retain structural boundaries", typeArgumentsHaveBoundaries)
    , ("type and value arguments cannot collide", typeAndValueArgumentsDiffer)
    , ("template argument order affects the symbol", argumentOrderMatters)
    , ("positive and negative integers cannot collide", integerSignMatters)
    , ("boolean template values are distinct", booleanValuesDiffer)
    , ("character and integer values cannot collide", characterAndIntegerDiffer)
    , ("Unicode identifiers become portable ASCII", unicodeNamesBecomeAscii)
    , ("Unicode scalar spellings remain distinct", unicodeNamesRemainDistinct)
    , ("function parameter order affects the symbol", functionParameterOrderMatters)
    , ("function result type affects the symbol", functionResultMatters)
    , ("function arity affects the symbol", functionArityMatters)
    , ("member names affect the symbol", memberNameMatters)
    , ("member signatures affect the symbol", memberSignatureMatters)
    , ("member staticness affects the symbol", memberStaticnessMatters)
    , ("member access affects the symbol", memberAccessMatters)
    , ("member mangling retains the source SymbolId", memberRetainsSymbol)
    , ("member mangling retains source spelling", memberRetainsSpelling)
    , ("nested types can be mangled as members", nestedTypeCanBeMangled)
    , ("member batches preserve declaration order", memberOrderIsStable)
    , ("member batches reject template declarations", memberBatchRejectsOpenTemplate)
    , ("member batches require an ordinary owner", memberBatchRejectsFunctionOwner)
    , ("open type variables are rejected", openTypesAreRejected)
    , ("open value parameters are rejected", openValuesAreRejected)
    , ("ErrorType is rejected", errorTypesAreRejected)
    , ("empty qualified names are rejected", emptyQualifiedNamesAreRejected)
    , ("empty identifiers are rejected", emptyIdentifiersAreRejected)
    , ("negative depth limits are rejected", negativeDepthLimitIsRejected)
    , ("zero length limits are rejected", zeroLengthLimitIsRejected)
    , ("zero name-part limits are rejected", zeroNamePartLimitIsRejected)
    , ("negative argument limits are rejected", negativeArgumentLimitIsRejected)
    , ("type-depth limits are enforced", typeDepthLimitIsEnforced)
    , ("qualified-name part limits are enforced", namePartLimitIsEnforced)
    , ("template argument limits are enforced", argumentLimitIsEnforced)
    , ("function parameter limits are enforced", functionLimitIsEnforced)
    , ("symbol length limits are enforced", symbolLengthLimitIsEnforced)
    , ("valid-symbol predicate rejects a wrong prefix", wrongPrefixIsRejected)
    , ("valid-symbol predicate rejects punctuation", punctuationIsRejected)
    , ("error rendering identifies open symbols", openErrorRenderingIsUseful)
    , ("error rendering identifies length limits", lengthErrorRenderingIsUseful)
    , ("default limits accept deeply nested practical types", defaultLimitsArePractical)
    ]

qualified :: [String] -> QualifiedName
qualified = QualifiedName . map Identifier

resolved :: Int -> String -> ResolvedName
resolved unique spelling = ResolvedName (SymbolId unique) (Identifier spelling)

typeArgument :: Type -> TemplateArgument
typeArgument = TypeTemplateArgument

valueArgument :: Integer -> TemplateArgument
valueArgument = ValueTemplateArgument . IntegerTemplateValue

templateType :: [String] -> [TemplateArgument] -> Type
templateType names = NamedType (qualified names)

boxOf :: Type -> Type
boxOf value = templateType ["Box"] [typeArgument value]

pairOf :: Type -> Type -> Type
pairOf left right = templateType ["Pair"] [typeArgument left, typeArgument right]

spanValue :: SourceSpan
spanValue = SourceSpan "mangling-test.tala" (SourcePosition 1 1) (SourcePosition 1 2)

functionMember :: Int -> String -> Type -> Bool -> Access -> Declaration ResolvedName Type
functionMember unique name signature isStatic access =
    FunctionDeclaration
        spanValue
        (resolved unique name)
        signature
        (ExplicitType (Identifier "void"))
        []
        (Block [])
        isStatic
        access

nestedMember :: Int -> String -> Type -> Declaration ResolvedName Type
nestedMember unique name annotation = TypeDeclaration spanValue (resolved unique name) annotation []

ownerDeclaration :: [Declaration ResolvedName Type] -> Declaration ResolvedName Type
ownerDeclaration members = TypeDeclaration spanValue (resolved 1 "Box") (boxOf intType) members

templateMember :: Declaration ResolvedName Type
templateMember =
    TemplateTypeDeclaration
        spanValue
        (resolved 90 "Nested")
        (templateType ["Nested"] [])
        []
        []

mangledText :: Type -> Maybe String
mangledText value = case mangleTemplateType defaultTemplateMangleLimits value of
    Right mangled -> Just (mangledTemplateTypeText mangled)
    Left _ -> Nothing

memberText :: Declaration ResolvedName Type -> Maybe String
memberText member = case mangleTemplateMember defaultTemplateMangleLimits (boxOf intType) member of
    Right mangled -> Just (mangledMemberText mangled)
    Left _ -> Nothing

distinctTypes :: Type -> Type -> Bool
distinctTypes left right = case (mangledText left, mangledText right) of
    (Just leftText, Just rightText) -> leftText /= rightText
    _ -> False

distinctMembers :: Declaration ResolvedName Type -> Declaration ResolvedName Type -> Bool
distinctMembers left right = case (memberText left, memberText right) of
    (Just leftText, Just rightText) -> leftText /= rightText
    _ -> False

hasPrivatePrefix :: Bool
hasPrivatePrefix = maybe False ("_TAT1_T" `isPrefixOf`) (mangledText (boxOf intType))

typeManglingIsDeterministic :: Bool
typeManglingIsDeterministic =
    let value = pairOf (boxOf stringType) (templateType ["Buffer"] [valueArgument 64])
     in mangleTemplateType defaultTemplateMangleLimits value
            == mangleTemplateType defaultTemplateMangleLimits value

typeManglingIsAscii :: Bool
typeManglingIsAscii = maybe False (all isAscii) (mangledText (templateType ["Dünya", "Kutu"] [typeArgument stringType]))

typeManglingIsLinkerSafe :: Bool
typeManglingIsLinkerSafe = maybe False validMangledTemplateSymbol (mangledText (pairOf intType stringType))

qualifiedNamesHaveBoundaries :: Bool
qualifiedNamesHaveBoundaries = distinctTypes (templateType ["AB", "C"] []) (templateType ["A", "BC"] [])

qualifiedNameJoinsCannotCollide :: Bool
qualifiedNameJoinsCannotCollide = distinctTypes (templateType ["A", "B", "C"] []) (templateType ["A", "BC"] [])

typeArgumentsHaveBoundaries :: Bool
typeArgumentsHaveBoundaries =
    distinctTypes
        (templateType ["Owner"] [typeArgument (templateType ["AB"] []), typeArgument (templateType ["C"] [])])
        (templateType ["Owner"] [typeArgument (templateType ["A"] []), typeArgument (templateType ["BC"] [])])

typeAndValueArgumentsDiffer :: Bool
typeAndValueArgumentsDiffer =
    distinctTypes
        (templateType ["Owner"] [typeArgument (templateType ["1"] [])])
        (templateType ["Owner"] [valueArgument 1])

argumentOrderMatters :: Bool
argumentOrderMatters = distinctTypes (pairOf intType stringType) (pairOf stringType intType)

integerSignMatters :: Bool
integerSignMatters =
    distinctTypes
        (templateType ["Buffer"] [valueArgument 8])
        (templateType ["Buffer"] [valueArgument (-8)])

booleanValuesDiffer :: Bool
booleanValuesDiffer =
    distinctTypes
        (templateType ["Feature"] [ValueTemplateArgument (BooleanTemplateValue True)])
        (templateType ["Feature"] [ValueTemplateArgument (BooleanTemplateValue False)])

characterAndIntegerDiffer :: Bool
characterAndIntegerDiffer =
    distinctTypes
        (templateType ["Token"] [ValueTemplateArgument (CharacterTemplateValue 65)])
        (templateType ["Token"] [valueArgument 65])

unicodeNamesBecomeAscii :: Bool
unicodeNamesBecomeAscii = case mangledText (templateType ["İşlem"] []) of
    Just value -> all isAscii value && validMangledTemplateSymbol value
    Nothing -> False

unicodeNamesRemainDistinct :: Bool
unicodeNamesRemainDistinct = distinctTypes (templateType ["I"] []) (templateType ["İ"] [])

functionParameterOrderMatters :: Bool
functionParameterOrderMatters =
    distinctTypes (FunctionType [intType, stringType] voidType) (FunctionType [stringType, intType] voidType)

functionResultMatters :: Bool
functionResultMatters = distinctTypes (FunctionType [intType] stringType) (FunctionType [intType] boolType)

functionArityMatters :: Bool
functionArityMatters = distinctTypes (FunctionType [intType] voidType) (FunctionType [intType, intType] voidType)

memberNameMatters :: Bool
memberNameMatters =
    distinctMembers
        (functionMember 10 "Read" (FunctionType [] intType) False PublicAccess)
        (functionMember 10 "Write" (FunctionType [] intType) False PublicAccess)

memberSignatureMatters :: Bool
memberSignatureMatters =
    distinctMembers
        (functionMember 10 "Read" (FunctionType [intType] intType) False PublicAccess)
        (functionMember 10 "Read" (FunctionType [stringType] intType) False PublicAccess)

memberStaticnessMatters :: Bool
memberStaticnessMatters =
    distinctMembers
        (functionMember 10 "Read" (FunctionType [] intType) False PublicAccess)
        (functionMember 10 "Read" (FunctionType [] intType) True PublicAccess)

memberAccessMatters :: Bool
memberAccessMatters =
    and
        [ distinctMembers publicMember privateMember
        , distinctMembers publicMember internalMember
        , distinctMembers publicMember protectedMember
        , distinctMembers publicMember defaultMember
        ]
    where
        make access = functionMember 10 "Read" (FunctionType [] intType) False access
        publicMember = make PublicAccess
        privateMember = make PrivateAccess
        internalMember = make InternalAccess
        protectedMember = make ProtectedAccess
        defaultMember = make DefaultAccess

memberRetainsSymbol :: Bool
memberRetainsSymbol = case mangleTemplateMember defaultTemplateMangleLimits (boxOf intType) member of
    Right mangled -> mangledMemberSourceSymbol mangled == SymbolId 42
    Left _ -> False
    where
        member = functionMember 42 "Read" (FunctionType [] intType) False PublicAccess

memberRetainsSpelling :: Bool
memberRetainsSpelling = case mangleTemplateMember defaultTemplateMangleLimits (boxOf intType) member of
    Right mangled -> mangledMemberSourceName mangled == Identifier "Read"
    Left _ -> False
    where
        member = functionMember 42 "Read" (FunctionType [] intType) False PublicAccess

nestedTypeCanBeMangled :: Bool
nestedTypeCanBeMangled = case memberText (nestedMember 12 "Iterator" (templateType ["Box", "Iterator"] [])) of
    Just value -> "_N" `isInfixOf` value && validMangledTemplateSymbol value
    Nothing -> False

memberOrderIsStable :: Bool
memberOrderIsStable = case mangleTemplateMembers defaultTemplateMangleLimits (boxOf intType) (ownerDeclaration members) of
    Right mangled -> map mangledMemberSourceName mangled == map (Identifier . fst) names
    Left _ -> False
    where
        names = [("First", 10), ("Second", 11), ("Third", 12)]
        members = [functionMember unique name (FunctionType [] voidType) False PublicAccess | (name, unique) <- names]

memberBatchRejectsOpenTemplate :: Bool
memberBatchRejectsOpenTemplate = case mangleTemplateMembers defaultTemplateMangleLimits (boxOf intType) (ownerDeclaration [templateMember]) of
    Left [ExpectedMangleableMemberDeclaration] -> True
    _ -> False

memberBatchRejectsFunctionOwner :: Bool
memberBatchRejectsFunctionOwner = case mangleTemplateMembers defaultTemplateMangleLimits (boxOf intType) member of
    Left [ExpectedMangleableMemberDeclaration] -> True
    _ -> False
    where
        member = functionMember 10 "Read" (FunctionType [] intType) False PublicAccess

openTypesAreRejected :: Bool
openTypesAreRejected = case mangleTemplateType defaultTemplateMangleLimits (TypeVariable (resolved 7 "T")) of
    Left (OpenTypeCannotBeMangled name) -> resolvedSymbol name == SymbolId 7
    _ -> False

openValuesAreRejected :: Bool
openValuesAreRejected = case mangleTemplateType defaultTemplateMangleLimits value of
    Left (OpenTypeCannotBeMangled name) -> resolvedSpelling name == Identifier "N"
    _ -> False
    where
        value = templateType ["Buffer"] [ValueTemplateArgument (TemplateValueParameter (resolved 8 "N"))]

errorTypesAreRejected :: Bool
errorTypesAreRejected = mangleTemplateType defaultTemplateMangleLimits ErrorType == Left ErrorTypeCannotBeMangled

emptyQualifiedNamesAreRejected :: Bool
emptyQualifiedNamesAreRejected =
    mangleTemplateType defaultTemplateMangleLimits (NamedType (QualifiedName []) [])
        == Left EmptyQualifiedNameCannotBeMangled

emptyIdentifiersAreRejected :: Bool
emptyIdentifiersAreRejected =
    mangleTemplateType defaultTemplateMangleLimits (templateType [""] [])
        == Left EmptyIdentifierCannotBeMangled

negativeDepthLimitIsRejected :: Bool
negativeDepthLimitIsRejected = invalidLimits (defaultTemplateMangleLimits {maximumMangledTypeDepth = -1})

zeroLengthLimitIsRejected :: Bool
zeroLengthLimitIsRejected = invalidLimits (defaultTemplateMangleLimits {maximumMangledSymbolLength = 0})

zeroNamePartLimitIsRejected :: Bool
zeroNamePartLimitIsRejected = invalidLimits (defaultTemplateMangleLimits {maximumMangledNameParts = 0})

negativeArgumentLimitIsRejected :: Bool
negativeArgumentLimitIsRejected = invalidLimits (defaultTemplateMangleLimits {maximumMangledArguments = -1})

invalidLimits :: TemplateMangleLimits -> Bool
invalidLimits limits = case mangleTemplateType limits intType of
    Left (InvalidTemplateMangleLimits _) -> True
    _ -> False

typeDepthLimitIsEnforced :: Bool
typeDepthLimitIsEnforced = case mangleTemplateType limits (boxOf (boxOf intType)) of
    Left (MangledTypeDepthExceeded 0) -> True
    _ -> False
    where
        limits = defaultTemplateMangleLimits {maximumMangledTypeDepth = 0}

namePartLimitIsEnforced :: Bool
namePartLimitIsEnforced = case mangleTemplateType limits (templateType ["A", "B"] []) of
    Left (MangledNamePartLimitExceeded 1 2) -> True
    _ -> False
    where
        limits = defaultTemplateMangleLimits {maximumMangledNameParts = 1}

argumentLimitIsEnforced :: Bool
argumentLimitIsEnforced = case mangleTemplateType limits (pairOf intType stringType) of
    Left (MangledArgumentLimitExceeded 1 2) -> True
    _ -> False
    where
        limits = defaultTemplateMangleLimits {maximumMangledArguments = 1}

functionLimitIsEnforced :: Bool
functionLimitIsEnforced = case mangleTemplateType limits (FunctionType [intType, stringType] voidType) of
    Left (MangledArgumentLimitExceeded 1 2) -> True
    _ -> False
    where
        limits = defaultTemplateMangleLimits {maximumMangledArguments = 1}

symbolLengthLimitIsEnforced :: Bool
symbolLengthLimitIsEnforced = case mangleTemplateType limits (boxOf intType) of
    Left (MangledSymbolLengthExceeded 8 actual) -> actual > 8
    _ -> False
    where
        limits = defaultTemplateMangleLimits {maximumMangledSymbolLength = 8}

wrongPrefixIsRejected :: Bool
wrongPrefixIsRejected = not (validMangledTemplateSymbol "Box_1")

punctuationIsRejected :: Bool
punctuationIsRejected = not (validMangledTemplateSymbol "_TAT1_Box<int>")

openErrorRenderingIsUseful :: Bool
openErrorRenderingIsUseful = "open template symbol" `isInfixOf` renderTemplateMangleError (OpenTypeCannotBeMangled (resolved 9 "T"))

lengthErrorRenderingIsUseful :: Bool
lengthErrorRenderingIsUseful =
    "limit 10" `isInfixOf` renderTemplateMangleError (MangledSymbolLengthExceeded 10 11)

defaultLimitsArePractical :: Bool
defaultLimitsArePractical = case mangleTemplateType defaultTemplateMangleLimits deeplyNested of
    Right mangled -> validMangledTemplateSymbol (mangledTemplateTypeText mangled)
    Left _ -> False
    where
        deeplyNested = foldr (\_ nested -> boxOf nested) intType [1 .. 64 :: Int]
