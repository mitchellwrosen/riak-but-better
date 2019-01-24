module Main where

import Options.Applicative

import Control.Lens               ((.~))
import Data.Function              ((&))
import Data.Generics.Product      (field)
import Data.List.Split            (splitOn)
import Network.Socket             (HostName, PortNumber)
import Riak.Interface             (Interface)
import Riak.Interface.Impl.Socket (EventHandlers(..))
import Text.Read                  (readMaybe)

import qualified Data.ByteString.Char8      as Latin1
import qualified Riak.Client
import qualified Riak.Client                as Riak (Client)
import qualified Riak.Interface.Impl.Socket as Riak.Interface
import qualified Riak.Key                   as Riak (Key(..))

main :: IO ()
main = do
  ((host, port), run) <-
    (customExecParser
      (prefs showHelpOnEmpty)
      (info
        ((,)
          <$> nodeParser
          <*> commandParser)
        (progDesc "Riak command-line client")))

  iface :: Interface <-
    Riak.Interface.new
      host
      port
      EventHandlers
        { onConnect = pure ()
        , onDisconnect = pure ()
        , onSend = \msg -> putStrLn (">>> " ++ show msg)
        , onReceive = \msg -> putStrLn ("<<< " ++ maybe "" show msg)
        }

  -- Riak.Interface.connect iface

  run (Riak.Client.new iface)

nodeParser :: Parser (HostName, PortNumber)
nodeParser =
  argument
    (eitherReader parseNode)
    (help "Riak node, e.g. localhost:8087" <> metavar "NODE")

  where
    parseNode :: String -> Either String (HostName, PortNumber)
    parseNode s =
      maybe (Left "Expected 'host' or 'host:port'") Right $ do
        case span (/= ':') s of
          (host, ':':port) -> do
            port' <- readMaybe port
            pure (host, port')
          (host, []) ->
            pure (host, 8087)
          _ -> undefined

commandParser :: Parser (Riak.Client -> IO ())
commandParser =
  hsubparser
    (mconcat
      [ commandGroup "Object operations"
      , command "get" (info getParser (progDesc "Get an object"))
      ])

getParser :: Parser (Riak.Client -> IO ())
getParser =
  doGet
    <$> argument (eitherReader parseKey) keyMod
  where
    doGet :: Riak.Key -> Riak.Client -> IO ()
    doGet key client = do
      print key

parseKey :: String -> Either String Riak.Key
parseKey string =
  case splitOn "/" string of
    [ bucket, key ] ->
      Right Riak.Key
        { Riak.type' = "default"
        , Riak.bucket = Latin1.pack bucket
        , Riak.key = Latin1.pack key
        }

    [ type', bucket, key ] ->
      Right Riak.Key
        { Riak.type' = Latin1.pack type'
        , Riak.bucket = Latin1.pack bucket
        , Riak.key = Latin1.pack key
        }

    _ ->
      Left "TODO key parse failure message"

keyMod :: HasMetavar f => Mod f a
keyMod =
  (help "Key (bucket/key or type/bucket/key)" <> metavar "KEY")
