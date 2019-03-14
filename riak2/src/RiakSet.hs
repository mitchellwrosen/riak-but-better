module RiakSet
  ( ConvergentSet(..)
  , newSet
  , setKey
  , setValue
  , getSet
  , putSet
  , toProto
  ) where

import RiakContext (Context(..), newContext)
import RiakCrdt    (parseGetCrdtError, parseUpdateCrdtError)
import RiakError
import RiakGetOpts (GetOpts)
import RiakHandle  (Handle)
import RiakKey     (Key(..), isGeneratedKey)
import RiakPutOpts (PutOpts)
import RiakUtils   (retrying)

import qualified RiakGetOpts as GetOpts
import qualified RiakHandle  as Handle
import qualified RiakKey     as Key
import qualified RiakPutOpts as PutOpts

import Control.Lens          (Lens', (.~), (^.))
import Data.Generics.Product (field)

import qualified Data.ByteString as ByteString
import qualified Data.HashSet    as HashSet
import qualified Data.Riak.Proto as Proto


-- | An eventually-convergent set.
--
-- Sets must be stored in a bucket type with the__@datatype = set@__ property.
data ConvergentSet a
  = ConvergentSet
  { _context :: Context
  , _key :: Key
  , _newValue :: HashSet a
  , _oldValue :: HashSet a
  } deriving stock (Generic, Show)

-- | Create a new eventually-convergent set.
newSet ::
     Key -- ^
  -> HashSet a -- ^
  -> ConvergentSet a
newSet key contents =
  ConvergentSet
    { _context = newContext
    , _key = key
    , _newValue = contents
    , _oldValue = HashSet.empty
    }

-- | A lens onto the key of an eventually-convergent set.
setKey :: Lens' (ConvergentSet a) Key
setKey =
  field @"_key"

-- | A lens onto the value of an eventually-convergent set.
setValue :: Lens' (ConvergentSet a) (HashSet a)
setValue =
  field @"_newValue"

-- | Get an eventually-convergent set.
getSet ::
     MonadIO m
  => Handle -- ^
  -> Key -- ^
  -> GetOpts -- ^
  -> m (Either GetSetError (Maybe (ConvergentSet ByteString)))
getSet handle key opts =
  liftIO (retrying 1000000 (getSet_ handle key opts))

getSet_ ::
     Handle
  -> Key
  -> GetOpts
  -> IO (Maybe (Either GetSetError (Maybe (ConvergentSet ByteString))))
getSet_ handle key@(Key bucketType _ _) opts =
  Handle.getCrdt handle request >>= \case
    Left err ->
      pure (Just (Left (HandleError err)))

    Right (Left err) ->
      pure (Left <$> parseGetCrdtError bucketType err)

    Right (Right response) ->
      pure (Just (Right (fromResponse response)))

  where
    request :: Proto.DtFetchReq
    request =
      Proto.defMessage
        & GetOpts.setProto opts
        & Key.setProto key

    fromResponse ::
         Proto.DtFetchResp
      -> Maybe (ConvergentSet ByteString)
    fromResponse response = do
      crdt :: Proto.DtValue <-
        response ^. Proto.maybe'value

      let
        value :: HashSet ByteString
        value =
          HashSet.fromList (crdt ^. Proto.setValue)

      pure ConvergentSet
        { _context = Context (response ^. Proto.context)
        , _key = key
        , _newValue = value
        , _oldValue = value
        }

-- | Put an eventually-convergent set.
putSet ::
     MonadIO m
  => Handle -- ^
  -> ConvergentSet ByteString -- ^
  -> PutOpts
  -> m (Either PutSetError (ConvergentSet ByteString))
putSet handle set opts =
  liftIO (retrying 1000000 (putSet_ handle set opts))

putSet_ ::
     Handle
  -> ConvergentSet ByteString
  -> PutOpts
  -> IO (Maybe (Either PutSetError (ConvergentSet ByteString)))
putSet_
    handle
    (ConvergentSet context key@(Key bucketType _ _) newValue oldValue)
    opts =

  Handle.updateCrdt handle request >>= \case
    Left err ->
      pure (Just (Left (HandleError err)))

    Right (Left err) ->
      pure (Left <$> parseUpdateCrdtError bucketType err)

    Right (Right response) ->
      pure (Just (Right (fromResponse response)))

  where
    request :: Proto.DtUpdateReq
    request =
      Proto.defMessage
        & Key.setMaybeProto key
        & Proto.maybe'context .~
            (if ByteString.null (unContext context)
              then Nothing
              else Just (unContext context))
        & Proto.op .~
            (Proto.defMessage
              & Proto.setOp .~ toProto newValue oldValue)
        & Proto.returnBody .~ True
        & PutOpts.setProto opts

    fromResponse ::
         Proto.DtUpdateResp
      -> ConvergentSet ByteString
    fromResponse response =
      ConvergentSet
        { _context = Context (response ^. Proto.context)
        , _key =
            if isGeneratedKey key
              then
                case key of
                  Key bucketType bucket _ ->
                    Key bucketType bucket (response ^. Proto.key)
              else
                key
        , _newValue = value
        , _oldValue = value
        }

      where
        value :: HashSet ByteString
        value =
          HashSet.fromList (response ^. Proto.setValue)

toProto ::
     HashSet ByteString -- ^ New value
  -> HashSet ByteString -- ^ Old value
  -> Proto.SetOp -- ^ Delta
toProto newValue oldValue =
  Proto.defMessage
    & Proto.adds .~ adds
    & Proto.removes .~ removes

  where
    adds :: [ByteString]
    adds =
      HashSet.toList (HashSet.difference newValue oldValue)

    removes :: [ByteString]
    removes =
      HashSet.toList (HashSet.difference oldValue newValue)
