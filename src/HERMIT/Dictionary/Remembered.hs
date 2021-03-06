{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module HERMIT.Dictionary.Remembered
    ( -- * Remembering definitions.
      externals
    , prefixRemembered
    , rememberR
    , unfoldRememberedR
    , foldRememberedR
    , foldAnyRememberedR
    , compileRememberedT
    ) where

import           Control.Monad

import qualified Data.Map as Map
import           Data.List (isPrefixOf)
import           Data.Monoid

import           HERMIT.Context
import           HERMIT.Core
import           HERMIT.External
import           HERMIT.GHC hiding ((<>), (<+>), nest, ($+$))
import           HERMIT.Kure
import           HERMIT.Lemma
import           HERMIT.Monad
import           HERMIT.PrettyPrinter.Common

import           HERMIT.Dictionary.Fold hiding (externals)
import           HERMIT.Dictionary.Reasoning hiding (externals)

------------------------------------------------------------------------------

externals :: [External]
externals =
    [ external "remember" (promoteCoreT . rememberR :: LemmaName -> TransformH LCore ())
        [ "Remember the current binding, allowing it to be folded/unfolded in the future." ] .+ Context
    , external "unfold-remembered" (promoteExprR . unfoldRememberedR Obligation :: LemmaName -> RewriteH LCore)
        [ "Unfold a remembered definition." ] .+ Deep .+ Context
    , external "fold-remembered" (promoteExprR . foldRememberedR Obligation :: LemmaName -> RewriteH LCore)
        [ "Fold a remembered definition." ]                      .+ Context .+ Deep
    , external "fold-any-remembered" (promoteExprR foldAnyRememberedR :: RewriteH LCore)
        [ "Attempt to fold any of the remembered definitions." ] .+ Context .+ Deep
    , external "show-remembered" (promoteCoreT . showLemmasT (Just "remembered-") :: PrettyPrinter -> PrettyH LCore)
        [ "Display all remembered definitions." ]
    ]

------------------------------------------------------------------------------

prefixRemembered :: LemmaName -> LemmaName
prefixRemembered = ("remembered-" <>)

-- | Remember a binding with a name for later use. Allows us to look at past definitions.
rememberR :: (AddBindings c, ExtendPath c Crumb, ReadPath c Crumb, HasLemmas m, MonadCatch m)
          => LemmaName -> Transform c m Core ()
rememberR nm = prefixFailMsg "remember failed: " $ do
    Def v e <- setFailMsg "not applied to a binding." $ defOrNonRecT idR idR Def
    insertLemmaT (prefixRemembered nm) $ Lemma (mkClause [] (varToCoreExpr v) e) Proven NotUsed

-- | Unfold a remembered definition (like unfoldR, but looks in stash instead of context).
unfoldRememberedR :: (LemmaContext c, ReadBindings c, HasLemmas m, MonadCatch m)
                  => Used -> LemmaName -> Rewrite c m CoreExpr
unfoldRememberedR u = prefixFailMsg "Unfolding remembered definition failed: " . forwardT . lemmaBiR u . prefixRemembered

-- | Fold a remembered definition (like foldR, but looks in stash instead of context).
foldRememberedR :: (LemmaContext c, ReadBindings c, HasLemmas m, MonadCatch m)
                => Used -> LemmaName -> Rewrite c m CoreExpr
foldRememberedR u = prefixFailMsg "Folding remembered definition failed: " . backwardT . lemmaBiR u . prefixRemembered

-- | Fold any of the remembered definitions.
foldAnyRememberedR :: (LemmaContext c, ReadBindings c, HasLemmas m, MonadCatch m)
                   => Rewrite c m CoreExpr
foldAnyRememberedR = setFailMsg "Fold failed: no definitions could be folded."
                   $ compileRememberedT >>= runFoldR

-- | Compile all remembered definitions into something that can be run with `runFoldR`
compileRememberedT :: (LemmaContext c, HasLemmas m, Monad m) => Transform c m x CompiledFold
compileRememberedT = do
    qs <- liftM (map lemmaC . Map.elems . Map.filterWithKey (\ k _ -> "remembered-" `isPrefixOf` show k)) getLemmasT
    return $ compileFold $ concatMap (map flipEquality . toEqualities) qs -- fold rhs to lhs
