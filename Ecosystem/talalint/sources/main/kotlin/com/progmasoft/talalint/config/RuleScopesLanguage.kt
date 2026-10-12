/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.talalint.config

class ExpressionsScope : RuleGroupScope() {
  var constantCondition by severity(Severity.WARNING)
  var identicalBranches by severity(Severity.WARNING)
  var selfAssignment by severity(Severity.WARNING)
  var suspiciousAssignmentChain by severity(Severity.WARNING)
  var assignmentInCondition by severity(Severity.WARNING)
  var redundantBooleanComparison by severity(Severity.INFO)
  var doubleNegation by severity(Severity.WARNING)
  var bitwiseNotOnBooleanIntent by severity(Severity.WARNING)
  var logicalNotOnNumericIntent by severity(Severity.WARNING)
  var chainedComparison by severity(Severity.WARNING)
  var chainedEquality by severity(Severity.WARNING)
  var integerPowerNegativeExponent by severity(Severity.WARNING)
  var rangeZeroStep by severity(Severity.ERROR)
  var repeatedRangeStep by severity(Severity.WARNING)
  var suspiciousDescendingRange by severity(Severity.WARNING)
  var rangePrecedenceAmbiguity by severity(Severity.INFO)
  var coalescingPrecedenceAmbiguity by severity(Severity.INFO)
  var roundedDivisionCommentConfusion by severity(Severity.WARNING)
  var decrementCommentAmbiguity by severity(Severity.WARNING)
  var nullSafeAccess by severity(Severity.WARNING)
  var redundantStaticCast by severity(Severity.INFO)
  var alwaysFailingDynamicCast by severity(Severity.WARNING)
  var panicCastAvoidable by severity(Severity.WARNING)
  var methodReferenceImmediatelyInvoked by severity(Severity.INFO)
  var newOnNonconstructibleType by severity(Severity.WARNING)
  var resultNeverUsed by severity(Severity.WARNING)
}

class ControlScope : RuleGroupScope() {
  var nonExhaustiveMatch by severity(Severity.WARNING)
  var unreachableMatchArm by severity(Severity.WARNING)
  var duplicateMatchPattern by severity(Severity.WARNING)
  var catchAllNotLast by severity(Severity.WARNING)
  var redundantMatchCatchAll by severity(Severity.INFO)
  var matchBindingUnused by severity(Severity.WARNING)
  var matchExpressionResultDiscarded by severity(Severity.WARNING)
  var ifBindingScopeConfusion by severity(Severity.WARNING)
  var guardWithoutEarlyExit by severity(Severity.WARNING)
  var emptyBranch by severity(Severity.WARNING)
  var duplicateCondition by severity(Severity.WARNING)
  var loopNeverExecutes by severity(Severity.WARNING)
  var infiniteLoopWithoutExit by severity(Severity.WARNING)
  var breakOutsideLoop by severity(Severity.WARNING)
  var continueOutsideLoop by severity(Severity.WARNING)
  var valueBreakContext by severity(Severity.WARNING)
  var gotoSkipsInitialization by severity(Severity.WARNING)
  var unusedLabel by severity(Severity.WARNING)
}

class ExceptionsScope : RuleGroupScope() {
  var undeclaredCheckedException by severity(Severity.ERROR)
  var duplicateThrowsType by severity(Severity.WARNING)
  var redundantThrowsSubtype by severity(Severity.WARNING)
  var uncheckedTypeInThrows by severity(Severity.INFO)
  var nonThrowableValue by severity(Severity.WARNING)
  var nullThrowable by severity(Severity.WARNING)
  var bareRethrowOutsideCatch by severity(Severity.WARNING)
  var rethrowLosesStack by severity(Severity.WARNING)
  var unreachableCatch by severity(Severity.WARNING)
  var redundantMultiCatchAlternative by severity(Severity.WARNING)
  var invalidCatchBindingReassignment by severity(Severity.WARNING)
  var swallowedException by severity(Severity.WARNING)
  var overlyBroadCatch by severity(Severity.WARNING)
  var throwInNoexcept by severity(Severity.ERROR)
  var finallyKeyword by severity(Severity.WARNING)
  var deferThrowsDuringUnwind by severity(Severity.WARNING)
  var deferCapturesInvalidState by severity(Severity.WARNING)
}

class OptionalScope : RuleGroupScope() {
  var valueWithoutCheck by severity(Severity.WARNING)
  var redundantValueOr by severity(Severity.INFO)
  var nestedOptional by severity(Severity.WARNING)
  var confusedNullPayload by severity(Severity.WARNING)
}

class OwnershipScope : RuleGroupScope() {
  var useAfterMove by severity(Severity.ERROR)
  var redundantCopy by severity(Severity.INFO)
  var redundantMove by severity(Severity.INFO)
  var aliasAfterOwnerTransfer by severity(Severity.WARNING)
  var cowMutationInSharedContext by severity(Severity.WARNING)
  var strongReferenceCycle by severity(Severity.WARNING)
  var weakValueType by severity(Severity.WARNING)
  var unownedValueType by severity(Severity.WARNING)
  var unownedMayOutliveOwner by severity(Severity.WARNING)
  var weakPromotionIgnored by severity(Severity.WARNING)
}

class ClosuresScope : RuleGroupScope() {
  var unusedParameter by severity(Severity.WARNING)
  var implicitParameterOutOfRange by severity(Severity.WARNING)
  var namedArgumentInvocation by severity(Severity.WARNING)
  var redundantCapture by severity(Severity.INFO)
  var duplicateCapture by severity(Severity.WARNING)
  var captureAliasCollision by severity(Severity.WARNING)
  var mutableCaptureSurprise by severity(Severity.WARNING)
  var strongSelfCycle by severity(Severity.WARNING)
  var weakCaptureWithoutCheck by severity(Severity.WARNING)
  var unownedCaptureEscape by severity(Severity.WARNING)
  var captureLargeCowValue by severity(Severity.OFF)
  var genericInferenceTooBroad by severity(Severity.OFF)
  var exceptionSurfaceHidden by severity(Severity.WARNING)
}

class GeneratorsScope : RuleGroupScope() {
  var yieldOutsideGenerator by severity(Severity.WARNING)
  var invalidReturnValue by severity(Severity.WARNING)
  var unreachableYield by severity(Severity.WARNING)
  var yieldTypeMismatch by severity(Severity.WARNING)
  var autoReturnWithYield by severity(Severity.WARNING)
  var yieldInConstructor by severity(Severity.WARNING)
  var yieldInPropertyAccessor by severity(Severity.WARNING)
  var yieldInOp by severity(Severity.WARNING)
  var resourceWithoutDefer by severity(Severity.WARNING)
  var multipleEnumerationSideEffect by severity(Severity.WARNING)
}

class IterationScope : RuleGroupScope() {
  var sourceMutatedDuringIteration by severity(Severity.WARNING)
  var redundantExplicitType by severity(Severity.OFF)
  var expensiveSourceRecomputation by severity(Severity.WARNING)
  var iteratorTypeExposed by severity(Severity.WARNING)
}

class CollectionsScope : RuleGroupScope() {
  var fixedSizeMismatch by severity(Severity.WARNING)
  var duplicateDictionaryKey by severity(Severity.WARNING)
  var duplicateSetElement by severity(Severity.WARNING)
  var indexOutOfBoundsConstant by severity(Severity.WARNING)
  var negativeCapacity by severity(Severity.WARNING)
  var unusedCapacityReservation by severity(Severity.INFO)
  var mutationDuringIteration by severity(Severity.WARNING)
  var repeatedLinearLookup by severity(Severity.WARNING)
  var dictionaryDefaultMasksMissingKey by severity(Severity.WARNING)
}

class BlinqScope : RuleGroupScope() {
  var lazyQueryNeverConsumed by severity(Severity.WARNING)
  var reenumeratedSideEffectfulQuery by severity(Severity.WARNING)
  var orderingReplaced by severity(Severity.WARNING)
  var thenByWithoutOrdering by severity(Severity.WARNING)
  var strictWithoutReason by severity(Severity.INFO)
  var allStrictWithoutReason by severity(Severity.INFO)
  var materializeThenQuery by severity(Severity.INFO)
  var countForEmptiness by severity(Severity.INFO)
  var firstAfterOrderingForMin by severity(Severity.INFO)
  var nonterminalQueryResultDiscarded by severity(Severity.WARNING)
  var relationalPushdownBlocked by severity(Severity.WARNING)
  var unstableHashContract by severity(Severity.WARNING)
}

class TextScope : RuleGroupScope() {
  var invalidSourceUtf8 by severity(Severity.ERROR)
  var invalidUnicodeScalarEscape by severity(Severity.ERROR)
  var noncharacterEscape by severity(Severity.WARNING)
  var confusableIdentifier by severity(Severity.WARNING)
  var mixedScriptIdentifier by severity(Severity.WARNING)
  var bidirectionalControl by severity(Severity.ERROR)
  var invisibleCharacter by severity(Severity.WARNING)
  var byteLengthAssumption by severity(Severity.WARNING)
  var utf16LengthAssumption by severity(Severity.WARNING)
  var invalidScalarIndexAssumption by severity(Severity.WARNING)
  var normalizationSensitiveComparison by severity(Severity.OFF)
  var rawStringDelimiterConfusion by severity(Severity.WARNING)
  var rawStringIndentationAssumption by severity(Severity.WARNING)
  var normalStringPhysicalNewline by severity(Severity.WARNING)
  var escapeCanBeLiteral by severity(Severity.INFO)
}

class CommentsScope : RuleGroupScope() {
  var todoWithoutOwner by severity(Severity.OFF)
  var fixmeInPublicCode by severity(Severity.OFF)
  var commentedOutCode by severity(Severity.OFF)
  var malformedDocumentComment by severity(Severity.WARNING)
  var orphanDocumentComment by severity(Severity.WARNING)
  var namespaceDocumentMisplaced by severity(Severity.WARNING)
  var declarationDocumentMisplaced by severity(Severity.WARNING)
  var documentAttributeDuplicate by severity(Severity.WARNING)
  var publicApiMissingDocumentation by severity(Severity.OFF)
  var staleParameterDocumentation by severity(Severity.WARNING)
  var invalidLongDelimiterLevel by severity(Severity.WARNING)
  var nestedLongCommentAssumption by severity(Severity.WARNING)
}

class AttributesScope : RuleGroupScope() {
  var runtimeArgument by severity(Severity.WARNING)
  var duplicateNonrepeatable by severity(Severity.WARNING)
  var invalidTarget by severity(Severity.WARNING)
  var invalidTargetPrefix by severity(Severity.WARNING)
  var orderSensitiveReordering by severity(Severity.WARNING)
  var redundantParentheses by severity(Severity.INFO)
  var reflectionPrivateAccess by severity(Severity.WARNING)
  var missingUsageDeclaration by severity(Severity.WARNING)
  var noImplicitSystemRepeated by severity(Severity.WARNING)
  var multipleEntryPoint by severity(Severity.ERROR)
}
