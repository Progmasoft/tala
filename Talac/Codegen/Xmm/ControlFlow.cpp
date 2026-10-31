// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <vector>

#include "Progmasoft/Tala/Xmm/ControlFlow.hpp"

namespace tala::xmm
{
    namespace
    {
        namespace Analysis = Progmasoft::Tala::Analysis;

        [[nodiscard]] auto
        Successors(const Terminator &terminator)
            -> std::vector<Analysis::ControlFlowBlockId>
        {
            switch (terminator.kind)
            {
                case Terminator::Kind::Branch:
                    return { terminator.true_target, terminator.false_target };
                case Terminator::Kind::Jump:
                    return { terminator.true_target };
                case Terminator::Kind::Return:
                case Terminator::Kind::Unreachable:
                    return {};
            }
            return {};
        }
    } // namespace

    auto
    AnalyzeControlStructure(const Function &function)
        -> Analysis::DominanceResult
    {
        Analysis::ControlFlowGraph graph;
        graph.entry = function.entry;
        graph.blocks.reserve(function.blocks.size());
        for (const auto &block : function.blocks)
            graph.blocks.push_back({ block.id, Successors(block.terminator) });
        return Analysis::AnalyzeDominance(graph);
    }
} // namespace tala::xmm
