{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}

{-|
Module      :  Pipes.ZMQ4
Copyright   :  (c) Matthew Peddie 2014
License     :  BSD3 (see the file zeromq4-pipes/LICENSE)

Maintainer  :  matt.peddie@planet.com
Stability   :  experimental
Portability :  GHC

This module provides functions to help you attach ZMQ sockets to
"Pipes" processing pipelines.

If you want to hook ZMQ sockets into a unidirectional pipeline
involving 'Producer's, 'Consumer's and 'Pipe's, see
@examples/proxy.hs@ for a short usage example for 'setupProducer' and
'setupConsumer'.

If you want to hook ZMQ sockets into a bidirectional or
non-'Pull'-based pipeline involving 'Client's, 'Server's and 'Proxy's,
see @examples/server.hs@ and @examples/client.hs@ for a short usage
example for 'setupServer' and 'setupClient'.

This module relies on the functions provided by "Pipes.Safe" to deal
with exceptions and termination.  If you need to avoid this layer of
safety, please don't hesitate to contact the author for support.

Currently, everything runs in the same thread as the rest of the
'Effect', so
__if something blocks forever on a ZMQ receive or send, you may be in trouble.__

-}

module Pipes.ZMQ4 (
  -- * Create data sources and sinks

  -- | Each of these functions takes a setup function, which is is run
  -- before any messaging activities happen, so anything you need to
  -- do to configure the socket (e.g. 'Z.subscribe', set options,
  -- 'Z.connect' or 'Z.bind') should be done within it.
  --
  -- __Note that according to the ZeroMQ manual pages__, the correct
  -- order of operations is to perform all socket configuration before
  -- running 'Z.connect' or 'Z.bind'.

  -- ** One-directional sources and sinks (for use with "Pipes"'s 'Pipe', 'Producer' and 'Consumer')
  setupProducer
  , setupConsumer
  , setupPipe
  , setupPipePair
  , setupPipeline
    -- ** Bidirectional sources and sinks (for use with "Pipes.Core"'s 'Proxy', 'Server' and 'Client').
  , setupClient
  , setupServer
    -- ** Low-level safe setup

    -- | It's recommended to use 'setupProducer', 'setupConsumer' and
    -- friends instead of these functions unless you know what you're
    -- doing and need something else.
  , setup
  , receiveMessage
  , sendMessage
    -- * Helpers
  , toNonEmpty
    -- * Re-exported modules
  , module Pipes
  , module Pipes.Safe
  ) where

import Control.Monad (unless, forever)

import qualified System.ZMQ4 as Z

import qualified Data.ByteString      as B
import Data.List.NonEmpty (NonEmpty(..))

import Pipes
import Pipes.Safe
import Pipes.Core

-- | This is the low-level function for safely 'bracket'ing ZMQ socket
-- creation, so that any exceptions or 'Pipe' termination will not
-- result in abandoned sockets.  For example, 'setupProducer' is
-- defined as
--
-- @
-- setupProducer ctx ty opts = setup ctx ty opts $ forever . receiveMessage
-- @
setup :: (MonadSafe m, Base m ~ IO,
          Z.SocketType sockty) =>
         Z.Context
      -> sockty
      -> (Z.Socket sockty -> IO ())
      -> (Z.Socket sockty -> m v)
      -> m v
setup ctx ty opts act =
  bracket (Z.socket ctx ty) (liftIO . Z.close) $ \sock -> do
    _ <- liftIO $ opts sock
    act sock

-- | This is a low-level function for simply passing a message
-- received on a socket downstream.
--
-- @
-- receiveMessage sock = forever $ liftIO (Z.receiveMulti sock) >>= yield
-- @
receiveMessage :: (Z.Receiver sck, MonadIO m) =>
               Z.Socket sck -> Producer' [B.ByteString] m ()
receiveMessage sock = liftIO (Z.receiveMulti sock) >>= yield

-- | This is a low-level function for simply sending a message
-- available from upstream out on the socket.
--
-- @
-- sendMessage sock = await >>= liftIO . Z.sendMulti sock
-- @
sendMessage :: (Z.Sender sck, MonadIO m) =>
            Z.Socket sck -> Consumer' (NonEmpty B.ByteString) m ()
sendMessage sock = await >>= liftIO . Z.sendMulti sock

-- | Create a 'Producer' of message data from the given ZeroMQ
-- parameters.  All messages received on the socket will be sent
-- downstream with 'yield'.
setupProducer :: (MonadSafe m, Base m ~ IO,
                  Z.SocketType sockty, Z.Receiver sockty) =>
                 Z.Context  -- ^ ZMQ context
              -> sockty     -- ^ ZMQ socket type
              -> (Z.Socket sockty -> IO ())  -- ^ Setup function
              -> Producer [B.ByteString] m ()  -- ^ Message source
setupProducer ctx ty opts = setup ctx ty opts $ forever . receiveMessage

-- | Create a 'Consumer' of message data from the given ZeroMQ
-- parameters.  All data successfully 'await'ed from upstream will be
-- sent out the socket.
--
-- The resulting 'Consumer' will only accept 'NonEmpty' lists of
-- 'B.ByteString' message parts.  See 'toNonEmpty' if this is a
-- sticking point for you.
setupConsumer :: (MonadSafe m, Base m ~ IO,
                  Z.SocketType sockty, Z.Sender sockty) =>
                 Z.Context  -- ^ ZMQ context
              -> sockty     -- ^ ZMQ socket type
              -> (Z.Socket sockty -> IO ())  -- ^ Setup function
              -> Consumer' (NonEmpty B.ByteString) m ()  -- ^ Message sink
setupConsumer ctx ty opts = setup ctx ty opts $ forever . sendMessage

-- | Create a 'Pipe' out of a socket from the given ZeroMQ parameters.
-- All data successfully 'await'ed from upstream will be sent out the
-- socket, and all message data received on the socket will be
-- 'yield'ed downstream.
--
-- You can use this 'Pipe' to replace a processing stage in your
-- pipeline with a ZMQ transaction.  Note that the ZMQ actions here
-- are blocking; for example, if you make a 'Z.Req' socket, the
-- pipeline will block when the message from upstream is transmitted
-- until the response from the remote ZMQ socket is received.
-- Consider using the @pipes-concurrency@ package if you are sure
-- you're using the right socket type but you don't want everything to
-- block here.
setupPipe :: (MonadSafe m, Base m ~ IO,
                  Z.SocketType sockty,
                  Z.Sender sockty, Z.Receiver sockty) =>
                 Z.Context  -- ^ ZMQ context
              -> sockty     -- ^ ZMQ socket type
              -> (Z.Socket sockty -> IO ())  -- ^ Setup function for socket
              -> Pipe (NonEmpty B.ByteString) [B.ByteString] m ()  -- ^ Pipeline stage via ZMQ
setupPipe ctx ty opts = setup ctx ty opts $ \sock ->
  forever $ sendMessage sock >> receiveMessage sock

-- | 'setupPipePair' is the same as 'setupPipe' except that it allows
-- you to use two different sockets, one for sending and the other for
-- receiving.
setupPipePair :: (MonadSafe m, Base m ~ IO,
                  Z.SocketType txsock, Z.SocketType rxsock,
                  Z.Sender txsock, Z.Receiver rxsock) =>
                 Z.Context  -- ^ ZMQ context
              -> txsock     -- ^ ZMQ transmit socket type
              -> rxsock     -- ^ ZMQ receive socket type
              -> (Z.Socket txsock -> IO ())  -- ^ Setup function for transmit socket
              -> (Z.Socket rxsock -> IO ())  -- ^ Setup function for receive socket
              -> Pipe (NonEmpty B.ByteString) [B.ByteString] m ()  -- ^ Pipeline stage via ZMQ
setupPipePair ctx txty rxty txopts rxopts =
  setup ctx txty txopts $ \tx ->
  setup ctx rxty rxopts $ \rx ->
  forever $ sendMessage tx >> receiveMessage rx

-- | Create an 'Effect' out of a socket from the given ZeroMQ
-- parameters and a pipe to use to connect the resulting 'Producer'
-- and 'Consumer'.
--
-- There are two ways to use a single socket to do both ZMQ sends and
-- receives in the same pipeline.  'setupPipe' places the ZMQ socket
-- in the middle of the pipeline.  'setupPipeline' places the same ZMQ
-- socket at both ends: the provided 'Pipe' is used to connect the
-- receiving Producer and sending Consumer generated from the ZMQ
-- socket.  In other words, for @setupPipeline ctx socktype opts
-- myPipe@,
--
-- @
-- socket RX >-> myPipe >-> socket TX
-- @
--
-- See 'setupPipe' for some caveats.  See @examples/serverPipeline.hs@
-- for a usage example.
setupPipeline :: (MonadSafe m, Base m ~ IO,
                  Z.SocketType sockty,
                  Z.Sender sockty, Z.Receiver sockty) =>
                 Z.Context  -- ^ ZMQ context
              -> sockty     -- ^ ZMQ socket type
              -> (Z.Socket sockty -> IO ())  -- ^ Setup function for socket
              -> Pipe [B.ByteString] (NonEmpty B.ByteString) m ()  -- ^ Pipeline to run in the middle
              -> Effect m ()
setupPipeline ctx ty opts inpipe = setup ctx ty opts $ \sock ->
  forever $
  (liftIO (Z.receiveMulti sock) >>= yield) >->
  inpipe >->
  (await >>= liftIO . Z.sendMulti sock)

-- |
-- This is a low-level function for passing all messages received on
-- the socket upstream and sending the responses out on the same
-- socket.
--
-- @
-- clientLoop sock = forever $
--   liftIO (Z.receiveMulti sock) >>=
--   request >>=
--   liftIO . Z.sendMulti sock
-- @
clientLoop :: (Z.Receiver sockty, Z.Sender sockty, MonadIO m) =>
              Z.Socket sockty
           -> Client' [B.ByteString] (NonEmpty B.ByteString) m ()
clientLoop sock = forever $
                  liftIO (Z.receiveMulti sock) >>=
                  request >>=
                  liftIO . Z.sendMulti sock

-- | Create a 'Client'' from the given ZeroMQ parameters.  The 'Client''
-- passes all messages it receives on the ZMQ socket upstream with
-- 'request' and sends all corresponding replies back out the socket.
setupClient :: (MonadSafe m, Base m ~ IO,
               Z.SocketType sockty, Z.Sender sockty, Z.Receiver sockty) =>
              Z.Context  -- ^ ZMQ context
           -> sockty     -- ^ ZMQ socket type
           -> (Z.Socket sockty -> IO ()) -- ^ Setup function
           -> Client [B.ByteString] (NonEmpty B.ByteString) m ()
setupClient ctx ty opts = setup ctx ty opts clientLoop

-- |
-- This is a low-level function for passing all messages received on
-- the socket upstream and sending the responses out on the same
-- socket.
--
-- @
-- serverLoop sock msg =
--   liftIO (Z.sendMulti sock msg) >>
--   liftIO (Z.receiveMulti sock) >>=
--   respond >>=
--   serverLoop sock
-- @
serverLoop :: (Z.Receiver sockty, Z.Sender sockty, MonadIO m) =>
              Z.Socket sockty
           -> NonEmpty B.ByteString
           -> Server' (NonEmpty B.ByteString) [B.ByteString] m ()
serverLoop sock msg = liftIO (Z.sendMulti sock msg) >>
                      liftIO (Z.receiveMulti sock) >>=
                      respond >>=
                      serverLoop sock

-- | Create a 'Server'' from the given ZeroMQ parameters.  The 'Server''
-- sends all received requests out on the ZMQ socket and passes all
-- messages it receives over the ZMQ socket back downstream with
-- 'respond'.
setupServer :: (MonadSafe m, Base m ~ IO,
                Z.SocketType sockty, Z.Sender sockty, Z.Receiver sockty) =>
               Z.Context  -- ^ ZMQ context
            -> sockty     -- ^ ZMQ socket type
            -> (Z.Socket sockty -> IO ())       -- ^ Setup function
            -> NonEmpty B.ByteString            -- ^ Server request input
            -> Server (NonEmpty B.ByteString) [B.ByteString] m ()
setupServer ctx ty opts n = setup ctx ty opts (`serverLoop` n)

-- | This is simply an adapter between lists of message parts and the
-- 'NonEmpty' lists demanded by ZMQ 'Consumer's.  If an empty list
-- arrives in the input, it will be ignored.
toNonEmpty :: Monad m => Pipe [B.ByteString] (NonEmpty B.ByteString) m ()
toNonEmpty = forever $ do
  msg <- await
  unless (null msg) $ yield (head msg :| tail msg)
