/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.talalint.config

class NamingScope : RuleGroupScope() {
  var namespacePascalCase by severity(Severity.WARNING)
  var typePascalCase by severity(Severity.WARNING)
  var methodPascalCase by severity(Severity.WARNING)
  var propertyPascalCase by severity(Severity.WARNING)
  var fieldCamelCase by severity(Severity.WARNING)
  var localCamelCase by severity(Severity.WARNING)
  var parameterCamelCase by severity(Severity.WARNING)
  var templateParameterPascalCase by severity(Severity.WARNING)
  var valueTemplateParameterCamelCase by severity(Severity.WARNING)
  var enumMemberUpperSnakeCase by severity(Severity.WARNING)
  var enumClassCasePascalCase by severity(Severity.WARNING)
  var constantUpperSnakeCase by severity(Severity.OFF)
  var booleanPrefix by severity(Severity.OFF)
  var avoidCaseOnlyCollision by severity(Severity.WARNING)
  var avoidKeywordLikeIdentifier by severity(Severity.WARNING)
  var disallowedNames: List<String> = emptyList()

  private val maximumIdentifierLengthScope = MaximumIdentifierLengthScope()
  private val minimumIdentifierLengthScope = MinimumIdentifierLengthScope()

  fun maximumIdentifierLength(block: MaximumIdentifierLengthScope.() -> Unit) =
    maximumIdentifierLengthScope.apply(block)

  fun minimumIdentifierLength(block: MinimumIdentifierLengthScope.() -> Unit) =
    minimumIdentifierLengthScope.apply(block)

  internal fun parameterizedRules() =
    mapOf(
      "naming.maximumIdentifierLength" to maximumIdentifierLengthScope.snapshot(),
      "naming.minimumIdentifierLength" to minimumIdentifierLengthScope.snapshot(),
    )
}

class ImportsScope : RuleGroupScope() {
  var unusedUsing by severity(Severity.WARNING)
  var duplicateUsing by severity(Severity.WARNING)
  var redundantSelectedImport by severity(Severity.WARNING)
  var redundantAlias by severity(Severity.WARNING)
  var ambiguousWildSurface by severity(Severity.WARNING)
  var systemImplicitRedundancy by severity(Severity.WARNING)
  var noImplicitSystemMismatch by severity(Severity.WARNING)
}

class VisibilityScope : RuleGroupScope() {
  var redundantInternal by severity(Severity.INFO)
  var publicApiExposesInternalType by severity(Severity.ERROR)
  var fileprivateApiEscape by severity(Severity.ERROR)
  var overlyBroadMember by severity(Severity.OFF)
  var publicMutableField by severity(Severity.WARNING)
  var privateMemberNeverUsed by severity(Severity.WARNING)
  var protectedMemberNeverUsed by severity(Severity.OFF)
}

class DeclarationsScope : RuleGroupScope() {
  var emptyType by severity(Severity.WARNING)
  var duplicateSemanticMember by severity(Severity.ERROR)
  var forwardDeclarationLikeForm by severity(Severity.WARNING)
  var partialKeyword by severity(Severity.WARNING)
  var abstractKeyword by severity(Severity.WARNING)
  var finalPrefix by severity(Severity.WARNING)
  var finalSealedConflict by severity(Severity.WARNING)
  var emptyPermits by severity(Severity.WARNING)
  var duplicatePermit by severity(Severity.WARNING)
  var unusedPermit by severity(Severity.WARNING)
  var unpermittedSubtype by severity(Severity.ERROR)
  var objectInheritance by severity(Severity.WARNING)
  var nestedObject by severity(Severity.WARNING)
  var topLevelStaticClass by severity(Severity.WARNING)
  var staticClassInstanceMember by severity(Severity.WARNING)
  var interfaceUsedAsRuntimeType by severity(Severity.WARNING)
  var interfaceState by severity(Severity.WARNING)
  var cowImplementsInterface by severity(Severity.WARNING)
  var typeHasConstructor by severity(Severity.WARNING)
  var typeHasInheritance by severity(Severity.WARNING)
  var enumAliasMatchArm by severity(Severity.WARNING)
  var enumCaseMemberCollision by severity(Severity.WARNING)
  var extensionField by severity(Severity.WARNING)
  var extensionSpecialMember by severity(Severity.WARNING)
  var extensionVirtualMember by severity(Severity.WARNING)
  var recursiveTypealias by severity(Severity.WARNING)
  var typealiasOverloadCollision by severity(Severity.WARNING)

  private val largeTypeBodyScope = LargeTypeBodyScope()
  private val tooManyParametersScope = TooManyParametersScope()

  fun largeTypeBody(block: LargeTypeBodyScope.() -> Unit) = largeTypeBodyScope.apply(block)

  fun tooManyParameters(block: TooManyParametersScope.() -> Unit) =
    tooManyParametersScope.apply(block)

  internal fun parameterizedRules() =
    mapOf(
      "declarations.largeTypeBody" to largeTypeBodyScope.snapshot(),
      "declarations.tooManyParameters" to tooManyParametersScope.snapshot(),
    )
}

class ModifiersScope : RuleGroupScope() {
  var noncanonicalOrder by severity(Severity.WARNING)
  var redundantStatic by severity(Severity.WARNING)
  var redundantFinal by severity(Severity.WARNING)
}

class OverrideScope : RuleGroupScope() {
  var missingOverride by severity(Severity.WARNING)
  var noBaseMember by severity(Severity.WARNING)
  var finalMember by severity(Severity.WARNING)
  var signatureDrift by severity(Severity.ERROR)
  var visibilityNarrowing by severity(Severity.WARNING)
  var checkedExceptionWidening by severity(Severity.WARNING)
  var noexceptWeakening by severity(Severity.WARNING)
}

class MembersScope : RuleGroupScope() {
  var unusedPrivateMethod by severity(Severity.WARNING)
  var unreadField by severity(Severity.WARNING)
  var unwrittenMutableField by severity(Severity.WARNING)
  var propertyBackingFieldExposure by severity(Severity.WARNING)
  var indexerInconsistentContract by severity(Severity.WARNING)
}

class BindingsScope : RuleGroupScope() {
  var unusedLocal by severity(Severity.WARNING)
  var unusedParameter by severity(Severity.WARNING)
  var unusedTemplateParameter by severity(Severity.WARNING)
  var unusedCapture by severity(Severity.WARNING)
  var unusedLoopBinding by severity(Severity.WARNING)
  var unusedCatchBinding by severity(Severity.WARNING)
  var shadowedLocal by severity(Severity.WARNING)
  var shadowedParameter by severity(Severity.WARNING)
  var shadowedMember by severity(Severity.WARNING)
  var shadowedImport by severity(Severity.WARNING)
  var assignmentToFinal by severity(Severity.ERROR)
  var neverReassigned by severity(Severity.INFO)
  var writeOnlyAssignment by severity(Severity.WARNING)
  var selfBeforeInitialization by severity(Severity.ERROR)
  var laterMemberInInitializer by severity(Severity.WARNING)
  var loopBindingEscape by severity(Severity.WARNING)
  var discardedNamedValue by severity(Severity.WARNING)
}

class FunctionsScope : RuleGroupScope() {
  var unreachableCode by severity(Severity.WARNING)
  var missingReturnPath by severity(Severity.WARNING)
  var redundantReturn by severity(Severity.INFO)
  var implicitReturnClarity by severity(Severity.OFF)
  var ignoredResult by severity(Severity.WARNING)
  var explicitDiscardPreferred by severity(Severity.INFO)
  var discardUsedAsExpression by severity(Severity.WARNING)
  var defaultArgumentAmbiguity by severity(Severity.WARNING)
  var returnTypeOnlyOverload by severity(Severity.WARNING)
  var parameterLabelCollision by severity(Severity.WARNING)
  var unlabeledParameterClarity by severity(Severity.OFF)
}

class ConstructorsScope : RuleGroupScope() {
  var explicitShorthand by severity(Severity.WARNING)
  var delegationNotFirst by severity(Severity.WARNING)
  var multipleDelegation by severity(Severity.WARNING)
  var delegationCycle by severity(Severity.WARNING)
  var missingBaseConstructor by severity(Severity.WARNING)
  var parameterDisablesAutoAssignment by severity(Severity.WARNING)
  var overridableCallDuringInitialization by severity(Severity.WARNING)
}

class DestructorsScope : RuleGroupScope() {
  var throwingDestructor by severity(Severity.WARNING)
}

class EntryScope : RuleGroupScope() {
  var topLevelFunction by severity(Severity.WARNING)
  var classNotFound by severity(Severity.ERROR)
  var missingMain by severity(Severity.ERROR)
  var invalidMainSignature by severity(Severity.ERROR)
  var multipleCandidates by severity(Severity.ERROR)
}
