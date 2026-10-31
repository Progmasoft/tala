-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Public facade combining CorePrep wire encoding, decoding, and schema types.
The binary format is an internal compiler boundary and is not a user-facing
emission format.
-}
module Progmasoft.Tala.Core.CorePrep.Wire
    ( encodeCorePrep
    , encodeCorePrepWith
    , decodeCorePrep
    , decodeCorePrepWith
    , WireVersion (..)
    , currentWireVersion
    , WireLimits (..)
    , defaultWireLimits
    , WireErrorKind (..)
    , WireError (..)
    ) where

import Progmasoft.Tala.Core.CorePrep.Wire.Decode
import Progmasoft.Tala.Core.CorePrep.Wire.Encode
import Progmasoft.Tala.Core.CorePrep.Wire.Format
