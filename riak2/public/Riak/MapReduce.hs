-- |
-- * <https://docs.basho.com/riak/kv/2.2.3/developing/usage/mapreduce/>
-- * <https://docs.basho.com/riak/kv/2.2.3/developing/app-guide/advanced-mapreduce/>

module Riak.MapReduce
  ( mapReduceBucket
  , mapReduceKeys
    -- TODO map reduce functions for other input types
  , MapReducePhase(..)
  , MapReduceFunction(..)
  ) where

import RiakMapReduce
import RiakMapReduceFunction
import RiakMapReducePhase
