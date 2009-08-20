%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[RnPat]{Renaming of patterns}

Basically dependency analysis.

Handles @Match@, @GRHSs@, @HsExpr@, and @Qualifier@ datatypes.  In
general, all of these functions return a renamed thing, and a set of
free variables.

\begin{code}
module RnPat (-- main entry points
              rnPats, rnBindPat,

              NameMaker, applyNameMaker,     -- a utility for making names:
              localRecNameMaker, topRecNameMaker,  --   sometimes we want to make local names,
                                             --   sometimes we want to make top (qualified) names.

              rnHsRecFields1, HsRecFieldContext(..),

	      -- Literals
	      rnLit, rnOverLit,     

	      -- Quasiquotation
	      rnQuasiQuote,

             -- Pattern Error messages that are also used elsewhere
             checkTupSize, patSigErr
             ) where

-- ENH: thin imports to only what is necessary for patterns

import {-# SOURCE #-} RnExpr ( rnLExpr )
#ifdef GHCI
import {-# SOURCE #-} TcSplice ( runQuasiQuotePat )
#endif 	/* GHCI */

#include "HsVersions.h"

import HsSyn            
import TcRnMonad
import TcHsSyn		( hsOverLitName )
import RnEnv
import RnTypes
import DynFlags		( DynFlag(..) )
import PrelNames
import Constants	( mAX_TUPLE_SIZE )
import Name
import NameSet
import Module
import RdrName
import ListSetOps	( removeDups, minusList )
import Outputable
import SrcLoc
import FastString
import Literal		( inCharRange )
import Control.Monad	( when )
\end{code}


%*********************************************************
%*							*
	The CpsRn Monad
%*							*
%*********************************************************

Note [CpsRn monad]
~~~~~~~~~~~~~~~~~~
The CpsRn monad uses continuation-passing style to support this
style of programming:

	do { ...
           ; ns <- bindNames rs
           ; ...blah... }

   where rs::[RdrName], ns::[Name]

The idea is that '...blah...' 
  a) sees the bindings of ns
  b) returns the free variables it mentions
     so that bindNames can report unused ones

In particular, 
    mapM rnPatAndThen [p1, p2, p3]
has a *left-to-right* scoping: it makes the binders in 
p1 scope over p2,p3.

\begin{code}
newtype CpsRn b = CpsRn { unCpsRn :: forall r. (b -> RnM (r, FreeVars))
                                            -> RnM (r, FreeVars) }
	-- See Note [CpsRn monad]

instance Monad CpsRn where
  return x = CpsRn (\k -> k x)
  (CpsRn m) >>= mk = CpsRn (\k -> m (\v -> unCpsRn (mk v) k))

runCps :: CpsRn a -> RnM (a, FreeVars)
runCps (CpsRn m) = m (\r -> return (r, emptyFVs))

liftCps :: RnM a -> CpsRn a
liftCps rn_thing = CpsRn (\k -> rn_thing >>= k)

liftCpsFV :: RnM (a, FreeVars) -> CpsRn a
liftCpsFV rn_thing = CpsRn (\k -> do { (v,fvs1) <- rn_thing
                                     ; (r,fvs2) <- k v
                                     ; return (r, fvs1 `plusFV` fvs2) })

wrapSrcSpanCps :: (a -> CpsRn b) -> Located a -> CpsRn (Located b)
-- Set the location, and also wrap it around the value returned
wrapSrcSpanCps fn (L loc a)
  = CpsRn (\k -> setSrcSpan loc $ 
                 unCpsRn (fn a) $ \v -> 
                 k (L loc v))

lookupConCps :: Located RdrName -> CpsRn (Located Name)
lookupConCps con_rdr 
  = CpsRn (\k -> do { con_name <- lookupLocatedOccRn con_rdr
                    ; (r, fvs) <- k con_name
                    ; return (r, fvs `plusFV` unitFV (unLoc con_name)) })
\end{code}

%*********************************************************
%*							*
	Name makers
%*							*
%*********************************************************

Externally abstract type of name makers,
which is how you go from a RdrName to a Name

\begin{code}
data NameMaker 
  = LamMk 	-- Lambdas 
      Bool	-- True <=> report unused bindings

  | LetMk       -- Let bindings, incl top level
		-- Do not check for unused bindings
      (Maybe Module)   -- Just m  => top level of module m
                       -- Nothing => not top level
      MiniFixityEnv

topRecNameMaker :: Module -> MiniFixityEnv -> NameMaker
topRecNameMaker mod fix_env = LetMk (Just mod) fix_env

localRecNameMaker :: MiniFixityEnv -> NameMaker
localRecNameMaker fix_env = LetMk Nothing fix_env 

matchNameMaker :: NameMaker
matchNameMaker = LamMk True

newName :: NameMaker -> Located RdrName -> CpsRn Name
newName (LamMk report_unused) rdr_name
  = CpsRn (\ thing_inside -> 
	do { name <- newLocalBndrRn rdr_name
	   ; (res, fvs) <- bindLocalName name (thing_inside name)
	   ; when report_unused $ warnUnusedMatches [name] fvs
	   ; return (res, name `delFV` fvs) })

newName (LetMk mb_top fix_env) rdr_name
  = CpsRn (\ thing_inside -> 
        do { name <- case mb_top of
                       Nothing  -> newLocalBndrRn rdr_name
                       Just mod -> newTopSrcBinder mod rdr_name
	   ; bindLocalNamesFV_WithFixities [name] fix_env $
	     thing_inside name })
			  
    -- Note: the bindLocalNamesFV_WithFixities is somewhat suspicious 
    --       because it binds a top-level name as a local name.
    --       however, this binding seems to work, and it only exists for
    --       the duration of the patterns and the continuation;
    --       then the top-level name is added to the global env
    --       before going on to the RHSes (see RnSource.lhs).
\end{code}


%*********************************************************
%*							*
	External entry points
%*							*
%*********************************************************

There are various entry points to renaming patterns, depending on
 (1) whether the names created should be top-level names or local names
 (2) whether the scope of the names is entirely given in a continuation
     (e.g., in a case or lambda, but not in a let or at the top-level,
      because of the way mutually recursive bindings are handled)
 (3) whether the a type signature in the pattern can bind 
	lexically-scoped type variables (for unpacking existential 
	type vars in data constructors)
 (4) whether we do duplicate and unused variable checking
 (5) whether there are fixity declarations associated with the names
     bound by the patterns that need to be brought into scope with them.
     
 Rather than burdening the clients of this module with all of these choices,
 we export the three points in this design space that we actually need:

\begin{code}
-- ----------- Entry point 1: rnPats -------------------
-- Binds local names; the scope of the bindings is entirely in the thing_inside
--   * allows type sigs to bind type vars
--   * local namemaker
--   * unused and duplicate checking
--   * no fixities
rnPats :: HsMatchContext Name -- for error messages
       -> [LPat RdrName] 
       -> ([LPat Name] -> RnM (a, FreeVars))
       -> RnM (a, FreeVars)
rnPats ctxt pats thing_inside
  = do	{ envs_before <- getRdrEnvs

	  -- (0) bring into scope all of the type variables bound by the patterns
	  -- (1) rename the patterns, bringing into scope all of the term variables
	  -- (2) then do the thing inside.
	; bindPatSigTyVarsFV (collectSigTysFromPats pats) $ 
	  unCpsRn (rnLPatsAndThen matchNameMaker pats)	  $ \ pats' -> do
        { -- Check for duplicated and shadowed names 
	         -- Because we don't bind the vars all at once, we can't
	         -- 	check incrementally for duplicates; 
	         -- Nor can we check incrementally for shadowing, else we'll
	         -- 	complain *twice* about duplicates e.g. f (x,x) = ...
        ; let names = collectPatsBinders pats'
        ; checkDupNames doc_pat names
	; checkShadowedNames doc_pat envs_before
			     [(nameSrcSpan name, nameOccName name) | name <- names]
        ; thing_inside pats' } }
  where
    doc_pat = ptext (sLit "In") <+> pprMatchContext ctxt


applyNameMaker :: NameMaker -> Located RdrName -> RnM Name
applyNameMaker mk rdr = do { (n, _fvs) <- runCps (newName mk rdr); return n }

-- ----------- Entry point 2: rnBindPat -------------------
-- Binds local names; in a recursive scope that involves other bound vars
--	e.g let { (x, Just y) = e1; ... } in ...
--   * does NOT allows type sig to bind type vars
--   * local namemaker
--   * no unused and duplicate checking
--   * fixities might be coming in
rnBindPat :: NameMaker
          -> LPat RdrName
          -> RnM (LPat Name, FreeVars)
   -- Returned FreeVars are the free variables of the pattern,
   -- of course excluding variables bound by this pattern 

rnBindPat name_maker pat = runCps (rnLPatAndThen name_maker pat)
\end{code}


%*********************************************************
%*							*
	The main event
%*							*
%*********************************************************

\begin{code}
-- ----------- Entry point 3: rnLPatAndThen -------------------
-- General version: parametrized by how you make new names

rnLPatsAndThen :: NameMaker -> [LPat RdrName] -> CpsRn [LPat Name]
rnLPatsAndThen mk = mapM (rnLPatAndThen mk)
  -- Despite the map, the monad ensures that each pattern binds
  -- variables that may be mentioned in subsequent patterns in the list

--------------------
-- The workhorse
rnLPatAndThen :: NameMaker -> LPat RdrName -> CpsRn (LPat Name)
rnLPatAndThen nm lpat = wrapSrcSpanCps (rnPatAndThen nm) lpat

rnPatAndThen :: NameMaker -> Pat RdrName -> CpsRn (Pat Name)
rnPatAndThen _  (WildPat _)   = return (WildPat placeHolderType)
rnPatAndThen mk (ParPat pat)  = do { pat' <- rnLPatAndThen mk pat; return (ParPat pat') }
rnPatAndThen mk (LazyPat pat) = do { pat' <- rnLPatAndThen mk pat; return (LazyPat pat') }
rnPatAndThen mk (BangPat pat) = do { pat' <- rnLPatAndThen mk pat; return (BangPat pat') }
rnPatAndThen mk (VarPat rdr)  = do { loc <- liftCps getSrcSpanM
                                   ; name <- newName mk (L loc rdr)
                                   ; return (VarPat name) }
     -- we need to bind pattern variables for view pattern expressions
     -- (e.g. in the pattern (x, x -> y) x needs to be bound in the rhs of the tuple)
                                     
rnPatAndThen mk (SigPatIn pat ty)
  = do { patsigs <- liftCps (doptM Opt_ScopedTypeVariables)
       ; if patsigs
         then do { pat' <- rnLPatAndThen mk pat
                 ; ty' <- liftCpsFV (rnHsTypeFVs tvdoc ty)
		 ; return (SigPatIn pat' ty') }
         else do { liftCps (addErr (patSigErr ty))
                 ; rnPatAndThen mk (unLoc pat) } }
  where
    tvdoc = text "In a pattern type-signature"
       
rnPatAndThen mk (LitPat lit)
  | HsString s <- lit
  = do { ovlStr <- liftCps (doptM Opt_OverloadedStrings)
       ; if ovlStr 
         then rnPatAndThen mk (mkNPat (mkHsIsString s placeHolderType) Nothing)
         else normal_lit }
  | otherwise = normal_lit
  where
    normal_lit = do { liftCps (rnLit lit); return (LitPat lit) }

rnPatAndThen _ (NPat lit mb_neg _eq)
  = do { lit'    <- liftCpsFV $ rnOverLit lit
       ; mb_neg' <- liftCpsFV $ case mb_neg of
		      Nothing -> return (Nothing, emptyFVs)
		      Just _  -> do { (neg, fvs) <- lookupSyntaxName negateName
				    ; return (Just neg, fvs) }
       ; eq' <- liftCpsFV $ lookupSyntaxName eqName
       ; return (NPat lit' mb_neg' eq') }

rnPatAndThen mk (NPlusKPat rdr lit _ _)
  = do { new_name <- newName mk rdr
       ; lit'  <- liftCpsFV $ rnOverLit lit
       ; minus <- liftCpsFV $ lookupSyntaxName minusName
       ; ge    <- liftCpsFV $ lookupSyntaxName geName
       ; return (NPlusKPat (L (nameSrcSpan new_name) new_name) lit' ge minus) }
	   	-- The Report says that n+k patterns must be in Integral

rnPatAndThen mk (AsPat rdr pat)
  = do { new_name <- newName mk rdr
       ; pat' <- rnLPatAndThen mk pat
       ; return (AsPat (L (nameSrcSpan new_name) new_name) pat') }

rnPatAndThen mk p@(ViewPat expr pat ty)
  = do { liftCps $ do { vp_flag <- doptM Opt_ViewPatterns
                      ; checkErr vp_flag (badViewPat p) }
         -- Because of the way we're arranging the recursive calls,
         -- this will be in the right context 
       ; expr' <- liftCpsFV $ rnLExpr expr 
       ; pat' <- rnLPatAndThen mk pat
       ; return (ViewPat expr' pat' ty) }

rnPatAndThen mk (ConPatIn con stuff)
   -- rnConPatAndThen takes care of reconstructing the pattern
  = rnConPatAndThen mk con stuff

rnPatAndThen mk (ListPat pats _)
  = do { pats' <- rnLPatsAndThen mk pats
       ; return (ListPat pats' placeHolderType) }

rnPatAndThen mk (PArrPat pats _)
  = do { pats' <- rnLPatsAndThen mk pats
       ; return (PArrPat pats' placeHolderType) }

rnPatAndThen mk (TuplePat pats boxed _)
  = do { liftCps $ checkTupSize (length pats)
       ; pats' <- rnLPatsAndThen mk pats
       ; return (TuplePat pats' boxed placeHolderType) }

rnPatAndThen _ (TypePat ty)
  = do { ty' <- liftCpsFV $ rnHsTypeFVs (text "In a type pattern") ty
       ; return (TypePat ty') }

#ifndef GHCI
rnPatAndThen _ p@(QuasiQuotePat {}) 
  = pprPanic "Can't do QuasiQuotePat without GHCi" (ppr p)
#else
rnPatAndThen mk (QuasiQuotePat qq)
  = do { qq' <- liftCpsFV $ rnQuasiQuote qq
       ; pat <- liftCps $ runQuasiQuotePat qq'
       ; L _ pat' <- rnLPatAndThen mk pat
       ; return pat' }
#endif 	/* GHCI */

rnPatAndThen _ pat = pprPanic "rnLPatAndThen" (ppr pat)


--------------------
rnConPatAndThen :: NameMaker
                -> Located RdrName          -- the constructor
                -> HsConPatDetails RdrName 
                -> CpsRn (Pat Name)

rnConPatAndThen mk con (PrefixCon pats)
  = do	{ con' <- lookupConCps con
	; pats' <- rnLPatsAndThen mk pats
	; return (ConPatIn con' (PrefixCon pats')) }

rnConPatAndThen mk con (InfixCon pat1 pat2)
  = do	{ con' <- lookupConCps con
   	; pat1' <- rnLPatAndThen mk pat1
	; pat2' <- rnLPatAndThen mk pat2
	; fixity <- liftCps $ lookupFixityRn (unLoc con')
	; liftCps $ mkConOpPatRn con' fixity pat1' pat2' }

rnConPatAndThen mk con (RecCon rpats)
  = do	{ con' <- lookupConCps con
  	; rpats' <- rnHsRecPatsAndThen mk con' rpats
	; return (ConPatIn con' (RecCon rpats')) }

--------------------
rnHsRecPatsAndThen :: NameMaker
                   -> Located Name	-- Constructor
		   -> HsRecFields RdrName (LPat RdrName)
		   -> CpsRn (HsRecFields Name (LPat Name))
rnHsRecPatsAndThen mk (L _ con) hs_rec_fields@(HsRecFields { rec_dotdot = dd })
  = do { flds <- liftCpsFV $ rnHsRecFields1 (HsRecFieldPat con) VarPat hs_rec_fields
       ; flds' <- mapM rn_field (flds `zip` [1..])
       ; return (HsRecFields { rec_flds = flds', rec_dotdot = dd }) }
  where 
    rn_field (fld, n') = do { arg' <- rnLPatAndThen (nested_mk dd mk n') 
                                                    (hsRecFieldArg fld)
                            ; return (fld { hsRecFieldArg = arg' }) }

	-- Suppress unused-match reporting for fields introduced by ".."
    nested_mk Nothing  mk                    _  = mk
    nested_mk (Just _) mk@(LetMk {})         _  = mk
    nested_mk (Just n) (LamMk report_unused) n' = LamMk (report_unused && (n' <= n))
\end{code}


%************************************************************************
%*									*
	Record fields
%*									*
%************************************************************************

\begin{code}
data HsRecFieldContext 
  = HsRecFieldCon Name
  | HsRecFieldPat Name
  | HsRecFieldUpd

rnHsRecFields1 
    :: HsRecFieldContext
    -> (RdrName -> arg) -- When punning, use this to build a new field
    -> HsRecFields RdrName (Located arg)
    -> RnM ([HsRecField Name (Located arg)], FreeVars)

-- This supprisingly complicated pass
--   a) looks up the field name (possibly using disambiguation)
--   b) fills in puns and dot-dot stuff
-- When we we've finished, we've renamed the LHS, but not the RHS,
-- of each x=e binding

rnHsRecFields1 ctxt mk_arg (HsRecFields { rec_flds = flds, rec_dotdot = dotdot })
  = do { pun_ok      <- doptM Opt_RecordPuns
       ; disambig_ok <- doptM Opt_DisambiguateRecordFields
       ; parent <- check_disambiguation disambig_ok mb_con
       ; flds1 <- mapM (rn_fld pun_ok parent) flds
       ; mapM_ (addErr . dupFieldErr ctxt) dup_flds
       ; flds2 <- rn_dotdot dotdot mb_con flds1
       ; return (flds2, mkFVs (getFieldIds flds2)) }
  where
    mb_con = case ctxt of
		HsRecFieldUpd     -> Nothing
		HsRecFieldCon con -> Just con
		HsRecFieldPat con -> Just con
    doc = case mb_con of
            Nothing  -> ptext (sLit "constructor field name")
            Just con -> ptext (sLit "field of constructor") <+> quotes (ppr con)

    name_to_arg (L loc n) = L loc (mk_arg (mkRdrUnqual (nameOccName n)))

    rn_fld pun_ok parent (HsRecField { hsRecFieldId = fld
                       	      	     , hsRecFieldArg = arg
                       	      	     , hsRecPun = pun })
      = do { fld' <- wrapLocM (lookupSubBndr parent doc) fld
           ; arg' <- if pun 
                     then do { checkErr pun_ok (badPun fld)
                             ; return (name_to_arg fld') }
                     else return arg
           ; return (HsRecField { hsRecFieldId = fld'
                                , hsRecFieldArg = arg'
                                , hsRecPun = pun }) }

    rn_dotdot Nothing _mb_con flds     -- No ".." at all
      = return flds
    rn_dotdot (Just {}) Nothing flds   -- ".." on record update
      = do { addErr (badDotDot ctxt); return flds }
    rn_dotdot (Just n) (Just con) flds -- ".." on record con/pat
      = ASSERT( n == length flds )
        do { loc <- getSrcSpanM	-- Rather approximate
           ; dd_flag <- doptM Opt_RecordWildCards
           ; checkErr dd_flag (needFlagDotDot ctxt)

           ; con_fields <- lookupConstructorFields con
           ; let present_flds = getFieldIds flds
                 absent_flds  = con_fields `minusList` present_flds
                 extras = [ HsRecField
                              { hsRecFieldId = L loc f
                              , hsRecFieldArg = name_to_arg (L loc f)
                              , hsRecPun = True }
                          | f <- absent_flds ]

           ; return (flds ++ extras) }

    check_disambiguation :: Bool -> Maybe Name -> RnM Parent
    -- When disambiguation is on, return the parent *type constructor*
    -- That is, the parent of the data constructor.  That's the parent
    -- to use for looking up record fields.
    check_disambiguation disambig_ok mb_con
      | disambig_ok, Just con <- mb_con
      = do { env <- getGlobalRdrEnv
           ; return (case lookupGRE_Name env con of
	       	       [gre] -> gre_par gre
               	       gres  -> WARN( True, ppr con <+> ppr gres ) NoParent) }
      | otherwise = return NoParent
 
    dup_flds :: [[RdrName]]
        -- Each list represents a RdrName that occurred more than once
        -- (the list contains all occurrences)
        -- Each list in dup_fields is non-empty
    (_, dup_flds) = removeDups compare (getFieldIds flds)

getFieldIds :: [HsRecField id arg] -> [id]
getFieldIds flds = map (unLoc . hsRecFieldId) flds

needFlagDotDot :: HsRecFieldContext -> SDoc
needFlagDotDot ctxt = vcat [ptext (sLit "Illegal `..' in record") <+> pprRFC ctxt,
			    ptext (sLit "Use -XRecordWildCards to permit this")]

badDotDot :: HsRecFieldContext -> SDoc
badDotDot ctxt = ptext (sLit "You cannot use `..' in a record") <+> pprRFC ctxt

badPun :: Located RdrName -> SDoc
badPun fld = vcat [ptext (sLit "Illegal use of punning for field") <+> quotes (ppr fld),
		   ptext (sLit "Use -XNamedFieldPuns to permit this")]

dupFieldErr :: HsRecFieldContext -> [RdrName] -> SDoc
dupFieldErr ctxt dups
  = hsep [ptext (sLit "duplicate field name"), 
          quotes (ppr (head dups)),
	  ptext (sLit "in record"), pprRFC ctxt]

pprRFC :: HsRecFieldContext -> SDoc
pprRFC (HsRecFieldCon {}) = ptext (sLit "construction")
pprRFC (HsRecFieldPat {}) = ptext (sLit "pattern")
pprRFC (HsRecFieldUpd {}) = ptext (sLit "update")
\end{code}


%************************************************************************
%*									*
\subsubsection{Literals}
%*									*
%************************************************************************

When literals occur we have to make sure
that the types and classes they involve
are made available.

\begin{code}
rnLit :: HsLit -> RnM ()
rnLit (HsChar c) = checkErr (inCharRange c) (bogusCharError c)
rnLit _ = return ()

rnOverLit :: HsOverLit t -> RnM (HsOverLit Name, FreeVars)
rnOverLit lit@(OverLit {ol_val=val})
  = do	{ let std_name = hsOverLitName val
	; (from_thing_name, fvs) <- lookupSyntaxName std_name
	; let rebindable = case from_thing_name of
				HsVar v -> v /= std_name
				_	-> panic "rnOverLit"
	; return (lit { ol_witness = from_thing_name
		      , ol_rebindable = rebindable }, fvs) }
\end{code}

%************************************************************************
%*									*
\subsubsection{Quasiquotation}
%*									*
%************************************************************************

See Note [Quasi-quote overview] in TcSplice.

\begin{code}
rnQuasiQuote :: HsQuasiQuote RdrName -> RnM (HsQuasiQuote Name, FreeVars)
rnQuasiQuote (HsQuasiQuote n quoter quoteSpan quote)
  = do	{ loc  <- getSrcSpanM
   	; n' <- newLocalBndrRn (L loc n)
   	; quoter' <- lookupOccRn quoter
		-- If 'quoter' is not in scope, proceed no further
		-- Otherwise lookupOcc adds an error messsage and returns 
		-- an "unubound name", which makes the subsequent attempt to
		-- run the quote fail
   	; return (HsQuasiQuote n' quoter' quoteSpan quote, unitFV quoter') }
\end{code}

%************************************************************************
%*									*
\subsubsection{Errors}
%*									*
%************************************************************************

\begin{code}
checkTupSize :: Int -> RnM ()
checkTupSize tup_size
  | tup_size <= mAX_TUPLE_SIZE 
  = return ()
  | otherwise		       
  = addErr (sep [ptext (sLit "A") <+> int tup_size <> ptext (sLit "-tuple is too large for GHC"),
		 nest 2 (parens (ptext (sLit "max size is") <+> int mAX_TUPLE_SIZE)),
		 nest 2 (ptext (sLit "Workaround: use nested tuples or define a data type"))])

patSigErr :: Outputable a => a -> SDoc
patSigErr ty
  =  (ptext (sLit "Illegal signature in pattern:") <+> ppr ty)
	$$ nest 4 (ptext (sLit "Use -XScopedTypeVariables to permit it"))

bogusCharError :: Char -> SDoc
bogusCharError c
  = ptext (sLit "character literal out of range: '\\") <> char c  <> char '\''

badViewPat :: Pat RdrName -> SDoc
badViewPat pat = vcat [ptext (sLit "Illegal view pattern: ") <+> ppr pat,
                       ptext (sLit "Use -XViewPatterns to enable view patterns")]
\end{code}
