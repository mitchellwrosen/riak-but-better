module RiakSecondaryIndex where

import Libriak.Proto           (RpbPair)
import RiakPanic
import RiakSecondaryIndexValue (SecondaryIndexValue)
import RiakUtils

import qualified RiakProtoPair           as Pair
import qualified RiakSecondaryIndexValue as SecondaryIndexValue

import qualified Data.ByteString as ByteString


-- TODO Index values should be a set
-- | A secondary index.
data SecondaryIndex
  = forall a.
    SecondaryIndex !ByteString !(SecondaryIndexValue a)

deriving stock instance Show SecondaryIndex

instance Eq SecondaryIndex where
  SecondaryIndex x1 y1 == SecondaryIndex x2 y2 =
    x1 == x2 &&
      case y1 of
        SecondaryIndexValue.Binary v1 ->
          case y2 of
            SecondaryIndexValue.Binary v2 -> v1 == v2
            SecondaryIndexValue.Integer{} -> False
        SecondaryIndexValue.Integer v1 ->
          case y2 of
            SecondaryIndexValue.Integer v2 -> v1 == v2
            SecondaryIndexValue.Binary{} -> False

-- | Binary index smart constructor.
binary ::
     ByteString -- ^ Index name
  -> ByteString -- ^ Value
  -> SecondaryIndex
binary index value =
  SecondaryIndex index (SecondaryIndexValue.Binary value)

-- | Integer index smart constructor.
integer ::
     ByteString -- ^ Index name
  -> Int64 -- ^ Value
  -> SecondaryIndex
integer index value =
  SecondaryIndex index (SecondaryIndexValue.Integer value)

fromPair :: RpbPair -> SecondaryIndex
fromPair =
  Pair.toTuple >>> \case
    (ByteString.stripSuffix "_bin" -> Just k, v) ->
      SecondaryIndex k (SecondaryIndexValue.Binary v)

    (ByteString.stripSuffix "_int" -> Just k, v) ->
      SecondaryIndex k (SecondaryIndexValue.Integer (bs2int v))

    (k, v) ->
      impurePanic "Riak.Internal.SecondaryIndex.fromPair"
        ( ("key",   k)
        , ("value", v)
        )

toPair :: SecondaryIndex -> RpbPair
toPair = \case
  SecondaryIndex k (SecondaryIndexValue.Binary v) ->
    Pair.fromTuple (k <> "_bin", v)

  SecondaryIndex k (SecondaryIndexValue.Integer v) ->
    Pair.fromTuple (k <> "_int", int2bs v)
