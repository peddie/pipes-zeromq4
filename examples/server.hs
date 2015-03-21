{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Pipes.ZMQ4
import Pipes.Core
import qualified System.ZMQ4 as Z

import qualified Data.ByteString as B
import Data.List.NonEmpty (NonEmpty(..))

echo :: MonadIO m => [B.ByteString] -> Server [B.ByteString] (NonEmpty B.ByteString) m ()
echo [] = do
  liftIO . putStrLn $ "Received empty list."
  nxt <- respond ("" :| [])
  echo nxt
echo bs@(b:moar) = do
  liftIO . putStrLn $ "Received data " ++ show (B.concat bs) ++ "."
  nxt <- respond (b :| moar)
  echo nxt

main :: IO ()
main = Z.withContext $ \ctx ->
  runSafeT . runEffect $
  echo +>> setupClient ctx Z.Rep (`Z.bind` "ipc:///tmp/server")
