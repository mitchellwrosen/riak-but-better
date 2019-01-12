{-# LANGUAGE UndecidableInstances #-}

module Riak.Internal.Crdts
  ( RiakCrdtError(..)
  , IsRiakCrdt(..)
  , IsRiakMap(..)
  , RiakMapEntries(..)
  , RiakMapFieldParser
  , riakCounterField
  , riakFlagField
  , riakMapField
  , riakRegisterField
  , riakSetField
  , RiakMapParseError(..)
  -- , allowExtraKeys
  , IsRiakRegister(..)
  , IsRiakSet
  , RiakSetOp(..)
  , riakSetAddOp
  , riakSetRemoveOp
  ) where

import Riak.Internal.Prelude
import Riak.Internal.Types
import Riak.Proto

import Data.Bifunctor     (first)
import Data.DList         (DList)
import Data.Text.Encoding (decodeUtf8', encodeUtf8)

import qualified Data.HashMap.Strict as HashMap
import qualified Data.Set            as Set
import qualified Lens.Labels         as L


-- TODO CRDTs: Set -> HashSet

-- Internal type class. Not exported.
class IsRiakCrdt (ty :: RiakTy) where
  type CrdtVal ty :: *

  parseDtFetchResp
    :: Proxy# ty
    -> RiakKey
    -> DtFetchResp
    -> Either SomeException (Maybe (CrdtVal ty))

  parseDtUpdateResp
    :: Proxy# ty
    -> RiakKey
    -> DtUpdateResp
    -> Either SomeException (CrdtVal ty)


-- | A 'RiakCrdtError' is thrown when a data type operation is performed on
-- an incompatible bucket type (for example, attempting to fetch a counter from
-- a bucket type that contains sets).
data RiakCrdtError
  = RiakCrdtError !RiakKey !Text
  deriving stock (Eq, Show)
  deriving anyclass (Exception)


dataTypeToText :: DtFetchResp'DataType -> Text
dataTypeToText = \case
  DtFetchResp'COUNTER -> "counter"
  DtFetchResp'GSET    -> "gset"
  DtFetchResp'HLL     -> "hll"
  DtFetchResp'MAP     -> "map"
  DtFetchResp'SET     -> "set"


--------------------------------------------------------------------------------
-- Counter
--------------------------------------------------------------------------------

instance IsRiakCrdt 'RiakCounterTy where
  type CrdtVal 'RiakCounterTy = Int64

  parseDtFetchResp
    :: Proxy# 'RiakCounterTy
    -> RiakKey
    -> DtFetchResp
    -> Either SomeException (Maybe Int64)
  parseDtFetchResp _ key resp =
    case resp L.^. #type' of
      DtFetchResp'COUNTER ->
        Right (L.view #counterValue <$> resp L.^. #maybe'value)

      x ->
        (Left . toException . RiakCrdtError key)
          ("expected counter but found " <> dataTypeToText x)

  -- TODO split into update, update-and-get

  parseDtUpdateResp
    :: Proxy# 'RiakCounterTy
    -> RiakKey
    -> DtUpdateResp
    -> Either SomeException Int64
  parseDtUpdateResp _ _ resp =
    Right (resp L.^. #counterValue)


--------------------------------------------------------------------------------
-- Grow-only set
--------------------------------------------------------------------------------

instance IsRiakCrdt 'RiakGrowOnlySetTy where
  type CrdtVal 'RiakGrowOnlySetTy = Set ByteString

  parseDtFetchResp
    :: Proxy# 'RiakGrowOnlySetTy
    -> RiakKey
    -> DtFetchResp
    -> Either SomeException (Maybe (Set ByteString))
  parseDtFetchResp _ key resp =
    case resp L.^. #type' of
      DtFetchResp'GSET ->
        Right (Set.fromList . L.view #gsetValue <$> resp L.^. #maybe'value)

      x ->
        (Left . toException . RiakCrdtError key)
          ("expected gset but found " <> dataTypeToText x)

  parseDtUpdateResp
    :: Proxy# 'RiakGrowOnlySetTy
    -> RiakKey
    -> DtUpdateResp
    -> Either SomeException (Set ByteString)
  parseDtUpdateResp _ _ resp =
    Right (Set.fromList (resp L.^. #gsetValue))


--------------------------------------------------------------------------------
-- HyperLogLog
--------------------------------------------------------------------------------

instance IsRiakCrdt 'RiakHyperLogLogTy where
  type CrdtVal 'RiakHyperLogLogTy = Word64

  parseDtFetchResp
    :: Proxy# 'RiakHyperLogLogTy
    -> RiakKey
    -> DtFetchResp
    -> Either SomeException (Maybe Word64)
  parseDtFetchResp _ key resp =
    case resp L.^. #type' of
      DtFetchResp'HLL ->
        Right (L.view #hllValue <$> resp L.^. #maybe'value)

      x ->
        (Left . toException . RiakCrdtError key)
          ("expected hll but found " <> dataTypeToText x)

  parseDtUpdateResp
    :: Proxy# 'RiakHyperLogLogTy
    -> RiakKey
    -> DtUpdateResp
    -> Either SomeException Word64
  parseDtUpdateResp _ _ resp =
    Right (resp L.^. #hllValue)


--------------------------------------------------------------------------------
-- Map
--------------------------------------------------------------------------------

instance IsRiakMap a => IsRiakCrdt ('RiakMapTy a) where
  type CrdtVal ('RiakMapTy a) = a

  parseDtFetchResp
    :: Proxy# ('RiakMapTy a)
    -> RiakKey
    -> DtFetchResp
    -> Either SomeException (Maybe a)
  parseDtFetchResp _ key resp =
    case resp L.^. #type' of
      DtFetchResp'MAP ->
        case resp L.^. #maybe'value of
          Nothing ->
            Right Nothing

          Just value ->
            bimap toException Just
              (runFieldParser
                decodeRiakMap
                (parseMapEntries (value L.^. #mapValue)))

      x ->
        (Left . toException . RiakCrdtError key)
          ("expected map but found " <> dataTypeToText x)

  parseDtUpdateResp
    :: Proxy# ('RiakMapTy a)
    -> RiakKey
    -> DtUpdateResp
    -> Either SomeException a
  parseDtUpdateResp _ _ resp =
    first toException
      (runFieldParser
        decodeRiakMap
        (parseMapEntries (resp L.^. #mapValue)))

parseMapEntries :: [MapEntry] -> RiakMapEntries
parseMapEntries =
  foldMap $ \entry ->
    let
      k =
        entry L.^. #field . #name
    in
      case entry L.^. #field . #type' of
        MapField'COUNTER ->
          RiakMapEntries
            (HashMap.singleton k (entry L.^. #counterValue))
            mempty
            mempty
            mempty
            mempty

        MapField'FLAG ->
          RiakMapEntries
            mempty
            (HashMap.singleton k (entry L.^. #flagValue))
            mempty
            mempty
            mempty

        MapField'MAP ->
          RiakMapEntries
            mempty
            mempty
            (HashMap.singleton k (parseMapEntries (entry L.^. #mapValue)))
            mempty
            mempty

        MapField'REGISTER ->
          RiakMapEntries
            mempty
            mempty
            mempty
            (HashMap.singleton k (entry L.^. #registerValue))
            mempty

        MapField'SET ->
          RiakMapEntries
            mempty
            mempty
            mempty
            mempty
            (HashMap.singleton k (Set.fromList (entry L.^. #setValue)))


data RiakMapEntries
  = RiakMapEntries
      !(HashMap ByteString Int64)            -- Counters
      !(HashMap ByteString Bool)             -- Flags
      !(HashMap ByteString RiakMapEntries)   -- Maps
      !(HashMap ByteString ByteString)       -- Registers
      !(HashMap ByteString (Set ByteString)) -- Sets
  deriving (Show)

instance Monoid RiakMapEntries where
  mempty = RiakMapEntries mempty mempty mempty mempty mempty
  mappend = (<>)

instance Semigroup RiakMapEntries where
  RiakMapEntries a1 b1 c1 d1 e1 <> RiakMapEntries a2 b2 c2 d2 e2 =
    RiakMapEntries (a1 <> a2) (b1 <> b2) (c1 <> c2) (d1 <> d2) (e1 <> e2)


-- | An error occurred when decoding a Riak map.
data RiakMapParseError
  -- = TypeMismatch Text Text
  -- | UnexpectedKeys [ByteString]
  = ParseFailure SomeException
  deriving stock (Show)
  deriving anyclass (Exception)

data RiakMapFieldParser a
  = RiakMapFieldParser
      (RiakMapEntries -> Either RiakMapParseError a)
      -- (Maybe (HashMap ByteString ())) -- TODO unexpected keys
  deriving (Functor)

runFieldParser
  :: RiakMapFieldParser a
  -> RiakMapEntries
  -> Either RiakMapParseError a
runFieldParser (RiakMapFieldParser f) m =
  f m

-- allowExtraKeys :: RiakMapFieldParser a -> RiakMapFieldParser a
-- allowExtraKeys (RiakMapFieldParser f _) =
--   RiakMapFieldParser f Nothing

riakCounterField :: ByteString -> RiakMapFieldParser Int64
riakCounterField key =
  RiakMapFieldParser f -- (Just (HashMap.singleton key ()))
 where
  f :: RiakMapEntries -> Either RiakMapParseError Int64
  f (RiakMapEntries counters _ _ _ _) =
    maybe (Right 0) Right (HashMap.lookup key counters)

riakFlagField :: ByteString -> RiakMapFieldParser Bool
riakFlagField key =
  RiakMapFieldParser f -- (Just (HashMap.singleton key ()))
 where
  f :: RiakMapEntries -> Either RiakMapParseError Bool
  f (RiakMapEntries _ flags _ _ _) =
    maybe (Right False) Right (HashMap.lookup key flags)

riakMapField :: forall a. IsRiakMap a => ByteString -> RiakMapFieldParser a
riakMapField key =
  RiakMapFieldParser f -- (Just (HashMap.singleton key ()))
 where
  f :: RiakMapEntries -> Either RiakMapParseError a
  f (RiakMapEntries _ _ maps _ _) =
    HashMap.lookup key maps
      & fromMaybe mempty
      & runFieldParser decodeRiakMap

riakRegisterField :: forall a. IsRiakRegister a => ByteString -> RiakMapFieldParser a
riakRegisterField key =
  RiakMapFieldParser f -- (Just (HashMap.singleton key ()))
 where
  f :: RiakMapEntries -> Either RiakMapParseError a
  f (RiakMapEntries _ _ _ registers _) =
    HashMap.lookup key registers
      & fromMaybe mempty
      & decodeRiakRegister
      & first ParseFailure

riakSetField
  :: forall a.
     IsRiakSet a
  => ByteString
  -> RiakMapFieldParser (Set a)
riakSetField key =
  RiakMapFieldParser f -- (Just (HashMap.singleton key ()))
 where
  f :: RiakMapEntries -> Either RiakMapParseError (Set a)
  f (RiakMapEntries _ _ _ _ sets) =
    maybe
      (pure mempty)
      -- TODO make it so I don't have to pay for to/from/to set
      -- TODO batch errors, don't only report one
      (bimap ParseFailure Set.fromList . traverse decodeRiakRegister . toList)
      (HashMap.lookup key sets)

-- | 'IsRiakMap' classifies types that are stored in Riak map data types. A Riak
-- map contains any number of key-value pairs, where the keys are byte arrays,
-- and the values are either counters, flags, registers, sets, or maps.
--
-- This data structure can be parsed in three ways:
--
-- [Untyped]
-- An @untyped@ map is simply the primitive key-value pairs stored in Riak. It
-- is provided by the instance @IsRiakMap RiakMapEntries@.
--
-- [Homogenous]
-- TODO
--
-- [Heterogeneous]
-- A @heterogeneous@ map is an arbitrary data structure encoded as a Riak map.
-- Its decoder is provided by a user-supplied 'decodeRiakMap', which is built
-- from individual field parsers such as 'riakCounterField'.
--
-- By default, when parsing a heterogeneous map, any unexpected keys will be
-- treated as an error. For more lenient parsing, use 'allowExtraKeys'.
class IsRiakMap a where
  decodeRiakMap :: RiakMapFieldParser a

instance IsRiakMap RiakMapEntries where
  decodeRiakMap :: RiakMapFieldParser RiakMapEntries
  decodeRiakMap =
    RiakMapFieldParser Right -- Nothing

--------------------------------------------------------------------------------
-- Register
--------------------------------------------------------------------------------

-- | 'IsRiakRegister' classifies types that are stored in Riak register data
-- types, which are simple arrays of bytes with a timestamp-based,
-- last-write-wins conflict resolution strategy.
class IsRiakRegister a where
  decodeRiakRegister :: ByteString -> Either SomeException a

  encodeRiakRegister :: a -> ByteString

instance IsRiakRegister ByteString where
  decodeRiakRegister :: ByteString -> Either SomeException ByteString
  decodeRiakRegister =
    Right

  encodeRiakRegister :: ByteString -> ByteString
  encodeRiakRegister =
    id

instance IsRiakRegister Text where
  decodeRiakRegister :: ByteString -> Either SomeException Text
  decodeRiakRegister =
    first toException . decodeUtf8'

  encodeRiakRegister :: Text -> ByteString
  encodeRiakRegister =
    encodeUtf8


--------------------------------------------------------------------------------
-- Set
--------------------------------------------------------------------------------

-- | 'IsRiakSet' classifies types that are stored in Riak set data types. Riak
-- sets only contain arrays of bytes, like Riak registers, so this type class is
-- satisfied for all types that are instances of both 'IsRiakRegister' and
-- 'Ord'.
type IsRiakSet a =
  (IsRiakRegister a, Ord a)

instance IsRiakSet a => IsRiakCrdt ('RiakSetTy a) where
  type CrdtVal ('RiakSetTy a) = Set a

  parseDtFetchResp
    :: Proxy# ('RiakSetTy a)
    -> RiakKey
    -> DtFetchResp
    -> Either SomeException (Maybe (Set a))
  parseDtFetchResp _ key resp =
    case resp L.^. #type' of
      DtFetchResp'SET ->
        case resp L.^. #maybe'value of
          Nothing ->
            Right Nothing

          Just value ->
            Just . Set.fromList <$>
              for (value L.^. #setValue) decodeRiakRegister

      x ->
        (Left . toException . RiakCrdtError key)
          ("expected set but found " <> dataTypeToText x)

  parseDtUpdateResp
    :: Proxy# ('RiakSetTy a)
    -> RiakKey
    -> DtUpdateResp
    -> Either SomeException (Set a)
  parseDtUpdateResp _ _ resp =
    Set.fromList <$> for (resp L.^. #setValue) decodeRiakRegister


newtype RiakSetOp a
  = RiakSetOp (DList a, DList a)
  deriving newtype (Monoid, Semigroup)

riakSetAddOp :: a -> RiakSetOp a
riakSetAddOp x =
  RiakSetOp (pure x, mempty)

riakSetRemoveOp :: a -> RiakSetOp a
riakSetRemoveOp x =
  RiakSetOp (mempty, pure x)