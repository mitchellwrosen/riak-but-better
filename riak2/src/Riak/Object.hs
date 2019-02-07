module Riak.Object
  ( -- * Object operations
    -- ** Get object
    get
  , getHead
  , getIfModified
  , getHeadIfModified
    -- ** Put object
  , put
  , putGet
  , putGetHead
    -- ** Delete object
  , delete
    -- * Object type
  , Object(..)
  ) where

import Riak.Client           (Client)
import Riak.Content          (Content(..))
import Riak.Internal.Context (Context(..))
import Riak.Internal.Error
import Riak.Internal.Object  (Object(..))
import Riak.Internal.Prelude
import Riak.Key              (Key(..))
import Riak.Opts             (GetOpts(..), PutOpts(..))

import qualified Riak.Interface               as Interface
import qualified Riak.Internal.Object         as Object
import qualified Riak.Internal.Proto.Pair     as Proto.Pair
import qualified Riak.Internal.Quorum         as Quorum
import qualified Riak.Internal.SecondaryIndex as SecondaryIndex
import qualified Riak.Proto                   as Proto
import qualified Riak.Proto.Lens              as L

import Control.Lens                ((.~), (^.))
import Data.Generics.Product       (field)
import Data.Generics.Product.Typed (HasType(..))
import Data.Text.Encoding          (decodeUtf8)

import qualified ByteString

-- TODO specialize HasType for Object,Content


-- | Get an object.
--
-- If multiple siblings are returned, you should resolve them, then perform a
-- 'put'.
--
-- /Note/: The object(s) returned may be tombstones; check
-- 'Riak.Metadata.deleted'.
get
  :: MonadIO m
  => Client -- ^
  -> Key -- ^
  -> GetOpts -- ^
  -> m (Either (Error 'GetOp) [Object ByteString])
get client key opts = liftIO $
  (fmap.fmap)
    (Object.fromGetResponse key)
    (doGet client request)

  where
    request :: Proto.GetRequest
    request =
      makeGetRequest key opts

-- | Get an object's metadata.
--
-- If multiple siblings are returned, you should resolve them, then perform a
-- 'put'.
--
-- /Note/: The object(s) returned may be tombstones; check
-- 'Riak.Metadata.deleted'.
getHead
  :: MonadIO m
  => Client -- ^
  -> Key -- ^
  -> GetOpts -- ^
  -> m (Either (Error 'GetOp) [Object ()])
getHead client key opts = liftIO $
  (fmap.fmap)
    (map (() <$) . Object.fromGetResponse key)
    (doGet client request)
  where
    request :: Proto.GetRequest
    request =
      makeGetRequest key opts
        & L.head .~ True

-- | Get an object if it has been modified since the given version.
--
-- If multiple siblings are returned, you should resolve them, then perform a
-- 'put'.
--
-- /Note/: The object(s) returned may be tombstones; check
-- 'Riak.Object.deleted'.
getIfModified ::
     -- ( (forall x. HasType (Content x) (content x))
     ( MonadIO m
     )
  => Client -- ^
  -> Content a -- ^
  -> GetOpts -- ^
  -> m (Either (Error 'GetOp) (Maybe [Object ByteString]))
getIfModified client content opts =
  liftIO (getIfModified_ client content opts)

getIfModified_ ::
     Client
  -> Content a
  -> GetOpts
  -> IO (Either (Error 'GetOp) (Maybe [Object ByteString]))
getIfModified_ client (Content { key, context }) opts =
  (fmap.fmap)
    (\response ->
      if response ^. L.unchanged
        then Nothing
        else Just (Object.fromGetResponse key response))
    (doGet client request)

  where
    request :: Proto.GetRequest
    request =
      makeGetRequest key opts
        & L.ifModified .~ unContext context

-- | Get an object's metadata if it has been modified since the given version.
--
-- If multiple siblings are returned, you should resolve them, then perform a
-- 'put'.
--
-- /Note/: The object(s) returned may be tombstones; check
-- 'Riak.Metadata.deleted'.
getHeadIfModified
  :: MonadIO m
  => Client -- ^
  -> Content a -- ^
  -> GetOpts -- ^
  -> m (Either (Error 'GetOp) (Maybe [Object ()]))
getHeadIfModified client (Content { key, context }) opts = liftIO $
  (fmap.fmap)
    fromResponse
    (doGet client request)
  where
    request :: Proto.GetRequest
    request =
      makeGetRequest key opts
        & L.head .~ True
        & L.ifModified .~ unContext context

    fromResponse :: Proto.GetResponse -> Maybe [Object ()]
    fromResponse response =
      if response ^. L.unchanged
        then Nothing
        else Just ((() <$) <$> Object.fromGetResponse key response)

doGet ::
     Client
  -> Proto.GetRequest
  -> IO (Either (Error 'GetOp) Proto.GetResponse)
doGet client request =
  first parseGetError <$>
    Interface.get client request
  where
    parseGetError :: ByteString -> Error 'GetOp
    parseGetError err
      | isBucketTypeDoesNotExistError err =
          BucketTypeDoesNotExistError (request ^. L.bucketType)
      | isInvalidNError err =
          InvalidNError (request ^. L.n)
      | otherwise =
          UnknownError (decodeUtf8 err)

makeGetRequest :: Key -> GetOpts -> Proto.GetRequest
makeGetRequest (Key bucketType bucket key) opts =
  Proto.defMessage
    & L.bucket .~ bucket
    & L.bucketType .~ bucketType
    & L.deletedContext .~ True
    & L.key .~ key
    & L.maybe'basicQuorum .~ defFalse (basicQuorum opts)
    & L.maybe'n .~ (Quorum.toWord32 <$> (opts ^. field @"n"))
    & L.maybe'notfoundOk .~ notfoundOk opts
    & L.maybe'pr .~ (Quorum.toWord32 <$> pr opts)
    & L.maybe'r .~ (Quorum.toWord32 <$> r opts)
    & L.maybe'timeout .~ (opts ^. field @"timeout")


-- | Put an object and return its key.
--
-- /See also/: Riak.Context.'Riak.Context.newContext', Riak.Key.'Riak.Key.generatedKey'
put ::
     ( HasType (Content ByteString) content
     , MonadIO m
     )
  => Client -- ^
  -> content -- ^
  -> PutOpts -- ^
  -> m (Either (Error 'PutOp) Key)
put client content opts =
  liftIO (put_ client (content ^. typed) opts)

put_ ::
     Client
  -> Content ByteString
  -> PutOpts
  -> IO (Either (Error 'PutOp) Key)
put_ client content opts =
  (fmap.fmap)
    fromResponse
    (doPut client request)
  where
    request :: Proto.PutRequest
    request =
      makePutRequest key content opts

    key@(Key bucketType bucket k) =
      content ^. field @"key"

    fromResponse :: Proto.PutResponse -> Key
    fromResponse response =
      if ByteString.null k
        then Key bucketType bucket (response ^. L.key)
        else key

-- | Put an object and return it.
--
-- If multiple siblings are returned, you should resolve them, then perform a
-- 'put'.
--
-- /Note/: The object(s) returned may be tombstones; check
-- 'Riak.Metadata.deleted'.
--
-- /See also/: Riak.Context.'Riak.Context.newContext', Riak.Key.'Riak.Key.generatedKey'
putGet ::
     ( HasType (Content ByteString) content
     , MonadIO m
     )
  => Client -- ^
  -> content -- ^
  -> PutOpts -- ^
  -> m (Either (Error 'PutOp) (NonEmpty (Object ByteString)))
putGet client content opts =
  liftIO (putGet_ client (content ^. typed) opts)

putGet_ ::
     Client -- ^
  -> Content ByteString -- ^
  -> PutOpts -- ^
  -> IO (Either (Error 'PutOp) (NonEmpty (Object ByteString)))
putGet_ client content opts =
  (fmap.fmap)
    (Object.fromPutResponse key)
    (doPut client request)

  where
    request :: Proto.PutRequest
    request =
      makePutRequest key content opts
        & L.returnBody .~ True

    key :: Key
    key =
      content ^. field @"key"

-- | Put an object and return its metadata.
--
-- If multiple siblings are returned, you should perform a 'get', resolve them,
-- then perform a 'put'.
--
-- /Note/: The object(s) returned may be tombstones; check
-- 'Riak.Metadata.deleted'.
--
-- /See also/: Riak.Context.'Riak.Context.newContext', Riak.Key.'Riak.Key.generatedKey'
putGetHead ::
     ( HasType (Content ByteString) content
     , MonadIO m
     )
  => Client -- ^
  -> content -- ^
  -> PutOpts -- ^
  -> m (Either (Error 'PutOp) (NonEmpty (Object ())))
putGetHead client content opts =
  liftIO (putGetHead_ client (content ^. typed) opts)

putGetHead_ ::
     Client
  -> Content ByteString
  -> PutOpts
  -> IO (Either (Error 'PutOp) (NonEmpty (Object ())))
putGetHead_ client content opts =
  (fmap.fmap)
    (fmap (() <$) . Object.fromPutResponse key)
    (doPut client request)

  where
    request :: Proto.PutRequest
    request =
      makePutRequest key content opts
        & L.returnHead .~ True

    key :: Key
    key =
      content ^. field @"key"

doPut ::
     Client
  -> Proto.PutRequest
  -> IO (Either (Error 'PutOp) Proto.PutResponse)
doPut client request =
  first parsePutError <$> Interface.put client request

  where
    parsePutError :: ByteString -> Error 'PutOp
    parsePutError err
      | isBucketTypeDoesNotExistError err =
          BucketTypeDoesNotExistError (request ^. L.bucketType)
      | isInvalidNError err =
          InvalidNError (request ^. L.n)
      | otherwise =
          UnknownError (decodeUtf8 err)

makePutRequest ::
     Key
  -> Content ByteString
  -> PutOpts
  -> Proto.PutRequest
makePutRequest (Key bucketType bucket key) content opts =
  Proto.defMessage
    & L.bucket .~ bucket
    & L.bucketType .~ bucketType
    & L.content .~
        (Proto.defMessage
          & L.indexes .~ map SecondaryIndex.toPair (content ^. field @"indexes")
          & L.maybe'charset .~ (content ^. field @"charset")
          & L.maybe'contentEncoding .~ (content ^. field @"encoding")
          & L.maybe'contentType .~ (content ^. field @"type'")
          & L.usermeta .~ map Proto.Pair.fromTuple (content ^. field @"metadata")
          & L.value .~ (content ^. field @"value")
        )
    & L.maybe'dw .~ (Quorum.toWord32 <$> dw opts)
    & L.maybe'key .~
        (if ByteString.null key
          then Nothing
          else Just key)
    & L.maybe'n .~ (Quorum.toWord32 <$> (opts ^. field @"n"))
    & L.maybe'pw .~ (Quorum.toWord32 <$> pw opts)
    & L.maybe'context .~
        (let
          context :: ByteString
          context =
            unContext (content ^. field @"context")
        in
          if ByteString.null context
            then Nothing
            else Just context)
    & L.maybe'w .~ (Quorum.toWord32 <$> w opts)
    & L.maybe'timeout .~ (opts ^. field @"timeout")

-- | Delete an object.
delete ::
     MonadIO m
  => Client -- ^
  -> Object a -- ^
  -> m (Either (Error 'DeleteOp) ())
delete client Object { content } = liftIO $
  first parseDeleteError <$> Interface.delete client request

  where
    request :: Proto.DeleteRequest
    request =
      Proto.defMessage
        & L.bucket .~ bucket
        & L.bucketType .~ bucketType
        & L.key .~ key
        -- TODO delete opts
        -- & L.maybe'dw .~ undefined
        -- & L.maybe'n .~ undefined
        -- & L.maybe'pr .~ undefined
        -- & L.maybe'pw .~ undefined
        -- & L.maybe'r .~ undefined
        -- & L.maybe'rw .~ undefined
        -- & L.maybe'timeout .~ undefined
        -- & L.maybe'w .~ undefined
        & L.context .~ unContext (content ^. field @"context")

    Key bucketType bucket key =
      content ^. field @"key"

    parseDeleteError :: ByteString -> Error 'DeleteOp
    parseDeleteError err =
      UnknownError (decodeUtf8 err)

defFalse :: Bool -> Maybe Bool
defFalse = \case
  False -> Nothing
  True -> Just True
