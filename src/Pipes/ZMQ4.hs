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
  setupProducer
  , setupConsumer
  , setupBi
  , setupClient
  , setupServer
    -- ** Low-level safe setup

    -- | It's recommended to use 'setupProducer', 'setupConsumer' and
    -- friends instead of these functions unless you know what you're
    -- doing and need something else.
  , setup
  , receiveLoop
  , sendLoop
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
-- setupProducer ctx ty opts = setup ctx ty opts receiveLoop
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

-- | This is a low-level function for simply passing all messages
-- received on a socket downstream.
--
-- @
-- receiveLoop sock = forever $ liftIO (Z.receiveMulti sock) >>= yield
-- @
receiveLoop :: (Z.Receiver sck, MonadIO m) =>
               Z.Socket sck -> Producer [B.ByteString] m ()
receiveLoop sock = forever $ liftIO (Z.receiveMulti sock) >>= yield

-- | This is a low-level function for simply sending all messages
-- available from upstream out on the socket.
--
-- @
-- sendLoop sock = forever $ await >>= liftIO . Z.sendMulti sock
-- @
sendLoop :: (Z.Sender sck, MonadIO m) =>
            Z.Socket sck -> Consumer' (NonEmpty B.ByteString) m ()
sendLoop sock = forever $ await >>= liftIO . Z.sendMulti sock

-- | Create a 'Producer' of message data from the given ZeroMQ
-- parameters.  All messages received on the socket will be sent
-- downstream with 'yield'.
setupProducer :: (MonadSafe m, Base m ~ IO,
                  Z.SocketType sockty, Z.Receiver sockty) =>
                 Z.Context  -- ^ ZMQ context
              -> sockty     -- ^ ZMQ socket type
              -> (Z.Socket sockty -> IO ())  -- ^ Setup function
              -> Producer [B.ByteString] m ()  -- ^ Message source
setupProducer ctx ty opts = setup ctx ty opts receiveLoop

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
setupConsumer ctx ty opts = setup ctx ty opts sendLoop

-- | Create both a 'Producer' and a 'Consumer' of message data, both
-- corresponding to the same socket, from the given ZeroMQ parameters.
-- This is like 'setupProducer' and 'setupConsumer' combined; the
-- socket type must be both a 'Z.Sender' and a 'Z.Receiver' (for
-- example, a 'Z.Dealer').  Messages received over the socket are
-- 'yield'ed by the 'Producer'; messages 'await'ed by the 'Consumer'
-- are sent over the socket.
--
-- See also the descriptions of 'setupProducer' and 'setupConsumer'.
setupBi :: (MonadSafe m, Base m ~ IO, MonadSafe m1, Base m1 ~ IO,
            Z.SocketType sockty, Z.Sender sockty, Z.Receiver sockty) =>
           Z.Context  -- ^ ZMQ context
        -> sockty     -- ^ ZMQ socket type
        -> (Z.Socket sockty -> IO ())  -- ^ Setup function
        -> m1 (Producer [B.ByteString] m (),
               Consumer (NonEmpty B.ByteString) m ())  -- ^ Message (source, sink) pair
setupBi ctx ty opts = setup ctx ty opts $ \sock -> return
  (receiveLoop sock, sendLoop sock)

-- |
-- This is a low-level function for passing all messages received on
-- the socket upstream and sending the responses out on the same
-- socket.
--
-- @
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
