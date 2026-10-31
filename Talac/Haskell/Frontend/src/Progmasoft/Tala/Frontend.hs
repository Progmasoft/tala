-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

{- | Reusable, target-independent frontend analysis boundaries.

Compiler-adjacent tools must observe exactly the same tokens, parsed tree, and
semantic names as a build. Keeping these boundaries in the compiler package
prevents an analyzer, formatter, or linter from growing a second language
implementation merely to stop before Core lowering.
-}
module Progmasoft.Tala.Frontend
    ( CompilerInput (..)
    , SyntaxArtifacts (..)
    , SemanticArtifacts (..)
    , analyzeSyntax
    , analyzeSyntaxWith
    , analyzeSemantics
    , analyzeParsedSemantics
    ) where

import Progmasoft.Tala.AST
import Progmasoft.Tala.Diagnostic
import Progmasoft.Tala.Directives
import Progmasoft.Tala.Lexer
import Progmasoft.Tala.NestingLimits
import Progmasoft.Tala.Parser
import Progmasoft.Tala.Resolver.NameResolution
import Progmasoft.Tala.Resolver.Renamer
import Progmasoft.Tala.TypeChecker

-- | Source identity and decoded text supplied to the frontend.
data CompilerInput = CompilerInput
    { compilerSourceFile :: FilePath
    -- ^ Path used in diagnostics and source spans.
    , compilerSourceText :: String
    -- ^ Source characters after caller-owned decoding.
    }
    deriving (Eq, Ord, Read, Show)

-- | Shared lexer and parser products, before name or type analysis.
data SyntaxArtifacts = SyntaxArtifacts
    { syntaxTokens :: [Token]
    -- ^ Tokens, including trivia policy from the lexer.
    , syntaxParsedAST :: ParsedAST
    -- ^ Parsed source tree with unresolved names.
    }
    deriving (Eq, Ord, Read, Show)

-- | Intermediate ASTs produced by the ordered semantic frontend passes.
data SemanticArtifacts = SemanticArtifacts
    { semanticParsedAST :: ParsedAST
    -- ^ Original parser output.
    , semanticRenamedAST :: RenamedAST
    -- ^ AST with unique local/declaration IDs.
    , semanticResolvedAST :: ResolvedAST
    -- ^ AST with references bound to symbols.
    , semanticTypedAST :: TypedAST
    -- ^ Type-checked AST consumed by later tools.
    }
    deriving (Eq, Ord, Read, Show)

-- | Lex and parse source without invoking semantic analysis or Core lowering.
analyzeSyntax :: CompilerInput -> Either [Diagnostic] SyntaxArtifacts
analyzeSyntax = analyzeSyntaxWith hostDirectiveEnvironment

{- | Lex and parse source for a target: the conditional directives choose
their branches for it. The artifacts keep every token the lexer read, the
directive lines and the branches that were not chosen among them, because a
tool that rewrites the source needs all of it; the parsed tree has the
chosen branches only.
-}
analyzeSyntaxWith :: DirectiveEnvironment -> CompilerInput -> Either [Diagnostic] SyntaxArtifacts
analyzeSyntaxWith environment input = do
    tokens <- runLexer defaultLexer (LexerInput (compilerSourceFile input) (compilerSourceText input))
    chosen <- resolveDirectives environment tokens
    parsed <- runParser defaultParser (ParserInput (compilerSourceFile input) chosen)
    pure (SyntaxArtifacts tokens parsed)

-- | Run syntax analysis followed by renaming, resolution, and type checking.
analyzeSemantics :: CompilerInput -> Either [Diagnostic] SemanticArtifacts
analyzeSemantics input = syntaxParsedAST <$> analyzeSyntax input >>= analyzeParsedSemantics

-- | Run semantic passes on an existing parsed AST without lexing or parsing.
analyzeParsedSemantics :: ParsedAST -> Either [Diagnostic] SemanticArtifacts
analyzeParsedSemantics parsed = do
    -- Every later pass, and every stage after the frontend, recurses along
    -- the nesting of the tree. A tree that nests beyond the limits is
    -- rejected here, with the place where it becomes too deep.
    case nestingProblems parsed of
        [] -> pure ()
        problems -> Left problems
    renamed <- runRenamer defaultRenamer parsed
    resolved <- runNameResolution defaultNameResolution renamed
    typed <- runTypeChecker defaultTypeChecker resolved
    pure (SemanticArtifacts parsed renamed resolved typed)
