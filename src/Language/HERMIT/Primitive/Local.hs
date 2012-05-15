-- Andre Santos' Local Transformations (Ch 3 in his dissertation)
module Language.HERMIT.Primitive.Local where

import GhcPlugins

import Language.KURE

import Language.HERMIT.HermitKure
import Language.HERMIT.External

externals :: [External]
externals =
         [
           external "beta-reduce" (promoteR beta_reduce)
                     [ "((\\ v -> E1) E2) ==> let v = E2 in E1, fails otherwise"
                     , "this form of beta reduction is safe if E2 is an arbitrary"
		     , "expression (won't duplicate work)" ]
         , external "beta-expand" (promoteR beta_expand)
                [ "(let v = E1 in E2) ==> (\\ v -> E2) E1, fails otherwise" ]
         , external "dead-code" (promoteR $ not_defined "dead-code")
                     [ "let x = E1 in E2 ==> E2, if x is not used in E2, fails otherwise" ]
         , external "inline-let" (promoteR $ not_defined "inline")
                     [ "'inline x': let x = E1 in ...x... ==> let x = E1 in ...E1..., fails otherwise" ]
         , external "constructor-reuse" (promoteR $ not_defined "constructor-reuse")
                     [ "let v = C v1..vn in ... C v1..vn ... ==> let v = C v1..vn in ... v ..., fails otherwise" ]
         , external "case-reduction" (promoteR $ not_defined "case-reduction")
                     [ "case C v1..vn of C w1..wn -> e ==> e[v1/w1..vn/wn]" ]
         , external "case-elimination" (promoteR $ not_defined "case-elimination")
                     [ "case v1 of v2 -> e ==> e[v1/v2]" ]
         , external "case-merging" (promoteR $ not_defined "case-merging")
                     [ "case v of ...; d -> case v of alt -> e ==> case v of ...; alt -> e[v/d]" ]
         , external "default-binding-elim" (promoteR $ not_defined "default-binding-elim")
                     [ "case v of ...;w -> e ==> case v of ...;w -> e[v/w]" ]
         , external "let-float-app" (promoteR $ not_defined "let-float-app")
                     [ "(let v = ev in e) x ==> let v = ev in e x" ]
         , external "let-float-let" (promoteR $ not_defined "let-float-let")
                     [ "let v = (let w = ew in ev) in e ==> let w = ew in let v = ev in e" ]
         , external "let-float-case" (promoteR $ not_defined "let-float-case")
                     [ "case (let v = ev in e) of ... ==> let v = ev in case e of ..." ]
         , external "case-float-app" (promoteR $ not_defined "case-float-app")
                     [ "(case ec of alt -> e) v ==> case ec of alt -> e v" ]
         , external "case-float-case" (promoteR $ not_defined "case-float-case")
                     [ "case (case ec of alt1 -> e1) of alta -> ea ==> case ec of alt1 -> case e1 of alta -> ea" ]
         , external "case-float-let" (promoteR $ not_defined "case-float-let")
                     [ "let v = case ec of alt1 -> e1 in e ==> case ec of alt1 -> let v = e1 in e" ]
         , external "let-to-case" (promoteR $ not_defined "let-to-case")
                     [ "let v = ev in e ==> case ev of v -> e" ]
         , external "let-to-case-unbox" (promoteR $ not_defined "let-to-case-unbox")
                     [ "let v = ev in e ==> case ev of C v1..vn -> let v = C v1..vn in e" ]
         , external "eta-reduce" (promoteR eta_reduce)
                     [ "(\\ v -> E1 v) ==> E1, fails otherwise" ]
         , external "eta-expand" (promoteR' . eta_expand)
                     [ "'eta-expand v' performs E1 ==> (\\ v -> E1 v), fails otherwise" ]
         ]

not_defined :: String -> RewriteH CoreExpr
not_defined nm = rewrite $ \ c e -> fail $ nm ++ " not implemented!"

------------------------------------------------------------------------------

beta_reduce :: RewriteH CoreExpr
beta_reduce = liftMT $ \ e -> case e of
        App (Lam v e1) e2 -> return $ Let (NonRec v e2) e1
        _ -> fail "beta_reduce failed. Not applied to an App."

beta_expand :: RewriteH CoreExpr
beta_expand = liftMT $ \ e -> case e of
        Let (NonRec v e2) e1 -> return $ App (Lam v e1) e2
        _ -> fail "beta_expand failed. Not applied to a NonRec Let."

------------------------------------------------------------------------------

eta_reduce :: RewriteH CoreExpr
eta_reduce = rewrite $ \ c e -> case e of
        Lam v1 (App f (Var v2)) | v1 == v2 -> do freesinFunction <- apply freeVarsT c f
                                                 if v1 `elem` freesinFunction
                                                  then fail $ "eta_reduce failed. " ++ showSDoc (ppr v1) ++
                                                              " is free in the function being applied."
                                                  else return f
        _ -> fail "eta_reduce failed"

eta_expand :: TH.Name -> RewriteH CoreExpr
eta_expand nm = liftMT $ \ e -> do
        -- First find the type of of e
        let ty = exprType e
        case splitAppTy_maybe ty of
           Nothing -> fail "eta-expand failed (expression is not an App)"
           Just (_ , a_ty) -> do
             v1 <- newVarH nm a_ty
             return $ Lam v1 (App e (Var v1))

------------------------------------------------------------------------------
