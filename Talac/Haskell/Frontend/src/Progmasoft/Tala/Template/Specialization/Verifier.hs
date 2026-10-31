-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- |
Invariant verification for declaration-level specialization plans.

The planner is pure, but its output crosses into Core and eventually native
linkage. Verification keeps malformed hand-built plans and future planner
regressions from becoming backend assumptions or duplicate linker symbols.
-}
module Progmasoft.Tala.Template.Specialization.Verifier
    ( TemplatePlanIssue (..)
    , verifyTemplateSpecializationPlan
    , templateSpecializationPlanIssues
    , renderTemplatePlanIssue
    ) where

import Data.List (intercalate, sort)
import Progmasoft.Tala.AST
import Progmasoft.Tala.Template.Mangling
import Progmasoft.Tala.Template.Specialization

-- | Independently checkable inconsistency in a specialization plan.
data TemplatePlanIssue
    = InvalidPlanSpecializationId TemplateSpecializationId
    | DuplicatePlanSpecializationId TemplateSpecializationId
    | EmptyPlanSpecializationIdentity TemplateSpecializationId
    | DuplicatePlanSpecializationIdentity String
    | PlanSpecializationTypeIsOpen TemplateSpecializationId [SymbolId]
    | PlanSpecializationTypeHasError TemplateSpecializationId
    | PlanDeclarationIsNotClosedType TemplateSpecializationId
    | PlanDeclarationTypeMismatch TemplateSpecializationId Type Type
    | EmptyPlanOrigin TemplateSpecializationId
    | DuplicatePlanOrigin TemplateSpecializationId String
    | MissingPlanDependency TemplateSpecializationId TemplateSpecializationId
    | DuplicatePlanDependency TemplateSpecializationId TemplateSpecializationId
    | SelfPlanDependency TemplateSpecializationId
    | InvalidFreshSymbol TemplateSpecializationId SymbolId SymbolId
    | DuplicateFreshSourceSymbol TemplateSpecializationId SymbolId
    | DuplicateFreshTargetSymbol TemplateSpecializationId SymbolId
    | SharedFreshTargetSymbol SymbolId [TemplateSpecializationId]
    | DeclarationSymbolMissingFromFreshMap TemplateSpecializationId SymbolId
    | LayoutPlanContainsMembers TemplateSpecializationId Int
    | RequestedPlanMemberMissing TemplateSpecializationId Identifier
    | UnexpectedPlanMember TemplateSpecializationId Identifier
    | InvalidPlanMangledType TemplateSpecializationId String
    | IncorrectPlanMangledType TemplateSpecializationId String String
    | InvalidPlanMangledMember TemplateSpecializationId SymbolId String
    | MissingPlanMangledMember TemplateSpecializationId SymbolId
    | UnexpectedPlanMangledMember TemplateSpecializationId SymbolId
    | DuplicatePlanMangledMember TemplateSpecializationId SymbolId
    | DuplicatePlanMangledSymbol String
    | IncorrectPlanStatistics TemplateSpecializationStatistics TemplateSpecializationStatistics
    | IncompletePlanEmissionOrder [TemplateSpecializationId] [TemplateSpecializationId]
    deriving (Eq, Ord, Read, Show)

-- | Return a plan unchanged when every invariant holds, otherwise all issues.
verifyTemplateSpecializationPlan ::
    TemplateSpecializationPlan ->
    Either [TemplatePlanIssue] TemplateSpecializationPlan
verifyTemplateSpecializationPlan plan = case templateSpecializationPlanIssues plan of
    [] -> Right plan
    problems -> Left problems

-- | Recompute plan invariants without trusting the planner that produced it.
templateSpecializationPlanIssues :: TemplateSpecializationPlan -> [TemplatePlanIssue]
templateSpecializationPlanIssues plan =
    idProblems
        ++ identityProblems
        ++ concatMap (specializationProblems ids) specializations
        ++ sharedSymbolProblems specializations
        ++ duplicateMangledSymbols specializations
        ++ statisticsProblems plan
        ++ emissionProblems plan
    where
        specializations = plannedTemplateSpecializations plan
        ids = map templateSpecializationId specializations
        identities = map templateSpecializationIdentity specializations
        idProblems =
            [InvalidPlanSpecializationId identifier | identifier <- ids, templateSpecializationIdValue identifier <= 0]
                ++ [DuplicatePlanSpecializationId identifier | identifier <- duplicates ids]
        identityProblems =
            [ EmptyPlanSpecializationIdentity (templateSpecializationId specialization)
            | specialization <- specializations
            , null (templateSpecializationIdentity specialization)
            ]
                ++ [DuplicatePlanSpecializationIdentity identity | identity <- duplicates identities]

specializationProblems :: [TemplateSpecializationId] -> TemplateSpecialization -> [TemplatePlanIssue]
specializationProblems available specialization =
    typeProblems specialization
        ++ declarationProblems specialization
        ++ originProblems specialization
        ++ dependencyProblems available specialization
        ++ freshMapProblems specialization
        ++ scopeProblems specialization
        ++ mangledTypeProblems specialization
        ++ mangledMemberProblems specialization

typeProblems :: TemplateSpecialization -> [TemplatePlanIssue]
typeProblems specialization =
    [PlanSpecializationTypeIsOpen identifier open | not (null open)]
        ++ [PlanSpecializationTypeHasError identifier | typeHasError valueType]
    where
        identifier = templateSpecializationId specialization
        valueType = templateSpecializationType specialization
        open = openTypeSymbols valueType

declarationProblems :: TemplateSpecialization -> [TemplatePlanIssue]
declarationProblems specialization = case templateSpecializationDeclaration specialization of
    TypeDeclaration _ _ annotation _ ->
        [ PlanDeclarationTypeMismatch identifier (templateSpecializationType specialization) annotation
        | annotation /= templateSpecializationType specialization
        ]
            ++ [PlanSpecializationTypeHasError identifier | declarationHasError (templateSpecializationDeclaration specialization)]
            ++ [ PlanSpecializationTypeIsOpen identifier open
               | let open = declarationOpenSymbols (templateSpecializationDeclaration specialization)
               , not (null open)
               ]
    _ -> [PlanDeclarationIsNotClosedType identifier]
    where
        identifier = templateSpecializationId specialization

originProblems :: TemplateSpecialization -> [TemplatePlanIssue]
originProblems specialization =
    [EmptyPlanOrigin identifier | any null origins]
        ++ [DuplicatePlanOrigin identifier origin | origin <- duplicates origins]
    where
        identifier = templateSpecializationId specialization
        origins = templateSpecializationOrigins specialization

dependencyProblems :: [TemplateSpecializationId] -> TemplateSpecialization -> [TemplatePlanIssue]
dependencyProblems available specialization =
    [ MissingPlanDependency owner dependency
    | dependency <- dependencies
    , dependency `notElem` available
    ]
        ++ [DuplicatePlanDependency owner dependency | dependency <- duplicates dependencies]
        ++ [SelfPlanDependency owner | owner `elem` dependencies]
    where
        owner = templateSpecializationId specialization
        dependencies = templateSpecializationDependencies specialization

freshMapProblems :: TemplateSpecialization -> [TemplatePlanIssue]
freshMapProblems specialization =
    [ InvalidFreshSymbol identifier old new
    | (old, new) <- mappings
    , symbolIdValue old <= 0 || symbolIdValue new <= 0 || old == new
    ]
        ++ [DuplicateFreshSourceSymbol identifier old | old <- duplicates (map fst mappings)]
        ++ [DuplicateFreshTargetSymbol identifier new | new <- duplicates (map snd mappings)]
        ++ [ DeclarationSymbolMissingFromFreshMap identifier symbol
           | symbol <- declarationDefinitionSymbols (templateSpecializationDeclaration specialization)
           , symbol `notElem` map snd mappings
           ]
    where
        identifier = templateSpecializationId specialization
        mappings = templateSpecializationSymbolMap specialization

sharedSymbolProblems :: [TemplateSpecialization] -> [TemplatePlanIssue]
sharedSymbolProblems specializations =
    [ SharedFreshTargetSymbol symbol owners
    | symbol <- duplicates allTargets
    , let owners =
            [ templateSpecializationId specialization
            | specialization <- specializations
            , symbol `elem` map snd (templateSpecializationSymbolMap specialization)
            ]
    ]
    where
        allTargets = concatMap (map snd . templateSpecializationSymbolMap) specializations

scopeProblems :: TemplateSpecialization -> [TemplatePlanIssue]
scopeProblems specialization = case templateSpecializationScope specialization of
    TemplateLayoutDemand -> [LayoutPlanContainsMembers identifier (length members) | not (null members)]
    TemplateMemberDemand requested ->
        [RequestedPlanMemberMissing identifier name | name <- requested, name `notElem` memberNames]
            ++ [UnexpectedPlanMember identifier name | name <- memberNames, name `notElem` requested]
    TemplateCompleteDemand -> []
    where
        identifier = templateSpecializationId specialization
        members = declarationMembers (templateSpecializationDeclaration specialization)
        memberNames = map (resolvedSpelling . declarationName) members

mangledTypeProblems :: TemplateSpecialization -> [TemplatePlanIssue]
mangledTypeProblems specialization =
    [InvalidPlanMangledType identifier actual | not (validMangledTemplateSymbol actual)]
        ++ case mangleTemplateType defaultTemplateMangleLimits (templateSpecializationType specialization) of
            Left _ -> [InvalidPlanMangledType identifier actual]
            Right expected ->
                [ IncorrectPlanMangledType identifier (mangledTemplateTypeText expected) actual
                | expected /= templateSpecializationMangledType specialization
                ]
    where
        identifier = templateSpecializationId specialization
        actual = mangledTemplateTypeText (templateSpecializationMangledType specialization)

mangledMemberProblems :: TemplateSpecialization -> [TemplatePlanIssue]
mangledMemberProblems specialization =
    invalid
        ++ missing
        ++ unexpected
        ++ repeated
        ++ incorrect
    where
        identifier = templateSpecializationId specialization
        members = declarationMembers (templateSpecializationDeclaration specialization)
        memberSymbols = map (resolvedSymbol . declarationName) members
        mangled = templateSpecializationMangledMembers specialization
        mangledSymbols = map mangledMemberSourceSymbol mangled
        invalid =
            [ InvalidPlanMangledMember identifier (mangledMemberSourceSymbol member) (mangledMemberText member)
            | member <- mangled
            , not (validMangledTemplateSymbol (mangledMemberText member))
            ]
        missing = [MissingPlanMangledMember identifier symbol | symbol <- memberSymbols, symbol `notElem` mangledSymbols]
        unexpected = [UnexpectedPlanMangledMember identifier symbol | symbol <- mangledSymbols, symbol `notElem` memberSymbols]
        repeated = [DuplicatePlanMangledMember identifier symbol | symbol <- duplicates mangledSymbols]
        incorrect = case mangleTemplateMembers
            defaultTemplateMangleLimits
            (templateSpecializationType specialization)
            (templateSpecializationDeclaration specialization) of
            Left _ -> [InvalidPlanMangledType identifier (mangledTemplateTypeText (templateSpecializationMangledType specialization))]
            Right expected ->
                [ InvalidPlanMangledMember identifier (mangledMemberSourceSymbol actual) (mangledMemberText actual)
                | actual <- mangled
                , Just expectedMember <- [findMember (mangledMemberSourceSymbol actual) expected]
                , mangledMemberText actual /= mangledMemberText expectedMember
                ]

duplicateMangledSymbols :: [TemplateSpecialization] -> [TemplatePlanIssue]
duplicateMangledSymbols specializations =
    [DuplicatePlanMangledSymbol symbol | symbol <- duplicates symbols]
    where
        symbols =
            concat
                [ mangledTemplateTypeText (templateSpecializationMangledType specialization)
                    : map mangledMemberText (templateSpecializationMangledMembers specialization)
                | specialization <- specializations
                ]

statisticsProblems :: TemplateSpecializationPlan -> [TemplatePlanIssue]
statisticsProblems plan =
    [IncorrectPlanStatistics expected actual | expected /= actual]
    where
        actual = plannedTemplateStatistics plan
        specializations = plannedTemplateSpecializations plan
        expected =
            actual
                { uniqueTemplateSpecializations = length specializations
                , coalescedTemplateSpecializations = requestedTemplateSpecializations actual - length specializations
                , instantiatedTemplateMembers =
                    sum (map (length . declarationMembers . templateSpecializationDeclaration) specializations)
                , retainedTemplateOrigins = sum (map (length . templateSpecializationOrigins) specializations)
                , templateDependencyEdges = sum (map (length . templateSpecializationDependencies) specializations)
                }

emissionProblems :: TemplateSpecializationPlan -> [TemplatePlanIssue]
emissionProblems plan =
    [IncompletePlanEmissionOrder expected actual | sort expected /= sort actual || length actual /= length expected]
    where
        expected = map templateSpecializationId (plannedTemplateSpecializations plan)
        actual = specializationEmissionOrder plan

declarationMembers :: Declaration ResolvedName Type -> [Declaration ResolvedName Type]
declarationMembers TypeDeclaration {typeMembers = members} = members
declarationMembers _ = []

declarationDefinitionSymbols :: Declaration ResolvedName Type -> [SymbolId]
declarationDefinitionSymbols declaration = case declaration of
    TypeDeclaration _ name _ members -> resolvedSymbol name : concatMap declarationDefinitionSymbols members
    FunctionDeclaration _ name _ _ parameters body _ _ _ ->
        resolvedSymbol name
            : map (resolvedSymbol . parameterName) parameters
            ++ blockDefinitionSymbols body
    TemplateTypeDeclaration {} -> []
    EnumDeclaration _ name _ _ _ -> [resolvedSymbol name]

blockDefinitionSymbols :: Block ResolvedName Type -> [SymbolId]
blockDefinitionSymbols (Block statements) = concatMap statementDefinitionSymbols statements

statementDefinitionSymbols :: Statement ResolvedName Type -> [SymbolId]
statementDefinitionSymbols statement = case statement of
    BindingStatement _ _ _ name _ value -> resolvedSymbol name : expressionDefinitionSymbols value
    AssignmentStatement _ _ _ value -> expressionDefinitionSymbols value
    ReturnStatement _ value -> maybe [] expressionDefinitionSymbols value
    IfStatement _ condition trueBlock falseBlock ->
        expressionDefinitionSymbols condition
            ++ blockDefinitionSymbols trueBlock
            ++ maybe [] blockDefinitionSymbols falseBlock
    WhileStatement _ condition body -> expressionDefinitionSymbols condition ++ blockDefinitionSymbols body
    DoWhileStatement _ body condition -> blockDefinitionSymbols body ++ expressionDefinitionSymbols condition
    ForStatement _ initializer condition updates body ->
        maybe [] statementDefinitionSymbols initializer
            ++ maybe [] expressionDefinitionSymbols condition
            ++ concatMap statementDefinitionSymbols updates
            ++ blockDefinitionSymbols body
    ForEachStatement _ _ _ name _ source body ->
        resolvedSymbol name : expressionDefinitionSymbols source ++ blockDefinitionSymbols body
    IncrementStatement _ name _ -> [resolvedSymbol name]
    CompoundAssignmentStatement _ _ _ _ value -> expressionDefinitionSymbols value
    DiscardStatement _ value -> expressionDefinitionSymbols value
    BreakStatement _ value -> maybe [] expressionDefinitionSymbols value
    ContinueStatement {} -> []
    GuardStatement _ condition block -> expressionDefinitionSymbols condition ++ blockDefinitionSymbols block
    BlockStatement _ block -> blockDefinitionSymbols block
    ExpressionStatement _ expression _ -> expressionDefinitionSymbols expression

expressionDefinitionSymbols :: Expression ResolvedName Type -> [SymbolId]
expressionDefinitionSymbols expression = case expression of
    MemberAccessExpression _ receiver _ _ -> expressionDefinitionSymbols receiver
    MethodReferenceExpression _ receiver _ _ -> expressionDefinitionSymbols receiver
    CallExpression _ callee arguments _ ->
        expressionDefinitionSymbols callee ++ concatMap expressionDefinitionSymbols arguments
    UnaryExpression _ _ value _ -> expressionDefinitionSymbols value
    BinaryExpression _ _ left right _ -> expressionDefinitionSymbols left ++ expressionDefinitionSymbols right
    IsPatternExpression _ subject _ _ -> expressionDefinitionSymbols subject
    ConditionalExpression _ condition first second _ ->
        concatMap expressionDefinitionSymbols [condition, first, second]
    CoalesceExpression _ left fallback _ ->
        expressionDefinitionSymbols left ++ expressionDefinitionSymbols fallback
    AssignmentExpression _ _ _ value _ -> expressionDefinitionSymbols value
    IncrementExpression {} -> []
    LoopExpression _ loop _ -> statementDefinitionSymbols loop
    BlockExpression _ block _ -> blockDefinitionSymbols block
    MatchExpression _ subjects arms _ ->
        [ resolvedSymbol name
        | arm <- arms
        , Just name <- map matchPatternBinding (matchArmPatterns arm)
        ]
            ++ concatMap expressionDefinitionSymbols (subjects ++ concatMap matchArmExpressions arms)
    CallableExpression _ _ captures parameters body _ ->
        map (resolvedSymbol . captureName) captures
            ++ map (resolvedSymbol . parameterName) parameters
            ++ callableBodyDefinitionSymbols body
    NameExpression {} -> []
    LiteralExpression {} -> []

callableBodyDefinitionSymbols :: CallableBody ResolvedName Type -> [SymbolId]
callableBodyDefinitionSymbols body = case body of
    CallableExpressionBody expression -> expressionDefinitionSymbols expression
    CallableBlockBody block -> blockDefinitionSymbols block

declarationOpenSymbols :: Declaration ResolvedName Type -> [SymbolId]
declarationOpenSymbols declaration = unique (concatMap openTypeSymbols (declarationTypes declaration))

declarationHasError :: Declaration ResolvedName Type -> Bool
declarationHasError = any typeHasError . declarationTypes

declarationTypes :: Declaration ResolvedName Type -> [Type]
declarationTypes declaration = case declaration of
    TypeDeclaration _ _ annotation members -> annotation : concatMap declarationTypes members
    FunctionDeclaration _ _ annotation _ parameters body _ _ _ ->
        annotation : map parameterAnnotation parameters ++ blockTypes body
    TemplateTypeDeclaration _ _ annotation parameters members ->
        annotation : map templateParameterAnnotation parameters ++ concatMap declarationTypes members
    EnumDeclaration _ _ annotation _ _ -> [annotation]

blockTypes :: Block ResolvedName Type -> [Type]
blockTypes (Block statements) = concatMap statementTypes statements

statementTypes :: Statement ResolvedName Type -> [Type]
statementTypes statement = case statement of
    BindingStatement _ _ _ _ annotation value -> annotation : expressionTypes value
    AssignmentStatement _ _ annotation value -> annotation : expressionTypes value
    ReturnStatement _ value -> maybe [] expressionTypes value
    IfStatement _ condition trueBlock falseBlock ->
        expressionTypes condition ++ blockTypes trueBlock ++ maybe [] blockTypes falseBlock
    WhileStatement _ condition body -> expressionTypes condition ++ blockTypes body
    DoWhileStatement _ body condition -> blockTypes body ++ expressionTypes condition
    ForStatement _ initializer condition updates body ->
        maybe [] statementTypes initializer
            ++ maybe [] expressionTypes condition
            ++ concatMap statementTypes updates
            ++ blockTypes body
    ForEachStatement _ _ _ _ annotation source body -> annotation : expressionTypes source ++ blockTypes body
    IncrementStatement _ _ annotation -> [annotation]
    CompoundAssignmentStatement _ _ _ annotation value -> annotation : expressionTypes value
    DiscardStatement _ value -> expressionTypes value
    BreakStatement _ value -> maybe [] expressionTypes value
    ContinueStatement {} -> []
    GuardStatement _ condition block -> expressionTypes condition ++ blockTypes block
    BlockStatement _ block -> blockTypes block
    ExpressionStatement _ value _ -> expressionTypes value

expressionTypes :: Expression ResolvedName Type -> [Type]
expressionTypes expression = case expression of
    NameExpression _ _ annotation -> [annotation]
    LiteralExpression _ _ annotation -> [annotation]
    MemberAccessExpression _ receiver _ annotation -> annotation : expressionTypes receiver
    MethodReferenceExpression _ receiver _ annotation -> annotation : expressionTypes receiver
    CallExpression _ callee arguments annotation ->
        annotation : expressionTypes callee ++ concatMap expressionTypes arguments
    UnaryExpression _ _ value annotation -> annotation : expressionTypes value
    BinaryExpression _ _ left right annotation -> annotation : expressionTypes left ++ expressionTypes right
    IsPatternExpression _ subject patternValue annotation ->
        annotation : expressionTypes subject ++ patternTypes patternValue
    ConditionalExpression _ condition first second annotation ->
        annotation : concatMap expressionTypes [condition, first, second]
    CoalesceExpression _ left fallback annotation ->
        annotation : expressionTypes left ++ expressionTypes fallback
    AssignmentExpression _ _ _ value annotation -> annotation : expressionTypes value
    IncrementExpression _ _ _ annotation -> [annotation]
    LoopExpression _ loop annotation -> annotation : statementTypes loop
    BlockExpression _ block annotation -> annotation : blockTypes block
    MatchExpression _ subjects arms annotation ->
        annotation
            : map matchPatternAnnotation (concatMap matchArmPatterns arms)
            ++ concatMap expressionTypes (subjects ++ concatMap matchArmExpressions arms)
    CallableExpression _ _ captures parameters body annotation ->
        annotation
            : map captureAnnotation captures
            ++ map parameterAnnotation parameters
            ++ callableBodyTypes body

patternTypes :: Pattern ResolvedName Type -> [Type]
patternTypes patternValue = case patternValue of
    WildcardPattern _ annotation -> [annotation]
    NullPattern _ annotation -> [annotation]
    LiteralPattern _ _ annotation -> [annotation]
    TypePattern _ _ annotation -> [annotation]
    RelationalPattern _ _ _ annotation -> [annotation]
    NotPattern _ nested annotation -> annotation : patternTypes nested
    AndPattern _ left right annotation -> annotation : patternTypes left ++ patternTypes right
    OrPattern _ left right annotation -> annotation : patternTypes left ++ patternTypes right

callableBodyTypes :: CallableBody ResolvedName Type -> [Type]
callableBodyTypes body = case body of
    CallableExpressionBody expression -> expressionTypes expression
    CallableBlockBody block -> blockTypes block

openTypeSymbols :: Type -> [SymbolId]
openTypeSymbols valueType = unique (collectType valueType)
    where
        collectType current = case current of
            NamedType _ arguments -> concatMap collectArgument arguments
            FunctionType parameters result -> concatMap collectType (parameters ++ [result])
            TypeVariable name -> [resolvedSymbol name]
            ErrorType -> []
        collectArgument argument = case argument of
            TypeTemplateArgument nested -> collectType nested
            ValueTemplateArgument (TemplateValueParameter name) -> [resolvedSymbol name]
            ValueTemplateArgument _ -> []

typeHasError :: Type -> Bool
typeHasError valueType = case valueType of
    NamedType _ arguments -> any argumentHasError arguments
    FunctionType parameters result -> any typeHasError parameters || typeHasError result
    TypeVariable _ -> False
    ErrorType -> True
    where
        argumentHasError (TypeTemplateArgument nested) = typeHasError nested
        argumentHasError (ValueTemplateArgument _) = False

findMember :: SymbolId -> [MangledTemplateMember] -> Maybe MangledTemplateMember
findMember _ [] = Nothing
findMember symbol (member : remaining)
    | mangledMemberSourceSymbol member == symbol = Just member
    | otherwise = findMember symbol remaining

duplicates :: (Ord value) => [value] -> [value]
duplicates values =
    [ firstValue
    | duplicate@(firstValue : _) <- grouped (sort values)
    , length duplicate > 1
    ]
    where
        grouped [] = []
        grouped (value : remaining) =
            let (same, rest) = span (== value) remaining
             in (value : same) : grouped rest

unique :: (Eq value) => [value] -> [value]
unique = foldl append []
    where
        append values value
            | value `elem` values = values
            | otherwise = values ++ [value]

-- | Render one plan-verification issue as a diagnostic-ready message.
renderTemplatePlanIssue :: TemplatePlanIssue -> String
renderTemplatePlanIssue issue = case issue of
    InvalidPlanSpecializationId identifier -> prefix identifier ++ "has a non-positive id"
    DuplicatePlanSpecializationId identifier -> prefix identifier ++ "duplicates a specialization id"
    EmptyPlanSpecializationIdentity identifier -> prefix identifier ++ "has an empty canonical identity"
    DuplicatePlanSpecializationIdentity identity -> "template plan duplicates canonical identity " ++ identity
    PlanSpecializationTypeIsOpen identifier symbols -> prefix identifier ++ "remains open over " ++ intercalate "," (map showSymbol symbols)
    PlanSpecializationTypeHasError identifier -> prefix identifier ++ "contains ErrorType"
    PlanDeclarationIsNotClosedType identifier -> prefix identifier ++ "does not contain an ordinary closed type declaration"
    PlanDeclarationTypeMismatch identifier expected actual -> prefix identifier ++ "declaration type differs: " ++ show expected ++ " /= " ++ show actual
    EmptyPlanOrigin identifier -> prefix identifier ++ "contains an empty diagnostic origin"
    DuplicatePlanOrigin identifier origin -> prefix identifier ++ "duplicates origin " ++ origin
    MissingPlanDependency owner dependency -> prefix owner ++ "references missing dependency " ++ showId dependency
    DuplicatePlanDependency owner dependency -> prefix owner ++ "duplicates dependency " ++ showId dependency
    SelfPlanDependency identifier -> prefix identifier ++ "depends directly on itself"
    InvalidFreshSymbol identifier old new -> prefix identifier ++ "has invalid fresh mapping " ++ showSymbol old ++ " -> " ++ showSymbol new
    DuplicateFreshSourceSymbol identifier symbol -> prefix identifier ++ "maps source symbol twice: " ++ showSymbol symbol
    DuplicateFreshTargetSymbol identifier symbol -> prefix identifier ++ "allocates target symbol twice: " ++ showSymbol symbol
    SharedFreshTargetSymbol symbol owners -> "fresh symbol " ++ showSymbol symbol ++ " is shared by " ++ showIds owners
    DeclarationSymbolMissingFromFreshMap identifier symbol -> prefix identifier ++ "definition is absent from fresh map: " ++ showSymbol symbol
    LayoutPlanContainsMembers identifier count -> prefix identifier ++ "layout-only demand contains " ++ show count ++ " members"
    RequestedPlanMemberMissing identifier name -> prefix identifier ++ "is missing requested member " ++ identifierText name
    UnexpectedPlanMember identifier name -> prefix identifier ++ "contains unexpected member " ++ identifierText name
    InvalidPlanMangledType identifier symbol -> prefix identifier ++ "has invalid mangled type symbol " ++ symbol
    IncorrectPlanMangledType identifier expected actual -> prefix identifier ++ "mangled type differs: " ++ expected ++ " /= " ++ actual
    InvalidPlanMangledMember identifier symbol name -> prefix identifier ++ "has invalid mangled member " ++ showSymbol symbol ++ ": " ++ name
    MissingPlanMangledMember identifier symbol -> prefix identifier ++ "has no mangled name for member " ++ showSymbol symbol
    UnexpectedPlanMangledMember identifier symbol -> prefix identifier ++ "has a mangled name for unknown member " ++ showSymbol symbol
    DuplicatePlanMangledMember identifier symbol -> prefix identifier ++ "mangles member twice: " ++ showSymbol symbol
    DuplicatePlanMangledSymbol symbol -> "template plan emits duplicate mangled symbol " ++ symbol
    IncorrectPlanStatistics expected actual -> "template plan statistics differ: " ++ show expected ++ " /= " ++ show actual
    IncompletePlanEmissionOrder expected actual -> "template emission order differs: " ++ showIds expected ++ " /= " ++ showIds actual
    where
        prefix identifier = "template specialization " ++ showId identifier ++ " "
        showId = show . templateSpecializationIdValue
        showIds = intercalate "," . map showId
        showSymbol = show . symbolIdValue
