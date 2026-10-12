// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <Progmasoft/Catch3/Assertions.hpp>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "Progmasoft/Tala/Backend/LLVM.hpp"
#include "Progmasoft/Tala/Core/IR.hpp"
#include "Progmasoft/Tala/Core/Wire.hpp"
#include "Progmasoft/Tala/Pipeline.hpp"

// LLVM reserves every global name that begins with `llvm.` for intrinsics
// and rejects a module that defines one. `llvm` is an ordinary Tala
// namespace name, so the backend must give such functions a symbol outside
// the reserved prefix instead of failing module verification. Found by the
// source-to-LLVM fuzz campaign.

namespace
{
    namespace Core = Progmasoft::Tala::Core;
    namespace Llvm = Progmasoft::Tala::Backend::LLVM;
    namespace Pipeline = Progmasoft::Tala::Pipeline;

    [[nodiscard]] auto
    Constant(std::vector<std::u32string> moduleName, std::int64_t value)
        -> Core::Module
    {
        return {
            std::move(moduleName),
            { Core::Function{
                { 1U, U"Evaluate" },
                {},
                Core::Type::int64(),
                { Core::Statement::Return(
                    Core::Expression::Constant(value, Core::Type::int64())) },
            } }
        };
    }

    [[nodiscard]] auto
    Invoke(const Core::Module &module, std::string_view symbol) -> std::int64_t
    {
        const auto encoded = Core::Wire::Encode(module);
        REQUIRE(encoded);
        const auto pipeline = Pipeline::ConsumeCore(encoded.bytes);
        if (pipeline.llvm_error)
            FAIL_CHECK(pipeline.llvm_error->code
                       << ": " << pipeline.llvm_error->message);
        REQUIRE(pipeline);
        REQUIRE(pipeline.llvm);
        // LLVM quotes a global name that contains `$`.
        const auto quoted = "@\"" + std::string(symbol) + "\"(";
        const auto plain = "@" + std::string(symbol) + "(";
        CHECK((pipeline.llvm->llvm_ir.find(quoted) != std::string::npos
               || pipeline.llvm->llvm_ir.find(plain) != std::string::npos));

        Llvm::JitSession session;
        REQUIRE_FALSE(session.AddModule(pipeline.llvm->bitcode,
                                        "reserved-symbol",
                                        symbol,
                                        Core::Type::int64()));
        const auto result = session.InvokeScalar(symbol, Core::Type::int64());
        REQUIRE(result);
        return std::get<std::int64_t>(result.value->payload);
    }
} // namespace

TEST_CASE("functions in a namespace named llvm leave the intrinsic prefix",
          "[llvm][symbols]")
{
    CHECK(Invoke(Constant({ U"llvm" }, 11), "$llvm.Evaluate.1") == 11);
    CHECK(Invoke(Constant({ U"llvm", U"Fuzz" }, 12), "$llvm.Fuzz.Evaluate.1")
          == 12);
}

TEST_CASE("namespaces that merely resemble the intrinsic prefix are unchanged",
          "[llvm][symbols]")
{
    CHECK(Invoke(Constant({ U"llvmx" }, 21), "llvmx.Evaluate.1") == 21);
    CHECK(Invoke(Constant({ U"Llvm" }, 22), "Llvm.Evaluate.1") == 22);
    CHECK(Invoke(Constant({ U"Demo", U"llvm" }, 23), "Demo.llvm.Evaluate.1")
          == 23);
}
