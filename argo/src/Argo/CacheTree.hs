{-# Language BangPatterns #-}
module Argo.CacheTree
  ( Cache(..)
  , newCache
  , cacheLookup
  , cacheAdvance
  ) where

import           Control.Concurrent
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.HashMap.Lazy (HashMap)
import qualified Data.HashMap.Lazy as HashMap
import           Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString

import           Data.Hashable (Hashable)

data Cache st cmd = Cache
  { cacheRoot :: st
  , cacheBranches :: !(MVar (HashMap cmd (MVar (Cache st cmd))))
  }

newCache :: st -> IO (Cache st cmd)
newCache initialState =
  Cache initialState <$> newMVar HashMap.empty

cacheLookup ::
  (Eq cmd, Hashable cmd) =>
  (cmd -> st -> IO st)  {- ^ run command -} ->
  (st -> IO Bool)       {- ^ validate    -} ->
  Cache st cmd          {- ^ cache       -} ->
  [cmd]                 {- ^ commands    -} ->
  IO (Cache st cmd)
cacheLookup runStep validate =
  foldM (cacheAdvance runStep validate)

-- | Validation must return true when cached server state is valid.
cacheAdvance ::
  (Eq cmd, Hashable cmd) =>
  (cmd -> st -> IO st) {- ^ run command -} ->
  (st -> IO Bool)      {- ^ validate    -} ->
  Cache st cmd         {- ^ cache       -} ->
  cmd                  {- ^ command     -} ->
  IO (Cache st cmd)
cacheAdvance runStep validate (Cache st var) cmd =
  do (found, nextVar) <-
       modifyMVar var $ \hashMap ->
         case HashMap.lookup cmd hashMap of
           Just nextVar -> return (hashMap, (True, nextVar))
           Nothing ->
             do nextVar <- newEmptyMVar
                let !hashMap' = HashMap.insert cmd nextVar hashMap
                return (hashMap', (False, nextVar))

     if found then
       modifyMVar nextVar $ \c ->
         do valid <- validate (cacheRoot c)
            c' <- if valid then return c
                  else newCache =<< runStep cmd st
            return (c', c')

     else
       do cache <- newCache =<< runStep cmd st
          putMVar nextVar cache
          return cache
