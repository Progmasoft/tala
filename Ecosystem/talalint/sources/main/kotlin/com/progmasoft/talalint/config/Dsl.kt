/*
 * SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
 * SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
 */

package com.progmasoft.talalint.config

/**
 * Typed state intended for a future `talalint.kts` script template.
 *
 * The scope owns defaults, validation, and immutable snapshots only. It deliberately does not
 * discover, compile, load, or execute Kotlin scripts; those responsibilities belong to the later
 * evaluator layer.
 */
@LinterDsl
class LinterScope {
  private val fixesScope = FixesScope()
  private val analysisScope = AnalysisScope()
  private val rulesScope = RulesScope()
  private val suppressionsScope = SuppressionsScope()
  private val baselineScope = BaselineScope()
  private val namingScope = NamingScope()
  private val importsScope = ImportsScope()
  private val visibilityScope = VisibilityScope()
  private val declarationsScope = DeclarationsScope()
  private val modifiersScope = ModifiersScope()
  private val overrideScope = OverrideScope()
  private val membersScope = MembersScope()
  private val bindingsScope = BindingsScope()
  private val functionsScope = FunctionsScope()
  private val constructorsScope = ConstructorsScope()
  private val destructorsScope = DestructorsScope()
  private val entryScope = EntryScope()
  private val expressionsScope = ExpressionsScope()
  private val controlScope = ControlScope()
  private val exceptionsScope = ExceptionsScope()
  private val optionalScope = OptionalScope()
  private val ownershipScope = OwnershipScope()
  private val closuresScope = ClosuresScope()
  private val generatorsScope = GeneratorsScope()
  private val iterationScope = IterationScope()
  private val collectionsScope = CollectionsScope()
  private val blinqScope = BlinqScope()
  private val textScope = TextScope()
  private val commentsScope = CommentsScope()
  private val attributesScope = AttributesScope()
  private val operatorsScope = OperatorsScope()
  private val unsafeScope = UnsafeScope()
  private val ffiScope = FfiScope()
  private val asmScope = AsmScope()
  private val directivesScope = DirectivesScope()
  private val performanceScope = PerformanceScope()
  private val concurrencyScope = ConcurrencyScope()
  private val ioScope = IoScope()
  private val commandScope = CommandScope()
  private val databaseScope = DatabaseScope()
  private val apiScope = ApiScope()
  private val maintenanceScope = MaintenanceScope()
  private val formatScope = FormatScope()

  var version: String = "latest"
  var defaultSeverity: Severity = Severity.WARNING
  var maxDiagnostics: Int = 0
  var diagnosticOrder: DiagnosticOrder = DiagnosticOrder.SOURCE
  var showRuleId: Boolean = true
  var showExplanationUrl: Boolean = true

  fun fixes(block: FixesScope.() -> Unit) = fixesScope.apply(block)

  fun analysis(block: AnalysisScope.() -> Unit) = analysisScope.apply(block)

  fun rules(block: RulesScope.() -> Unit) = rulesScope.apply(block)

  fun suppressions(block: SuppressionsScope.() -> Unit) = suppressionsScope.apply(block)

  fun baseline(block: BaselineScope.() -> Unit) = baselineScope.apply(block)

  fun naming(block: NamingScope.() -> Unit) = namingScope.apply(block)

  fun imports(block: ImportsScope.() -> Unit) = importsScope.apply(block)

  fun visibility(block: VisibilityScope.() -> Unit) = visibilityScope.apply(block)

  fun declarations(block: DeclarationsScope.() -> Unit) = declarationsScope.apply(block)

  fun modifiers(block: ModifiersScope.() -> Unit) = modifiersScope.apply(block)

  fun `override`(block: OverrideScope.() -> Unit) = overrideScope.apply(block)

  fun members(block: MembersScope.() -> Unit) = membersScope.apply(block)

  fun bindings(block: BindingsScope.() -> Unit) = bindingsScope.apply(block)

  fun functions(block: FunctionsScope.() -> Unit) = functionsScope.apply(block)

  fun constructors(block: ConstructorsScope.() -> Unit) = constructorsScope.apply(block)

  fun destructors(block: DestructorsScope.() -> Unit) = destructorsScope.apply(block)

  fun entry(block: EntryScope.() -> Unit) = entryScope.apply(block)

  fun expressions(block: ExpressionsScope.() -> Unit) = expressionsScope.apply(block)

  fun control(block: ControlScope.() -> Unit) = controlScope.apply(block)

  fun exceptions(block: ExceptionsScope.() -> Unit) = exceptionsScope.apply(block)

  fun optional(block: OptionalScope.() -> Unit) = optionalScope.apply(block)

  fun ownership(block: OwnershipScope.() -> Unit) = ownershipScope.apply(block)

  fun closures(block: ClosuresScope.() -> Unit) = closuresScope.apply(block)

  fun generators(block: GeneratorsScope.() -> Unit) = generatorsScope.apply(block)

  fun iteration(block: IterationScope.() -> Unit) = iterationScope.apply(block)

  fun collections(block: CollectionsScope.() -> Unit) = collectionsScope.apply(block)

  fun blinq(block: BlinqScope.() -> Unit) = blinqScope.apply(block)

  fun text(block: TextScope.() -> Unit) = textScope.apply(block)

  fun comments(block: CommentsScope.() -> Unit) = commentsScope.apply(block)

  fun attributes(block: AttributesScope.() -> Unit) = attributesScope.apply(block)

  fun operators(block: OperatorsScope.() -> Unit) = operatorsScope.apply(block)

  fun unsafe(block: UnsafeScope.() -> Unit) = unsafeScope.apply(block)

  fun ffi(block: FfiScope.() -> Unit) = ffiScope.apply(block)

  fun asm(block: AsmScope.() -> Unit) = asmScope.apply(block)

  fun directives(block: DirectivesScope.() -> Unit) = directivesScope.apply(block)

  fun performance(block: PerformanceScope.() -> Unit) = performanceScope.apply(block)

  fun concurrency(block: ConcurrencyScope.() -> Unit) = concurrencyScope.apply(block)

  fun io(block: IoScope.() -> Unit) = ioScope.apply(block)

  fun command(block: CommandScope.() -> Unit) = commandScope.apply(block)

  fun database(block: DatabaseScope.() -> Unit) = databaseScope.apply(block)

  fun api(block: ApiScope.() -> Unit) = apiScope.apply(block)

  fun maintenance(block: MaintenanceScope.() -> Unit) = maintenanceScope.apply(block)

  fun format(block: FormatScope.() -> Unit) = formatScope.apply(block)

  fun build(): LinterConfiguration {
    if (maxDiagnostics < 0) {
      throw LinterConfigurationException("maxDiagnostics must be zero or a positive integer")
    }
    return LinterConfiguration(
      validateLinterVersion(version),
      defaultSeverity,
      maxDiagnostics,
      diagnosticOrder,
      showRuleId,
      showExplanationUrl,
      fixesScope.snapshot(),
      analysisScope.snapshot(),
      rulesScope.snapshot(),
      suppressionsScope.snapshot(),
      baselineScope.snapshot(),
      snapshotRuleGroups(),
      namingScope.parameterizedRules() +
        declarationsScope.parameterizedRules() +
        maintenanceScope.parameterizedRules(),
      mapOf("naming.disallowedNames" to namingScope.disallowedNames.toList()),
    )
  }

  private fun snapshotRuleGroups(): Map<String, RuleGroupConfiguration> =
    linkedMapOf(
      "naming" to namingScope.snapshot(),
      "imports" to importsScope.snapshot(),
      "visibility" to visibilityScope.snapshot(),
      "declarations" to declarationsScope.snapshot(),
      "modifiers" to modifiersScope.snapshot(),
      "override" to overrideScope.snapshot(),
      "members" to membersScope.snapshot(),
      "bindings" to bindingsScope.snapshot(),
      "functions" to functionsScope.snapshot(),
      "constructors" to constructorsScope.snapshot(),
      "destructors" to destructorsScope.snapshot(),
      "entry" to entryScope.snapshot(),
      "expressions" to expressionsScope.snapshot(),
      "control" to controlScope.snapshot(),
      "exceptions" to exceptionsScope.snapshot(),
      "optional" to optionalScope.snapshot(),
      "ownership" to ownershipScope.snapshot(),
      "closures" to closuresScope.snapshot(),
      "generators" to generatorsScope.snapshot(),
      "iteration" to iterationScope.snapshot(),
      "collections" to collectionsScope.snapshot(),
      "blinq" to blinqScope.snapshot(),
      "text" to textScope.snapshot(),
      "comments" to commentsScope.snapshot(),
      "attributes" to attributesScope.snapshot(),
      "operators" to operatorsScope.snapshot(),
      "unsafe" to unsafeScope.snapshot(),
      "ffi" to ffiScope.snapshot(),
      "asm" to asmScope.snapshot(),
      "directives" to directivesScope.snapshot(),
      "performance" to performanceScope.snapshot(),
      "concurrency" to concurrencyScope.snapshot(),
      "io" to ioScope.snapshot(),
      "command" to commandScope.snapshot(),
      "database" to databaseScope.snapshot(),
      "api" to apiScope.snapshot(),
      "maintenance" to maintenanceScope.snapshot(),
      "format" to formatScope.snapshot(),
    )
}

fun linterConfiguration(block: LinterScope.() -> Unit = {}): LinterConfiguration =
  LinterScope().apply(block).build()

private val semanticVersion =
  Regex("(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?")

internal fun validateLinterVersion(value: String): String {
  if (value == "latest" || semanticVersion.matches(value)) return value
  throw LinterConfigurationException("version must be 'latest' or a semantic version: $value")
}
