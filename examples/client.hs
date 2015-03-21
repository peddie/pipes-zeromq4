{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Pipes.ZMQ4
import Pipes.Core
import qualified System.ZMQ4 as Z
import Control.Concurrent (threadDelay)

import qualified Data.ByteString as B
import Data.List.NonEmpty (NonEmpty(..))

get :: MonadIO m => Client (NonEmpty B.ByteString) [B.ByteString] m ()
get = mapM_ (\x -> do
                liftIO . putStrLn $ "Requesting " ++ show x
                resp <- request $ x :| []
                liftIO . putStrLn $ "Received response " ++ show (B.concat resp)
                liftIO $ threadDelay 1000000)
      ["1", "2", "3" :: B.ByteString]

main :: IO ()
main = Z.withContext $ \ctx ->
  runSafeT . runEffect $
  setupServer ctx Z.Req (`Z.connect` "ipc:///tmp/server") +>> get
