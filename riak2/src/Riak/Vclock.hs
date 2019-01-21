module Riak.Vclock
  ( Vclock(..)
  ) where

import Riak.Internal.Prelude

import qualified Data.ByteString.Base64 as Base64


newtype Vclock
  = Vclock { unVclock :: ByteString }
  deriving stock (Eq)

instance Show Vclock where
  show :: Vclock -> String
  show =
    show . Base64.encode . unVclock