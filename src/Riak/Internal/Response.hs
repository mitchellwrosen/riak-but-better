{-# LANGUAGE DefaultSignatures, OverloadedStrings, ScopedTypeVariables, TypeApplications #-}

module Riak.Internal.Response
  ( Response
  , parseResponse

  , RpbPingResp(..)
  , RpbSetBucketResp(..)
  , RpbResetBucketResp(..)
  ) where

import Data.ByteString (ByteString)
import Data.Word

import qualified Data.ProtoLens as Proto

import Proto.Riak
import Riak.Internal.Message
import Riak.Internal.Panic

class Response a where
  responseCode :: MessageCode a

  responseDecode :: ByteString -> Either String a
  default responseDecode :: Proto.Message a => ByteString -> Either String a
  responseDecode = Proto.decodeMessage

instance Response RpbErrorResp         where responseCode = 0
instance Response RpbGetServerInfoResp where responseCode = 8
instance Response RpbListBucketsResp   where responseCode = 16
instance Response RpbListKeysResp      where responseCode = 18
instance Response RpbGetBucketResp     where responseCode = 20

data RpbPingResp
  = RpbPingResp

instance Response RpbPingResp where
  responseCode = 2
  responseDecode _ = pure RpbPingResp

data RpbSetBucketResp
  = RpbSetBucketResp

instance Response RpbSetBucketResp where
  responseCode = 22
  responseDecode _ = pure RpbSetBucketResp

data RpbResetBucketResp
  = RpbResetBucketResp

instance Response RpbResetBucketResp where
  responseCode = 30
  responseDecode _ = pure RpbResetBucketResp

parseResponse :: forall a. Response a => Message -> IO (Either RpbErrorResp a)
parseResponse (Message actual bytes)
  | actual == expected =
      Right <$> decodeResponse actual bytes

  | actual == 0 =
      Left <$> decodeResponse actual bytes

  | otherwise =
      panic "Unexpected message code"
        ( ("actual", actual)
        , ("expected", expected)
        )
 where
  expected :: Word8
  expected =
    unMessageCode (responseCode @a)

decodeResponse :: Response a => Word8 -> ByteString -> IO a
decodeResponse code bytes =
  case responseDecode bytes of
    Left err ->
      panic "Protobuf decoding failure"
        ( ("code", code)
        , ("error", err)
        )

    Right x ->
      pure x
