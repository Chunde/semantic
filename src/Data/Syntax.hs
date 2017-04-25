module Data.Syntax where

import Data.Functor.Classes.Eq.Generic
import Data.Functor.Classes.Show.Generic
import GHC.Generics
import Prologue
import Text.Show

-- Undifferentiated

newtype Leaf a = Leaf { leafContent :: ByteString }
  deriving (Eq, Foldable, Generic1, Show)

instance Eq1 Leaf where liftEq = genericLiftEq
instance Show1 Leaf where liftShowsPrec = genericLiftShowsPrec

newtype Branch a = Branch { branchElements :: [a] }
  deriving (Eq, Foldable, Generic1, Show)

instance Eq1 Branch where liftEq = genericLiftEq
instance Show1 Branch where liftShowsPrec = genericLiftShowsPrec


-- Common

-- | An identifier of some other construct, whether a containing declaration (e.g. a class name) or a reference (e.g. a variable).
newtype Identifier a = Identifier ByteString
  deriving (Eq, Foldable, Generic1, Show)

instance Eq1 Identifier where liftEq = genericLiftEq
instance Show1 Identifier where liftShowsPrec = genericLiftShowsPrec


-- | Empty syntax, with essentially no-op semantics.
--
--   This can be used to represent an implicit no-op, e.g. the alternative in an 'if' statement without an 'else'.
data Empty a = Empty
  deriving (Eq, Foldable, Generic1, Show)

instance Eq1 Empty where liftEq _ _ _ = True
instance Show1 Empty where liftShowsPrec _ _ _ _ = showString "Empty"