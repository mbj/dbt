{-# LANGUAGE RankNTypes #-}

module DBT.Wait (Config(..), wait) where

import Control.Concurrent (threadDelay)
import DBT.Connection
import DBT.Prelude
import Data.Int (Int)
import GHC.Enum (succ)
import GHC.Real (fromIntegral)

import qualified CBT
import qualified Colog
import qualified DBT.Postgresql   as Postgresql
import qualified Hasql.Connection as Hasql

data Config = Config
  { clientConfig :: Postgresql.ClientConfig
  , maxAttempts  :: Natural
  , onFail       :: forall env . CBT.WithEnv env => RIO env ()
  , prefix       :: String
  , waitTime     :: Natural
  }

wait :: forall env . CBT.WithEnv env => Config -> RIO env ()
wait Config{clientConfig = clientConfig@Postgresql.ClientConfig{..}, ..} =
  start =<< effectiveWaitTime
  where
    failPrefix :: String -> RIO env a
    failPrefix message = liftIO $ fail $ prefix <> (' ':message)

    effectiveWaitTime :: RIO env Int
    effectiveWaitTime =
      if waitTime <= fromIntegral (maxBound @Int)
        then pure $ fromIntegral waitTime
        else failPrefix $ "Cannot convert waitTime: " <> show waitTime <> " to Int"

    start :: Int -> RIO env ()
    start waitTime' = attempt 1
      where
        attempt :: Natural -> RIO env ()
        attempt count =
          either (onError count) pure =<< (liftIO . withConnectionEither clientConfig $ const $ pure ())

        onError :: Natural -> Hasql.ConnectionError -> RIO env ()
        onError attempts error =
          if attempts == maxAttempts
            then do
              onFail
              failPrefix $ "Giving up connection, last error: " <> show error
            else do
              Colog.logDebug . convert $ "Retrying failed connection attempt from error: " <> show error
              liftIO $ threadDelay waitTime'
              attempt $ succ attempts
