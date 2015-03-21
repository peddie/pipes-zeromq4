{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Monad

import Pipes.ZMQ4
import qualified Pipes.Prelude as P
import qualified System.ZMQ4 as Z
import System.Environment (getArgs)
import Control.Concurrent (threadDelay)

proxy :: IO ()
proxy = Z.withContext $ \ctx ->
  runSafeT . runEffect $
  setupProducer ctx Z.Pull (`Z.bind` "ipc:///tmp/proxy_in") >->
  P.tee P.print >-> toNonEmpty >->
  setupConsumer ctx Z.Push (`Z.connect` "ipc:///tmp/proxy_out")

sender :: IO ()
sender = Z.withContext $ \ctx ->
  Z.withSocket ctx Z.Push $ \sock -> do
    Z.connect sock "ipc:///tmp/proxy_in"
    replicateM_ 3 $ Z.send sock [] "hello" >> threadDelay 1000000
    Z.send sock [] "done"

receiver :: IO ()
receiver = Z.withContext $ \ctx ->
  Z.withSocket ctx Z.Pull $ \sock -> do
    Z.bind sock "ipc:///tmp/proxy_out"
    go sock
    putStrLn "Received 'done'; exiting."
  where
    go sock = do
      msg <- Z.receive sock
      unless (msg == "done") $ do
        putStrLn $ "Received: " ++ show msg
        go sock

{-| You will need 3 terminals: A, B and C.  Once the program is
compiled, start the receiver in terminal A:
@
./proxy 22
@

Start the proxy in terminal B:
@
./proxy 22 22
@

Start the sender in terminal C:
@
./proxy
@

Once the sender starts, three ordinary messages (@"hello"@) should be
passed one second apart from the sender via the proxy to the receiver,
followed by a termination message (@"done"@) which causes the receiver
to exit.  The proxy remains running until interrupted (@Ctrl-C@).

-}
main :: IO ()
main = do
  as <- getArgs
  case as of
   [] -> sender
   [_] -> receiver
   _ -> proxy
