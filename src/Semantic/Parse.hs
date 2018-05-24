{-# LANGUAGE GADTs, RankNTypes #-}
module Semantic.Parse where

import Analysis.ConstructorName (ConstructorName, constructorLabel)
import Analysis.IdentifierName (IdentifierName, identifierLabel)
import Analysis.Declaration (HasDeclaration, declarationAlgebra)
import Analysis.PackageDef (HasPackageDef, packageDefAlgebra)
import Data.AST
import Data.Blob
import Data.JSON.Fields
import Data.Record
import Data.Term
import Parsing.Parser
import Prologue hiding (MonadError(..))
import Rendering.Graph
import Rendering.Renderer
import Semantic.IO (noLanguageForBlob)
import Semantic.Task
import Serializing.Format

runParse :: Members '[Distribute WrappedTask, Task, Exc SomeException] effs => TermRenderer output -> [Blob] -> Eff effs Builder
runParse JSONTermRenderer             = withParsedBlobs (\ blob -> decorate constructorLabel >=> decorate identifierLabel >=> render (renderJSONTerm blob)) >=> serialize JSON
runParse SExpressionTermRenderer      = withParsedBlobs (const (serialize (SExpression ByConstructorName)))
runParse ShowTermRenderer             = withParsedBlobs (const (serialize Show))
runParse TagsTermRenderer             = withParsedBlobs (\ blob -> decorate (declarationAlgebra blob) >=> render (renderToTags blob)) >=> serialize JSON
runParse ImportsTermRenderer          = withParsedBlobs (\ blob -> decorate (declarationAlgebra blob) >=> decorate (packageDefAlgebra blob) >=> render (renderToImports blob)) >=> serialize JSON
runParse (SymbolsTermRenderer fields) = withParsedBlobs (\ blob -> decorate (declarationAlgebra blob) >=> render (renderSymbolTerms . renderToSymbols fields blob)) >=> serialize JSON
runParse DOTTermRenderer              = withParsedBlobs (const (render renderTreeGraph)) >=> serialize (DOT (termStyle "terms"))

withParsedBlobs :: (Members '[Distribute WrappedTask, Task, Exc SomeException] effs, Monoid output) => (forall syntax . (ConstructorName syntax, Foldable syntax, Functor syntax, HasDeclaration syntax, HasPackageDef syntax, IdentifierName syntax, Show1 syntax, ToJSONFields1 syntax) => Blob -> Term syntax (Record Location) -> TaskEff output) -> [Blob] -> Eff effs output
withParsedBlobs render = distributeFoldMap (\ blob -> WrapTask (parseSomeBlob blob >>= withSomeTerm (render blob)))

parseSomeBlob :: Members '[Task, Exc SomeException] effs => Blob -> Eff effs (SomeTerm '[ConstructorName, Foldable, Functor, HasDeclaration, HasPackageDef, IdentifierName, Show1, ToJSONFields1] (Record Location))
parseSomeBlob blob@Blob{..} = maybe (noLanguageForBlob blobPath) (flip parse blob . someParser) blobLanguage