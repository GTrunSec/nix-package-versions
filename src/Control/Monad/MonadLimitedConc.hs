{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE TypeFamilies #-}

module Control.Monad.MonadLimitedConc where

{- | A Monad to limit the amount of concurrent threads for a given task

This is useful because if we create too many threads that download things
from Nix we will exhaust the computer's resources and crash.
-}

import Control.Monad.Trans.Reader (ReaderT, reader)
import Control.Monad.Trans.Class (MonadTrans, lift)
import Control.Monad.Conc.Class (MonadConc, STM, atomically, ThreadId, fork)
import Control.Monad.STM.Class (retry)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Concurrent.Classy.MVar (MVar, modifyMVar)
import Control.Concurrent.Classy.STM.TVar (TVar, newTVar, readTVar, modifyTVar)
import Data.Map (Map)
import Data.Maybe (fromMaybe)
import UnliftIO (askUnliftIO, MonadUnliftIO, unliftIO)

import qualified Data.Map as Map

class MonadConc m => MonadLimitedConc k m | m -> k where
    asyncTask :: k -> m a -> m (ThreadId m)

data ConcState m k = ConcState
    { conc_limits :: Map k Int
    , conc_used :: MVar m (Map k (TVar (STM m) Int))
    }

instance
    ( MonadUnliftIO (t m)
    , MonadConc (t m)
    , MonadIO m
    , MonadLimitedConc k m
    , MonadTrans t
    , ThreadId (t m) ~ ThreadId m
    ) => MonadLimitedConc k (t m) where
    asyncTask k action = do
        u <- askUnliftIO
        lift $ asyncTask k $ liftIO $ unliftIO u $ action

instance (Ord k, MonadConc m, MonadIO m) => MonadLimitedConc k (ReaderT (ConcState m k) m) where
    asyncTask key task = fork $ do
        limits <- reader conc_limits
        let maxThreads = fromMaybe maxBound $ Map.lookup key limits

        usedMapVar <-reader conc_used
        threadPool <- modifyMVar usedMapVar $ \usedMap -> do
            threadPool <- maybe (atomically $ newTVar 0) return $ Map.lookup key usedMap
            return (Map.insert key threadPool usedMap, threadPool)

        -- | Block until a thread becomes available for this task
        atomically $ do
            used <- readTVar threadPool
            if used < maxThreads then do
                -- | Take a thread
                modifyTVar threadPool (+ 1)
                return ()
            else
                retry
        _ <- task
        -- | Return the thread to the pool
        atomically $ modifyTVar threadPool (\v -> v - 1)
        return ()


