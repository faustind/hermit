-- Andre Santos' Local Transformations (Ch 3 in his dissertation)
module Language.HERMIT.Primitive.Local.Case where

import GhcPlugins

import Data.List
import Control.Arrow
import Control.Applicative

import Language.HERMIT.Kure
import Language.HERMIT.External

import Language.HERMIT.Primitive.Common
import Language.HERMIT.Primitive.GHC
import Language.HERMIT.Primitive.Subst hiding (letSubstR)

-- NOTE: these are hard to test in small examples, as GHC does them for us, so use with caution
------------------------------------------------------------------------------

externals :: [External]
externals =
         [ -- I'm not sure this is possible. In core, v2 can only be a Constructor, Lit, or DEFAULT
           -- In the last case, v1 is already inlined in e. So we can't construct v2 as a Var.
         --   external "case-elimination" (promoteR $ not_defined "case-elimination" :: RewriteH Core)
         --             [ "case v1 of v2 -> e ==> e[v1/v2]" ]                                         .+ Unimplemented .+ Eval
         --   -- Again, don't think the lhs of this rule is possible to construct in core.
         -- , external "default-binding-elim" (promoteR $ not_defined "default-binding-elim" :: RewriteH Core)
         --             [ "case v of ...;w -> e ==> case v of ...;w -> e[v/w]" ]                      .+ Unimplemented .+ Eval
         --   -- Again, don't think the lhs of this rule is possible to construct in core.
         -- , external "case-merging" (promoteR $ not_defined "case-merging" :: RewriteH Core)
         --             [ "case v of ...; d -> case v of alt -> e ==> case v of ...; alt -> e[v/d]" ] .+ Unimplemented .+ Eval
           external "let-float-case" (promoteExprR letFloatCase :: RewriteH Core)
                     [ "case (let v = ev in e) of ... ==> let v = ev in case e of ..." ]  .+ Commute .+ Shallow .+ Eval .+ Bash
         , external "case-float-app" (promoteExprR caseFloatApp :: RewriteH Core)
                     [ "(case ec of alt -> e) v ==> case ec of alt -> e v" ]              .+ Commute .+ Shallow .+ Bash
         , external "case-float-arg" (promoteExprR caseFloatArg :: RewriteH Core)
                     [ "f (case s of alt -> e) ==> case s of alt -> f e" ]                .+ Commute .+ Shallow .+ PreCondition
         , external "case-float-case" (promoteExprR caseFloatCase :: RewriteH Core)
                     [ "case (case ec of alt1 -> e1) of alta -> ea ==> case ec of alt1 -> case e1 of alta -> ea" ] .+ Commute .+ Eval .+ Bash
         , external "case-reduce" (promoteExprR caseReduce :: RewriteH Core)
                     [ "case-of-known-constructor"
                     , "case C v1..vn of C w1..wn -> e ==> e[v1/w1..vn/wn]" ] .+ Shallow .+ Eval .+ Bash
         ]

-- not_defined :: String -> RewriteH CoreExpr
-- not_defined nm = fail $ nm ++ " not implemented!"

-- | case (let v = e1 in e2) of alts ==> let v = e1 in case e2 of alts
letFloatCase :: RewriteH CoreExpr
letFloatCase = do
    captures <- caseT letVarsT (const (pure ())) $ \ vs _ _ _ -> vs
    cFrees   <- freeVarsT -- so we get type variables too
    caseT (if null (intersect cFrees captures) then idR else alphaLet)
          (const idR)
          (\ (Let bnds e) b ty alts -> Let bnds (Case e b ty alts))

-- | (case s of alt1 -> e1; alt2 -> e2) v ==> case s of alt1 -> e1 v; alt2 -> e2 v
caseFloatApp :: RewriteH CoreExpr
caseFloatApp = do
    captures <- appT caseAltVarsT freeVarsT (flip (map . intersect))
    appT (caseAllR idR
                   (\i -> if null (captures !! i) then idR else alphaAlt))
         idR
         (\(Case s b _ty alts) v -> let newTy = exprType (App (case head alts of (_,_,f) -> f) v)
                                    in Case s b newTy [ (c, ids, App f v)
                                                      | (c,ids,f) <- alts ])

-- | f (case s of alt1 -> e1; alt2 -> e2) ==> case s of alt1 -> f e1; alt2 -> f e2
caseFloatArg :: RewriteH CoreExpr
caseFloatArg = do
    captures <- appT freeVarsT caseAltVarsT (map . intersect)
    appT idR
         (caseAllR idR
                   (\i -> if null (captures !! i) then idR else alphaAlt))
         (\f (Case s b _ty alts) -> let newTy = exprType (App f (case head alts of (_,_,e) -> e))
                                    in Case s b newTy [ (c, ids, App f e)
                                                      | (c,ids,e) <- alts ])

-- | case (case s1 of alt11 -> e11; alt12 -> e12) of alt21 -> e21; alt22 -> e22
--   ==>
--   case s1 of
--     alt11 -> case e11 of alt21 -> e21; alt22 -> e22
--     alt12 -> case e12 of alt21 -> e21; alt22 -> e22
caseFloatCase :: RewriteH CoreExpr
caseFloatCase = do
    captures <- caseT caseAltVarsT (const altFreeVarsT) $ \ vss bndr _ fs -> map (intersect (concatMap ($ bndr) fs)) vss
    caseT (caseAllR idR (\i -> if null (captures !! i) then idR else alphaAlt))
          (const idR)
          (\ (Case s1 b1 ty1 alts1) b2 ty2 alts2 -> Case s1 b1 ty1 [ (c1, ids1, Case e1 b2 ty2 alts2) | (c1, ids1, e1) <- alts1 ])

-- | Case-of-known-constructor rewrite
caseReduce :: RewriteH CoreExpr
caseReduce = letTransform >>> tryR (repeatR letSubstR)
    where letTransform = withPatFailMsg "caseReduce failed, not a Case" $
                         do Case s _ _ alts <- idR
                            case isDataCon s of
                              Nothing -> fail "caseReduce failed, not a DataCon"
                              Just (dc, args) -> case [ (bs, rhs) | (DataAlt dc', bs, rhs) <- alts, dc == dc' ] of
                                    [(bs,e')] -> return $ nestedLets e' $ zip bs args
                                    []   -> fail "caseReduce failed, no matching alternative"
                                    _    -> fail "caseReduce failed, more than one matching alt"

-- | If expression is a constructor application, return the relevant bits.
isDataCon :: CoreExpr -> Maybe (DataCon, [CoreExpr])
isDataCon expr = case fn of
                    (Var i) -> do
                        dc <- isDataConId_maybe i
                        return (dc, args)
                    _ -> fail "not a var"
    where (fn, args) = collectArgs expr

-- | We don't want to use the recursive let here, so nest a bunch of non-recursive lets
nestedLets :: Expr b -> [(b, Expr b)] -> Expr b
nestedLets e = foldr (\(b,rhs) -> Let $ NonRec b rhs) e

