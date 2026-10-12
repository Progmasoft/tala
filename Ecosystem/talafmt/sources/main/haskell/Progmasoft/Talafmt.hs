-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

-- | Syntax-validated, trivia-preserving Tala formatting.
module Progmasoft.Talafmt
    ( LineEnding (..)
    , FormatOptions (..)
    , FormatResult (..)
    , defaultFormatOptions
    , formatSource
    ) where

import Progmasoft.Talafmt.Layout
import Progmasoft.Talafmt.Options
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Frontend
import Progmasoft.Tala.SourceText

data FormatResult = FormatResult
    { formattedSource :: String
    , formattingChanged :: Bool
    }
    deriving (Eq, Ord, Read, Show)

formatSource :: FormatOptions -> CompilerInput -> Either [Diagnostic] FormatResult
formatSource options input = case validateFormatOptions options of
    Just message -> Left [formatterDiagnostic message]
    Nothing -> do
        -- The parser remains the semantic safety gate. The independent source
        -- scan then supplies exact trivia/literal spelling to the layout pass.
        _ <- analyzeSyntax input
        fragments <- scanSourceFragments (compilerSourceFile input) (compilerSourceText input)
        let source = compilerSourceText input
            output = formatLayout options source fragments
        pure (FormatResult output (output /= source))

formatterDiagnostic :: String -> Diagnostic
formatterDiagnostic message = Diagnostic SourceLoaderStage Error "TAF0001" Nothing message
