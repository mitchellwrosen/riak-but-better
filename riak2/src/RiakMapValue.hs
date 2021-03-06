module RiakMapValue
  ( ConvergentMapValue(..)
  , emptyMapValue
  , fromProto
  , toProto
  ) where

import qualified RiakSet

import Control.Lens          ((%~), (.~), (^.))
import Data.Generics.Product (field)
import Data.List             (foldl')
import Data.Maybe            (mapMaybe)

import qualified Data.HashMap.Strict as HashMap
import qualified Data.HashSet        as HashSet
import qualified Data.Riak.Proto     as Proto


-- | Convergent map value.
--
-- In Riak, map values are keyed by both a name and type.
--
-- The 'Semigroup' instance mimics how Riak merges maps:
--
-- * Counters are added together.
-- * Flags are anded together.
-- * The right-hand register overwrites the left-hand register (mimicking
--   "last write wins").
-- * Sets are unioned.
data ConvergentMapValue
  = ConvergentMapValue
  { counters :: HashMap ByteString Int64 -- ^ Counters
  , flags :: HashMap ByteString Bool -- ^ Flags
  , maps :: HashMap ByteString ConvergentMapValue -- ^ Maps
  , registers :: HashMap ByteString ByteString -- ^ Registers
  , sets :: HashMap ByteString (HashSet ByteString) -- ^ Sets
  } deriving stock (Eq, Generic, Show)

-- TODO test ConvergentMapValue monoid instance
instance Monoid ConvergentMapValue where
  mempty = emptyMapValue
  mappend = (<>)

instance Semigroup ConvergentMapValue where
  ConvergentMapValue counters1 flags1 maps1 registers1 sets1 <>
    ConvergentMapValue counters2 flags2 maps2 registers2 sets2 =

    ConvergentMapValue counters3 flags3 maps3 registers3 sets3

    where
      counters3 :: HashMap ByteString Int64
      counters3 =
        HashMap.unionWith (+) counters1 counters2

      flags3 :: HashMap ByteString Bool
      flags3 =
        HashMap.unionWith (&&) flags1 flags2

      maps3 :: HashMap ByteString ConvergentMapValue
      maps3 =
        HashMap.unionWith (<>) maps1 maps2

      registers3 :: HashMap ByteString ByteString
      registers3 =
        HashMap.unionWith (const id) registers1 registers2

      sets3 :: HashMap ByteString (HashSet ByteString)
      sets3 =
        HashMap.unionWith HashSet.union sets1 sets2

-- | An empty map value.
emptyMapValue :: ConvergentMapValue
emptyMapValue =
  ConvergentMapValue
    { counters = HashMap.empty
    , flags = HashMap.empty
    , maps = HashMap.empty
    , registers = HashMap.empty
    , sets = HashMap.empty
    }

fromProto :: [Proto.MapEntry] -> ConvergentMapValue
fromProto =
  foldl' step emptyMapValue

  where
    step :: ConvergentMapValue -> Proto.MapEntry -> ConvergentMapValue
    step acc entry =
      fromProtoMapEntry entry acc

fromProtoMapEntry :: Proto.MapEntry -> ConvergentMapValue -> ConvergentMapValue
fromProtoMapEntry entry =
  case entry ^. Proto.field . Proto.type' of
    Proto.MapField'COUNTER ->
      field @"counters" %~
        HashMap.insert name (entry ^. Proto.counterValue)

    Proto.MapField'FLAG ->
      field @"flags" %~
        (HashMap.insert name (entry ^. Proto.flagValue))

    Proto.MapField'MAP ->
      field @"maps" %~
        (HashMap.insert name (fromProto (entry ^. Proto.mapValue)))

    Proto.MapField'REGISTER ->
      field @"registers" %~
        (HashMap.insert name (entry ^. Proto.registerValue))

    Proto.MapField'SET ->
      field @"sets" %~
        (HashMap.insert name (HashSet.fromList (entry ^. Proto.setValue)))

  where
    name :: ByteString
    name =
      entry ^. Proto.field . Proto.name

toProto ::
     ConvergentMapValue -- ^ New value
  -> ConvergentMapValue -- ^ Old value
  -> Proto.MapOp -- ^ Delta
toProto newValue oldValue =
  Proto.defMessage
    & Proto.removes .~ removes
    & Proto.updates .~ updates

  where
    removes :: [Proto.MapField]
    removes =
      concat
        [ makeRemoves counters  Proto.MapField'COUNTER
        , makeRemoves flags     Proto.MapField'FLAG
        , makeRemoves maps      Proto.MapField'MAP
        , makeRemoves registers Proto.MapField'REGISTER
        , makeRemoves sets      Proto.MapField'SET
        ]

      where
        makeRemoves ::
            (ConvergentMapValue -> HashMap ByteString a)
          -> Proto.MapField'MapFieldType
          -> [Proto.MapField]
        makeRemoves f t =
          HashMap.difference (f oldValue) (f newValue)
            & HashMap.keys
            & map
                (\key ->
                  Proto.defMessage
                    & Proto.name .~ key
                    & Proto.type' .~ t)


    updates :: [Proto.MapUpdate]
    updates =
      concat
        [ counterUpdates
        , flagUpdates
        , mapUpdates
        , registerUpdates
        , setUpdates
        ]

      where
        counterUpdates :: [Proto.MapUpdate]
        counterUpdates =
          mapMaybe
            (\(key, newValue) ->
              case HashMap.lookup key oldCounters of
                Nothing ->
                  Just (counterUpdate key newValue)
                Just oldValue ->
                  case newValue - oldValue of
                    0 ->
                      Nothing
                    difference ->
                      Just (counterUpdate key difference))
            (HashMap.toList (counters newValue))

          where
            oldCounters :: HashMap ByteString Int64
            oldCounters =
              counters oldValue

        flagUpdates :: [Proto.MapUpdate]
        flagUpdates =
          mapMaybe
            (\(key, newValue) ->
              case HashMap.lookup key oldFlags of
                Nothing ->
                  Just (flagUpdate key newValue)
                Just oldValue -> do
                  guard (newValue /= oldValue)
                  Just (flagUpdate key newValue))
            (HashMap.toList (flags newValue))

          where
            oldFlags :: HashMap ByteString Bool
            oldFlags =
              flags oldValue

        mapUpdates :: [Proto.MapUpdate]
        mapUpdates =
          mapMaybe
            (\(key, newValue) ->
              let
                op :: Proto.MapOp
                op =
                  toProto
                    newValue
                    (fromMaybe
                      emptyMapValue
                      (HashMap.lookup key oldMaps))
              in do
                guard (not (isEmptyMapOp op))
                Just (mapUpdate key op))
            (HashMap.toList (maps newValue))

          where
            oldMaps :: HashMap ByteString ConvergentMapValue
            oldMaps =
              maps oldValue

        registerUpdates :: [Proto.MapUpdate]
        registerUpdates =
          mapMaybe
            (\(key, newValue) ->
              case HashMap.lookup key oldRegisters of
                Nothing ->
                  Just (registerUpdate key newValue)
                Just oldValue -> do
                  guard (newValue /= oldValue)
                  Just (registerUpdate key newValue))
            (HashMap.toList (registers newValue))

          where
            oldRegisters :: HashMap ByteString ByteString
            oldRegisters =
              registers oldValue

        setUpdates :: [Proto.MapUpdate]
        setUpdates =
          mapMaybe
            (\(key, newValue) ->
              let
                op :: Proto.SetOp
                op =
                  RiakSet.toProto
                    newValue
                    (fromMaybe HashSet.empty (HashMap.lookup key oldSets))
              in do
                guard (not (isEmptySetOp op))
                Just (setUpdate key op))
            (HashMap.toList (sets newValue))

          where
            oldSets :: HashMap ByteString (HashSet ByteString)
            oldSets =
              sets oldValue

counterUpdate :: ByteString -> Int64 -> Proto.MapUpdate
counterUpdate key value =
  Proto.defMessage
    & Proto.field .~
        (Proto.defMessage
          & Proto.name .~ key
          & Proto.type' .~ Proto.MapField'COUNTER)
    & Proto.counterOp .~
        (Proto.defMessage
          & Proto.increment .~ value)

flagUpdate :: ByteString -> Bool -> Proto.MapUpdate
flagUpdate key value =
  Proto.defMessage
    & Proto.field .~
        (Proto.defMessage
          & Proto.name .~ key
          & Proto.type' .~ Proto.MapField'FLAG)
    & Proto.flagOp .~
        (if value
          then Proto.MapUpdate'ENABLE
          else Proto.MapUpdate'DISABLE)

mapUpdate :: ByteString -> Proto.MapOp -> Proto.MapUpdate
mapUpdate key value =
  Proto.defMessage
    & Proto.field .~
        (Proto.defMessage
          & Proto.name .~ key
          & Proto.type' .~ Proto.MapField'MAP)
    & Proto.mapOp .~
        value

registerUpdate :: ByteString -> ByteString -> Proto.MapUpdate
registerUpdate key value =
  Proto.defMessage
    & Proto.field .~
        (Proto.defMessage
          & Proto.name .~ key
          & Proto.type' .~ Proto.MapField'REGISTER)
    & Proto.registerOp .~
        value

setUpdate :: ByteString -> Proto.SetOp -> Proto.MapUpdate
setUpdate key value =
  Proto.defMessage
    & Proto.field .~
        (Proto.defMessage
          & Proto.name .~ key
          & Proto.type' .~ Proto.MapField'SET)
    & Proto.setOp .~
        value

isEmptyMapOp :: Proto.MapOp -> Bool
isEmptyMapOp op =
  null (op ^. Proto.removes) && null (op ^. Proto.updates)

isEmptySetOp :: Proto.SetOp -> Bool
isEmptySetOp op =
  null (op ^. Proto.adds) && null (op ^. Proto.removes)
