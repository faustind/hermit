{-# LANGUAGE TypeFamilies, DeriveDataTypeable, FlexibleContexts, TypeSynonymInstances, FlexibleInstances #-}

module Language.HERMIT.External where

import Data.Map hiding (map)
import Data.Dynamic
import Data.List

import qualified Language.Haskell.TH as TH

import Language.HERMIT.HermitKure
--import Language.HERMIT.Kernel

-----------------------------------------------------------------

type ExternalName = String
type ExternalHelp = [String]

data CmdTag = Bash -- this command will be run as part of the bash command
            | Slow -- this command is slow
            | KURE -- a KURE command
            | GHC  -- a tunnel into GHC
            | Local     -- local thing, O(1)
            | Eval      -- the arrow of evaluation
            | Lens      -- focuses into a specific node
            | Context   -- something that uses the context
            | Experiment -- things we are trying out
            | Shell     -- Shell commands
            | Restful    -- RESTful API commands
            | Unimplemented
            -- etc
    deriving (Eq, Show, Read)

data CmdCategory = CaseCmd
                 | LetCmd
                 | TraversalCmd
                 | MetaCmd         -- cmds built from other commands, like bash
                 -- etc
    deriving (Eq, Ord, Show, Read, Bounded, Enum)


data External = External
        { externName :: ExternalName
        , externFun  :: Dynamic
        , externHelp :: ExternalHelp
        , externTags :: [CmdTag]
        , externCats :: [CmdCategory]
        }

external :: Extern a => ExternalName -> a -> ExternalHelp -> External
external nm fn help = External
        { externName = nm
        , externFun  = toDyn (box fn)
        , externHelp = map ("  " ++) help
        , externTags = []
        , externCats = []
        }

-- Unfortunately, record update syntax seems to associate to the right.
-- This guy saves us some parens.
infixl .+

class ExternTag a where
    (.+) :: External -> a -> External
    hasTag :: External -> a -> Bool

instance ExternTag CmdTag where
    ex@(External {externTags = ts}) .+ t = ex { externTags = (t:ts) }
    hasTag (External {externTags = ts}) t = t `elem` ts

instance ExternTag CmdCategory where
    ex@(External {externCats = cs}) .+ c = ex { externCats = (c:cs) }
    hasTag (External {externCats = cs}) c = c `elem` cs

toDictionary :: [External] -> Map ExternalName [Dynamic]
toDictionary
        -- TODO: check names are uniquely-prefixed
        | otherwise = fromListWith (++) . map toD
  where
         toD :: External -> (ExternalName,[Dynamic])
         toD e = (externName e,[externFun e])

toHelp :: [External] -> Map ExternalName ExternalHelp
toHelp = fromListWith (++) . map toH
  where
         toH :: External -> (ExternalName,ExternalHelp)
         toH e = (externName e, spaceout (externName e ++ " :: " ++ fixup (show (dynTypeRep (externFun e))))
                                         (show (externTags e)) : externHelp e)

         spaceout xs ys = xs ++ take (width - (length xs + length ys)) (repeat ' ') ++ ys

         width = 78

         fixup :: String -> String
         fixup xs | "Box" `isPrefixOf` xs = fixup (drop 3 xs)
         fixup (x:xs)                     = x : fixup xs
         fixup []                         = []


-----------------------------------------------------------------

class Typeable (Box a) => Extern a where
    type Box a
    box :: a -> Box a
    unbox :: Box a -> a

instance (Extern a, Extern b) => Extern (a -> b) where
    type Box (a -> b) = Box a -> Box b
    box f = box . f . unbox
    unbox f = unbox . f . box

data IntBox = IntBox Int deriving Typeable

instance Extern Int where
    type Box Int = IntBox
    box i = IntBox i
    unbox (IntBox i) = i

data RewriteCoreBox = RewriteCoreBox (RewriteH Core) deriving Typeable

instance Extern (RewriteH Core) where
    type Box (RewriteH Core) = RewriteCoreBox
    box i = RewriteCoreBox i
    unbox (RewriteCoreBox i) = i

data TranslateCoreStringBox = TranslateCoreStringBox (TranslateH Core String) deriving Typeable

instance Extern (TranslateH Core String) where
    type Box (TranslateH Core String) = TranslateCoreStringBox
    box i = TranslateCoreStringBox i
    unbox (TranslateCoreStringBox i) = i

data NameBox = NameBox (TH.Name) deriving Typeable

instance Extern TH.Name where
    type Box TH.Name = NameBox
    box i = NameBox i
    unbox (NameBox i) = i

data LensCoreCoreBox = LensCoreCoreBox (LensH Core Core) deriving Typeable

instance Extern (LensH Core Core) where
    type Box (LensH Core Core) = LensCoreCoreBox
    box i = LensCoreCoreBox i
    unbox (LensCoreCoreBox i) = i

{-
-}

data StringBox = StringBox String deriving Typeable

instance Extern String where
    type Box String = StringBox
    box i = StringBox i
    unbox (StringBox i) = i

-----------------------------------------------------------------
