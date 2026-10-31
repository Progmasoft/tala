// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include "Progmasoft/Tala/Pipeline.hpp"
#include "Progmasoft/Tala/Xpp/OwnershipPlacement.hpp"

namespace
{
    void
    ContinueFromXmm(tala::PipelineResult &result,
                    const tala::PipelineOptions &options)
    {
        // The caller stores the module before continuing; without one there
        // is nothing to verify or lower.
        if (!result.xmm)
            return;
        result.xmmVerificationIssues
            = Progmasoft::Tala::Xmm::Verify(*result.xmm);
        if (!result.xmmVerificationIssues.empty())
            return;
        if (options.stop_after == tala::PipelineStop::Xmm)
        {
            result.succeeded = true;
            return;
        }
        auto loweredLlvm
            = Progmasoft::Tala::Backend::LLVM::Lower(*result.xmm, options.llvm);
        if (!loweredLlvm)
        {
            result.llvm_error = std::move(loweredLlvm.error);
            return;
        }
        result.llvm = std::move(loweredLlvm.artifact);
        result.succeeded = true;
    }

    void
    ContinueFromXpp(tala::PipelineResult &result,
                    const tala::PipelineOptions &options)
    {
        if (!result.xpp)
            return;
        result.xppVerificationIssues
            = Progmasoft::Tala::Xpp::Verify(*result.xpp);
        if (!result.xppVerificationIssues.empty())
            return;
        if (options.stop_after == tala::PipelineStop::Xpp)
        {
            result.succeeded = true;
            return;
        }
        auto loweredXmm = ::tala::xmm::lower(*result.xpp);
        result.xmm = options.optimize_xmm
                         ? ::tala::xmm::optimize(std::move(loweredXmm))
                         : std::move(loweredXmm);
        ContinueFromXmm(result, options);
    }
} // namespace

namespace tala
{
    auto
    consume_coreprep(std::span<const std::uint8_t> bytes,
                     const PipelineOptions &options) -> PipelineResult
    {
        PipelineResult result;
        // Decode from bounded wire bytes even for in-process callers. A single
        // entry path keeps size/depth limits identical for files, Haskell
        // output and embedded hosts.
        auto decoded = core::wire::decode(bytes, options.wire_limits);
        if (!decoded)
        {
            result.wire_error = std::move(decoded.error);
            return result;
        }

        result.core_prep = std::move(decoded.module);
        // A successful decode always carries its module.
        if (!result.core_prep)
            return result;
        // Semantic verification precedes every lowering stage. Partial state is
        // retained in result, but no downstream IR is fabricated from an
        // invalid CorePrep module.
        result.verification_issues = core::verify(*result.core_prep);
        if (!result.verification_issues.empty())
            return result;

        auto lowered_xpp = xpp::lower(*result.core_prep);
        // Optimization toggles select identity-vs-optimized forms; they never
        // skip a stage. Xmm therefore receives the same typed Xpp contract in
        // debug and release modes. Ownership is placed last, on the form
        // that is kept: it is part of that contract in either mode.
        result.xpp = ::Progmasoft::Tala::Xpp::PlaceOwnership(
            options.optimize_xpp ? xpp::optimize(std::move(lowered_xpp))
                                 : std::move(lowered_xpp));
        ContinueFromXpp(result, options);
        return result;
    }
} // namespace tala

namespace Progmasoft::Tala::Pipeline
{
    auto
    ConsumeCore(std::span<const std::uint8_t> bytes, const Options &options)
        -> Result
    {
        Result result;
        auto decoded = Core::Wire::Decode(bytes, options.coreWireLimits);
        if (!decoded)
        {
            result.coreWireError = std::move(decoded.error);
            return result;
        }

        result.core = std::move(decoded.module);
        // A successful decode always carries its module.
        if (!result.core)
            return result;
        result.coreVerificationIssues = Core::Verify(*result.core);
        if (!result.coreVerificationIssues.empty())
            return result;

        // CorePrep remains an internal adapting stage. Re-encoding to TACP here
        // would add a redundant memory copy, so native Core input hands the
        // verified model directly to the existing CorePrep verifier and
        // post-CorePrep owners.
        result.core_prep = Core::CorePrep::Prepare(*result.core);
        result.verification_issues = ::tala::core::verify(*result.core_prep);
        if (!result.verification_issues.empty())
            return result;

        auto loweredXpp = ::tala::xpp::lower(*result.core_prep);
        // Ownership is placed once, here: an Xpp artifact read from disk
        // already carries its retains and releases.
        result.xpp = Xpp::PlaceOwnership(
            options.optimize_xpp ? ::tala::xpp::optimize(std::move(loweredXpp))
                                 : std::move(loweredXpp));
        ContinueFromXpp(result, options);
        return result;
    }

    auto
    ConsumeXpp(std::span<const std::uint8_t> bytes, const Options &options)
        -> Result
    {
        Result result;
        auto decoded = Xpp::Wire::Decode(bytes, options.artifactWireLimits);
        if (!decoded)
        {
            result.xppWireError = std::move(decoded.error);
            return result;
        }
        result.xpp = std::move(decoded.module);
        // A successful decode always carries its module.
        if (!result.xpp)
            return result;
        result.xppVerificationIssues = Xpp::Verify(*result.xpp);
        if (!result.xppVerificationIssues.empty())
            return result;
        if (options.optimize_xpp)
            result.xpp = ::tala::xpp::optimize(std::move(*result.xpp));
        ContinueFromXpp(result, options);
        return result;
    }

    auto
    ConsumeXmm(std::span<const std::uint8_t> bytes, const Options &options)
        -> Result
    {
        Result result;
        auto decoded = Xmm::Wire::Decode(bytes, options.artifactWireLimits);
        if (!decoded)
        {
            result.xmmWireError = std::move(decoded.error);
            return result;
        }
        result.xmm = std::move(decoded.module);
        // A successful decode always carries its module.
        if (!result.xmm)
            return result;
        if (options.stop_after == Stop::Xpp)
        {
            result.xmmWireError = Xmm::Wire::Error{
                Xmm::Wire::ErrorKind::InvalidModel,
                0U,
                "pipeline boundary",
                "Xmm input cannot move backward to Xpp",
            };
            return result;
        }
        result.xmmVerificationIssues = Xmm::Verify(*result.xmm);
        if (!result.xmmVerificationIssues.empty())
            return result;
        if (options.optimize_xmm)
            result.xmm = ::tala::xmm::optimize(std::move(*result.xmm));
        ContinueFromXmm(result, options);
        return result;
    }
} // namespace Progmasoft::Tala::Pipeline
