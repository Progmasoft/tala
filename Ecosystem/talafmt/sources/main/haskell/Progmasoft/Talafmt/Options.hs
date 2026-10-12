-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

module Progmasoft.Talafmt.Options
    ( LineEnding (..)
    , FormatOptions (..)
    , defaultFormatOptions
    , validateFormatOptions
    ) where

data LineEnding = Auto | CrLf | Lf
    deriving (Bounded, Enum, Eq, Ord, Read, Show)

-- The Haskell engine mirrors the subset of talafmt.kts which already
-- has executable behavior. Keeping unsupported DSL keys out of this record is
-- intentional: accepting a setting and silently ignoring it is worse than
-- waiting until its layout pass exists.
data FormatOptions = FormatOptions
    { formatLineEnding :: LineEnding
    , formatTrimTrailingWhitespace :: Bool
    , formatInsertFinalNewline :: Bool
    , formatReindentBlocks :: Bool
    , formatIndentWidth :: Int
    , formatTabWidth :: Int
    , formatUseTabs :: Bool
    }
    deriving (Eq, Ord, Read, Show)

defaultFormatOptions :: FormatOptions
defaultFormatOptions =
    FormatOptions
        { formatLineEnding = Auto
        , formatTrimTrailingWhitespace = True
        , formatInsertFinalNewline = True
        , formatReindentBlocks = True
        , formatIndentWidth = 4
        , formatTabWidth = 4
        , formatUseTabs = False
        }

validateFormatOptions :: FormatOptions -> Maybe String
validateFormatOptions options
    | formatIndentWidth options <= 0 = Just "indent width must be a positive integer"
    | formatTabWidth options <= 0 = Just "tab width must be a positive integer"
    | otherwise = Nothing
