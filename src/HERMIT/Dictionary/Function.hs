{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HERMIT.Dictionary.Function
    ( externals
    , appArgM
    , buildAppM
    , buildAppsM
    , buildCompositionT
    , buildFixT
    , buildIdT
    , staticArgR
    , staticArgPosR
    , staticArgPredR
    , staticArgTypesR
    ) where

import Control.Arrow
import Control.Monad
import Control.Monad.IO.Class

import Data.List (nub, intercalate, intersect, partition, transpose)
import Data.Maybe (isNothing)
import Data.String (fromString)

import HERMIT.Context
import HERMIT.Core
import HERMIT.External
import HERMIT.GHC
import HERMIT.Kure
import HERMIT.Monad
import HERMIT.Name

import HERMIT.Dictionary.Common

import Control.Monad.Fail (MonadFail)

externals ::  [External]
externals =
    [ external "static-arg" (promoteDefR staticArgR :: RewriteH LCore)
        [ "perform the static argument transformation on a recursive function." ]
    , external "static-arg-types" (promoteDefR staticArgTypesR :: RewriteH LCore)
        [ "perform the static argument transformation on a recursive function, only transforming type arguments." ]
    , external "static-arg-pos" (promoteDefR . staticArgPosR :: [Int] -> RewriteH LCore)
        [ "perform the static argument transformation on a recursive function, only transforming the arguments specified (by index)." ]
    ]

------------------------------------------------------------------------------------------------------

-- | Traditional Static Argument Transformation
staticArgR :: (MonadFail m, AddBindings c, ExtendPath c Crumb, HasEmptyContext c, ReadPath c Crumb, MonadCatch m, MonadUnique m)
           => Rewrite c m CoreDef
staticArgR = staticArgPredR (return . map fst)

-- | Static Argument Transformation that only considers type arguments to be static.
staticArgTypesR :: (MonadFail m, AddBindings c, ExtendPath c Crumb, HasEmptyContext c, ReadPath c Crumb, MonadCatch m, MonadUnique m)
                => Rewrite c m CoreDef
staticArgTypesR = staticArgPredR (return . map fst . filter (isTyVar . snd))

-- | Static Argument Transformations which requires that arguments in the given position are static.
staticArgPosR :: (MonadFail m, AddBindings c, ExtendPath c Crumb, HasEmptyContext c, ReadPath c Crumb, MonadCatch m, MonadUnique m)
              => [Int] -> Rewrite c m CoreDef
staticArgPosR is' = staticArgPredR $ \ss' -> let is = nub is'
                                                 ss = map fst ss'
                                            in if is == (is `intersect` ss)
                                               then return is
                                               else fail $ "args " ++ commas (filter (`notElem` ss) is) ++ " are not static."

-- | Generalized Static Argument Transformation, which allows static arguments to be filtered.
staticArgPredR :: forall c m. (MonadFail m, AddBindings c, ExtendPath c Crumb, HasEmptyContext c, ReadPath c Crumb
                              , MonadCatch m, MonadUnique m)
               => ([(Int, Var)] -> m [Int]) -- ^ given list of static args and positions, decided which to transform
               -> Rewrite c m CoreDef
staticArgPredR decide = prefixFailMsg "static-arg failed: " $ do
    Def f rhs <- idR
    let (bnds, body) = collectBinders rhs
    guardMsg (notNull bnds) "rhs is not a function"
    contextonlyT $ \ c -> do
        let bodyContext = foldl (flip addLambdaBinding) c bnds

            callPatsT :: Transform c m CoreExpr [[CoreExpr]]
            callPatsT = extractT $ collectPruneT
                            (promoteExprT $ callPredT (const . (== f)) >>> arr snd :: Transform c m Core [CoreExpr])

        callPats <- applyT callPatsT bodyContext body
        let argExprs = transpose callPats
            numCalls = length callPats
            allBinds = zip [0..] bnds

            staticBinds = [ (i,b) | ((i,b),exprs) <- zip allBinds $ argExprs ++ repeat []
                                  , length exprs == numCalls && isStatic b exprs ]
                                    -- ensure argument is present in every call (partial applications boo)

            isStatic _ []                          = True  -- all were static
            isStatic b ((Var b'):es)               | b == b' = isStatic b es
            isStatic b ((Type (TyVarTy v)):es)     | b == v  = isStatic b es
            isStatic b ((Coercion (CoVarCo v)):es) | b == v  = isStatic b es
            isStatic _ _                           = False -- not a simple repass, so dynamic

        chosen <- decide staticBinds
        let choices = map fst staticBinds
        guardMsg (notNull chosen) "no arguments selected for transformation."
        guardMsg (all (`elem` choices) chosen)
            $ "args " ++ commas choices ++ " are static, but " ++ commas chosen ++ " were selected."

        let (chosenBinds, dynBinds) = partition ((`elem` chosen) . fst) allBinds
            (ps, dbnds) = unzip dynBinds
            unboundTys = concat [ [ (i,i') | (i',b') <- dynBinds, i' < i , b' `elem` fvs ]
#if __GLASGOW_HASKELL__ > 710
                                | (i,b) <- chosenBinds, let fvs = nonDetEltsUniqSet (varTypeTyCoVars b) ]
#else
                                | (i,b) <- chosenBinds, let fvs = varSetElems (varTypeTyVars b) ]
#endif

        guardMsg (null unboundTys)
            $ "type variables in args " ++ commas (nub $ map fst unboundTys) ++ " would become unbound unless args "
              ++ commas (nub $ map snd unboundTys) ++ " are included in the transformation."

        wkr <- newIdH (unqualifiedName f ++ "'") (exprType (mkCoreLams dbnds body))

        let replaceCall :: Rewrite c m CoreExpr
            replaceCall = do
                (_,exprs) <- callPredT (const . (== f))
                return $ mkApps (Var wkr) [ e | (p,e) <- zip [0..] exprs, (p::Int) `elem` ps ]

        body' <- applyT (extractR $ prunetdR (promoteExprR replaceCall :: Rewrite c m Core)) bodyContext body

        return $ Def f $ mkCoreLams bnds $ Let (Rec [(wkr, mkCoreLams dbnds body')])
                                             $ mkApps (Var wkr) (varsToCoreExprs dbnds)

------------------------------------------------------------------------------

-- | Get the nth argument of an application. Arg 0 is the function being applied.
appArgM :: Monad m => Int -> CoreExpr -> m CoreExpr
appArgM n e | n < 0     = fail "appArgM: arg must be non-negative"
            | otherwise = let (fn,args) = collectArgs e
                              l = fn : args
                          in if n > length args
                             then fail "appArgM: not enough arguments"
                             else return $ l !! n

-- | Build composition of two functions.
buildCompositionT :: (BoundVars c, HasHermitMEnv m, LiftCoreM m, MonadCatch m, MonadIO m, MonadThings m)
                  => CoreExpr -> CoreExpr -> Transform c m x CoreExpr
buildCompositionT f g = do
    composeId <- findIdT $ fromString "Data.Function.."
    fDot <- prefixFailMsg "building (.) f failed:" $ buildAppM (varToCoreExpr composeId) f
    prefixFailMsg "building f . g failed:" $ buildAppM fDot g

buildAppsM :: MonadCatch m => CoreExpr -> [CoreExpr] -> m CoreExpr
buildAppsM = foldM buildAppM

-- | Given expression for f and for x, build f x, figuring out the type arguments.
buildAppM :: MonadCatch m => CoreExpr -> CoreExpr -> m CoreExpr
buildAppM f x = do
    (vsF, domF, _) <- splitFunTypeM (exprType f)
    let (vsX, xTy) = splitForAllTys (exprType x)
        allTvs = vsF ++ vsX
        bindFn v = if v `elem` allTvs then BindMe else Skolem

    sub <- maybe (fail "buildAppM - domain of f and type of x do not unify")
                 return
                 (tcUnifyTys bindFn [domF] [xTy])

    f' <- substOrApply f [ (v, Type $ substTyVar sub v) | v <- vsF ]
    x' <- substOrApply x [ (v, Type $ substTyVar sub v) | v <- vsX ]
    let vs = [ v | v <- vsF ++ vsX, isNothing $ lookupTyVar sub v ]  -- things we should stick back on as foralls
    -- TODO: make sure vsX don't capture anything in f'
    --       and vsF' doesn't capture anything in x'
#if __GLASGOW_HASKELL__ > 710
    return $ mkCoreLams vs $ mkCoreApp (text "buildAppM") f' x'
#else
    return $ mkCoreLams vs $ mkCoreApp f' x'
#endif

-- | Given expression for f, build fix f.
buildFixT :: (BoundVars c, LiftCoreM m, HasHermitMEnv m, MonadCatch m, MonadIO m, MonadThings m)
          => CoreExpr -> Transform c m x CoreExpr
buildFixT f = do
    (tvs, ty) <- endoFunExprTypeM f
    fixId <- findIdT $ fromString "Data.Function.fix"
    f' <- substOrApply f [ (v, varToCoreExpr v) | v <- tvs ]
    return $ mkCoreLams tvs $ mkCoreApps (varToCoreExpr fixId) [Type ty, f']

-- | Build an expression that is the monomorphic id function for given type.
buildIdT :: (BoundVars c, LiftCoreM m, HasHermitMEnv m, MonadCatch m, MonadIO m, MonadThings m)
         => Type -> Transform c m x CoreExpr
buildIdT ty = do
    idId <- findIdT $ fromString "Data.Function.id"
#if __GLASGOW_HASKELL__ > 710
    return $ mkCoreApp (text "buildIdT") (varToCoreExpr idId) (Type ty)
#else
    return $ mkCoreApp (varToCoreExpr idId) (Type ty)
#endif

------------------------------------------------------------------------------

commas :: Show a => [a] -> String
commas = intercalate "," . map show

-- | Like mkCoreApps, but automatically beta-reduces when possible.
substOrApply :: Monad m => CoreExpr -> [(Var,CoreExpr)] -> m CoreExpr
substOrApply e         []         = return e
substOrApply (Lam b e) ((v,ty):r) = if b == v
                                    then substOrApply e r >>= return . substCoreExpr b ty
                                    else fail $ "substOrApply: unexpected binder - "
                                                ++ unqualifiedName b ++ " - " ++ unqualifiedName v
substOrApply e         rest       = return $ mkCoreApps e (map snd rest)

------------------------------------------------------------------------------
