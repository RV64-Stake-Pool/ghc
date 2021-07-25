{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE BangPatterns #-}

-- | 'RoughMap' is an approximate finite map data structure keyed on
-- @['RoughMatchTc']@. This is useful when keying maps on lists of 'Type's
-- (e.g. an instance head).
module GHC.Core.RoughMap
  ( -- * RoughMatchTc
    RoughMatchTc(..)
  , isRoughOtherTc
  , typeToRoughMatchTc

    -- * RoughMap
  , RoughMap
  , emptyRM
  , lookupRM
  , insertRM
  , filterRM
  , filterMatchingRM
  , elemsRM
  , sizeRM
  ) where

#include "HsVersions.h"

import GHC.Prelude

import GHC.Core.TyCon
import GHC.Core.Type
import GHC.Utils.Misc
import GHC.Utils.Outputable
import GHC.Utils.Panic
import GHC.Types.Name
import GHC.Types.Name.Env

import Data.Data (Data)

{-
Note [Rough maps of Types]
~~~~~~~~~~~~~~~~~~~~~~~~~~

-}

data RoughMatchTc
  = KnownTc Name   -- INVARIANT: Name refers to a TyCon tc that responds
                   -- true to `isGenerativeTyCon tc Nominal`. See
                   -- Note [Rough matching in class and family instances]
  | OtherTc        -- e.g. type variable at the head
  deriving( Data )

isRoughOtherTc :: RoughMatchTc -> Bool
isRoughOtherTc OtherTc      = True
isRoughOtherTc (KnownTc {}) = False

typeToRoughMatchTc :: Type -> RoughMatchTc
typeToRoughMatchTc ty
  | Just (ty', _) <- splitCastTy_maybe ty   = typeToRoughMatchTc ty'
  | Just (tc,_)   <- splitTyConApp_maybe ty
  , not (isTypeFamilyTyCon tc)              = ASSERT2( isGenerativeTyCon tc Nominal, ppr tc )
                                              KnownTc (tyConName tc)
    -- See Note [Rough matching in class and family instances]
  | otherwise                               = OtherTc

-- | Trie of @[RoughMatchTc]@
--
-- *Examples*
-- @
-- insert [OtherTc] 1
-- insert [OtherTc] 2
-- lookup [OtherTc] == [1,2]
-- @
data RoughMap a = RM { rm_empty   :: [a]
                     , rm_known   :: !(DNameEnv (RoughMap a))
                        -- See Note [InstEnv determinism] in GHC.Core.InstEnv
                     , rm_unknown :: !(RoughMap a) }
                | RMEmpty -- an optimised (finite) form of emptyRM
                          -- invariant: Empty RoughMaps are always represented with RMEmpty

emptyRM :: RoughMap a
emptyRM = RMEmpty

-- | Deterministic.
lookupRM :: [RoughMatchTc] -> RoughMap a -> [a]
lookupRM _                  RMEmpty = []
lookupRM []                 rm      = elemsRM rm
lookupRM (KnownTc tc : tcs) rm      = maybe [] (lookupRM tcs) (lookupDNameEnv (rm_known rm) tc)
                                      ++ lookupRM tcs (rm_unknown rm)
                                      ++ rm_empty rm
lookupRM (OtherTc : tcs)    rm      = [ x
                                      | m <- eltsDNameEnv (rm_known rm)
                                      , x <- lookupRM tcs m ]
                                      ++ lookupRM tcs (rm_unknown rm)
                                      ++ rm_empty rm

{-
Note [RoughMap]
~~~~~~~~~~~~~~~
RoughMap is a finite map keyed on the rough "shape" of a list of type
applications. This allows efficient (yet approximate) instance look-up.

-}

    -- TODO: Including rm_empty due to Note [Eta reduction for data families]
    -- in GHC.Core.Coercion.Axiom. e.g., we may have an environment which includes
    --     data instance Fam Int a = ...
    -- which will result in `axiom ax :: Fam Int ~ FamInt` and an FamInst with
    -- `fi_tcs = [Int]`, `fi_eta_tvs = [a]`. We need to make sure that this
    -- instance matches when we are looking for an instance `Fam Int a`.

insertRM :: [RoughMatchTc] -> a -> RoughMap a -> RoughMap a
insertRM k v RMEmpty =
    insertRM k v $ RM { rm_empty = []
                      , rm_known = emptyDNameEnv
                      , rm_unknown = emptyRM }
insertRM [] v rm@(RM {}) =
    rm { rm_empty = v : rm_empty rm }
insertRM (KnownTc k : ks) v rm@(RM {}) =
    rm { rm_known = alterDNameEnv f (rm_known rm) k }
  where
    f Nothing  = Just $ insertRM ks v emptyRM
    f (Just m) = Just $ insertRM ks v m
insertRM (OtherTc : ks) v rm@(RM {}) =
    rm { rm_unknown = insertRM ks v (rm_unknown rm) }

filterRM :: (a -> Bool) -> RoughMap a -> RoughMap a
filterRM _ RMEmpty = RMEmpty
filterRM pred rm =
    normalise $ RM {
      rm_empty = filter pred (rm_empty rm),
      rm_known = mapDNameEnv (filterRM pred) (rm_known rm),
      rm_unknown = filterRM pred (rm_unknown rm)
    }

-- | Place a 'RoughMap' in normal form, turning all empty 'RM's into
-- 'RMEmpty's. Necessary after removing items.
normalise :: RoughMap a -> RoughMap a
normalise RMEmpty = RMEmpty
normalise (RM [] known RMEmpty)
  | isEmptyDNameEnv known = RMEmpty
normalise rm = rm

-- | Filter all elements that might match a particular key with the given
-- predicate.
filterMatchingRM :: (a -> Bool) -> [RoughMatchTc] -> RoughMap a -> RoughMap a
filterMatchingRM _    _  RMEmpty = RMEmpty
filterMatchingRM pred [] rm      = filterRM pred rm
filterMatchingRM pred (KnownTc tc : tcs) rm =
    normalise $ RM {
      rm_empty = filter pred (rm_empty rm),
      rm_known = alterDNameEnv (fmap $ filterMatchingRM pred tcs) (rm_known rm) tc,
      rm_unknown = filterMatchingRM pred tcs (rm_unknown rm)
    }
filterMatchingRM pred (OtherTc : tcs) rm =
    normalise $ RM {
      rm_empty = filter pred (rm_empty rm),
      rm_known = mapDNameEnv (filterMatchingRM pred tcs) (rm_known rm),
      rm_unknown = filterMatchingRM pred tcs (rm_unknown rm)
    }

elemsRM :: RoughMap a -> [a]
elemsRM = foldRM (:) []

foldRM :: (a -> b -> b) -> b -> RoughMap a -> b
foldRM f = go
  where
    -- N.B. local worker ensures that the loop can be specialised to the fold
    -- function.
    go z RMEmpty = z
    go z rm@(RM{}) =
      foldr
        f
        (foldDNameEnv
           (flip go)
           (go z (rm_unknown rm))
           (rm_known rm)
        )
        (rm_empty rm)

nonDetStrictFoldRM :: (b -> a -> b) -> b -> RoughMap a -> b
nonDetStrictFoldRM f = go
  where
    -- N.B. local worker ensures that the loop can be specialised to the fold
    -- function.
    go !z RMEmpty = z
    go  z rm@(RM{}) =
      foldl'
        f
        (nonDetStrictFoldDNameEnv
           (flip go)
           (go z (rm_unknown rm))
           (rm_known rm)
        )
        (rm_empty rm)

sizeRM :: RoughMap a -> Int
sizeRM = nonDetStrictFoldRM (\acc _ -> acc + 1) 0
