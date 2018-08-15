{-# OPTIONS_GHC -fno-warn-orphans #-}

module SpecHelpers
( module X
, runBuilder
, diffFilePaths
, parseFilePath
, readFilePair
, testEvaluating
, deNamespace
, derefQName
, verbatim
, TermEvaluator(..)
, Verbatim(..)
, toList
, Config
, LogQueue
, StatQueue
) where

import Control.Abstract
import Control.Arrow ((&&&))
import Control.Monad.Effect.Trace as X (runIgnoringTrace, runReturningTrace)
import Control.Monad ((>=>))
import Data.Abstract.Address.Precise as X
import Data.Abstract.Environment as Env
import Data.Abstract.Evaluatable
import Data.Abstract.FreeVariables as X
import Data.Abstract.Heap as X
import Data.Abstract.Module as X
import Data.Abstract.ModuleTable as X hiding (lookup)
import Data.Abstract.Name as X
import Data.Abstract.Value.Concrete (Value(..), ValueError, runValueError, materializeEnvironment)
import Data.Bifunctor (first)
import Data.Blob as X
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Lazy (toStrict)
import Data.Project as X
import Data.Proxy as X
import Data.Foldable (toList)
import Data.Functor.Listable as X
import Data.Language as X
import Data.List.NonEmpty as X (NonEmpty(..))
import Data.Range as X
import Data.Record as X
import Data.Semilattice.Lower as X
import Data.Source as X
import Data.Span as X
import Data.String
import Data.Sum
import Data.Term as X
import Parsing.Parser as X
import Rendering.Renderer as X hiding (error)
import Semantic.Diff as X
import Semantic.Parse as X
import Semantic.Task as X hiding (parsePackage)
import Semantic.Util as X
import System.FilePath as X

import Data.ByteString as X (ByteString)
import Data.Functor.Both as X (Both, runBothWith, both)
import Data.Maybe as X
import Data.Monoid as X (Monoid(..), First(..), Last(..))
import Data.Semigroup as X (Semigroup(..))
import Control.Monad as X

import Test.Hspec as X (Spec, SpecWith, context, describe, it, xit, parallel, pendingWith, around, runIO)
import Test.Hspec.Expectations.Pretty as X
import Test.Hspec.LeanCheck as X
import Test.LeanCheck as X

import qualified Data.ByteString as B
import qualified Data.Set as Set
import qualified Semantic.IO as IO
import Semantic.Config (Config)
import Semantic.Telemetry (LogQueue, StatQueue)
import System.Exit (die)
import Control.Exception (displayException)

runBuilder = toStrict . toLazyByteString

-- | This orphan instance is so we don't have to insert @name@ calls
-- in dozens and dozens of environment specs.
instance IsString Name where
  fromString = name . fromString

-- | Returns an s-expression formatted diff for the specified FilePath pair.
diffFilePaths :: TaskConfig -> Both FilePath -> IO ByteString
diffFilePaths (TaskConfig config logger statter) paths = readFilePair paths >>= runTaskWithConfig config logger statter . runDiff SExpressionDiffRenderer . pure >>= either (die . displayException) (pure . runBuilder)

-- | Returns an s-expression parse tree for the specified FilePath.
parseFilePath :: TaskConfig -> FilePath -> IO ByteString
parseFilePath (TaskConfig config logger statter) path = (fromJust <$> IO.readFile (file path)) >>= runTaskWithConfig config logger statter . runParse SExpressionTermRenderer . pure >>= either (die . displayException) (pure . runBuilder)

-- | Read two files to a BlobPair.
readFilePair :: Both FilePath -> IO BlobPair
readFilePair paths = let paths' = fmap file paths in
                     runBothWith IO.readFilePair paths'

type TestEvaluatingEffects = '[ Resumable (BaseError (ValueError Precise (ConcreteEff Precise '[Trace, Lift IO])))
                              , Resumable (BaseError (AddressError Precise Val))
                              , Resumable (BaseError ResolutionError)
                              , Resumable (BaseError EvalError)
                              , Resumable (BaseError (EnvironmentError Precise))
                              , Resumable (BaseError (UnspecializedError Val))
                              , Resumable (BaseError (LoadError Precise))
                              , Fresh
                              , State (Heap Precise Val)
                              , Trace
                              , Lift IO
                              ]
type TestEvaluatingErrors = '[ BaseError (ValueError Precise (ConcreteEff Precise '[Trace, Lift IO]))
                             , BaseError (AddressError Precise Val)
                             , BaseError ResolutionError
                             , BaseError EvalError
                             , BaseError (EnvironmentError Precise)
                             , BaseError (UnspecializedError Val)
                             , BaseError (LoadError Precise)
                             ]
testEvaluating :: Evaluator Precise Val TestEvaluatingEffects (ModuleTable (NonEmpty (Module (ModuleResult Precise))))
               -> IO
                 ( [String]
                 , ( Heap Precise Val
                   , Either (SomeExc (Data.Sum.Sum TestEvaluatingErrors))
                            (ModuleTable (NonEmpty (Module (ModuleResult Precise))))
                   )
                 )
testEvaluating
  = runM
  . runReturningTrace
  . runState lowerBound
  . runFresh 0
  . fmap reassociate
  . runLoadError
  . runUnspecialized
  . runEnvironmentError
  . runEvalError
  . runResolutionError
  . runAddressError
  . runValueError @_ @Precise @(ConcreteEff Precise _)

type Val = Value Precise (ConcreteEff Precise '[Trace, Lift IO])


deNamespace :: Heap Precise (Value Precise term)
            -> Value Precise term
            -> Maybe (Name, [Name])
deNamespace heap ns@(Namespace name _ _) = (,) name . Env.allNames <$> namespaceScope heap ns
deNamespace _ _                          = Nothing

namespaceScope :: Heap Precise (Value Precise term)
               -> Value Precise term
               -> Maybe (Environment Precise)
namespaceScope heap ns@(Namespace _ _ _)
  = either (const Nothing) snd
  . run
  . runFresh 0
  . runAddressError
  . runState heap
  . runReader (lowerBound @Span)
  . runReader (ModuleInfo "SpecHelper.hs")
  . runDeref
  $ materializeEnvironment ns

namespaceScope _ _ = Nothing

derefQName :: Heap Precise (Value Precise term) -> NonEmpty Name -> Bindings Precise -> Maybe (Value Precise term)
derefQName heap names binds = go names (Env.newEnv binds)
  where go (n1 :| ns) env = Env.lookupEnv' n1 env >>= flip heapLookup heap >>= fmap fst . Set.minView >>= case ns of
          []        -> Just
          (n2 : ns) -> namespaceScope heap >=> go (n2 :| ns)

newtype Verbatim = Verbatim ByteString
  deriving (Eq)

instance Show Verbatim where
  show (Verbatim x) = show x

verbatim :: ByteString -> Verbatim
verbatim = Verbatim . stripWhitespace
  where
    stripWhitespace :: ByteString -> ByteString
    stripWhitespace = B.foldl' go B.empty
      where go acc x | x `B.elem` " \t\n" = acc
                     | otherwise = B.snoc acc x
