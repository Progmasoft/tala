-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Compiler-backed document analysis for editor protocol hosts.

The @tala-analyzer@ executable owns LSP process lifecycle via the Hackage
@lsp@ package. This module remains transport-independent: it owns the
language result and the zero-based scalar positions adapted at the boundary.
-}
module Progmasoft.TalaAnalyzer
    ( AnalysisMode (..)
    , AnalysisResult (..)
    , ProtocolPosition (..)
    , ProtocolRange (..)
    , AnalyzerDiagnostic (..)
    , analyzeDocument
    ) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Frontend

data AnalysisMode = Syntax | Semantic | Full
    deriving (Bounded, Enum, Eq, Ord, Read, Show)

data AnalysisResult
    = SyntaxResult SyntaxArtifacts
    | SemanticResult SemanticArtifacts
    | FullResult FrontendArtifacts
    deriving (Eq, Ord, Read, Show)

data ProtocolPosition = ProtocolPosition
    { protocolLine :: Int
    , protocolCharacter :: Int
    }
    deriving (Eq, Ord, Read, Show)

data ProtocolRange = ProtocolRange
    { protocolStart :: ProtocolPosition
    , protocolEnd :: ProtocolPosition
    }
    deriving (Eq, Ord, Read, Show)

data AnalyzerDiagnostic = AnalyzerDiagnostic
    { analyzerCode :: String
    , analyzerSeverity :: DiagnosticSeverity
    , analyzerStage :: DiagnosticStage
    , analyzerRange :: Maybe ProtocolRange
    , analyzerMessage :: String
    }
    deriving (Eq, Ord, Read, Show)

analyzeDocument :: AnalysisMode -> CompilerInput -> Either [AnalyzerDiagnostic] AnalysisResult
analyzeDocument mode input = mapLeft (map toAnalyzerDiagnostic) $ case mode of
    Syntax -> SyntaxResult <$> analyzeSyntax input
    Semantic -> SemanticResult <$> analyzeSemantics input
    Full -> FullResult <$> compileToCorePrep input

toAnalyzerDiagnostic :: Diagnostic -> AnalyzerDiagnostic
toAnalyzerDiagnostic problem =
    AnalyzerDiagnostic
        (diagnosticCode problem)
        (diagnosticSeverity problem)
        (diagnosticStage problem)
        (toProtocolRange <$> diagnosticSpan problem)
        (diagnosticMessage problem)

toProtocolRange :: SourceSpan -> ProtocolRange
toProtocolRange spanValue =
    ProtocolRange
        (toProtocolPosition (sourceStart spanValue))
        (toProtocolPosition (sourceEnd spanValue))

toProtocolPosition :: SourcePosition -> ProtocolPosition
toProtocolPosition position =
    ProtocolPosition
        (max 0 (sourceLine position - 1))
        (max 0 (sourceColumn position - 1))

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft transform value = case value of
    Left problem -> Left (transform problem)
    Right result -> Right result
