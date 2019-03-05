-- | A low-level connection to Riak.
--
-- Like the underlying socket, this is not a thread-safe abstraction.

module Libriak.Connection
  ( Connection
  , withConnection
  , connect
  , disconnect
  , send
  , receive
  , ConnectError(..)
  , ConnectionError(..)
    -- * Re-exports
  , Endpoint(..)
  , DecodeError(..)
  , CloseException(..)
  ) where

import Libriak.Internal.Connection (CloseException(..), Connection,
                                    Endpoint(..), Interruptibility(..),
                                    ReceiveException(..), SendException(..),
                                    disconnect)
import Libriak.Request             (EncodedRequest(..))
import Libriak.Response            (DecodeError(..), EncodedResponse(..))

import qualified Libriak.Internal.Connection as Connection

import Data.Bifunctor (bimap, first)
import Data.Kind (Type)


data ConnectError :: Type where
  ConnectFirewalled :: ConnectError
  ConnectRefused :: ConnectError
  ConnectTimedOut :: ConnectError
  NetworkUnreachable :: ConnectError
  NoEphemeralPortsAvailable :: ConnectError
  TooManyOpenFiles :: ConnectError
  deriving stock (Eq, Show)

data ConnectionError :: Type where
  -- | The socket write channel is shut down.
  LocalShutdown :: ConnectionError
  -- | The remote peer reset the connection.
  RemoteReset :: ConnectionError
  -- | The remote peer's write channel is shut down.
  RemoteShutdown :: ConnectionError
  -- | We timed out waiting for a message from the remote peer.
  RemoteTimeout :: ConnectionError
  deriving stock (Eq, Show)

-- | Acquire a connection.
--
-- /Throws/. This function will never throw an exception.
withConnection ::
     Endpoint
  -> Int -- ^ Receive timeout (microseconds)
  -> (Connection -> IO a)
  -> IO (Either ConnectError a)
withConnection endpoint receiveTimeout onSuccess =
  first fromConnectException <$>
    Connection.withConnection endpoint receiveTimeout (const pure) onSuccess

-- | Acquire a connection.
--
-- /Throws/. This function will never throw an exception.
connect ::
     Endpoint
  -> Int -- ^ Receive timeout (microseconds)
  -> IO (Either ConnectError Connection)
connect endpoint receiveTimeout =
  first fromConnectException <$>
    Connection.connect endpoint receiveTimeout

-- | Send a request.
--
-- /Throws/. This function will never throw an exception.
send ::
     Connection
  -> EncodedRequest
  -> IO (Either ConnectionError ())
send conn (EncodedRequest request) =
  first fromSendException <$>
    Connection.send conn request

-- | Receive a response.
receive ::
     Connection
  -> IO (Either ConnectionError EncodedResponse)
receive =
  fmap (bimap fromReceiveException EncodedResponse) . Connection.receive

fromConnectException ::
     Connection.ConnectException 'Uninterruptible
  -> ConnectError
fromConnectException = \case
  Connection.ConnectEphemeralPortsExhausted -> NoEphemeralPortsAvailable
  Connection.ConnectFileDescriptorLimit     -> TooManyOpenFiles
  Connection.ConnectFirewalled              -> ConnectFirewalled
  Connection.ConnectNetworkUnreachable      -> NetworkUnreachable
  Connection.ConnectRefused                 -> ConnectRefused
  Connection.ConnectTimeout                 -> ConnectTimedOut

fromSendException :: SendException 'Uninterruptible -> ConnectionError
fromSendException = \case
  SendReset    -> RemoteReset
  SendShutdown -> LocalShutdown

fromReceiveException :: ReceiveException 'Interruptible -> ConnectionError
fromReceiveException = \case
  ReceiveInterrupted -> RemoteTimeout
  ReceiveReset -> RemoteReset
  ReceiveShutdown -> RemoteShutdown