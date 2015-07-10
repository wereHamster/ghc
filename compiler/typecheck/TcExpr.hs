{-
c%
(c) The University of Glasgow 2006
(c) The GRASP/AQUA Project, Glasgow University, 1992-1998

\section[TcExpr]{Typecheck an expression}
-}

{-# LANGUAGE CPP #-}

module TcExpr ( tcPolyExpr, tcPolyExprNC, tcMonoExpr, tcMonoExprNC,
                tcInferSigma, tcInferSigmaNC, tcInferRho, tcInferRhoNC,
                tcSyntaxOp, tcCheckId,
                addExprErrCtxt, tcSkolemiseExpr ) where

#include "HsVersions.h"

import {-# SOURCE #-}   TcSplice( tcSpliceExpr, tcTypedBracket, tcUntypedBracket )
import THNames( liftStringName, liftName )

import HsSyn
import TcHsSyn
import TcRnMonad
import TcUnify
import BasicTypes
import Inst
import TcBinds
import FamInst          ( tcGetFamInstEnvs, tcLookupDataFamInst )
import TcEnv
import TcArrows
import TcMatches
import TcHsType
import TcPatSyn( tcPatSynBuilderOcc )
import TcPat
import TcMType
import TcType
import DsMonad
import Id
import ConLike
import DataCon
import Name
import TyCon
import Type
import TcEvidence
import Var
import VarSet
import VarEnv
import TysWiredIn
import TysPrim( intPrimTy, addrPrimTy )
import PrimOp( tagToEnumKey )
import PrelNames
import DynFlags
import SrcLoc
import Util
import ListSetOps
import Maybes
import ErrUtils
import Outputable
import FastString
import Control.Monad
import Class(classTyCon)
import Data.Function
import Data.List
import qualified Data.Set as Set

{-
************************************************************************
*                                                                      *
\subsection{Main wrappers}
*                                                                      *
************************************************************************
-}

tcPolyExpr, tcPolyExprNC
         :: LHsExpr Name        -- Expression to type check
         -> TcSigmaType         -- Expected type (could be a polytype)
         -> TcM (LHsExpr TcId)  -- Generalised expr with expected type

-- tcPolyExpr is a convenient place (frequent but not too frequent)
-- place to add context information.
-- The NC version does not do so, usually because the caller wants
-- to do so himself.

tcPolyExpr expr res_ty
  = addExprErrCtxt expr $
    do { traceTc "tcPolyExpr" (ppr res_ty); tcPolyExprNC expr res_ty }

tcPolyExprNC (L loc expr) res_ty
  = setSrcSpan loc $
    do { traceTc "tcPolyExprNC" (ppr res_ty)
       ; expr' <- tcSkolemiseExpr res_ty $ \ res_ty ->
                  tcExpr expr res_ty
       ; return (L loc expr') }

---------------
tcMonoExpr, tcMonoExprNC
    :: LHsExpr Name      -- Expression to type check
    -> TcRhoType         -- Expected type (could be a type variable)
                         -- Definitely no foralls at the top
    -> TcM (LHsExpr TcId)

tcMonoExpr expr res_ty
  = addErrCtxt (exprCtxt expr) $
    tcMonoExprNC expr res_ty

tcMonoExprNC (L loc expr) res_ty
  = ASSERT( not (isSigmaTy res_ty) )
    setSrcSpan loc $
    do  { expr' <- tcExpr expr res_ty
        ; return (L loc expr') }

---------------
tcInferSigma, tcInferSigmaNC :: LHsExpr Name -> TcM (LHsExpr TcId, TcSigmaType)
-- Infer a *sigma*-type.
tcInferSigma expr = addErrCtxt (exprCtxt expr) (tcInferSigmaNC expr)

tcInferSigmaNC (L loc expr)
  = setSrcSpan loc $
    do { (expr', sigma) <- tcInfer (tcExpr expr)
       ; return (L loc expr', sigma) }

tcInferRho, tcInferRhoNC :: LHsExpr Name -> TcM (LHsExpr TcId, TcRhoType)
-- Infer a *rho*-type. The return type is always (shallowly) instantiated.
tcInferRho expr = addErrCtxt (exprCtxt expr) (tcInferRhoNC expr)

tcInferRhoNC expr
  = do { (expr', sigma) <- tcInferSigmaNC expr
                    -- TODO (RAE): Fix origin stuff
       ; (wrap, rho) <- topInstantiate AppOrigin sigma
       ; return (mkLHsWrap wrap expr', rho) }


{-
************************************************************************
*                                                                      *
        tcExpr: the main expression typechecker
*                                                                      *
************************************************************************

NB: The res_ty is always deeply skolemised.
-}

tcExpr :: HsExpr Name -> TcRhoType -> TcM (HsExpr TcId)
tcExpr (HsVar name)     res_ty = tcCheckId name res_ty
tcExpr (HsUnboundVar v) res_ty = tcUnboundId v res_ty

tcExpr (HsApp e1 e2) res_ty
  = do { (wrap, fun, args) <- tcApp Nothing AppOrigin e1 [e2] res_ty
       ; return (mkHsWrap wrap $ unLoc $ foldl mkHsApp fun args) }

tcExpr (HsLit lit)   res_ty = do { let lit_ty = hsLitType lit
                                    ; tcWrapResult (HsLit lit) lit_ty res_ty }

tcExpr (HsPar expr)   res_ty = do { expr' <- tcMonoExprNC expr res_ty
                                    ; return (HsPar expr') }

tcExpr (HsSCC src lbl expr) res_ty
  = do { expr' <- tcMonoExpr expr res_ty
       ; return (HsSCC src lbl expr') }

tcExpr (HsTickPragma src info expr) res_ty
  = do { expr' <- tcMonoExpr expr res_ty
       ; return (HsTickPragma src info expr') }

tcExpr (HsCoreAnn src lbl expr) res_ty
  = do  { expr' <- tcMonoExpr expr res_ty
        ; return (HsCoreAnn src lbl expr') }

tcExpr (HsOverLit lit) res_ty
  = do  { (wrap,  lit') <- newOverloadedLit Expected lit res_ty
        ; return (mkHsWrap wrap $ HsOverLit lit') }

tcExpr (NegApp expr neg_expr) res_ty
  = do  { neg_expr' <- tcSyntaxOp NegateOrigin neg_expr
                                  (mkFunTy res_ty res_ty)
        ; expr' <- tcMonoExpr expr res_ty
        ; return (NegApp expr' neg_expr') }

tcExpr (HsIPVar x) res_ty
  = do { let origin = IPOccOrigin x
       ; ipClass <- tcLookupClass ipClassName
           {- Implicit parameters must have a *tau-type* not a
              type scheme.  We enforce this by creating a fresh
              type variable as its type.  (Because res_ty may not
              be a tau-type.) -}
       ; ip_ty <- newFlexiTyVarTy openTypeKind
       ; let ip_name = mkStrLitTy (hsIPNameFS x)
       ; ip_var <- emitWanted origin (mkClassPred ipClass [ip_name, ip_ty])
       ; tcWrapResult (fromDict ipClass ip_name ip_ty (HsVar ip_var)) ip_ty res_ty }
  where
  -- Coerces a dictionary for `IP "x" t` into `t`.
  fromDict ipClass x ty = HsWrap $ mkWpCast $ TcCoercion $
                          unwrapIP $ mkClassPred ipClass [x,ty]

tcExpr (HsLam match) res_ty
  = do  { (co_fn, match') <- tcMatchLambda match res_ty
        ; return (mkHsWrap co_fn (HsLam match')) }

tcExpr e@(HsLamCase _ matches) res_ty
  = do {(wrap1, [arg_ty], body_ty) <-
            matchExpectedFunTys Expected msg 1 res_ty
       ; (wrap2, matches') <- tcMatchesCase match_ctxt arg_ty matches body_ty
       ; return $ mkHsWrap (wrap1 <.> wrap2) $ HsLamCase arg_ty matches' }
  where msg = sep [ ptext (sLit "The function") <+> quotes (ppr e)
                  , ptext (sLit "requires")]
        match_ctxt = MC { mc_what = CaseAlt, mc_body = tcBody }

tcExpr (ExprWithTySig expr sig_ty wcs) res_ty
 = do { nwc_tvs <- mapM newWildcardVarMetaKind wcs
      ; tcExtendTyVarEnv nwc_tvs $ do {
        sig_tc_ty <- tcHsSigType ExprSigCtxt sig_ty
      ; (gen_fn, expr')
            <- tcSkolemise ExprSigCtxt sig_tc_ty $
               \ skol_tvs res_ty ->

                  -- Remember to extend the lexical type-variable environment;
                  -- indeed, this is the only reason we skolemise here at all
               tcExtendTyVarEnv2
                  [(n,tv) | (Just n, tv) <- findScopedTyVars sig_ty sig_tc_ty skol_tvs] $

               tcPolyExprNC expr res_ty

      ; let inner_expr = ExprWithTySigOut (mkLHsWrap gen_fn expr') sig_ty

      ; addErrCtxt (pprSigCtxt ExprSigCtxt empty (ppr sig_ty)) $
        emitWildcardHoleConstraints (zip wcs nwc_tvs)
      ; tcWrapResult inner_expr sig_tc_ty res_ty } }

tcExpr (HsType ty _) _
  = failWithTc (sep [ text "Type argument used outside of a function argument:"
                    , ppr ty ])

{-
************************************************************************
*                                                                      *
                Infix operators and sections
*                                                                      *
************************************************************************

Note [Left sections]
~~~~~~~~~~~~~~~~~~~~
Left sections, like (4 *), are equivalent to
        \ x -> (*) 4 x,
or, if PostfixOperators is enabled, just
        (*) 4
With PostfixOperators we don't actually require the function to take
two arguments at all.  For example, (x `not`) means (not x); you get
postfix operators!  Not Haskell 98, but it's less work and kind of
useful.

Note [Typing rule for ($)]
~~~~~~~~~~~~~~~~~~~~~~~~~~
People write
   runST $ blah
so much, where
   runST :: (forall s. ST s a) -> a
that I have finally given in and written a special type-checking
rule just for saturated appliations of ($).
  * Infer the type of the first argument
  * Decompose it; should be of form (arg2_ty -> res_ty),
       where arg2_ty might be a polytype
  * Use arg2_ty to typecheck arg2

Note [Typing rule for seq]
~~~~~~~~~~~~~~~~~~~~~~~~~~
We want to allow
       x `seq` (# p,q #)
which suggests this type for seq:
   seq :: forall (a:*) (b:??). a -> b -> b,
with (b:??) meaning that be can be instantiated with an unboxed tuple.
But that's ill-kinded!  Function arguments can't be unboxed tuples.
And indeed, you could not expect to do this with a partially-applied
'seq'; it's only going to work when it's fully applied.  so it turns
into
    case x of _ -> (# p,q #)

For a while I slid by by giving 'seq' an ill-kinded type, but then
the simplifier eta-reduced an application of seq and Lint blew up
with a kind error.  It seems more uniform to treat 'seq' as if it
were a language construct.

See also Note [seqId magic] in MkId
-}

tcExpr (OpApp arg1 op fix arg2) res_ty
  | (L loc (HsVar op_name)) <- op
  , op_name `hasKey` seqIdKey           -- Note [Typing rule for seq]
  = do { arg1_ty <- newFlexiTyVarTy liftedTypeKind
       ; let arg2_ty = res_ty
       ; arg1' <- tcArg op (arg1, arg1_ty, 1)
       ; arg2' <- tcArg op (arg2, arg2_ty, 2)
       ; op_id <- tcLookupId op_name
       ; let op' = L loc (HsWrap (mkWpTyApps [arg1_ty, arg2_ty]) (HsVar op_id))
       ; return $ OpApp arg1' op' fix arg2' }

  | (L loc (HsVar op_name)) <- op
  , op_name `hasKey` dollarIdKey        -- Note [Typing rule for ($)]
  = do { traceTc "Application rule" (ppr op)
       ; (arg1', arg1_ty) <- tcInferSigma arg1

       ; let doc = ptext (sLit "The first argument of ($) takes")
       ; (wrap_arg1, [arg2_sigma], op_res_ty) <-
           matchExpectedFunTys (Actual AppOrigin) doc 1 arg1_ty

         -- We have (arg1 $ arg2)
         -- So: arg1_ty = arg2_ty -> op_res_ty
         -- where arg2_sigma maybe polymorphic; that's the point

       ; arg2' <- tcArg op (arg2, arg2_sigma, 2)

         -- Make sure that the argument type has kind '*'
         --    ($) :: forall (a2:*) (r:Open). (a2->r) -> a2 -> r
         -- Eg we do not want to allow  (D#  $  4.0#)   Trac #5570
         --    (which gives a seg fault)
         -- We do this by unifying with a MetaTv; but of course
         -- it must allow foralls in the type it unifies with (hence ReturnTv)!
         --
         -- The *result* type can have any kind (Trac #8739),
         -- so we don't need to check anything for that
       ; a2_tv <- newReturnTyVar liftedTypeKind
       ; let a2_ty = mkTyVarTy a2_tv
       ; co_a <- unifyType arg2_sigma a2_ty    -- arg2_sigma ~N a2_ty

       ; wrap_res <- tcSubTypeHR op_res_ty res_ty    -- op_res -> res

       ; op_id  <- tcLookupId op_name
       ; let op' = L loc (HsWrap (mkWpTyApps [a2_ty, res_ty]) (HsVar op_id))
             -- arg1' :: arg1_ty
             -- wrap_arg1 :: arg1_ty "->" (arg2_sigma -> op_res_ty)
             -- wrap_res :: op_res_ty "->" res_ty
             -- co_a :: arg2_sigma ~N a2_ty
             -- op' :: (a2_ty -> res_ty) -> a2_ty -> res_ty

             -- wrap1 :: arg1_ty "->" (a2_ty -> res_ty)
             wrap1 = mkWpFun (coToHsWrapper (mkTcSymCo co_a))
                       wrap_res a2_ty res_ty <.> wrap_arg1

             -- arg2' :: arg2_sigma
             -- wrap_a :: a2_ty "->" arg2_sigma
       ; return $
         OpApp (mkLHsWrap wrap1 arg1')
               op' fix
               (mkLHsWrapCo co_a arg2') }

  | otherwise
  = do { traceTc "Non Application rule" (ppr op)
       ; (wrap, op', [arg1', arg2']) <- tcApp (Just $ mk_op_msg op) AppOrigin
                                        op [arg1, arg2] res_ty
       ; return $ mkHsWrap wrap $ OpApp arg1' op' fix arg2' }

-- Right sections, equivalent to \ x -> x `op` expr, or
--      \ x -> op x expr

tcExpr (SectionR op arg2) res_ty
  = do { (op', op_ty) <- tcInferFun op
       ; (wrap_fun, [arg1_ty, arg2_ty], op_res_ty) <-
           matchExpectedFunTys (Actual SectionOrigin) (mk_op_msg op) 2 op_ty
       ; wrap_res <- tcSubTypeHR (mkFunTy arg1_ty op_res_ty) res_ty
       ; arg2' <- tcArg op (arg2, arg2_ty, 2)
       ; return $ mkHsWrap wrap_res $
         SectionR (mkLHsWrap wrap_fun op') arg2' }

tcExpr (SectionL arg1 op) res_ty
  = do { (op', op_ty) <- tcInferFun op
       ; dflags <- getDynFlags      -- Note [Left sections]
       ; let n_reqd_args | xopt Opt_PostfixOperators dflags = 1
                         | otherwise                        = 2

       ; (wrap_fn, (arg1_ty:arg_tys), op_res_ty)
           <- matchExpectedFunTys (Actual SectionOrigin)
                (mk_op_msg op) n_reqd_args op_ty
       ; wrap_res <- tcSubTypeHR (mkFunTys arg_tys op_res_ty) res_ty
       ; arg1' <- tcArg op (arg1, arg1_ty, 1)
       ; return $ mkHsWrap wrap_res $
         SectionL arg1' (mkLHsWrap wrap_fn op') }

tcExpr (ExplicitTuple tup_args boxity) res_ty
  | all tupArgPresent tup_args
  = do { let tup_tc = tupleTyCon boxity (length tup_args)
       ; (coi, arg_tys) <- matchExpectedTyConApp tup_tc res_ty
       ; tup_args1 <- tcTupArgs tup_args arg_tys
       ; return $ mkHsWrapCo coi (ExplicitTuple tup_args1 boxity) }

  | otherwise
  = -- The tup_args are a mixture of Present and Missing (for tuple sections)
    do { let kind = case boxity of { Boxed   -> liftedTypeKind
                                   ; Unboxed -> openTypeKind }
             arity = length tup_args
             tup_tc = tupleTyCon boxity arity

       ; arg_tys <- newFlexiTyVarTys (tyConArity tup_tc) kind
       ; let actual_res_ty
               = mkFunTys [ty | (ty, L _ (Missing _)) <- arg_tys `zip` tup_args]
                          (mkTyConApp tup_tc arg_tys)

       ; wrap <- tcSubTypeHR actual_res_ty res_ty

       -- Handle tuple sections where
       ; tup_args1 <- tcTupArgs tup_args arg_tys

       ; return $ mkHsWrap wrap (ExplicitTuple tup_args1 boxity) }

tcExpr (ExplicitList _ witness exprs) res_ty
  = case witness of
      Nothing   -> do  { (coi, elt_ty) <- matchExpectedListTy res_ty
                       ; exprs' <- mapM (tc_elt elt_ty) exprs
                       ; return $ mkHsWrapCo coi (ExplicitList elt_ty Nothing exprs') }

      Just fln -> do  { list_ty <- newFlexiTyVarTy liftedTypeKind
                     ; fln' <- tcSyntaxOp ListOrigin fln (mkFunTys [intTy, list_ty] res_ty)
                     ; (coi, elt_ty) <- matchExpectedListTy list_ty
                     ; exprs' <- mapM (tc_elt elt_ty) exprs
                     ; return $ mkHsWrapCo coi (ExplicitList elt_ty (Just fln') exprs') }
     where tc_elt elt_ty expr = tcPolyExpr expr elt_ty

tcExpr (ExplicitPArr _ exprs) res_ty    -- maybe empty
  = do  { (coi, elt_ty) <- matchExpectedPArrTy res_ty
        ; exprs' <- mapM (tc_elt elt_ty) exprs
        ; return $ mkHsWrapCo coi (ExplicitPArr elt_ty exprs') }
  where
    tc_elt elt_ty expr = tcPolyExpr expr elt_ty

{-
************************************************************************
*                                                                      *
                Let, case, if, do
*                                                                      *
************************************************************************
-}

tcExpr (HsLet binds expr) res_ty
  = do  { (binds', expr') <- tcLocalBinds binds $
                             tcMonoExpr expr res_ty
        ; return (HsLet binds' expr') }

tcExpr (HsCase scrut matches) exp_ty
  = do  {  -- We used to typecheck the case alternatives first.
           -- The case patterns tend to give good type info to use
           -- when typechecking the scrutinee.  For example
           --   case (map f) of
           --     (x:xs) -> ...
           -- will report that map is applied to too few arguments
           --
           -- But now, in the GADT world, we need to typecheck the scrutinee
           -- first, to get type info that may be refined in the case alternatives
          (scrut', scrut_ty) <- tcInferSigma scrut

        ; traceTc "HsCase" (ppr scrut_ty)
        ; (wrap, matches') <- tcMatchesCase match_ctxt scrut_ty matches exp_ty
        ; return $ mkHsWrap wrap $ HsCase scrut' matches' }
 where
    match_ctxt = MC { mc_what = CaseAlt,
                      mc_body = tcBody }

tcExpr (HsIf Nothing pred b1 b2) res_ty    -- Ordinary 'if'
  = do { pred' <- tcMonoExpr pred boolTy
            -- this forces the branches to be fully instantiated
            -- (See #10619)
       ; tau_ty <- tauTvsForReturnTvs res_ty
       ; b1' <- tcMonoExpr b1 tau_ty
       ; b2' <- tcMonoExpr b2 tau_ty
       ; tcWrapResult (HsIf Nothing pred' b1' b2') tau_ty res_ty }

tcExpr (HsIf (Just fun) pred b1 b2) res_ty
  -- Note [Rebindable syntax for if]
  = do { (wrap, fun', [pred', b1', b2'])
           <- tcApp (Just herald) IfOrigin (noLoc fun) [pred, b1, b2] res_ty
       ; return $ mkHsWrap wrap $ (HsIf (Just (unLoc fun')) pred' b1' b2') }
  where
    herald = text "Rebindable" <+> quotes (text "if") <+> text "takes"

tcExpr (HsMultiIf _ alts) res_ty
  = do { alts' <- mapM (wrapLocM $ tcGRHS match_ctxt res_ty) alts
       ; return $ HsMultiIf res_ty alts' }
  where match_ctxt = MC { mc_what = IfAlt, mc_body = tcBody }

tcExpr (HsDo do_or_lc stmts _) res_ty
  = tcDoStmts do_or_lc stmts res_ty

tcExpr (HsProc pat cmd) res_ty
  = do  { (pat', cmd', coi) <- tcProc pat cmd res_ty
        ; return $ mkHsWrapCo coi (HsProc pat' cmd') }

tcExpr (HsStatic expr) res_ty
  = do  { staticPtrTyCon  <- tcLookupTyCon staticPtrTyConName
        ; (co, [expr_ty]) <- matchExpectedTyConApp staticPtrTyCon res_ty
        ; (expr', lie)    <- captureConstraints $
            addErrCtxt (hang (ptext (sLit "In the body of a static form:"))
                             2 (ppr expr)
                       ) $
            tcPolyExprNC expr expr_ty
        -- Require the type of the argument to be Typeable.
        -- The evidence is not used, but asking the constraint ensures that
        -- the current implementation is as restrictive as future versions
        -- of the StaticPointers extension.
        ; typeableClass <- tcLookupClass typeableClassName
        ; _ <- emitWanted StaticOrigin $
                  mkTyConApp (classTyCon typeableClass)
                             [liftedTypeKind, expr_ty]
        -- Insert the static form in a global list for later validation.
        ; stWC <- tcg_static_wc <$> getGblEnv
        ; updTcRef stWC (andWC lie)
        ; return $ mkHsWrapCo co $ HsStatic expr'
        }

{-
Note [Rebindable syntax for if]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The rebindable syntax for 'if' uses the most flexible possible type
for conditionals:
  ifThenElse :: p -> b1 -> b2 -> res
to support expressions like this:

 ifThenElse :: Maybe a -> (a -> b) -> b -> b
 ifThenElse (Just a) f _ = f a
 ifThenElse Nothing  _ e = e

 example :: String
 example = if Just 2
              then \v -> show v
              else "No value"


************************************************************************
*                                                                      *
                Record construction and update
*                                                                      *
************************************************************************
-}

tcExpr (RecordCon (L loc con_name) _ rbinds) res_ty
  = do  { data_con <- tcLookupDataCon con_name

        -- Check for missing fields
        ; checkMissingFields data_con rbinds

        ; (con_expr, con_sigma) <- tcInferId con_name
        ; (con_wrap, con_tau) <-
            topInstantiate (OccurrenceOf con_name) con_sigma
              -- a shallow instantiation should really be enough for
              -- a data constructor.
        ; let arity = dataConSourceArity data_con
              (arg_tys, actual_res_ty) = tcSplitFunTysN con_tau arity
              con_id = dataConWrapId data_con

        ; res_wrap <- tcSubTypeHR actual_res_ty res_ty
        ; rbinds' <- tcRecordBinds data_con arg_tys rbinds
        ; return $ mkHsWrap res_wrap $
          RecordCon (L loc con_id) (mkHsWrap con_wrap con_expr) rbinds' }

{-
Note [Type of a record update]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The main complication with RecordUpd is that we need to explicitly
handle the *non-updated* fields.  Consider:

        data T a b c = MkT1 { fa :: a, fb :: (b,c) }
                     | MkT2 { fa :: a, fb :: (b,c), fc :: c -> c }
                     | MkT3 { fd :: a }

        upd :: T a b c -> (b',c) -> T a b' c
        upd t x = t { fb = x}

The result type should be (T a b' c)
not (T a b c),   because 'b' *is not* mentioned in a non-updated field
not (T a b' c'), because 'c' *is*     mentioned in a non-updated field
NB that it's not good enough to look at just one constructor; we must
look at them all; cf Trac #3219

After all, upd should be equivalent to:
        upd t x = case t of
                        MkT1 p q -> MkT1 p x
                        MkT2 a b -> MkT2 p b
                        MkT3 d   -> error ...

So we need to give a completely fresh type to the result record,
and then constrain it by the fields that are *not* updated ("p" above).
We call these the "fixed" type variables, and compute them in getFixedTyVars.

Note that because MkT3 doesn't contain all the fields being updated,
its RHS is simply an error, so it doesn't impose any type constraints.
Hence the use of 'relevant_cont'.

Note [Implicit type sharing]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
We also take into account any "implicit" non-update fields.  For example
        data T a b where { MkT { f::a } :: T a a; ... }
So the "real" type of MkT is: forall ab. (a~b) => a -> T a b

Then consider
        upd t x = t { f=x }
We infer the type
        upd :: T a b -> a -> T a b
        upd (t::T a b) (x::a)
           = case t of { MkT (co:a~b) (_:a) -> MkT co x }
We can't give it the more general type
        upd :: T a b -> c -> T c b

Note [Criteria for update]
~~~~~~~~~~~~~~~~~~~~~~~~~~
We want to allow update for existentials etc, provided the updated
field isn't part of the existential. For example, this should be ok.
  data T a where { MkT { f1::a, f2::b->b } :: T a }
  f :: T a -> b -> T b
  f t b = t { f1=b }

The criterion we use is this:

  The types of the updated fields
  mention only the universally-quantified type variables
  of the data constructor

NB: this is not (quite) the same as being a "naughty" record selector
(See Note [Naughty record selectors]) in TcTyClsDecls), at least
in the case of GADTs. Consider
   data T a where { MkT :: { f :: a } :: T [a] }
Then f is not "naughty" because it has a well-typed record selector.
But we don't allow updates for 'f'.  (One could consider trying to
allow this, but it makes my head hurt.  Badly.  And no one has asked
for it.)

In principle one could go further, and allow
  g :: T a -> T a
  g t = t { f2 = \x -> x }
because the expression is polymorphic...but that seems a bridge too far.

Note [Data family example]
~~~~~~~~~~~~~~~~~~~~~~~~~~
    data instance T (a,b) = MkT { x::a, y::b }
  --->
    data :TP a b = MkT { a::a, y::b }
    coTP a b :: T (a,b) ~ :TP a b

Suppose r :: T (t1,t2), e :: t3
Then  r { x=e } :: T (t3,t1)
  --->
      case r |> co1 of
        MkT x y -> MkT e y |> co2
      where co1 :: T (t1,t2) ~ :TP t1 t2
            co2 :: :TP t3 t2 ~ T (t3,t2)
The wrapping with co2 is done by the constructor wrapper for MkT

Outgoing invariants
~~~~~~~~~~~~~~~~~~~
In the outgoing (HsRecordUpd scrut binds cons in_inst_tys out_inst_tys):

  * cons are the data constructors to be updated

  * in_inst_tys, out_inst_tys have same length, and instantiate the
        *representation* tycon of the data cons.  In Note [Data
        family example], in_inst_tys = [t1,t2], out_inst_tys = [t3,t2]
-}

tcExpr (RecordUpd record_expr rbinds _ _ _) res_ty
  = ASSERT( notNull upd_fld_names )
    do  {
        -- STEP 0
        -- Check that the field names are really field names
        ; sel_ids <- mapM tcLookupField upd_fld_names
                        -- The renamer has already checked that
                        -- selectors are all in scope
        ; let bad_guys = [ setSrcSpan loc $ addErrTc (notSelector fld_name)
                         | (fld, sel_id) <- rec_flds rbinds `zip` sel_ids,
                           not (isRecordSelector sel_id),       -- Excludes class ops
                           let L loc fld_name = hsRecFieldId (unLoc fld) ]
        ; unless (null bad_guys) (sequence bad_guys >> failM)

        -- STEP 1
        -- Figure out the tycon and data cons from the first field name
        ; let   -- It's OK to use the non-tc splitters here (for a selector)
              sel_id : _  = sel_ids
              (tycon, _)  = recordSelectorFieldLabel sel_id     -- We've failed already if
              data_cons   = tyConDataCons tycon                 -- it's not a field label
                -- NB: for a data type family, the tycon is the instance tycon

              relevant_cons   = filter is_relevant data_cons
              is_relevant con = all (`elem` dataConFieldLabels con) upd_fld_names
                -- A constructor is only relevant to this process if
                -- it contains *all* the fields that are being updated
                -- Other ones will cause a runtime error if they occur

                -- Take apart a representative constructor
              con1 = ASSERT( not (null relevant_cons) ) head relevant_cons
              (con1_tvs, _, _, _, con1_arg_tys, _) = dataConFullSig con1
              con1_flds = dataConFieldLabels con1
              con1_res_ty = mkFamilyTyConApp tycon (mkTyVarTys con1_tvs)

        -- Step 2
        -- Check that at least one constructor has all the named fields
        -- i.e. has an empty set of bad fields returned by badFields
        ; checkTc (not (null relevant_cons)) (badFieldsUpd rbinds data_cons)

        -- STEP 3    Note [Criteria for update]
        -- Check that each updated field is polymorphic; that is, its type
        -- mentions only the universally-quantified variables of the data con
        ; let flds1_w_tys = zipEqual "tcExpr:RecConUpd" con1_flds con1_arg_tys
              upd_flds1_w_tys = filter is_updated flds1_w_tys
              is_updated (fld,_) = fld `elem` upd_fld_names

              bad_upd_flds = filter bad_fld upd_flds1_w_tys
              con1_tv_set = mkVarSet con1_tvs
              bad_fld (fld, ty) = fld `elem` upd_fld_names &&
                                      not (tyVarsOfType ty `subVarSet` con1_tv_set)
        ; checkTc (null bad_upd_flds) (badFieldTypes bad_upd_flds)

        -- STEP 4  Note [Type of a record update]
        -- Figure out types for the scrutinee and result
        -- Both are of form (T a b c), with fresh type variables, but with
        -- common variables where the scrutinee and result must have the same type
        -- These are variables that appear in *any* arg of *any* of the
        -- relevant constructors *except* in the updated fields
        --
        ; let fixed_tvs = getFixedTyVars con1_tvs relevant_cons
              is_fixed_tv tv = tv `elemVarSet` fixed_tvs

              mk_inst_ty :: TvSubst -> (TKVar, TcType) -> TcM (TvSubst, TcType)
              -- Deals with instantiation of kind variables
              --   c.f. TcMType.tcInstTyVars
              mk_inst_ty subst (tv, result_inst_ty)
                | is_fixed_tv tv   -- Same as result type
                = return (extendTvSubst subst tv result_inst_ty, result_inst_ty)
                | otherwise        -- Fresh type, of correct kind
                = do { new_ty <- newFlexiTyVarTy (TcType.substTy subst (tyVarKind tv))
                     ; return (extendTvSubst subst tv new_ty, new_ty) }

        ; (result_subst, con1_tvs') <- tcInstTyVars con1_tvs
        ; let result_inst_tys = mkTyVarTys con1_tvs'

        ; (scrut_subst, scrut_inst_tys) <- mapAccumLM mk_inst_ty emptyTvSubst
                                                      (con1_tvs `zip` result_inst_tys)

        ; let rec_res_ty    = TcType.substTy result_subst con1_res_ty
              scrut_ty      = TcType.substTy scrut_subst  con1_res_ty
              con1_arg_tys' = map (TcType.substTy result_subst) con1_arg_tys

        ; wrap_res <- tcSubTypeHR rec_res_ty res_ty

        -- STEP 5
        -- Typecheck the thing to be updated, and the bindings
        ; record_expr' <- tcMonoExpr record_expr scrut_ty
        ; rbinds'      <- tcRecordBinds con1 con1_arg_tys' rbinds

        -- STEP 6: Deal with the stupid theta
        ; let theta' = substTheta scrut_subst (dataConStupidTheta con1)
        ; instStupidTheta RecordUpdOrigin theta'

        -- Step 7: make a cast for the scrutinee, in the case that it's from a type family
        ; let scrut_co | Just co_con <- tyConFamilyCoercion_maybe tycon
                       = mkWpCast (mkTcUnbranchedAxInstCo Representational co_con scrut_inst_tys)
                       | otherwise
                       = idHsWrapper
        -- Phew!
        ; return $ mkHsWrap wrap_res $
          RecordUpd (mkLHsWrap scrut_co record_expr') rbinds'
                    relevant_cons scrut_inst_tys result_inst_tys  }
  where
    upd_fld_names = hsRecFields rbinds

    getFixedTyVars :: [TyVar] -> [DataCon] -> TyVarSet
    -- These tyvars must not change across the updates
    getFixedTyVars tvs1 cons
      = mkVarSet [tv1 | con <- cons
                      , let (tvs, theta, arg_tys, _) = dataConSig con
                            flds = dataConFieldLabels con
                            fixed_tvs = exactTyVarsOfTypes fixed_tys
                                    -- fixed_tys: See Note [Type of a record update]
                                        `unionVarSet` tyVarsOfTypes theta
                                    -- Universally-quantified tyvars that
                                    -- appear in any of the *implicit*
                                    -- arguments to the constructor are fixed
                                    -- See Note [Implicit type sharing]

                            fixed_tys = [ty | (fld,ty) <- zip flds arg_tys
                                            , not (fld `elem` upd_fld_names)]
                      , (tv1,tv) <- tvs1 `zip` tvs      -- Discards existentials in tvs
                      , tv `elemVarSet` fixed_tvs ]

{-
************************************************************************
*                                                                      *
        Arithmetic sequences                    e.g. [a,b..]
        and their parallel-array counterparts   e.g. [: a,b.. :]

*                                                                      *
************************************************************************
-}

tcExpr (ArithSeq _ witness seq) res_ty
  = tcArithSeq witness seq res_ty

tcExpr (PArrSeq _ seq@(FromTo expr1 expr2)) res_ty
  = do  { (coi, elt_ty) <- matchExpectedPArrTy res_ty
        ; expr1' <- tcPolyExpr expr1 elt_ty
        ; expr2' <- tcPolyExpr expr2 elt_ty
        ; enumFromToP <- initDsTc $ dsDPHBuiltin enumFromToPVar
        ; enum_from_to <- newMethodFromName (PArrSeqOrigin seq)
                                 (idName enumFromToP) elt_ty
        ; return $ mkHsWrapCo coi
                     (PArrSeq enum_from_to (FromTo expr1' expr2')) }

tcExpr (PArrSeq _ seq@(FromThenTo expr1 expr2 expr3)) res_ty
  = do  { (coi, elt_ty) <- matchExpectedPArrTy res_ty
        ; expr1' <- tcPolyExpr expr1 elt_ty
        ; expr2' <- tcPolyExpr expr2 elt_ty
        ; expr3' <- tcPolyExpr expr3 elt_ty
        ; enumFromThenToP <- initDsTc $ dsDPHBuiltin enumFromThenToPVar
        ; eft <- newMethodFromName (PArrSeqOrigin seq)
                      (idName enumFromThenToP) elt_ty        -- !!!FIXME: chak
        ; return $ mkHsWrapCo coi
                     (PArrSeq eft (FromThenTo expr1' expr2' expr3')) }

tcExpr (PArrSeq _ _) _
  = panic "TcExpr.tcExpr: Infinite parallel array!"
    -- the parser shouldn't have generated it and the renamer shouldn't have
    -- let it through

{-
************************************************************************
*                                                                      *
                Template Haskell
*                                                                      *
************************************************************************
-}

tcExpr (HsSpliceE splice)        res_ty = tcSpliceExpr splice res_ty
tcExpr (HsBracket brack)         res_ty = tcTypedBracket   brack res_ty
tcExpr (HsRnBracketOut brack ps) res_ty = tcUntypedBracket brack ps res_ty

{-
************************************************************************
*                                                                      *
                Catch-all
*                                                                      *
************************************************************************
-}

tcExpr other _ = pprPanic "tcMonoExpr" (ppr other)
  -- Include ArrForm, ArrApp, which shouldn't appear at all
  -- Also HsTcBracketOut, HsQuasiQuoteE

{-
************************************************************************
*                                                                      *
                Arithmetic sequences [a..b] etc
*                                                                      *
************************************************************************
-}

tcArithSeq :: Maybe (SyntaxExpr Name) -> ArithSeqInfo Name -> TcRhoType
           -> TcM (HsExpr TcId)

tcArithSeq witness seq@(From expr) res_ty
  = do { (coi, elt_ty, wit') <- arithSeqEltType witness res_ty
       ; expr' <- tcPolyExpr expr elt_ty
       ; enum_from <- newMethodFromName (ArithSeqOrigin seq)
                              enumFromName elt_ty
       ; return $ mkHsWrapCo coi (ArithSeq enum_from wit' (From expr')) }

tcArithSeq witness seq@(FromThen expr1 expr2) res_ty
  = do { (coi, elt_ty, wit') <- arithSeqEltType witness res_ty
       ; expr1' <- tcPolyExpr expr1 elt_ty
       ; expr2' <- tcPolyExpr expr2 elt_ty
       ; enum_from_then <- newMethodFromName (ArithSeqOrigin seq)
                              enumFromThenName elt_ty
       ; return $ mkHsWrapCo coi (ArithSeq enum_from_then wit' (FromThen expr1' expr2')) }

tcArithSeq witness seq@(FromTo expr1 expr2) res_ty
  = do { (coi, elt_ty, wit') <- arithSeqEltType witness res_ty
       ; expr1' <- tcPolyExpr expr1 elt_ty
       ; expr2' <- tcPolyExpr expr2 elt_ty
       ; enum_from_to <- newMethodFromName (ArithSeqOrigin seq)
                              enumFromToName elt_ty
       ; return $ mkHsWrapCo coi (ArithSeq enum_from_to wit' (FromTo expr1' expr2')) }

tcArithSeq witness seq@(FromThenTo expr1 expr2 expr3) res_ty
  = do { (coi, elt_ty, wit') <- arithSeqEltType witness res_ty
        ; expr1' <- tcPolyExpr expr1 elt_ty
        ; expr2' <- tcPolyExpr expr2 elt_ty
        ; expr3' <- tcPolyExpr expr3 elt_ty
        ; eft <- newMethodFromName (ArithSeqOrigin seq)
                              enumFromThenToName elt_ty
        ; return $ mkHsWrapCo coi (ArithSeq eft wit' (FromThenTo expr1' expr2' expr3')) }

-----------------
arithSeqEltType :: Maybe (SyntaxExpr Name) -> TcRhoType
                -> TcM (TcCoercionN, TcType, Maybe (SyntaxExpr Id))
arithSeqEltType Nothing res_ty
  = do { (coi, elt_ty) <- matchExpectedListTy res_ty
       ; return (coi, elt_ty, Nothing) }
arithSeqEltType (Just fl) res_ty
  = do { list_ty <- newFlexiTyVarTy liftedTypeKind
       ; fl' <- tcSyntaxOp ListOrigin fl (mkFunTy list_ty res_ty)
       ; (coi, elt_ty) <- matchExpectedListTy list_ty
       ; return (coi, elt_ty, Just fl') }

{-
************************************************************************
*                                                                      *
                Applications
*                                                                      *
************************************************************************
-}

tcApp :: Maybe SDoc  -- like "The function `f' is applied to"
                     -- or leave out to get exactly that message
      -> CtOrigin
      -> LHsExpr Name -> [LHsExpr Name] -- Function and args
      -> TcRhoType -> TcM (HsWrapper, LHsExpr TcId, [LHsExpr TcId])
           -- (wrap, fun, args). For an ordinary function application,
           -- these should be assembled as (wrap (fun args)).
           -- But OpApp is slightly different, so that's why the caller
           -- must assemble

tcApp m_herald orig orig_fun orig_args res_ty
  = go orig_fun orig_args
  where
    go (L _ (HsPar e))     args = go e  args
    go (L _ (HsApp e1 e2)) args = go e1 (e2:args)

    go (L loc (HsVar fun)) args
      | fun `hasKey` tagToEnumKey
      , count (not . isLHsTypeExpr) args == 1
      = tcTagToEnum loc fun args res_ty

      | fun `hasKey` seqIdKey
      , count (not . isLHsTypeExpr) args == 2
      = tcSeq loc fun args res_ty

    go fun args
      = do {   -- Type-check the function
           ; (fun1, fun_sigma) <- tcInferFun fun

               -- Extract its argument types
           ; (wrap_fun, expected_arg_tys, actual_res_ty)
                 <- matchExpectedFunTys_Args orig
                      (m_herald `orElse` mk_app_msg fun)
                      fun args fun_sigma

           -- Typecheck the result, thereby propagating
           -- info (if any) from result into the argument types
           -- Both actual_res_ty and res_ty are deeply skolemised
           -- Rather like tcWrapResult, but (perhaps for historical reasons)
           -- we do this before typechecking the arguments
           ; wrap_res <- addErrCtxtM (funResCtxt True (unLoc fun) actual_res_ty res_ty) $
                         tcSubTypeDS_NC GenSigCtxt actual_res_ty res_ty

           -- Typecheck the arguments
           ; args1 <- tcArgs fun args expected_arg_tys

           -- Assemble the result
           ; return (wrap_res, mkLHsWrap wrap_fun fun1, args1) }

mk_app_msg :: LHsExpr Name -> SDoc
mk_app_msg fun = sep [ ptext (sLit "The function") <+> quotes (ppr fun)
                     , ptext (sLit "is applied to")]

mk_op_msg :: LHsExpr Name -> SDoc
mk_op_msg op = text "The operator" <+> quotes (ppr op) <+> text "takes"

----------------
tcInferFun :: LHsExpr Name -> TcM (LHsExpr TcId, TcSigmaType)
-- Infer type of a function
tcInferFun (L loc (HsVar name))
  = do { (fun, ty) <- setSrcSpan loc (tcInferId name)
               -- Don't wrap a context around a plain Id
       ; return (L loc fun, ty) }

tcInferFun fun
  = do { (fun, fun_ty) <- tcInferSigma fun

         -- Zonk the function type carefully, to expose any polymorphism
         -- E.g. (( \(x::forall a. a->a). blah ) e)
         -- We can see the rank-2 type of the lambda in time to generalise e
       ; fun_ty' <- zonkTcType fun_ty

       ; return (fun, fun_ty') }

----------------
tcArgs :: LHsExpr Name                          -- The function (for error messages)
       -> [LHsExpr Name] -> [TcSigmaType]       -- Actual arguments and expected arg types
       -> TcM [LHsExpr TcId]                    -- Resulting args

tcArgs fun orig_args orig_arg_tys = go 1 orig_args orig_arg_tys
  where
    go _ [] [] = return []
    go n (arg:args) all_arg_tys
      | Just (hs_ty, _) <- isLHsTypeExpr_maybe arg
      = do { args' <- go (n+1) args all_arg_tys
           ; return (L (getLoc arg) (HsTypeOut hs_ty) : args') }

    go n (arg:args) (arg_ty:arg_tys)
      = do { arg'  <- tcArg fun (arg, arg_ty, n)
           ; args' <- go (n+1) args arg_tys
           ; return (arg':args') }

    go _ _ _ = pprPanic "tcArgs" (ppr fun $$ ppr orig_args $$ ppr orig_arg_tys)

----------------
tcArg :: LHsExpr Name                           -- The function (for error messages)
       -> (LHsExpr Name, TcSigmaType, Int)      -- Actual argument and expected arg type
       -> TcM (LHsExpr TcId)                    -- Resulting argument
tcArg fun (arg, ty, arg_no) = addErrCtxt (funAppCtxt fun arg arg_no)
                                         (tcPolyExprNC arg ty)

----------------
tcTupArgs :: [LHsTupArg Name] -> [TcSigmaType] -> TcM [LHsTupArg TcId]
tcTupArgs args tys
  = ASSERT( equalLength args tys ) mapM go (args `zip` tys)
  where
    go (L l (Missing {}),   arg_ty) = return (L l (Missing arg_ty))
    go (L l (Present expr), arg_ty) = do { expr' <- tcPolyExpr expr arg_ty
                                         ; return (L l (Present expr')) }

---------------------------
tcSyntaxOp :: CtOrigin -> HsExpr Name -> TcType -> TcM (HsExpr TcId)
-- Typecheck a syntax operator, checking that it has the specified type
-- The operator is always a variable at this stage (i.e. renamer output)
-- This version assumes res_ty is a monotype
tcSyntaxOp orig (HsVar op) res_ty = do { (expr, rho) <- tcInferIdWithOrig orig op
                                       ; tcWrapResult expr rho res_ty }

tcSyntaxOp _ other         _      = pprPanic "tcSyntaxOp" (ppr other)

{-
Note [Push result type in]
~~~~~~~~~~~~~~~~~~~~~~~~~~
Unify with expected result before type-checking the args so that the
info from res_ty percolates to args.  This is when we might detect a
too-few args situation.  (One can think of cases when the opposite
order would give a better error message.)
experimenting with putting this first.

Here's an example where it actually makes a real difference

   class C t a b | t a -> b
   instance C Char a Bool

   data P t a = forall b. (C t a b) => MkP b
   data Q t   = MkQ (forall a. P t a)

   f1, f2 :: Q Char;
   f1 = MkQ (MkP True)
   f2 = MkQ (MkP True :: forall a. P Char a)

With the change, f1 will type-check, because the 'Char' info from
the signature is propagated into MkQ's argument. With the check
in the other order, the extra signature in f2 is reqd.

Note [Visible type application]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
TODO (RAE): Move Note?

GHC implements a generalisation of the algorithm described in the
"Visible Type Application" paper (available from
http://www.cis.upenn.edu/~sweirich/publications.html). A key part
of that algorithm is to distinguish user-specified variables from inferred
variables. For example, the following should typecheck:

  f :: forall a b. a -> b -> b
  f = const id

  g = const id

  x = f @Int @Bool 5 False
  y = g 5 @Bool False

The idea is that we wish to allow visible type application when we are
instantiating a specified, fixed variable. In practice, specified, fixed
variables are either written in a type signature (or
annotation), OR are imported from another module. (We could do better here,
for example by doing SCC analysis on parts of a module and considering any
type from outside one's SCC to be fully specified, but this is very confusing to
users. The simple rule above is much more straightforward and predictable.)

So, both of f's quantified variables are specified and may be instantiated.
But g has no type signature, so only id's variable is specified (because id
is imported). We write the type of g as forall {a}. a -> forall b. b -> b.
Note that the a is in braces, meaning it cannot be instantiated with
visible type application.

Tracking specified vs. inferred variables is done conveniently by looking at
Names. A System name (from mkSystemName or a variant) is an inferred
variable; an Internal name is a specified one. Simple. This works out
because skolemiseUnboundMetaTyVar always produces a System name.

The only wrinkle with this scheme is in tidying. If all inferred names
are System names, then tidying will append lots of 0s. This pollutes
interface files and Haddock output. So we convert System tyvars to
Internal ones during the final zonk. This works because type-checking
is fully complete, and therefore the distinction between specified and
inferred is no longer relevant.

If using System vs. Internal to perform type-checking seems suspicious,
the alternative approach would mean adding a field to ForAllTy to track
specified vs. inferred. That seems considerably more painful. And, anyway,
once the (* :: *) branch is merged, this will be redesigned somewhat
to move away from using Names. That's because the (* :: *) branch already
has more structure available in ForAllTy, and there, it's easy to squeeze
in another specified-vs.-inferred bit.

TODO (RAE): Update this Note in the (* :: *) branch when merging.

************************************************************************
*                                                                      *
                 tcInferId
*                                                                      *
************************************************************************
-}

tcCheckId :: Name -> TcRhoType -> TcM (HsExpr TcId)
tcCheckId name res_ty
  = do { (expr, actual_res_ty) <- tcInferId name
       ; traceTc "tcCheckId" (vcat [ppr name, ppr actual_res_ty, ppr res_ty])
       ; addErrCtxtM (funResCtxt False (HsVar name) actual_res_ty res_ty) $
         tcWrapResult expr actual_res_ty res_ty }

------------------------
tcInferId :: Name -> TcM (HsExpr TcId, TcSigmaType)
-- Infer type, and deeply instantiate
tcInferId n = tcInferIdWithOrig (OccurrenceOf n) n

------------------------
tcInferIdWithOrig :: CtOrigin -> Name -> TcM (HsExpr TcId, TcSigmaType)
-- Look up an occurrence of an Id

tcInferIdWithOrig orig id_name
  | id_name `hasKey` tagToEnumKey
  = failWithTc (ptext (sLit "tagToEnum# must appear applied to one argument"))
        -- tcApp catches the case (tagToEnum# arg)

  | id_name `hasKey` assertIdKey
  = do { dflags <- getDynFlags
       ; if gopt Opt_IgnoreAsserts dflags
         then tc_infer_id orig id_name
         else tc_infer_assert dflags orig }

  | otherwise
  = do { (expr, ty) <- tc_infer_id orig id_name
       ; traceTc "tcInferIdWithOrig" (ppr id_name <+> dcolon <+> ppr ty)
       ; return (expr, ty) }

tc_infer_assert :: DynFlags -> CtOrigin -> TcM (HsExpr TcId, TcSigmaType)
-- Deal with an occurrence of 'assert'
-- See Note [Adding the implicit parameter to 'assert']
tc_infer_assert dflags orig
  = do { sloc <- getSrcSpanM
       ; assert_error_id <- tcLookupId assertErrorName
       ; (wrap, id_rho) <- topInstantiate orig (idType assert_error_id)
       ; let (arg_ty, res_ty) = case tcSplitFunTy_maybe id_rho of
                                   Nothing      -> pprPanic "assert type" (ppr id_rho)
                                   Just arg_res -> arg_res
       ; ASSERT( arg_ty `tcEqType` addrPrimTy )
         return (HsApp (L sloc (mkHsWrap wrap (HsVar assert_error_id)))
                       (L sloc (srcSpanPrimLit dflags sloc))
                , res_ty) }

tc_infer_id :: CtOrigin -> Name -> TcM (HsExpr TcId, TcSigmaType)
-- Return type is deeply instantiated
tc_infer_id orig id_name
 = do { thing <- tcLookup id_name
      ; case thing of
             ATcId { tct_id = id }
               -> do { check_naughty id        -- Note [Local record selectors]
                     ; checkThLocalId id
                     ; return_id id }

             AGlobal (AnId id)
               -> do { check_naughty id
                     ; return_id id }
                    -- A global cannot possibly be ill-staged
                    -- nor does it need the 'lifting' treatment
                    -- hence no checkTh stuff here

             AGlobal (AConLike cl) -> case cl of
                 RealDataCon con -> return_data_con con
                 PatSynCon ps    -> tcPatSynBuilderOcc orig ps

             _ -> failWithTc $
                  ppr thing <+> ptext (sLit "used where a value identifier was expected") }
  where
    return_id id = return (HsVar id, idType id)

    return_data_con con
       -- For data constructors, must perform the stupid-theta check
      | null stupid_theta
      = return_id con_wrapper_id

      | otherwise
       -- See Note [Instantiating stupid theta]
      = do { let (tvs, theta, rho) = tcSplitSigmaTy (idType con_wrapper_id)
           ; (subst, tvs') <- tcInstTyVars tvs
           ; let tys'   = mkTyVarTys tvs'
                 theta' = substTheta subst theta
                 rho'   = substTy subst rho
           ; wrap <- instCall orig tys' theta'
           ; addDataConStupidTheta con tys'
           ; return (mkHsWrap wrap (HsVar con_wrapper_id), rho') }

      where
        con_wrapper_id = dataConWrapId con
        stupid_theta   = dataConStupidTheta con

    check_naughty id
      | isNaughtyRecordSelector id = failWithTc (naughtyRecordSel id)
      | otherwise                  = return ()

srcSpanPrimLit :: DynFlags -> SrcSpan -> HsExpr TcId
srcSpanPrimLit dflags span
    = HsLit (HsStringPrim "" (unsafeMkByteString
                             (showSDocOneLine dflags (ppr span))))

tcUnboundId :: OccName -> TcRhoType -> TcM (HsExpr TcId)
-- Typechedk an occurrence of an unbound Id
--
-- Some of these started life as a true hole "_".  Others might simply
-- be variables that accidentally have no binding site
--
-- We turn all of them into HsVar, since HsUnboundVar can't contain an
-- Id; and indeed the evidence for the CHoleCan does bind it, so it's
-- not unbound any more!
tcUnboundId occ res_ty
 = do { ty <- newFlexiTyVarTy liftedTypeKind
      ; name <- newSysName occ
      ; let ev = mkLocalId name ty NoSigId
      ; loc <- getCtLocM HoleOrigin
      ; let can = CHoleCan { cc_ev = CtWanted ty ev loc, cc_occ = occ
                           , cc_hole = ExprHole }
      ; emitInsoluble can
      ; tcWrapResult (HsVar ev) ty res_ty }

{-
Note [Adding the implicit parameter to 'assert']
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The typechecker transforms (assert e1 e2) to (assertError "Foo.hs:27"
e1 e2).  This isn't really the Right Thing because there's no way to
"undo" if you want to see the original source code in the typechecker
output.  We'll have fix this in due course, when we care more about
being able to reconstruct the exact original program.

Note [tagToEnum#]
~~~~~~~~~~~~~~~~~
Nasty check to ensure that tagToEnum# is applied to a type that is an
enumeration TyCon.  Unification may refine the type later, but this
check won't see that, alas.  It's crude, because it relies on our
knowing *now* that the type is ok, which in turn relies on the
eager-unification part of the type checker pushing enough information
here.  In theory the Right Thing to do is to have a new form of
constraint but I definitely cannot face that!  And it works ok as-is.

Here's are two cases that should fail
        f :: forall a. a
        f = tagToEnum# 0        -- Can't do tagToEnum# at a type variable

        g :: Int
        g = tagToEnum# 0        -- Int is not an enumeration

When data type families are involved it's a bit more complicated.
     data family F a
     data instance F [Int] = A | B | C
Then we want to generate something like
     tagToEnum# R:FListInt 3# |> co :: R:FListInt ~ F [Int]
Usually that coercion is hidden inside the wrappers for
constructors of F [Int] but here we have to do it explicitly.

It's all grotesquely complicated.

Note [Instantiating stupid theta]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Normally, when we infer the type of an Id, we don't instantiate,
because we wish to allow for visible type application later on.
But if a datacon has a stupid theta, we're a bit stuck. We need
to emit the stupid theta constraints with instantiated types. It's
difficult to defer this to the lazy instantiation, because a stupid
theta has no spot to put it in a type. So we just instantiate eagerly
in this case. Thus, users cannot use visible type application with
a data constructor sporting a stupid theta. I won't feel so bad for
the users that complain.

-}

tcSeq :: SrcSpan -> Name -> [LHsExpr Name]
      -> TcRhoType -> TcM (HsWrapper, LHsExpr TcId, [LHsExpr TcId])
-- (seq e1 e2) :: res_ty
-- We need a special typing rule because res_ty can be unboxed
tcSeq loc fun_name args res_ty
  = do  { fun <- tcLookupId fun_name
        ; (arg1_ty, args1) <- case args of
            (ty_arg_expr1 : args1)
              | Just hs_ty_arg1 <- isLHsTypeExpr_maybe ty_arg_expr1
              -> do { ty_arg1 <- tcHsTypeApp hs_ty_arg1 liftedTypeKind
                    ; return (ty_arg1, args1) }

            _ -> do { arg_ty1 <- newReturnTyVarTy liftedTypeKind
                    ; return (arg_ty1, args) }

        ; (arg1, arg2) <- case args1 of
            [ty_arg_expr2, term_arg1, term_arg2]
              | Just hs_ty_arg2 <- isLHsTypeExpr_maybe ty_arg_expr2
              -> do { ty_arg2 <- tcHsTypeApp hs_ty_arg2 openTypeKind
                    ; _ <- unifyType ty_arg2 res_ty
                    ; return (term_arg1, term_arg2) }
            [term_arg1, term_arg2] -> return (term_arg1, term_arg2)
            _ -> too_many_args

        ; arg1' <- tcMonoExpr arg1 arg1_ty
        ; res_ty <- zonkTcType res_ty   -- just in case we learned something
                                        -- interesting about it
        ; arg2' <- tcMonoExpr arg2 res_ty
        ; let fun'    = L loc (HsWrap ty_args (HsVar fun))
              ty_args = WpTyApp res_ty <.> WpTyApp arg1_ty
        ; return (idHsWrapper, fun', [arg1', arg2']) }
  where
    too_many_args :: TcM a
    too_many_args
      = failWith $
        hang (text "Too many type arguments to seq:")
           2 (sep (map pprParendExpr args))


tcTagToEnum :: SrcSpan -> Name -> [LHsExpr Name] -> TcRhoType
            -> TcM (HsWrapper, LHsExpr TcId, [LHsExpr TcId])
-- tagToEnum# :: forall a. Int# -> a
-- See Note [tagToEnum#]   Urgh!
tcTagToEnum loc fun_name args res_ty
  = do { fun <- tcLookupId fun_name

       ; arg <- case args of
           [ty_arg_expr, term_arg]
             | Just hs_ty_arg <- isLHsTypeExpr_maybe ty_arg_expr
             -> do { ty_arg <- tcHsTypeApp hs_ty_arg liftedTypeKind
                   ; _ <- unifyType ty_arg res_ty
                     -- other than influencing res_ty, we just
                     -- don't care about a type arg passed in.
                     -- So drop the evidence.
                   ; return term_arg }
           [term_arg] -> return term_arg
           _          -> too_many_args

       ; ty' <- zonkTcType res_ty

       -- Check that the type is algebraic
       ; let mb_tc_app = tcSplitTyConApp_maybe ty'
             Just (tc, tc_args) = mb_tc_app
       ; checkTc (isJust mb_tc_app)
                 (mk_error ty' doc1)

       -- Look through any type family
       ; fam_envs <- tcGetFamInstEnvs
       ; let (rep_tc, rep_args, coi)
               = tcLookupDataFamInst fam_envs tc tc_args
            -- coi :: tc tc_args ~R rep_tc rep_args

       ; checkTc (isEnumerationTyCon rep_tc)
                 (mk_error ty' doc2)

       ; arg' <- tcMonoExpr arg intPrimTy
       ; let fun' = L loc (HsWrap (WpTyApp rep_ty) (HsVar fun))
             rep_ty = mkTyConApp rep_tc rep_args

       ; return (coToHsWrapperR (mkTcSymCo $ TcCoercion coi), fun', [arg']) }
                 -- coi is a Representational coercion
  where
    doc1 = vcat [ ptext (sLit "Specify the type by giving a type signature")
                , ptext (sLit "e.g. (tagToEnum# x) :: Bool") ]
    doc2 = ptext (sLit "Result type must be an enumeration type")

    mk_error :: TcType -> SDoc -> SDoc
    mk_error ty what
      = hang (ptext (sLit "Bad call to tagToEnum#")
               <+> ptext (sLit "at type") <+> ppr ty)
           2 what

    too_many_args :: TcM a
    too_many_args
      = failWith $
        hang (text "Too many type arguments to tagToEnum#:")
           2 (sep (map pprParendExpr args))

{-
************************************************************************
*                                                                      *
                 Template Haskell checks
*                                                                      *
************************************************************************
-}

checkThLocalId :: Id -> TcM ()
checkThLocalId id
  = do  { mb_local_use <- getStageAndBindLevel (idName id)
        ; case mb_local_use of
             Just (top_lvl, bind_lvl, use_stage)
                | thLevel use_stage > bind_lvl
                , isNotTopLevel top_lvl
                -> checkCrossStageLifting id use_stage
             _  -> return ()   -- Not a locally-bound thing, or
                               -- no cross-stage link
    }

--------------------------------------
checkCrossStageLifting :: Id -> ThStage -> TcM ()
-- If we are inside typed brackets, and (use_lvl > bind_lvl)
-- we must check whether there's a cross-stage lift to do
-- Examples   \x -> [|| x ||]
--            [|| map ||]
-- There is no error-checking to do, because the renamer did that
--
-- This is similar to checkCrossStageLifting in RnSplice, but
-- this code is applied to *typed* brackets.

checkCrossStageLifting id (Brack _ (TcPending ps_var lie_var))
  =     -- Nested identifiers, such as 'x' in
        -- E.g. \x -> [|| h x ||]
        -- We must behave as if the reference to x was
        --      h $(lift x)
        -- We use 'x' itself as the splice proxy, used by
        -- the desugarer to stitch it all back together.
        -- If 'x' occurs many times we may get many identical
        -- bindings of the same splice proxy, but that doesn't
        -- matter, although it's a mite untidy.
    do  { let id_ty = idType id
        ; checkTc (isTauTy id_ty) (polySpliceErr id)
               -- If x is polymorphic, its occurrence sites might
               -- have different instantiations, so we can't use plain
               -- 'x' as the splice proxy name.  I don't know how to
               -- solve this, and it's probably unimportant, so I'm
               -- just going to flag an error for now

        ; lift <- if isStringTy id_ty then
                     do { sid <- tcLookupId THNames.liftStringName
                                     -- See Note [Lifting strings]
                        ; return (HsVar sid) }
                  else
                     setConstraintVar lie_var   $
                          -- Put the 'lift' constraint into the right LIE
                     newMethodFromName (OccurrenceOf (idName id))
                                       THNames.liftName id_ty

                   -- Update the pending splices
        ; ps <- readMutVar ps_var
        ; let pending_splice = PendingTcSplice (idName id) (nlHsApp (noLoc lift) (nlHsVar id))
        ; writeMutVar ps_var (pending_splice : ps)

        ; return () }

checkCrossStageLifting _ _ = return ()

polySpliceErr :: Id -> SDoc
polySpliceErr id
  = ptext (sLit "Can't splice the polymorphic local variable") <+> quotes (ppr id)

{-
Note [Lifting strings]
~~~~~~~~~~~~~~~~~~~~~~
If we see $(... [| s |] ...) where s::String, we don't want to
generate a mass of Cons (CharL 'x') (Cons (CharL 'y') ...)) etc.
So this conditional short-circuits the lifting mechanism to generate
(liftString "xy") in that case.  I didn't want to use overlapping instances
for the Lift class in TH.Syntax, because that can lead to overlapping-instance
errors in a polymorphic situation.

If this check fails (which isn't impossible) we get another chance; see
Note [Converting strings] in Convert.hs

Local record selectors
~~~~~~~~~~~~~~~~~~~~~~
Record selectors for TyCons in this module are ordinary local bindings,
which show up as ATcIds rather than AGlobals.  So we need to check for
naughtiness in both branches.  c.f. TcTyClsBindings.mkAuxBinds.


************************************************************************
*                                                                      *
\subsection{Record bindings}
*                                                                      *
************************************************************************

Game plan for record bindings
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
1. Find the TyCon for the bindings, from the first field label.

2. Instantiate its tyvars and unify (T a1 .. an) with expected_ty.

For each binding field = value

3. Instantiate the field type (from the field label) using the type
   envt from step 2.

4  Type check the value using tcArg, passing the field type as
   the expected argument type.

This extends OK when the field types are universally quantified.
-}

tcRecordBinds
        :: DataCon
        -> [TcType]     -- Expected type for each field
        -> HsRecordBinds Name
        -> TcM (HsRecordBinds TcId)

tcRecordBinds data_con arg_tys (HsRecFields rbinds dd)
  = do  { mb_binds <- mapM do_bind rbinds
        ; return (HsRecFields (catMaybes mb_binds) dd) }
  where
    flds_w_tys = zipEqual "tcRecordBinds" (dataConFieldLabels data_con) arg_tys
    do_bind (L l fld@(HsRecField { hsRecFieldId = L loc field_lbl
                                 , hsRecFieldArg = rhs }))
      | Just field_ty <- assocMaybe flds_w_tys field_lbl
      = addErrCtxt (fieldCtxt field_lbl)        $
        do { rhs' <- tcPolyExprNC rhs field_ty
           ; let field_id = mkUserLocal (nameOccName field_lbl)
                                        (nameUnique field_lbl)
                                        field_ty HasSigId loc
                -- Yuk: the field_id has the *unique* of the selector Id
                --          (so we can find it easily)
                --      but is a LocalId with the appropriate type of the RHS
                --          (so the desugarer knows the type of local binder to make)
           ; return (Just (L l (fld { hsRecFieldId = L loc field_id
                                    , hsRecFieldArg = rhs' }))) }
      | otherwise
      = do { addErrTc (badFieldCon (RealDataCon data_con) field_lbl)
           ; return Nothing }

checkMissingFields :: DataCon -> HsRecordBinds Name -> TcM ()
checkMissingFields data_con rbinds
  | null field_labels   -- Not declared as a record;
                        -- But C{} is still valid if no strict fields
  = if any isBanged field_strs then
        -- Illegal if any arg is strict
        addErrTc (missingStrictFields data_con [])
    else
        return ()

  | otherwise = do              -- A record
    unless (null missing_s_fields)
           (addErrTc (missingStrictFields data_con missing_s_fields))

    warn <- woptM Opt_WarnMissingFields
    unless (not (warn && notNull missing_ns_fields))
           (warnTc True (missingFields data_con missing_ns_fields))

  where
    missing_s_fields
        = [ fl | (fl, str) <- field_info,
                 isBanged str,
                 not (fl `elem` field_names_used)
          ]
    missing_ns_fields
        = [ fl | (fl, str) <- field_info,
                 not (isBanged str),
                 not (fl `elem` field_names_used)
          ]

    field_names_used = hsRecFields rbinds
    field_labels     = dataConFieldLabels data_con

    field_info = zipEqual "missingFields"
                          field_labels
                          field_strs

    field_strs = dataConSrcBangs data_con

{-
************************************************************************
*                                                                      *
    Skolemisation
*                                                                      *
************************************************************************
-}

-- | Convenient wrapper for skolemising a type during typechecking an expression.
-- Always does uses a 'GenSigCtxt'.
tcSkolemiseExpr :: TcSigmaType
                -> (TcRhoType -> TcM (HsExpr TcId))
                -> (TcM (HsExpr TcId))
tcSkolemiseExpr res_ty thing_inside
  = do { (wrap, expr) <- tcSkolemise GenSigCtxt res_ty $
                         \_ rho -> thing_inside rho
       ; return (mkHsWrap wrap expr) }

{-
************************************************************************
*                                                                      *
\subsection{Errors and contexts}
*                                                                      *
************************************************************************

Boring and alphabetical:
-}

addExprErrCtxt :: LHsExpr Name -> TcM a -> TcM a
addExprErrCtxt expr = addErrCtxt (exprCtxt expr)

exprCtxt :: LHsExpr Name -> SDoc
exprCtxt expr
  = hang (ptext (sLit "In the expression:")) 2 (ppr expr)

fieldCtxt :: Name -> SDoc
fieldCtxt field_name
  = ptext (sLit "In the") <+> quotes (ppr field_name) <+> ptext (sLit "field of a record")

funAppCtxt :: LHsExpr Name -> LHsExpr Name -> Int -> SDoc
funAppCtxt fun arg arg_no
  = hang (hsep [ ptext (sLit "In the"), speakNth arg_no, ptext (sLit "argument of"),
                    quotes (ppr fun) <> text ", namely"])
       2 (quotes (ppr arg))

funResCtxt :: Bool  -- There is at least one argument
           -> HsExpr Name -> TcType -> TcType
           -> TidyEnv -> TcM (TidyEnv, MsgDoc)
-- When we have a mis-match in the return type of a function
-- try to give a helpful message about too many/few arguments
--
-- Used for naked variables too; but with has_args = False
funResCtxt has_args fun fun_res_ty env_ty tidy_env
  = do { fun_res' <- zonkTcType fun_res_ty
       ; env'     <- zonkTcType env_ty
       ; let (args_fun, res_fun) = tcSplitFunTys fun_res'
             (args_env, res_env) = tcSplitFunTys env'
             n_fun = length args_fun
             n_env = length args_env
             info  | n_fun == n_env = Outputable.empty
                   | n_fun > n_env
                   , not_fun res_env = ptext (sLit "Probable cause:") <+> quotes (ppr fun)
                                       <+> ptext (sLit "is applied to too few arguments")
                   | has_args
                   , not_fun res_fun = ptext (sLit "Possible cause:") <+> quotes (ppr fun)
                                       <+> ptext (sLit "is applied to too many arguments")
                   | otherwise       = Outputable.empty  -- Never suggest that a naked variable is
                                                         -- applied to too many args!
       ; return (tidy_env, info) }
  where
    not_fun ty   -- ty is definitely not an arrow type,
                 -- and cannot conceivably become one
      = case tcSplitTyConApp_maybe ty of
          Just (tc, _) -> isAlgTyCon tc
          Nothing      -> False

badFieldTypes :: [(Name,TcType)] -> SDoc
badFieldTypes prs
  = hang (ptext (sLit "Record update for insufficiently polymorphic field")
                         <> plural prs <> colon)
       2 (vcat [ ppr f <+> dcolon <+> ppr ty | (f,ty) <- prs ])

badFieldsUpd
  :: HsRecFields Name a -- Field names that don't belong to a single datacon
  -> [DataCon] -- Data cons of the type which the first field name belongs to
  -> SDoc
badFieldsUpd rbinds data_cons
  = hang (ptext (sLit "No constructor has all these fields:"))
       2 (pprQuotedList conflictingFields)
          -- See Note [Finding the conflicting fields]
  where
    -- A (preferably small) set of fields such that no constructor contains
    -- all of them.  See Note [Finding the conflicting fields]
    conflictingFields = case nonMembers of
        -- nonMember belongs to a different type.
        (nonMember, _) : _ -> [aMember, nonMember]
        [] -> let
            -- All of rbinds belong to one type. In this case, repeatedly add
            -- a field to the set until no constructor contains the set.

            -- Each field, together with a list indicating which constructors
            -- have all the fields so far.
            growingSets :: [(Name, [Bool])]
            growingSets = scanl1 combine membership
            combine (_, setMem) (field, fldMem)
              = (field, zipWith (&&) setMem fldMem)
            in
            -- Fields that don't change the membership status of the set
            -- are redundant and can be dropped.
            map (fst . head) $ groupBy ((==) `on` snd) growingSets

    aMember = ASSERT( not (null members) ) fst (head members)
    (members, nonMembers) = partition (or . snd) membership

    -- For each field, which constructors contain the field?
    membership :: [(Name, [Bool])]
    membership = sortMembership $
        map (\fld -> (fld, map (Set.member fld) fieldLabelSets)) $
          hsRecFields rbinds

    fieldLabelSets :: [Set.Set Name]
    fieldLabelSets = map (Set.fromList . dataConFieldLabels) data_cons

    -- Sort in order of increasing number of True, so that a smaller
    -- conflicting set can be found.
    sortMembership =
      map snd .
      sortBy (compare `on` fst) .
      map (\ item@(_, membershipRow) -> (countTrue membershipRow, item))

    countTrue = length . filter id

{-
Note [Finding the conflicting fields]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Suppose we have
  data A = A {a0, a1 :: Int}
         | B {b0, b1 :: Int}
and we see a record update
  x { a0 = 3, a1 = 2, b0 = 4, b1 = 5 }
Then we'd like to find the smallest subset of fields that no
constructor has all of.  Here, say, {a0,b0}, or {a0,b1}, etc.
We don't really want to report that no constructor has all of
{a0,a1,b0,b1}, because when there are hundreds of fields it's
hard to see what was really wrong.

We may need more than two fields, though; eg
  data T = A { x,y :: Int, v::Int }
          | B { y,z :: Int, v::Int }
          | C { z,x :: Int, v::Int }
with update
   r { x=e1, y=e2, z=e3 }, we

Finding the smallest subset is hard, so the code here makes
a decent stab, no more.  See Trac #7989.
-}

naughtyRecordSel :: TcId -> SDoc
naughtyRecordSel sel_id
  = ptext (sLit "Cannot use record selector") <+> quotes (ppr sel_id) <+>
    ptext (sLit "as a function due to escaped type variables") $$
    ptext (sLit "Probable fix: use pattern-matching syntax instead")

notSelector :: Name -> SDoc
notSelector field
  = hsep [quotes (ppr field), ptext (sLit "is not a record selector")]

missingStrictFields :: DataCon -> [FieldLabel] -> SDoc
missingStrictFields con fields
  = header <> rest
  where
    rest | null fields = Outputable.empty  -- Happens for non-record constructors
                                           -- with strict fields
         | otherwise   = colon <+> pprWithCommas ppr fields

    header = ptext (sLit "Constructor") <+> quotes (ppr con) <+>
             ptext (sLit "does not have the required strict field(s)")

missingFields :: DataCon -> [FieldLabel] -> SDoc
missingFields con fields
  = ptext (sLit "Fields of") <+> quotes (ppr con) <+> ptext (sLit "not initialised:")
        <+> pprWithCommas ppr fields

-- callCtxt fun args = ptext (sLit "In the call") <+> parens (ppr (foldl mkHsApp fun args))
