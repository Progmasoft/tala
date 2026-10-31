// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include "Progmasoft/Tala/Core/IR.hpp"

namespace Progmasoft::Tala::Core
{
    auto
    Capture::operator==(const Capture &other) const -> bool
    {
        const auto equalValue
            = (!value && !other.value)
              || (value && other.value && *value == *other.value);
        return mode == other.mode && symbol == other.symbol
               && type == other.type && equalValue;
    }

    Expression::~Expression()
    {
        if (operands.empty())
            return;
        std::vector<Expression> pending = std::move(operands);
        while (!pending.empty())
        {
            // The operands of the expression taken from the list join the
            // list, so that it is released without any of its own.
            Expression next = std::move(pending.back());
            pending.pop_back();
            for (auto &operand : next.operands)
                pending.push_back(std::move(operand));
            next.operands.clear();
        }
    }

    Statement::~Statement()
    {
        if (trueBranch.empty() && falseBranch.empty() && loopBody.empty()
            && loopUpdate.empty())
            return;
        std::vector<Statement> pending;
        const auto take = [&pending](std::vector<Statement> &statements) {
            for (auto &statement : statements)
                pending.push_back(std::move(statement));
            statements.clear();
        };
        take(trueBranch);
        take(falseBranch);
        take(loopBody);
        take(loopUpdate);
        while (!pending.empty())
        {
            Statement next = std::move(pending.back());
            pending.pop_back();
            take(next.trueBranch);
            take(next.falseBranch);
            take(next.loopBody);
            take(next.loopUpdate);
        }
    }

    auto
    Expression::Variable(SymbolName name, Type valueType) -> Expression
    {
        Expression expression;
        expression.kind = Kind::Variable;
        expression.type = std::move(valueType);
        expression.symbol = std::move(name);
        return expression;
    }

    auto
    Expression::Constant(Literal value, Type valueType) -> Expression
    {
        Expression expression;
        expression.kind = Kind::Literal;
        expression.type = std::move(valueType);
        expression.literal = std::move(value);
        return expression;
    }

    auto
    Expression::Apply(Expression target,
                      std::vector<Expression> arguments,
                      Type resultType) -> Expression
    {
        Expression expression;
        expression.kind = Kind::Apply;
        expression.type = std::move(resultType);
        expression.callee = std::make_shared<Expression>(std::move(target));
        expression.operands = std::move(arguments);
        return expression;
    }

    auto
    Expression::InvokePrimitive(Core::Primitive operation,
                                std::vector<Expression> arguments,
                                Type resultType) -> Expression
    {
        Expression expression;
        expression.kind = Kind::Primitive;
        expression.type = std::move(resultType);
        expression.primitive = operation;
        expression.operands = std::move(arguments);
        return expression;
    }

    auto
    Expression::Closure(std::vector<Capture> captured,
                        std::vector<std::pair<SymbolName, Type>> parameters,
                        Type returnType,
                        std::vector<Statement> body,
                        Type valueType) -> Expression
    {
        Expression expression;
        expression.kind = Kind::Closure;
        expression.type = std::move(valueType);
        expression.captures = std::move(captured);
        expression.closureParameters = std::move(parameters);
        expression.closureReturnType = std::move(returnType);
        expression.closureBody
            = std::make_shared<std::vector<Statement>>(std::move(body));
        return expression;
    }

    auto
    Expression::Let(SymbolName name,
                    Type bindingType,
                    Expression value,
                    Expression body,
                    Type resultType) -> Expression
    {
        Expression expression;
        expression.kind = Kind::Let;
        expression.type = std::move(resultType);
        expression.letSymbol = std::move(name);
        expression.letType = std::move(bindingType);
        expression.letValue = std::make_shared<Expression>(std::move(value));
        expression.letBody = std::make_shared<Expression>(std::move(body));
        return expression;
    }

    auto
    Expression::Conditional(Expression test,
                            Expression whenTrue,
                            Expression whenFalse,
                            Type resultType) -> Expression
    {
        Expression expression;
        expression.kind = Kind::Conditional;
        expression.type = std::move(resultType);
        expression.operands.reserve(3U);
        expression.operands.push_back(std::move(test));
        expression.operands.push_back(std::move(whenTrue));
        expression.operands.push_back(std::move(whenFalse));
        return expression;
    }

    auto
    Expression::operator==(const Expression &other) const -> bool
    {
        const auto equalCallee
            = (!callee && !other.callee)
              || (callee && other.callee && *callee == *other.callee);
        const auto equalBody = (!closureBody && !other.closureBody)
                               || (closureBody && other.closureBody
                                   && *closureBody == *other.closureBody);
        const auto equalLetValue
            = (!letValue && !other.letValue)
              || (letValue && other.letValue && *letValue == *other.letValue);
        const auto equalLetBody
            = (!letBody && !other.letBody)
              || (letBody && other.letBody && *letBody == *other.letBody);
        return kind == other.kind && type == other.type
               && symbol == other.symbol && literal == other.literal
               && primitive == other.primitive && equalCallee
               && operands == other.operands && captures == other.captures
               && closureParameters == other.closureParameters
               && closureReturnType == other.closureReturnType && equalBody
               && letSymbol == other.letSymbol && letType == other.letType
               && equalLetValue && equalLetBody;
    }

    auto
    Statement::Bind(Binding value) -> Statement
    {
        Statement statement;
        statement.kind = Kind::Bind;
        statement.binding = std::move(value);
        return statement;
    }

    auto
    Statement::Assign(SymbolName target, Expression value) -> Statement
    {
        Statement statement;
        statement.kind = Kind::Assign;
        statement.destination = std::move(target);
        statement.expression = std::move(value);
        return statement;
    }

    auto
    Statement::Return(Expression value) -> Statement
    {
        Statement statement;
        statement.kind = Kind::Return;
        statement.expression = std::move(value);
        return statement;
    }

    auto
    Statement::If(Expression condition,
                  std::vector<Statement> whenTrue,
                  std::vector<Statement> whenFalse) -> Statement
    {
        Statement statement;
        statement.kind = Kind::If;
        statement.expression = std::move(condition);
        statement.trueBranch = std::move(whenTrue);
        statement.falseBranch = std::move(whenFalse);
        return statement;
    }

    auto
    Statement::Evaluate(Expression value) -> Statement
    {
        Statement statement;
        statement.kind = Kind::Evaluate;
        statement.expression = std::move(value);
        return statement;
    }

    auto
    Statement::While(Expression condition, std::vector<Statement> body)
        -> Statement
    {
        Statement statement;
        statement.kind = Kind::While;
        statement.expression = std::move(condition);
        statement.loopBody = std::move(body);
        return statement;
    }

    auto
    Statement::DoWhile(std::vector<Statement> body, Expression condition)
        -> Statement
    {
        Statement statement;
        statement.kind = Kind::DoWhile;
        statement.expression = std::move(condition);
        statement.loopBody = std::move(body);
        return statement;
    }

    auto
    Statement::For(Expression condition,
                   std::vector<Statement> body,
                   std::vector<Statement> update) -> Statement
    {
        Statement statement;
        statement.kind = Kind::For;
        statement.expression = std::move(condition);
        statement.loopBody = std::move(body);
        statement.loopUpdate = std::move(update);
        return statement;
    }

    auto
    Statement::Break() -> Statement
    {
        Statement statement;
        statement.kind = Kind::Break;
        return statement;
    }

    auto
    Statement::Continue() -> Statement
    {
        Statement statement;
        statement.kind = Kind::Continue;
        return statement;
    }
} // namespace Progmasoft::Tala::Core
