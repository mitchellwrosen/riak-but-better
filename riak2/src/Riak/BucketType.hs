module Riak.BucketType
  ( BucketType(..)
  , get
  ) where

import Riak.Interface        (Result)
import Riak.Internal.Client  (Client(..))
import Riak.Internal.Prelude
import Riak.Proto

import qualified Riak.Interface  as Interface
import qualified Riak.Proto.Lens as L


-- | A bucket type.
--
-- /Note/: Must be UTF-8 encoded.
newtype BucketType
  = BucketType
  { type' :: ByteString
  } deriving stock (Eq, Show)
    deriving newtype (Hashable)

-- | Get bucket type properties.
--
-- TODO BucketProps
get ::
     MonadIO m
  => Client
  -> BucketType
  -> m (Result RpbBucketProps)
get client (BucketType type') = liftIO $
  (fmap.fmap)
    fromResponse
    (Interface.getBucketTypeProps (iface client) request)

  where
    request :: RpbGetBucketTypeReq
    request =
      defMessage
        & L.type' .~ type'

    fromResponse :: RpbGetBucketResp -> RpbBucketProps
    fromResponse =
      view L.props
