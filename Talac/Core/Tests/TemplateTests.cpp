// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <algorithm>
#include <atomic>
#include <thread>
#include <vector>

#include "Progmasoft/Tala/Core/CorePrep/Verifier.hpp"
#include "Progmasoft/Tala/Core/CorePrep/Wire.hpp"
#include "Progmasoft/Tala/Core/Scalar.hpp"
#include "Progmasoft/Tala/Core/Template.hpp"
#include "Progmasoft/Tala/Core/Verifier.hpp"
#include "Progmasoft/Tala/Core/Wire.hpp"

namespace
{
    namespace Model = ::tala::core;
    namespace Template = Progmasoft::Tala::Core::Template;
    namespace Core = Progmasoft::Tala::Core;
    namespace CorePrepWire = ::tala::core::wire;

    [[nodiscard]] auto
    Integer(const std::int64_t value) -> Model::IntegerLiteral
    {
        return Model::integer_from_signed(value);
    }

    [[nodiscard]] auto
    TypeArgument(Model::Type value) -> Model::TemplateArgument
    {
        return Model::TemplateArgument::type_argument(std::move(value));
    }

    [[nodiscard]] auto
    IntegerArgument(const std::int64_t value) -> Model::TemplateArgument
    {
        return Model::TemplateArgument::value_argument(
            Model::TemplateValue::integer_value(Integer(value)));
    }

    [[nodiscard]] auto
    BooleanArgument(const bool value) -> Model::TemplateArgument
    {
        return Model::TemplateArgument::value_argument(
            Model::TemplateValue::boolean_value(value));
    }

    [[nodiscard]] auto
    CharacterArgument(const std::uint32_t value) -> Model::TemplateArgument
    {
        return Model::TemplateArgument::value_argument(
            Model::TemplateValue::character_value(
                Model::integer_from_unsigned(value)));
    }

    [[nodiscard]] auto
    Parameter(const Model::SymbolId id, std::u32string spelling)
        -> Model::SymbolName
    {
        return Model::SymbolName{ id, std::move(spelling) };
    }

    [[nodiscard]] auto
    ValueParameterArgument(const Model::SymbolId id, std::u32string spelling)
        -> Model::TemplateArgument
    {
        return Model::TemplateArgument::value_argument(
            Model::TemplateValue::parameter_value(
                Parameter(id, std::move(spelling))));
    }

    [[nodiscard]] auto
    Applied(std::u32string name, std::vector<Model::TemplateArgument> arguments)
        -> Model::Type
    {
        return Model::Type::named_template({ std::move(name) },
                                           std::move(arguments));
    }

    [[nodiscard]] auto
    SystemArray(std::vector<Model::TemplateArgument> arguments) -> Model::Type
    {
        return Model::Type::named_template({ U"System", U"Array" },
                                           std::move(arguments));
    }

    [[nodiscard]] auto
    BuiltinArray(Model::Type element) -> Model::Type
    {
        return Model::Type::named_template(
            { U"[]" },
            { TypeArgument(std::move(element)) });
    }

    [[nodiscard]] auto
    DynamicArray(Model::Type element) -> Model::Type
    {
        return SystemArray({ TypeArgument(std::move(element)) });
    }

    [[nodiscard]] auto
    FixedArray(Model::Type element, const std::int64_t size) -> Model::Type
    {
        return SystemArray(
            { TypeArgument(std::move(element)), IntegerArgument(size) });
    }

    [[nodiscard]] auto
    HasIssue(const std::vector<Template::Issue> &issues,
             const Template::IssueKind kind) -> bool
    {
        return std::ranges::any_of(issues, [kind](const auto &issue) {
            return issue.kind == kind;
        });
    }

    [[nodiscard]] auto
    CoreModuleWithType(Model::Type type) -> Core::Module
    {
        return Core::Module{
            { U"Template" },
            { Core::Function{ { 1U, U"Value" }, {}, std::move(type), {} } }
        };
    }

    [[nodiscard]] auto
    CorePrepModuleWithType(Model::Type type) -> Model::CorePrepModule
    {
        Model::Block block;
        block.id = 0U;
        block.terminator.kind = Model::Terminator::Kind::Return;
        block.terminator.value
            = Model::Atom::constant(std::monostate{}, Model::Type::unit());
        return Model::CorePrepModule{ { U"Template" },
                                      { Model::Function{
                                          { 1U, U"Value" },
                                          {},
                                          std::move(type),
                                          0U,
                                          { std::move(block) } } } };
    }
} // namespace

TEST_CASE("array families retain distinct structural shapes")
{
    const auto builtin
        = Template::ClassifyArray(BuiltinArray(Model::Type::int64()));
    REQUIRE(builtin);
    CHECK(builtin->kind == Template::ArrayShape::Kind::Builtin);
    CHECK(builtin->element == Model::Type::int64());
    CHECK_FALSE(builtin->size);

    const auto dynamic
        = Template::ClassifyArray(DynamicArray(Model::Type::string()));
    REQUIRE(dynamic);
    CHECK(dynamic->kind == Template::ArrayShape::Kind::Dynamic);
    CHECK(dynamic->element == Model::Type::string());
    CHECK_FALSE(dynamic->size);

    const auto fixed
        = Template::ClassifyArray(FixedArray(Model::Type::int32(), 128));
    REQUIRE(fixed);
    CHECK(fixed->kind == Template::ArrayShape::Kind::Fixed);
    CHECK(fixed->element == Model::Type::int32());
    REQUIRE(fixed->size);
    CHECK(*fixed->size == Integer(128));
}

TEST_CASE("malformed array families do not masquerade as valid shapes")
{
    CHECK_FALSE(Template::ClassifyArray(
        Model::Type::named({ U"Array" }, { Model::Type::int64() })));
    CHECK_FALSE(Template::ClassifyArray(SystemArray({})));
    CHECK_FALSE(Template::ClassifyArray(SystemArray({ IntegerArgument(4) })));
    CHECK_FALSE(Template::ClassifyArray(SystemArray(
        { TypeArgument(Model::Type::int64()), BooleanArgument(true) })));
    CHECK_FALSE(Template::ClassifyArray(
        SystemArray({ TypeArgument(Model::Type::int64()),
                      IntegerArgument(4),
                      IntegerArgument(5) })));
    CHECK_FALSE(Template::ClassifyArray(Model::Type::named_template(
        { U"[]" },
        { TypeArgument(Model::Type::int64()), IntegerArgument(4) })));
}

TEST_CASE("template validation accepts portable concrete identities")
{
    const auto nested = Applied(
        U"Outer",
        { TypeArgument(DynamicArray(FixedArray(Model::Type::int64(), 16))),
          BooleanArgument(false),
          CharacterArgument(0x10ffffU) });
    CHECK(Template::Validate(nested).empty());
    CHECK(Template::IsConcrete(nested));
}

TEST_CASE("template validation reports qualified-name failures with paths")
{
    const auto emptyName = Model::Type::named_template({}, {});
    const auto emptyPart = Model::Type::named_template({ U"System", U"" }, {});
    const auto first = Template::Validate(emptyName);
    const auto second = Template::Validate(emptyPart);

    REQUIRE(first.size() == 1U);
    CHECK(first.front().kind == Template::IssueKind::EmptyQualifiedName);
    CHECK(first.front().path.empty());
    REQUIRE(second.size() == 1U);
    CHECK(second.front().kind == Template::IssueKind::EmptyNamePart);
    CHECK(second.front().path == std::vector<std::size_t>{ 1U });
}

TEST_CASE("template validation checks recursive type payloads")
{
    Model::TemplateArgument missing;
    missing.kind = Model::TemplateArgument::Kind::Type;
    missing.type.reset();
    const auto missingType = Applied(U"Box", { missing });
    CHECK(HasIssue(Template::Validate(missingType),
                   Template::IssueKind::InvalidTypeArgument));

    auto namedWithComponents = Applied(U"Box", {});
    namedWithComponents.components.push_back(Model::Type::int64());
    CHECK(HasIssue(Template::Validate(namedWithComponents),
                   Template::IssueKind::InvalidTypeArgument));

    auto scalarWithArguments = Model::Type::int64();
    scalarWithArguments.templateArguments.push_back(IntegerArgument(4));
    CHECK(HasIssue(Template::Validate(scalarWithArguments),
                   Template::IssueKind::InvalidTypeArgument));

    CHECK(Template::Validate(Model::Type::int64(), 0U).empty());
    CHECK(HasIssue(Template::Validate(
                       Applied(U"Box", { TypeArgument(Model::Type::int64()) }),
                       0U),
                   Template::IssueKind::DepthExceeded));
    CHECK(Template::Validate(
              Applied(U"Box", { TypeArgument(Model::Type::int64()) }),
              1U)
              .empty());
}

TEST_CASE("template validation checks value payloads")
{
    const auto badInteger = Model::IntegerLiteral{ true, {} };
    const auto integerType
        = Applied(U"Value",
                  { Model::TemplateArgument::value_argument(
                      Model::TemplateValue::integer_value(badInteger)) });
    CHECK(HasIssue(Template::Validate(integerType),
                   Template::IssueKind::InvalidInteger));

    const auto surrogate = Applied(U"Code", { CharacterArgument(0xd800U) });
    const auto aboveRange = Applied(U"Code", { CharacterArgument(0x110000U) });
    CHECK(HasIssue(Template::Validate(surrogate),
                   Template::IssueKind::InvalidCharacter));
    CHECK(HasIssue(Template::Validate(aboveRange),
                   Template::IssueKind::InvalidCharacter));

    const auto zeroParameter
        = Applied(U"Buffer", { ValueParameterArgument(0U, U"N") });
    const auto emptyParameter
        = Applied(U"Buffer", { ValueParameterArgument(1U, U"") });
    CHECK(HasIssue(Template::Validate(zeroParameter),
                   Template::IssueKind::InvalidValueParameter));
    CHECK(HasIssue(Template::Validate(emptyParameter),
                   Template::IssueKind::InvalidValueParameter));
}

TEST_CASE("System.Array overload validation is exact")
{
    CHECK(Template::Validate(DynamicArray(Model::Type::int64())).empty());
    CHECK(Template::Validate(FixedArray(Model::Type::int64(), 0)).empty());
    CHECK(Template::Validate(FixedArray(Model::Type::int64(), 4096)).empty());
    CHECK(HasIssue(Template::Validate(FixedArray(Model::Type::int64(), -1)),
                   Template::IssueKind::NegativeArraySize));
    CHECK(HasIssue(Template::Validate(SystemArray({})),
                   Template::IssueKind::MalformedArrayFamily));
    CHECK(HasIssue(
        Template::Validate(SystemArray({ TypeArgument(Model::Type::int64()),
                                         TypeArgument(Model::Type::int32()) })),
        Template::IssueKind::MalformedArrayFamily));
    CHECK(
        HasIssue(Template::Validate(Model::Type::named_template({ U"[]" }, {})),
                 Template::IssueKind::MalformedArrayFamily));
}

TEST_CASE("Core and CorePrep verifiers enforce specialization structure")
{
    const auto malformed = FixedArray(Model::Type::int64(), -1);
    const auto coreIssues = Core::Verify(CoreModuleWithType(malformed));
    const auto corePrepIssues
        = Model::verify(CorePrepModuleWithType(malformed));

    CHECK(std::ranges::any_of(coreIssues, [](const auto &issue) {
        return issue.code == "TAC1040";
    }));
    CHECK(std::ranges::any_of(corePrepIssues, [](const auto &issue) {
        return issue.code == "TAC1052";
    }));
}

TEST_CASE("template metrics describe mixed recursive identities")
{
    const auto typeParameter = Model::Type::type_variable(Parameter(10U, U"T"));
    const auto valueParameter = ValueParameterArgument(20U, U"N");
    const auto genericArray
        = SystemArray({ TypeArgument(typeParameter), valueParameter });
    const auto function = Model::Type::function({ genericArray, typeParameter },
                                                Model::Type::boolean());
    const auto metrics = Template::Measure(function);

    CHECK(metrics.typeNodes == 5U);
    CHECK(metrics.typeArguments == 1U);
    CHECK(metrics.valueArguments == 1U);
    CHECK(metrics.parameterReferences == 3U);
    CHECK(metrics.maximumDepth == 2U);
}

TEST_CASE("parameter collection is sorted and deduplicated")
{
    const auto first = Model::Type::type_variable(Parameter(40U, U"T"));
    const auto second = Model::Type::type_variable(Parameter(10U, U"U"));
    const auto value = Applied(U"Value", { ValueParameterArgument(30U, U"N") });
    const auto function
        = Model::Type::function({ first, second, first }, value);

    CHECK(Template::CollectParameters(function)
          == std::vector<Model::SymbolId>{ 10U, 30U, 40U });
    CHECK_FALSE(Template::IsConcrete(function));
    CHECK(Template::CollectParameters(FixedArray(Model::Type::int64(), 4))
              .empty());
    CHECK(Template::IsConcrete(FixedArray(Model::Type::int64(), 4)));
}

TEST_CASE("substitution handles type and value parameters independently")
{
    const auto typeName = Parameter(10U, U"T");
    const auto sizeName = Parameter(20U, U"N");
    const auto generic
        = SystemArray({ TypeArgument(Model::Type::type_variable(typeName)),
                        Model::TemplateArgument::value_argument(
                            Model::TemplateValue::parameter_value(sizeName)) });
    const Template::TypeBindingMap types{ { 10U, Model::Type::string() } };
    const Template::ValueBindingMap values{
        { 20U, Model::TemplateValue::integer_value(Integer(32)) }
    };

    CHECK(Template::Substitute(generic, types, values)
          == FixedArray(Model::Type::string(), 32));
    CHECK(Template::Substitute(generic, types, {})
          == SystemArray({ TypeArgument(Model::Type::string()),
                           ValueParameterArgument(20U, U"N") }));
    CHECK(Template::Substitute(generic, {}, values)
          == SystemArray({ TypeArgument(Model::Type::type_variable(typeName)),
                           IntegerArgument(32) }));
    CHECK(Template::Substitute(Model::Type::int64(), types, values)
          == Model::Type::int64());
}

TEST_CASE("substitution descends through callable signatures")
{
    const auto typeParameter = Model::Type::type_variable(Parameter(10U, U"T"));
    const auto genericArray = SystemArray(
        { TypeArgument(typeParameter), ValueParameterArgument(20U, U"N") });
    const auto genericFunction
        = Model::Type::function({ genericArray, typeParameter }, typeParameter);
    const Template::TypeBindingMap types{ { 10U, Model::Type::string() } };
    const Template::ValueBindingMap values{
        { 20U, Model::TemplateValue::integer_value(Integer(8)) }
    };
    const auto expected = Model::Type::function(
        { FixedArray(Model::Type::string(), 8), Model::Type::string() },
        Model::Type::string());

    CHECK(Template::Substitute(genericFunction, types, values) == expected);
}

TEST_CASE("rendered identity distinguishes every specialization dimension")
{
    const auto dynamic = DynamicArray(Model::Type::int64());
    const auto fixedFour = FixedArray(Model::Type::int64(), 4);
    const auto fixedFive = FixedArray(Model::Type::int64(), 5);
    const auto valueType = Applied(U"Box", { IntegerArgument(4) });
    const auto typeType
        = Applied(U"Box", { TypeArgument(Model::Type::int32()) });
    const auto ordered
        = Applied(U"Mix",
                  { TypeArgument(Model::Type::int32()), IntegerArgument(4) });
    const auto reversed
        = Applied(U"Mix",
                  { IntegerArgument(4), TypeArgument(Model::Type::int32()) });

    CHECK(Template::RenderIdentity(dynamic)
          != Template::RenderIdentity(fixedFour));
    CHECK(Template::RenderIdentity(fixedFour)
          != Template::RenderIdentity(fixedFive));
    CHECK(Template::RenderIdentity(valueType)
          != Template::RenderIdentity(typeType));
    CHECK(Template::RenderIdentity(ordered)
          != Template::RenderIdentity(reversed));
    CHECK(Template::RenderIdentity(Applied(U"Flag", { BooleanArgument(false) }))
          != Template::RenderIdentity(
              Applied(U"Flag", { BooleanArgument(true) })));
    CHECK(Template::RenderIdentity(Applied(U"Code", { IntegerArgument(65) }))
          != Template::RenderIdentity(
              Applied(U"Code", { CharacterArgument(65) })));
}

TEST_CASE("rendered identity length-prefixes qualified components")
{
    const auto oneComponent = Model::Type::named_template({ U"A.B" }, {});
    const auto twoComponents = Model::Type::named_template({ U"A", U"B" }, {});
    const auto first = Template::RenderIdentity(oneComponent);
    const auto second = Template::RenderIdentity(twoComponents);

    CHECK(first != second);
    CHECK(first.find("3:") != std::string::npos);
    CHECK(second.find("1:") != std::string::npos);
}

TEST_CASE("Core v10 preserves ordered template arguments and source ownership")
{
    const auto type = Applied(U"Mix",
                              { TypeArgument(Model::Type::string()),
                                IntegerArgument(-17),
                                BooleanArgument(true),
                                CharacterArgument(0x1f642U),
                                ValueParameterArgument(20U, U"N") });
    const auto module = CoreModuleWithType(type);
    const auto encoded = Core::Wire::Encode(module);
    REQUIRE(encoded);
    const auto decoded = Core::Wire::Decode(encoded.bytes);
    REQUIRE(decoded);
    CHECK(*decoded.module == module);
    CHECK(Core::Wire::kCurrentVersion == 10U);
}

TEST_CASE(
    "CorePrep v7 preserves ordered template arguments and source ownership")
{
    const auto type = Applied(U"Mix",
                              { TypeArgument(Model::Type::string()),
                                IntegerArgument(-17),
                                BooleanArgument(true),
                                CharacterArgument(0x1f642U),
                                ValueParameterArgument(20U, U"N") });
    const auto module = CorePrepModuleWithType(type);
    const auto encoded = CorePrepWire::encode(module);
    REQUIRE(encoded);
    const auto decoded = CorePrepWire::decode(encoded.bytes);
    REQUIRE(decoded);
    CHECK(*decoded.module == module);
    CHECK(CorePrepWire::current_version == 8U);
}

TEST_CASE("specialization table interns identical types once")
{
    Template::SpecializationTable table;
    const auto first = table.Intern(FixedArray(Model::Type::int64(), 4));
    const auto second = table.Intern(FixedArray(Model::Type::int64(), 4));

    REQUIRE(first);
    REQUIRE(second);
    CHECK(first.inserted);
    CHECK_FALSE(second.inserted);
    CHECK(first.specialization->id == 1U);
    CHECK(second.specialization->id == first.specialization->id);
    CHECK(table.Size() == 1U);
    CHECK(table.Find(1U) == first.specialization);
    CHECK_FALSE(table.Find(0U));
    CHECK_FALSE(table.Find(2U));
}

TEST_CASE("specialization table allocates stable insertion-order ids")
{
    Template::SpecializationTable table;
    const auto four = table.Intern(FixedArray(Model::Type::int64(), 4));
    const auto five = table.Intern(FixedArray(Model::Type::int64(), 5));
    const auto dynamic = table.Intern(DynamicArray(Model::Type::int64()));

    REQUIRE(four);
    REQUIRE(five);
    REQUIRE(dynamic);
    CHECK(four.specialization->id == 1U);
    CHECK(five.specialization->id == 2U);
    CHECK(dynamic.specialization->id == 3U);
    CHECK(table.Snapshot()
          == std::vector<Template::Specialization>{ *four.specialization,
                                                    *five.specialization,
                                                    *dynamic.specialization });
}

TEST_CASE("specialization table rejects malformed and generic types")
{
    Template::SpecializationTable table;
    const auto malformed = table.Intern(SystemArray({}));
    const auto generic
        = table.Intern(Model::Type::type_variable(Parameter(10U, U"T")));

    CHECK_FALSE(malformed);
    CHECK(
        HasIssue(malformed.issues, Template::IssueKind::MalformedArrayFamily));
    CHECK_FALSE(generic);
    CHECK_FALSE(generic.issues.empty());
    CHECK(table.Size() == 0U);
}

TEST_CASE("specialization table coalesces concurrent insertion races")
{
    Template::SpecializationTable table;
    constexpr std::size_t kWorkerCount = 12U;
    std::atomic<std::size_t> successful{};
    std::atomic<std::size_t> inserted{};
    std::vector<std::thread> workers;
    workers.reserve(kWorkerCount);

    for (std::size_t index = 0; index < kWorkerCount; ++index)
    {
        workers.emplace_back([&] {
            const auto result
                = table.Intern(FixedArray(Model::Type::int64(), 64));
            if (result)
                ++successful;
            if (result.inserted)
                ++inserted;
        });
    }
    for (auto &worker : workers)
        worker.join();

    CHECK(successful == kWorkerCount);
    CHECK(inserted == 1U);
    CHECK(table.Size() == 1U);
    REQUIRE(table.Find(FixedArray(Model::Type::int64(), 64)));
    CHECK(table.Find(FixedArray(Model::Type::int64(), 64))->id == 1U);
}
