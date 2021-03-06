module RiakSet
  ( ConvergentSet(..)
  , newSet
  , setKey
  , setValue
  , getSet
  , getSetWith
  , putSet
  , putSetWith
  , toProto
  ) where

import RiakContext (Context(..), emptyContext)
import RiakCrdt    (parseGetCrdtError)
import RiakError
import RiakGetOpts (GetOpts)
import RiakHandle  (Handle)
import RiakKey     (Key(..), isGeneratedKey, keyBucket)
import RiakPutOpts (PutOpts)

import qualified RiakGetOpts as GetOpts
import qualified RiakHandle  as Handle
import qualified RiakKey     as Key
import qualified RiakPutOpts as PutOpts

import Control.Lens          (Lens', (.~), (^.))
import Data.Default.Class    (def)
import Data.Generics.Product (field)
import Data.Text.Encoding    (decodeUtf8)

import qualified Data.ByteString as ByteString
import qualified Data.HashSet    as HashSet
import qualified Data.Riak.Proto as Proto


-- | An eventually-convergent set.
--
-- Sets must be stored in a bucket type with the @datatype = set@ property.
data ConvergentSet a
  = ConvergentSet
  { _context :: Context
  , _key :: Key
  , _newValue :: HashSet a
  , _oldValue :: HashSet a
  } deriving stock (Eq, Generic, Show)

-- | Create a new eventually-convergent set.
newSet ::
     Key -- ^
  -> HashSet a -- ^
  -> ConvergentSet a
newSet key contents =
  ConvergentSet
    { _context = emptyContext
    , _key = key
    , _newValue = contents
    , _oldValue = HashSet.empty
    }

-- | The key of an eventually-convergent set.
setKey :: ConvergentSet a -> Key
setKey =
  _key

-- | A lens onto the value of an eventually-convergent set.
setValue :: Lens' (ConvergentSet a) (HashSet a)
setValue =
  field @"_newValue"

-- | Get an eventually-convergent set.
getSet ::
     MonadIO m
  => Handle -- ^
  -> Key -- ^
  -> m (Either GetSetError (Maybe (ConvergentSet ByteString)))
getSet handle key =
  getSetWith handle key def

-- | 'getSet' with options.
getSetWith ::
     MonadIO m
  => Handle -- ^
  -> Key -- ^
  -> GetOpts -- ^
  -> m (Either GetSetError (Maybe (ConvergentSet ByteString)))
getSetWith handle key@(Key bucketType _ _) opts = liftIO $
  fromResult <$> Handle.getCrdt handle request

  where
    request :: Proto.DtFetchReq
    request =
      Proto.defMessage
        & GetOpts.setProto opts
        & Key.setProto key

    fromResult = \case
      Left err ->
        Left (HandleError err)

      Right (Left err) ->
        Left (parseGetCrdtError bucketType err)

      Right (Right response) ->
        Right (fromResponse response)

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
  -> m (Either PutSetError (ConvergentSet ByteString))
putSet handle value =
  putSetWith handle value def

-- | 'putSet' with options.
putSetWith ::
     MonadIO m
  => Handle -- ^
  -> ConvergentSet ByteString -- ^
  -> PutOpts -- ^
  -> m (Either PutSetError (ConvergentSet ByteString))
putSetWith
    handle
    (ConvergentSet context key@(Key bucketType _ _) newValue oldValue)
    opts = liftIO $

  fromResult <$> Handle.updateCrdt handle request

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

    fromResult = \case
      Left err ->
        Left (HandleError err)

      Right (Left err) ->
        Left (parseError err)

      Right (Right response) ->
        Right (fromResponse response)

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

    parseError ::
         ByteString
      -> Error 'UpdateCrdtOp
    parseError err
      | isBucketMustBeAllowMultError err =
          InvalidBucketError (key ^. keyBucket)
      | isBucketTypeDoesNotExistError1 err =
          BucketTypeDoesNotExistError bucketType
      | isInvalidNodesError0 err =
          InvalidNodesError
      | isNonCounterOperationOnDefaultBucketError err =
          InvalidBucketTypeError bucketType
      | isOperationTypeIsSetButBucketTypeIsError err =
          InvalidBucketTypeError bucketType
      | otherwise =
          UnknownError (decodeUtf8 err)

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
