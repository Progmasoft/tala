// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1
#pragma once

#include "Progmasoft/Tala/Xpp/IR.hpp"

namespace Progmasoft::Tala::Xpp
{
    /**
     * @brief Make the ownership of AARC values explicit in an Xpp module.
     *
     * CorePrep names values and does not say who releases them. This pass
     * gives every AARC value one owner and writes the operations that keep
     * the reference counts balanced, in the vocabulary the ownership
     * verifiers of Xpp and Xmm check.
     *
     * The convention is the same in every function, so functions agree
     * without looking at each other:
     *
     * - a parameter is borrowed: the caller keeps it alive for the call;
     * - a result is owned: the caller receives one reference and releases
     *   it;
     * - a local owns the reference it holds, from the instruction that
     *   defines it to its last use on each path, where it is released;
     * - a copy of a value that is used again takes a reference of its own,
     *   and a copy of a value that is not used again takes over its
     *   reference;
     * - a closure takes its own reference to each strong capture when it is
     *   created, which its destructor releases.
     *
     * A value is released after its last use rather than at the end of a
     * source scope: Xpp has no scopes, and a value that is live at a point
     * has been defined on every path to it, so the release needs no test of
     * whether there is anything to release. Where a value dies on one edge
     * of a branch and lives on the other, the release stands on the edge,
     * in a block of its own when the target has other predecessors.
     *
     * A method that is used as a value, not called, is a closure without
     * captures. The pass creates that closure where the value is used,
     * because a method has no closure object of its own to point to.
     *
     * The pass runs once, on a module lowered from CorePrep. A module read
     * from an Xpp artifact already carries its ownership operations.
     *
     * @param module Xpp module lowered from CorePrep, without ownership
     * operations.
     * @return The module with explicit retains, releases and closures of
     * method values.
     */
    [[nodiscard]] auto
    PlaceOwnership(::tala::xpp::Module module) -> ::tala::xpp::Module;
} // namespace Progmasoft::Tala::Xpp
