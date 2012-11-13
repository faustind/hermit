module Language.HERMIT.Primitive.Local.Let
       ( -- * Rewrites on Let Expressions
         letExternals
       , letIntro
       , letElim
       , letFloatApp
       , letFloatArg
       , letFloatLet
       , letFloatLam
       , letFloatCase
       , letFloatExpr
       , letFloatLetTop
       , letToCase
       )
where

import GhcPlugins

import Control.Category((>>>))

import Data.List
import Data.Monoid

import Language.HERMIT.Core
import Language.HERMIT.Monad
import Language.HERMIT.Kure
import Language.HERMIT.External
import Language.HERMIT.GHC

import Language.HERMIT.Primitive.Common
import Language.HERMIT.Primitive.GHC
import Language.HERMIT.Primitive.AlphaConversion

import qualified Language.Haskell.TH as TH

------------------------------------------------------------------------------

-- | Externals relating to Let expressions.
letExternals :: [External]
letExternals =
         [ external "let-intro" (promoteExprR . letIntro :: TH.Name -> RewriteH Core)
                [ "e => (let v = e in v), name of v is provided" ]                      .+ Shallow .+ Introduce
         , external "dead-let-elimination" (promoteExprR letElim :: RewriteH Core)
                     [ "dead-let-elimination removes an unused let binding."
                     , "(let v = e1 in e2) ==> e2, if v is not free in e2."
                     , "condition: let is not-recursive" ]                                   .+ Eval .+ Shallow .+ Bash
         , external "dead-code-elimination" (promoteExprR letElim :: RewriteH Core)
                     [ "Synonym for dead-let-elimination [deprecated]" ]  .+ Eval .+ Shallow -- TODO: delete this at some point
         -- , external "let-constructor-reuse" (promoteR $ not_defined "constructor-reuse" :: RewriteH Core)
         --             [ "let v = C v1..vn in ... C v1..vn ... ==> let v = C v1..vn in ... v ..., fails otherwise" ] .+ Unimplemented .+ Eval
         , external "let-float-app" (promoteExprR letFloatApp :: RewriteH Core)
                     [ "(let v = ev in e) x ==> let v = ev in e x" ]                    .+ Commute .+ Shallow .+ Bash
         , external "let-float-arg" (promoteExprR letFloatArg :: RewriteH Core)
                     [ "f (let v = ev in e) ==> let v = ev in f e" ]                    .+ Commute .+ Shallow .+ Bash
         , external "let-float-lam" (promoteExprR letFloatLam :: RewriteH Core)
                     [ "(\\ v1 -> let v2 = e1 in e2)  ==>  let v2 = e1 in (\\ v1 -> e2), if v1 is not free in e2.",
                       "If v1 = v2 then v1 will be alpha-renamed."
                     ]                                                                  .+ Commute .+ Shallow .+ Bash
         , external "let-float-let" (promoteExprR letFloatLet :: RewriteH Core)
                     [ "let v = (let w = ew in ev) in e ==> let w = ew in let v = ev in e" ] .+ Commute .+ Shallow .+ Bash
         , external "let-float-case" (promoteExprR letFloatCase :: RewriteH Core)
                     [ "case (let v = ev in e) of ... ==> let v = ev in case e of ..." ]  .+ Commute .+ Shallow .+ Eval .+ Bash
         , external "let-float-top" (promoteProgR letFloatLetTop :: RewriteH Core)
                     [ "v = (let w = ew in ev) : bds ==> w = ew : v = ev : bds" ] .+ Commute .+ Shallow .+ Bash
         , external "let-float" (promoteProgR letFloatLetTop <+ promoteExprR letFloatExpr :: RewriteH Core)
                     [ "Float a Let whatever the context." ] .+ Commute .+ Shallow .+ Bash
         , external "let-to-case" (promoteExprR letToCase :: RewriteH Core)
                     [ "let v = ev in e ==> case ev of v -> e" ] .+ Commute .+ Shallow .+ PreCondition
         -- , external "let-to-case-unbox" (promoteR $ not_defined "let-to-case-unbox" :: RewriteH Core)
         --             [ "let v = ev in e ==> case ev of C v1..vn -> let v = C v1..vn in e" ] .+ Unimplemented
         ]

-------------------------------------------------------------------------------------------

-- | e => (let v = e in v), name of v is provided
letIntro ::  TH.Name -> RewriteH CoreExpr
letIntro nm = prefixFailMsg "Let-introduction failed: " $
              contextfreeT $ \ e -> do guardMsg (not $ isType e) "let expressions may not return a type."
                                       v <- newIdH (show nm) (exprTypeOrKind e)
                                       return $ Let (NonRec v e) (Var v)

-- | Remove an unused let binding.
--   (let v = E1 in E2) => E2, if v is not free in E2
letElim :: RewriteH CoreExpr
letElim = prefixFailMsg "Dead-let-elimination failed: " $
          withPatFailMsg (wrongExprForm "Let (NonRec v e1) e2") $
      do Let (NonRec v _) e <- idR
         guardMsg (v `notElem` coreExprFreeVars e) "let-bound variable appears in the expression."
         return e

-- | let v = ev in e ==> case ev of v -> e
letToCase :: RewriteH CoreExpr
letToCase = prefixFailMsg "Converting Let to Case failed: " $
            withPatFailMsg (wrongExprForm "Let (NonRec v e1) e2") $
  do Let (NonRec v ev) _ <- idR
     guardMsg (not $ isType ev) "cannot case on a type."
     nameModifier <- freshNameGenT Nothing
     caseBndr <- constT (cloneVarH nameModifier v)
     letT mempty (replaceVarR v caseBndr) $ \ () e' -> Case ev caseBndr (varType v) [(DEFAULT, [], e')]

-------------------------------------------------------------------------------------------

-- | (let v = ev in e) x ==> let v = ev in e x
letFloatApp :: RewriteH CoreExpr
letFloatApp = prefixFailMsg "Let floating from App function failed: " $
  do vs <- appT letVarsT freeVarsT intersect
     let letAction = if null vs then idR else alphaLet
     appT letAction idR $ \ (Let bnds e) x -> Let bnds $ App e x

-- | f (let v = ev in e) ==> let v = ev in f e
letFloatArg :: RewriteH CoreExpr
letFloatArg = prefixFailMsg "Let floating from App argument failed: " $
  do vs <- appT freeVarsT letVarsT intersect
     let letAction = if null vs then idR else alphaLet
     appT idR letAction $ \ f (Let bnds e) -> Let bnds $ App f e

-- | let v = (let w = ew in ev) in e ==> let w = ew in let v = ev in e
letFloatLet :: RewriteH CoreExpr
letFloatLet = prefixFailMsg "Let floating from Let failed: " $
  do vs <- letNonRecT letVarsT freeVarsT (\ _ -> intersect)
     let bdsAction = if null vs then idR else nonRecR alphaLet
     letT bdsAction idR $ \ (NonRec v (Let bds ev)) e -> Let bds $ Let (NonRec v ev) e

-- | (\ v1 -> let v2 = e1 in e2)  ==>  let v2 = e1 in (\ v1 -> e2)
--   Fails if v1 occurs in e1.
--   If v1 = v2 then v1 will be alpha-renamed.
letFloatLam :: RewriteH CoreExpr
letFloatLam = prefixFailMsg "Let floating from Lam failed: " $
              withPatFailMsg (wrongExprForm "Lam v1 (Let (NonRec v2 e1) e2)") $
  do Lam v1 (Let (NonRec v2 e1) e2) <- idR
     guardMsg (v1 `notElem` coreExprFreeVars e1) $ var2String v1 ++ " occurs in the definition of " ++ var2String v2 ++ "."
     if v1 == v2
      then alphaLam Nothing >>> letFloatLam
      else return (Let (NonRec v2 e1) (Lam v1 e2))

-- | @case (let bnds in e) of wild alts ==> let bnds in (case e of wild alts)@
--   Fails if any variables bound in @bnds@ occurs in @alts@.
letFloatCase :: RewriteH CoreExpr
letFloatCase = prefixFailMsg "Let floating from Case failed: " $
  do captures <- caseT letVarsT
                       (\ _ -> altFreeVarsExclWildT)
                       (\ vs wild _ fs -> vs `intersect` concatMap ($ wild) fs)
     caseT (if null captures then idR else alphaLetVars captures)
           (const idR)
           (\ (Let bnds e) wild ty alts -> Let bnds (Case e wild ty alts))

-- | Float a Let through an expression, whatever the context.
letFloatExpr :: RewriteH CoreExpr
letFloatExpr = setFailMsg "Unsuitable expression for Let floating." $
               letFloatApp <+ letFloatArg <+ letFloatLet <+ letFloatLam <+ letFloatCase

-- | NonRec v (Let (NonRec w ew) ev) `ProgCons` p ==> NonRec w ew `ProgCons` NonRec v ev `ProgCons` p
letFloatLetTop :: RewriteH CoreProg
letFloatLetTop = prefixFailMsg "Let floating to top level failed: " $
                 withPatFailMsg (wrongExprForm "NonRec v (Let (NonRec w ew) ev) `ProgCons` p") $
  do NonRec v (Let (NonRec w ew) ev) `ProgCons` p <- idR
     guardMsg (not $ isType ew) "type bindings are not allowed at the top level."
     return (NonRec w ew `ProgCons` NonRec v ev `ProgCons` p)

-------------------------------------------------------------------------------------------
