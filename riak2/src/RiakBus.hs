module RiakBus
  ( Bus
  , withBus
  , exchange
  , stream
  , BusError(..)
  ) where

import Libriak.Connection (ConnectError(..), Connection, ConnectionError(..),
                           DecodeError, Endpoint(..))
import Libriak.Request    (Request, encodeRequest)
import Libriak.Response   (Response, decodeResponse)

import qualified Libriak.Connection as Connection

import Control.Concurrent.MVar
import Control.Concurrent.STM


data Bus
  = Bus
  { statusVar :: !(TVar Status)
  , sendLock :: !(MVar ())
    -- ^ Lock acquired during sending a request.
  , doneVarRef :: !(IORef (TMVar ()))
  }

-- | The connection status - it's alive until something goes wrong.
data Status
  = Alive Connection
  | Dead BusError

data BusError
  = BusConnectionError ConnectionError
  -- ^ A connection error occurred during a send or receive.
  | BusDecodeError DecodeError
  -- ^ A protobuf decode error occurred.
  deriving stock (Show)

-- | Acquire a bus.
--
-- /Throws/: This function will never throw an exception.
withBus ::
     Endpoint
  -> (Bus -> IO a)
  -> IO (Either ConnectError a)
withBus endpoint callback = do
  sendLock :: MVar () <-
    newMVar ()

  doneVarRef :: IORef (TMVar ()) <-
    newIORef =<< newEmptyTMVarIO

  Connection.withConnection endpoint $ \connection -> do
    statusVar :: TVar Status <-
      newTVarIO (Alive connection)

    callback Bus
      { statusVar = statusVar
      , sendLock = sendLock
      , doneVarRef = doneVarRef
      }

withConnection ::
     Bus
  -> (Connection -> IO (Either BusError a))
  -> IO (Either BusError a)
withConnection bus callback =
  readTVarIO (statusVar bus) >>= \case
    Alive connection ->
      callback connection

    Dead err ->
      pure (Left err)

-- | Send a request and receive the response (a single message).
--
-- TODO: Handle sooo many race conditions wrt. async exceptions (important use
-- case: killing a thread after a timeout)
exchange ::
     Bus -- ^
  -> Request -- ^
  -> IO (Either BusError Response)
exchange bus@(Bus { statusVar, sendLock, doneVarRef }) request =
  withConnection bus $ \connection -> do
    -- Try sending, which either results in an error, or two empty TMVars: one
    -- that will fill when it's our turn to receive, and one that we must fill
    -- when we are done receiving.
    sendResult :: Either BusError (TMVar (), TMVar ()) <-
      withMVar sendLock $ \() ->
        Connection.send connection (encodeRequest request) >>= \case
          Left err ->
            pure (Left (BusConnectionError err))

          Right () -> do
            doneVar <- newEmptyTMVarIO
            prevDoneVar <- readIORef doneVarRef
            writeIORef doneVarRef doneVar
            pure (Right (prevDoneVar, doneVar))

    case sendResult of
      Left err ->
        pure (Left err)

      Right (prevDoneVar, doneVar) -> do
        -- It's a race: either something goes wrong somewhere (at which point
        -- the connection status var will be filled with a bus error), or
        -- everything goes well and it becomes our turn to receive.
        waitResult :: Maybe BusError <-
          atomically $ do
            (Nothing <$ readTMVar prevDoneVar)
            <|>
            (readTVar statusVar >>= \case
              Alive _ -> retry
              Dead err -> pure (Just err))

        case waitResult of
          Nothing ->
            Connection.receive connection >>= \case
              Left err ->
                pure (Left (BusConnectionError err))

              Right bytes ->
                case decodeResponse bytes of
                  Left err ->
                    pure (Left (BusDecodeError err))

                  Right response -> do
                    atomically (putTMVar doneVar ())
                    pure (Right response)

          Just err ->
            pure (Left err)

-- | Send a request and stream the response (one or more messages).
--
-- /Throws/: If response decoding fails, throws 'DecodeError'.
stream ::
     ∀ r x.
     Bus -- ^
  -> Request -- ^
  -> x
  -> (x -> Response -> IO (Either x r))
  -> IO (Either BusError r)
stream bus@(Bus { sendLock }) request value0 step =
  withConnection bus $ \connection ->
    -- Riak request handling state machine is odd. Streaming responses are
    -- special; when one is active, no other requests can be serviced on this
    -- socket.
    --
    -- So, hold a lock for the entirety of the request-response exchange, not
    -- just during sending the request.
    withMVar sendLock $ \() ->
      Connection.send connection (encodeRequest request) >>= \case
        Left err ->
          pure (Left (BusConnectionError err))

        Right () ->
          let
            consume :: x -> IO (Either BusError r)
            consume value =
              Connection.receive connection >>= \case
                Left err ->
                  pure (Left (BusConnectionError err))

                Right bytes ->
                  case decodeResponse bytes of
                    Left err ->
                      pure (Left (BusDecodeError err))

                    Right response ->
                      step value response >>= \case
                        Left newValue ->
                          consume newValue
                        Right result ->
                          pure (Right result)
          in
            consume value0
