{-# LANGUAGE DerivingStrategies, GeneralizedNewtypeDeriving #-}

module Riak.Internal.Message
  ( Message(..)
  , MessageCode(..)
  ) where

import Data.ByteString (ByteString)
import Data.Word

-- | A 'Message' is a single message sent by both the server and client. On the
-- wire, it consists of a 4-byte big-endian length, 1-byte message code, and
-- encoded protobuf payload.
data Message
  = Message
      !Word8      -- Message code
      !ByteString -- Message payload

newtype MessageCode a
  = MessageCode { unMessageCode :: Word8 }
  deriving newtype Num
