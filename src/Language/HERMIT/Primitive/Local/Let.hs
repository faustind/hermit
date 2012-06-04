-- Andre Santos' Local Transformations (Ch 3 in his dissertation)
module Language.HERMIT.Primitive.Local.Let where

import GhcPlugins

-- import Control.Applicative
import Control.Arrow

import Data.List

import Language.HERMIT.HermitKure
import Language.HERMIT.HermitMonad
import Language.HERMIT.External

import Language.HERMIT.Primitive.Common
import Language.HERMIT.Primitive.GHC
import Language.HERMIT.Primitive.Subst

import qualified Language.Haskell.TH as TH

------------------------------------------------------------------------------

externals :: [External]
externals = map (.+ LetCmd) $
         [ external "let-intro" (promoteR . letIntro :: TH.Name -> RewriteH Core)
                [ "e => (let v = e in v), name of v is provided" ]
         , external "let-constructor-reuse" (promoteR $ not_defined "constructor-reuse" :: RewriteH Core)
                     [ "let v = C v1..vn in ... C v1..vn ... ==> let v = C v1..vn in ... v ..., fails otherwise" ] .+ Unimplemented .+ Eval
         , external "let-float-app" (promoteR letFloatApp :: RewriteH Core)
                     [ "(let v = ev in e) x ==> let v = ev in e x" ] .+ Eval
         , external "let-float-arg" (promoteR letFloatArg :: RewriteH Core)
                     [ "f (let v = ev in e) ==> let v = ev in f e" ] .+ Eval
         , external "let-float-let" (promoteR (letFloatLet <+ letFloatLetrec) <+ promoteR letFloatLetTop :: RewriteH Core)
                     [ "let v = (let w = ew in ev) in e ==> let w = ew in let v = ev in e" ] .+ Eval
         , external "case-float-let" (promoteR caseFloatLet :: RewriteH Core)
                     [ "let v = case ec of alt1 -> e1 in e ==> case ec of alt1 -> let v = e1 in e" ] .+ Eval
         , external "let-to-case" (promoteR letToCase :: RewriteH Core)
                     [ "let v = ev in e ==> case ev of v -> e" ]
         , external "let-to-case-unbox" (promoteR $ not_defined "let-to-case-unbox" :: RewriteH Core)
                     [ "let v = ev in e ==> case ev of C v1..vn -> let v = C v1..vn in e" ] .+ Unimplemented
         ]

not_defined :: String -> RewriteH CoreExpr
not_defined nm = rewrite $ \ c e -> fail $ nm ++ " not implemented!"

letIntro ::  TH.Name -> RewriteH CoreExpr
letIntro nm = contextfreeT $ \ e -> do letvar <- newVarH nm (exprType e)
                                       return $ Let (NonRec letvar e) (Var letvar)

letFloatApp :: RewriteH CoreExpr
letFloatApp = do
    shadowed <- appT letVarsT freeVarsT intersect
    let letAction = if null shadowed then idR else alphaLet
    appT letAction idR $ \ (Let bnds e) x -> Let bnds $ App e x

letFloatArg :: RewriteH CoreExpr
letFloatArg = do
    shadowed <- appT freeVarsT letVarsT intersect
    let letAction = if null shadowed then idR else alphaLet
    appT idR letAction $ \ f (Let bnds e) -> Let bnds $ App f e

-- todo if v used in ew
letFloatLet :: RewriteH CoreExpr
letFloatLet = do
    Let (NonRec v (Let (NonRec w ew) ev)) e <- idR
    return $ Let (NonRec w ew) $ Let (NonRec v ev) e

letFloatLetrec :: RewriteH CoreExpr
letFloatLetrec = do
    Let (NonRec v (Let (Rec bds) ev)) e <- idR
    return $ Let (Rec bds) $ Let (NonRec v ev) e

-- todo if v used in ew
letFloatLetTop :: RewriteH CoreProgram
letFloatLetTop = do
    NonRec v (Let (NonRec w ew) ev) : e <- idR
    return $ (NonRec w ew) : (NonRec v ev) : e

-- todo v used in s, ty, or alts
caseFloatLet :: RewriteH CoreExpr
caseFloatLet = do
    Let (NonRec v (Case s b ty alts)) e <- idR
    return $ Case s b ty [ (con, ids, Let (NonRec v ec) e) | (con, ids, ec) <- alts]

letToCase :: RewriteH CoreExpr
letToCase = do
    Let (NonRec v ev) e <- idR
    caseBndr <- freshVarT v
    letT (return ()) (substR v (Var caseBndr)) $ \ () e' -> Case ev caseBndr (varType v) [(DEFAULT, [], e')]
