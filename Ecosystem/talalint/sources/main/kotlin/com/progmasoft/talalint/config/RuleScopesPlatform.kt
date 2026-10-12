/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.talalint.config

class OperatorsScope : RuleGroupScope() {
  var impureOp by severity(Severity.WARNING)
  var throwingOp by severity(Severity.WARNING)
  var yieldingOp by severity(Severity.WARNING)
  var nonOverloadableOperator by severity(Severity.WARNING)
  var directCompoundAssignment by severity(Severity.WARNING)
  var invalidPrefixPostfixTarget by severity(Severity.WARNING)
  var missingCustomPrecedence by severity(Severity.WARNING)
  var invalidAssociativity by severity(Severity.WARNING)
  var surprisingPrecedence by severity(Severity.WARNING)
  var asymmetricPair by severity(Severity.WARNING)
  var equalityHashContract by severity(Severity.WARNING)
  var incrementNonLvalue by severity(Severity.WARNING)
}

class UnsafeScope : RuleGroupScope() {
  var languageBlock by severity(Severity.WARNING)
  var allocationWithoutNullCheck by severity(Severity.WARNING)
  var negativeCapacity by severity(Severity.WARNING)
  var zeroCapacityAssumption by severity(Severity.WARNING)
  var allocationLeak by severity(Severity.ERROR)
  var useAfterDeallocate by severity(Severity.ERROR)
  var doubleDeallocate by severity(Severity.ERROR)
  var readBeforeInitialize by severity(Severity.ERROR)
  var initializeTwice by severity(Severity.ERROR)
  var deinitializeCountMismatch by severity(Severity.WARNING)
  var pointerArithmeticOutOfBounds by severity(Severity.ERROR)
  var mutableFromConstantPointer by severity(Severity.WARNING)
  var freeWithoutNullingCPointer by severity(Severity.WARNING)
  var mrcRetainReleaseImbalance by severity(Severity.ERROR)
  var mrcReleaseAfterDeallocate by severity(Severity.ERROR)
  var mrcManualDeallocate by severity(Severity.WARNING)
  var pointerEscapesScope by severity(Severity.ERROR)
  var rawPointerPublicApi by severity(Severity.WARNING)
}

class FfiScope : RuleGroupScope() {
  var importWithoutExtern by severity(Severity.WARNING)
  var externWithBody by severity(Severity.WARNING)
  var externWithoutImport by severity(Severity.WARNING)
  var noMangleInvalidTarget by severity(Severity.WARNING)
  var cExportAbiUnsafeType by severity(Severity.ERROR)
  var objectiveCInvalidMember by severity(Severity.WARNING)
  var swiftInvalidSurface by severity(Severity.WARNING)
  var platformLibraryMismatch by severity(Severity.WARNING)
  var missingSymbolName by severity(Severity.WARNING)
  var uncheckedNullNativeResult by severity(Severity.WARNING)
  var nativeResourceLeak by severity(Severity.ERROR)
  var variadicCallUnsafeType by severity(Severity.WARNING)
  var exceptionCrossesBoundary by severity(Severity.ERROR)
  var missingWorldImport by severity(Severity.WARNING)
}

class AsmScope : RuleGroupScope() {
  var nonLiteralTemplate by severity(Severity.WARNING)
  var resultFromVoidForm by severity(Severity.WARNING)
  var invalidOutputLvalue by severity(Severity.WARNING)
  var duplicateOperandName by severity(Severity.WARNING)
  var invalidConstraint by severity(Severity.WARNING)
  var missingMemoryClobber by severity(Severity.WARNING)
  var missingCcClobber by severity(Severity.WARNING)
  var volatileWithoutSideEffect by severity(Severity.INFO)
  var nonvolatileUnusedResult by severity(Severity.WARNING)
  var targetDialectMismatch by severity(Severity.WARNING)
  var unwindContractMissing by severity(Severity.WARNING)
  var gotoTargetMissing by severity(Severity.WARNING)
  var gotoTargetUnused by severity(Severity.WARNING)
  var registerClobberConflict by severity(Severity.WARNING)
}

class DirectivesScope : RuleGroupScope() {
  var unknownSymbol by severity(Severity.WARNING)
  var duplicateDefine by severity(Severity.WARNING)
  var undefUnknown by severity(Severity.WARNING)
  var setdefBeforeDefine by severity(Severity.WARNING)
  var constantCondition by severity(Severity.WARNING)
  var unreachableBranch by severity(Severity.WARNING)
  var mismatchedBranch by severity(Severity.WARNING)
  var invalidPlacement by severity(Severity.WARNING)
  var unknownPlatform by severity(Severity.WARNING)
  var errorInActiveBranch by severity(Severity.ERROR)
  var warningInActiveBranch by severity(Severity.WARNING)
  var emptyRegion by severity(Severity.INFO)
  var unbalancedRegion by severity(Severity.WARNING)
}

class PerformanceScope : RuleGroupScope() {
  var unnecessaryAllocation by severity(Severity.INFO)
  var copyLargeCowValue by severity(Severity.INFO)
  var movePreventsOptimization by severity(Severity.INFO)
  var repeatedPropertyCall by severity(Severity.INFO)
  var collectionGrowthWithoutReserve by severity(Severity.INFO)
  var reserveFarAboveUse by severity(Severity.INFO)
  var stringConcatenationInLoop by severity(Severity.INFO)
  var eagerMaterialization by severity(Severity.INFO)
  var fullSortForExtreme by severity(Severity.INFO)
  var repeatedDynamicCast by severity(Severity.INFO)
  var reflectionInHotPath by severity(Severity.INFO)
  var boxingValueType by severity(Severity.INFO)
  var nonTailTemplateRecursion by severity(Severity.OFF)
}

class ConcurrencyScope : RuleGroupScope() {
  var sharedMutableCapture by severity(Severity.WARNING)
  var blockingCallInAsyncContext by severity(Severity.WARNING)
  var unjoinedThread by severity(Severity.WARNING)
  var lockNotReleased by severity(Severity.ERROR)
  var lockOrderCycle by severity(Severity.WARNING)
  var atomicityAssumption by severity(Severity.WARNING)
}

class IoScope : RuleGroupScope() {
  var ignoredError by severity(Severity.WARNING)
  var resourceWithoutDefer by severity(Severity.WARNING)
  var pathStringPortability by severity(Severity.WARNING)
}

class CommandScope : RuleGroupScope() {
  var shellInjection by severity(Severity.ERROR)
  var argumentStringConcatenation by severity(Severity.WARNING)
}

class DatabaseScope : RuleGroupScope() {
  var queryConcatenation by severity(Severity.ERROR)
  var unclosedResult by severity(Severity.WARNING)
}

class ApiScope : RuleGroupScope() {
  var publicTypeWithoutExplicitAccess by severity(Severity.WARNING)
  var publicMemberWithoutExplicitAccess by severity(Severity.WARNING)
  var publicAutoType by severity(Severity.WARNING)
  var publicAnonymousCallableSurface by severity(Severity.WARNING)
  var exposesUnsafeType by severity(Severity.WARNING)
  var exposesPlatformSpecificType by severity(Severity.WARNING)
  var checkedExceptionDocumentation by severity(Severity.WARNING)
  var deprecatedWithoutReplacement by severity(Severity.WARNING)
  var experimentalWithoutMarker by severity(Severity.OFF)
  var inconsistentParameterLabels by severity(Severity.WARNING)
  var booleanParameterWithoutLabel by severity(Severity.WARNING)
  var returnedMutableInternalCollection by severity(Severity.WARNING)
  var extensionConflictsWithRealMember by severity(Severity.WARNING)
  var ambiguousExtensions by severity(Severity.WARNING)
}

class MaintenanceScope : RuleGroupScope() {
  var duplicateBranchBody by severity(Severity.WARNING)
  var magicNumber by severity(Severity.OFF)

  private val excessiveNestingScope = ExcessiveNestingScope()
  private val functionComplexityScope = FunctionComplexityScope()
  private val functionLengthScope = FunctionLengthScope()
  private val typeMemberCountScope = TypeMemberCountScope()

  fun excessiveNesting(block: ExcessiveNestingScope.() -> Unit) = excessiveNestingScope.apply(block)

  fun functionComplexity(block: FunctionComplexityScope.() -> Unit) =
    functionComplexityScope.apply(block)

  fun functionLength(block: FunctionLengthScope.() -> Unit) = functionLengthScope.apply(block)

  fun typeMemberCount(block: TypeMemberCountScope.() -> Unit) = typeMemberCountScope.apply(block)

  internal fun parameterizedRules() =
    mapOf(
      "maintenance.excessiveNesting" to excessiveNestingScope.snapshot(),
      "maintenance.functionComplexity" to functionComplexityScope.snapshot(),
      "maintenance.functionLength" to functionLengthScope.snapshot(),
      "maintenance.typeMemberCount" to typeMemberCountScope.snapshot(),
    )
}

class FormatScope : RuleGroupScope() {
  var sourceNotFormatted by severity(Severity.OFF)
  var trailingWhitespace by severity(Severity.WARNING)
  var mixedLineEndings by severity(Severity.WARNING)
  var missingFinalNewline by severity(Severity.WARNING)
  var tabsInIndentation by severity(Severity.OFF)
  var lineTooLong by severity(Severity.OFF)
}
