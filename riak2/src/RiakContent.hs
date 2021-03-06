module RiakContent
  ( Content(..)
  , newContent
  ) where

import RiakSecondaryIndex (SecondaryIndex)

import Data.Time          (UTCTime(..))
import Data.Time.Calendar (Day(..))

import qualified Data.HashMap.Strict as HashMap


-- | Object content.
data Content a
  = Content
  { charset :: Maybe ByteString -- ^ Charset (read-write)
  , encoding :: Maybe ByteString -- ^ Content encoding (read-write)
  , indexes :: [SecondaryIndex] -- ^ Secondary indexes (read-write)
  , lastModified :: UTCTime -- ^ Last modified (read only)
  , metadata :: HashMap ByteString ByteString -- ^ User metadata (read-write)
  , type' :: Maybe ByteString -- ^ Content type (read-write)
  , value :: a -- ^ Value (read-write)
  } deriving stock (Eq, Functor, Generic, Show)

-- | Create a new content from a value.
--
-- An arbitrary date in the 1850s is chosen for @lastModified@. This is only
-- relevant if you are using the unrecommended bucket settings that both
-- disallow siblings and use internal (unreliable) timestamps for conflict
-- resolution. TODO test that, is it even accurate?
newContent ::
     a -- ^ Value
  -> Content a
newContent value =
  Content
    { charset = Nothing
    , encoding = Nothing
    , indexes = []
    , lastModified = UTCTime (ModifiedJulianDay 0) 0
    , metadata = HashMap.empty
    , type' = Nothing
    , value = value
    }
