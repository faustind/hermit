{-# LANGUAGE CPP, DeriveDataTypeable, FlexibleContexts, GADTs, InstanceSigs, KindSignatures #-}

module HERMIT.Monad
    ( -- * The HERMIT Monad
      HermitM
    , runHM
    , embedHermitM
    , HermitMEnv(..)
    , HermitMResult(..)
    , LiftCoreM(..)
    , runTcM
    , runDsM
      -- * Saving Definitions
    , RememberedName(..)
    , DefStash
    , saveDef
    , lookupDef
    , HasStash(..)
      -- * Lemmas
    , Equality(..)
    , LemmaName(..)
    , Lemma(..)
    , Lemmas
    , addLemma
      -- * Reader Information
    , HasHermitMEnv(..)
    , mkEnv
    , getModGuts
    , HasHscEnv(..)
      -- * Writer Information
    , HasLemmas(..)
      -- * Messages
    , HasDebugChan(..)
    , DebugMessage(..)
    , sendDebugMessage
    ) where

import Prelude hiding (lookup)

import Data.Dynamic (Typeable)
import Data.Map
import Data.String (IsString(..))

import Control.Applicative
import Control.Arrow
import Control.Concurrent.STM
import Control.Monad
import Control.Monad.IO.Class

import Language.KURE

import HERMIT.Core
import HERMIT.Context
import HERMIT.Kure.SumTypes
import HERMIT.GHC
import HERMIT.GHC.Typechecker

----------------------------------------------------------------------------

-- | A label for individual definitions. Use a newtype so we can tab-complete in shell.
newtype RememberedName = RememberedName String deriving (Eq, Ord, Typeable)

instance IsString RememberedName where fromString = RememberedName
instance Show RememberedName where show (RememberedName s) = s

-- | A store of saved definitions.
type DefStash = Map RememberedName CoreDef

-- | An equality is represented as a set of universally quantified binders, and the LHS and RHS of the equality.
data Equality = Equality [CoreBndr] CoreExpr CoreExpr

-- | A name for lemmas. Use a newtype so we can tab-complete in shell.
newtype LemmaName = LemmaName String deriving (Eq, Ord, Typeable)

instance IsString LemmaName where fromString = LemmaName
instance Show LemmaName where show (LemmaName s) = s

-- | An equality with a proven status.
data Lemma = Lemma { lemmaEq :: Equality
                   , lemmaP  :: Bool     -- whether lemma has been proven
                   , lemmaU  :: Bool     -- whether lemma has been used
                   }

-- | A collectin of named lemmas.
type Lemmas = Map LemmaName Lemma

-- | The HermitM reader environment.
data HermitMEnv = HermitMEnv { hEnvModGuts   :: ModGuts -- ^ Note: this is a snapshot of the ModGuts from
                                                        --         before the current transformation.
                             , hEnvStash     :: DefStash
                             , hEnvLemmas    :: Lemmas
                             }

mkEnv :: ModGuts -> DefStash -> Lemmas -> HermitMEnv
mkEnv = HermitMEnv

-- | The HermitM result record.
data HermitMResult a = HermitMResult { hResStash  :: DefStash
                                     , hResLemmas :: Lemmas
                                     , hResult    :: a
                                     }

mkResult :: DefStash -> Lemmas -> a -> HermitMResult a
mkResult = HermitMResult

mkResultEnv :: HermitMEnv -> a -> HermitMResult a
mkResultEnv env = mkResult (hEnvStash env) (hEnvLemmas env)

-- | The HERMIT monad is kept abstract.
--
-- It provides a reader for ModGuts, state for DefStash and Lemmas,
-- and access to a debugging channel.
newtype HermitM a = HermitM { runHermitM :: DebugChan -> HermitMEnv -> CoreM (KureM (HermitMResult a)) }

type DebugChan = DebugMessage -> HermitM ()

-- | Eliminator for 'HermitM'.
runHM :: DebugChan                     -- debug chan
      -> HermitMEnv                    -- env
      -> (HermitMResult a -> CoreM b)  -- success
      -> (String -> CoreM b)           -- failure
      -> HermitM a                     -- ma
      -> CoreM b
runHM chan env success failure ma = runHermitM ma chan env >>= runKureM success failure

-- | Allow HermitM to be embedded in another monad with proper capabilities.
embedHermitM :: (HasDebugChan m, HasHermitMEnv m, HasLemmas m, HasStash m, LiftCoreM m) => HermitM a -> m a
embedHermitM hm = do
    env <- getHermitMEnv
    c <- liftCoreM $ liftIO newTChanIO -- we are careful to do IO within liftCoreM to avoid the MonadIO constraint
    r <- liftCoreM (runHermitM hm (liftIO . atomically . writeTChan c) env) >>= runKureM return fail
    chan <- getDebugChan
    let relayDebugMessages = do
            mm <- liftCoreM $ liftIO $ atomically $ tryReadTChan c
            case mm of
                Nothing -> return ()
                Just dm -> chan dm >> relayDebugMessages

    relayDebugMessages
    putStash $ hResStash r
    forM_ (toList (hResLemmas r)) $ uncurry insertLemma
    return $ hResult r

instance Functor HermitM where
  fmap :: (a -> b) -> HermitM a -> HermitM b
  fmap = liftM

instance Applicative HermitM where
  pure :: a -> HermitM a
  pure = return

  (<*>) :: HermitM (a -> b) -> HermitM a -> HermitM b
  (<*>) = ap

instance Monad HermitM where
  return :: a -> HermitM a
  return a = HermitM $ \ _ env -> return (return (mkResultEnv env a))

  (>>=) :: HermitM a -> (a -> HermitM b) -> HermitM b
  (HermitM gcm) >>= f =
        HermitM $ \ chan env -> gcm chan env >>= runKureM (\ (HermitMResult s ls a) ->
                                                            let env' = env { hEnvStash = s, hEnvLemmas = ls }
                                                            in  runHermitM (f a) chan env')
                                                          (return . fail)

  fail :: String -> HermitM a
  fail msg = HermitM $ \ _ _ -> return (fail msg)

instance MonadCatch HermitM where
  catchM :: HermitM a -> (String -> HermitM a) -> HermitM a
  (HermitM gcm) `catchM` f = HermitM $ \ chan env -> gcm chan env >>= runKureM (return.return)
                                                                               (\ msg -> runHermitM (f msg) chan env)

instance MonadIO HermitM where
  liftIO :: IO a -> HermitM a
  liftIO = liftCoreM . liftIO

instance MonadUnique HermitM where
  getUniqueSupplyM :: HermitM UniqSupply
  getUniqueSupplyM = liftCoreM getUniqueSupplyM

instance MonadThings HermitM where
    lookupThing :: Name -> HermitM TyThing
    -- We do not simply do:
    --
    --     lookupThing = liftCoreM . lookupThing
    --
    -- because we can do better. HermitM has access
    -- to the ModGuts, so we can find TyThings defined
    -- in the current module, not just imported ones.
    -- Usually we look in the context first, which has
    -- *most* things from the current module. However,
    -- some Ids, such as class method selectors, are not
    -- explicitly bound in the core, so will not be in
    -- the context. These are instead kept in the
    -- ModGuts' list of instances. Which this will find.
    lookupThing nm = runTcM $ tcLookupGlobal nm

instance HasDynFlags HermitM where
    getDynFlags :: HermitM DynFlags
    getDynFlags = liftCoreM getDynFlags

----------------------------------------------------------------------------

class HasStash m where
    -- | Get the stash of saved definitions.
    getStash :: m DefStash

    -- | Replace the stash of saved definitions.
    putStash :: DefStash -> m ()

instance HasStash HermitM where
    getStash = HermitM $ \ _ env -> return $ return $ mkResultEnv env $ hEnvStash env

    putStash s = HermitM $ \ _ env -> return $ return $ mkResult s (hEnvLemmas env) ()

-- | Save a definition for future use.
saveDef :: (HasStash m, Monad m) => RememberedName -> CoreDef -> m ()
saveDef l d = getStash >>= (insert l d >>> putStash)

-- | Lookup a previously saved definition.
lookupDef :: (HasStash m, Monad m) => RememberedName -> m CoreDef
lookupDef l = getStash >>= (lookup l >>> maybe (fail "Definition not found.") return)

----------------------------------------------------------------------------

class HasHermitMEnv m where
    -- | Get the HermitMEnv
    getHermitMEnv :: m HermitMEnv

instance HasHermitMEnv HermitM where
    getHermitMEnv = HermitM $ \ _ env -> return $ return $ mkResultEnv env env

getModGuts :: (HasHermitMEnv m, Monad m) => m ModGuts
getModGuts = liftM hEnvModGuts getHermitMEnv

----------------------------------------------------------------------------

class HasDebugChan m where
    -- | Get the debugging channel
    getDebugChan :: m (DebugMessage -> m ())

instance HasDebugChan HermitM where
    getDebugChan = HermitM $ \ chan env -> return $ return $ mkResultEnv env chan

sendDebugMessage :: (HasDebugChan m, Monad m) => DebugMessage -> m ()
sendDebugMessage msg = getDebugChan >>= ($ msg)

----------------------------------------------------------------------------

class HasHscEnv m where
    getHscEnv :: m HscEnv

instance HasHscEnv CoreM where
    getHscEnv = getHscEnvCoreM

instance HasHscEnv HermitM where
    getHscEnv = liftCoreM getHscEnv

----------------------------------------------------------------------------

class HasLemmas m where
    -- | Add (or replace) a named lemma.
    insertLemma :: LemmaName -> Lemma -> m ()

    getLemmas :: m Lemmas

instance HasLemmas HermitM where
    insertLemma nm l = HermitM $ \ _ env -> return $ return $ mkResult (hEnvStash env) (insert nm l $ hEnvLemmas env) ()

    getLemmas = HermitM $ \ _ env -> return $ return $ mkResultEnv env (hEnvLemmas env)

-- | Only adds a lemma if doesn't already exist.
addLemma :: (HasLemmas m, Monad m) => LemmaName -> Lemma -> m ()
addLemma nm l = do
    ls <- getLemmas
    maybe (insertLemma nm l) (\ _ -> return ()) (lookup nm ls)

----------------------------------------------------------------------------

class Monad m => LiftCoreM m where
    -- | 'CoreM' can be lifted to this monad.
    liftCoreM :: CoreM a -> m a

instance LiftCoreM HermitM where
    liftCoreM coreM = HermitM $ \ _ env -> coreM >>= return . return . mkResultEnv env

----------------------------------------------------------------------------

-- | A message packet.
data DebugMessage :: * where
    DebugTick ::                                       String                -> DebugMessage
    DebugCore :: (ReadBindings c, ReadPath c Crumb) => String -> c -> CoreTC -> DebugMessage

----------------------------------------------------------------------------

runTcM :: (HasDynFlags m, HasHermitMEnv m, HasHscEnv m, MonadIO m) => TcM a -> m a
runTcM m = do
    env <- getHscEnv
    dflags <- getDynFlags
    guts <- getModGuts
    -- What is the effect of HsSrcFile (should we be using something else?)
    -- What should the boolean flag be set to?
    (msgs, mr) <- liftIO $ initTcFromModGuts env guts HsSrcFile False m
    let showMsgs (warns, errs) = showSDoc dflags $ vcat
                                                 $    text "Errors:" : pprErrMsgBag errs
                                                   ++ text "Warnings:" : pprErrMsgBag warns
    maybe (fail $ showMsgs msgs) return mr

runDsM :: (HasDynFlags m, HasHermitMEnv m, HasHscEnv m, MonadIO m) => DsM a -> m a
runDsM = runTcM . initDsTc
