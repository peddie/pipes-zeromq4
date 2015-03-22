{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Monad
import Pipes.ZMQ4
import qualified System.ZMQ4 as Z

import qualified Data.ByteString as B
import Data.List.NonEmpty (NonEmpty(..))

echo :: MonadIO m => Pipe [B.ByteString] (NonEmpty B.ByteString) m ()
echo = forever $ do
  nxt <- await
  case nxt of
   []          -> liftIO . putStrLn $ "Received empty list."
   bs@(b:moar) -> do
     liftIO . putStrLn $ "Received data " ++ show (B.concat bs) ++ "."
     yield (b :| moar)

-- | Please run me concurrently with the 'client' program.
main :: IO ()
main = Z.withContext $ \ctx ->
  runSafeT . runEffect $
  setupPipeline ctx Z.Rep (`Z.bind` "ipc:///tmp/server") echo
