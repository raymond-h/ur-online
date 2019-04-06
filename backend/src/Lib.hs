{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Lib where

import Control.Monad (void)
import Configuration.Dotenv
import Configuration.Dotenv.Types
import GHC.Generics
import Data.Aeson
import Data.Aeson.Lens
import Network.Wai (Application)
import Network.Wai.Handler.Warp (runEnv)
import Network.Wai.Middleware.RequestLogger
import Network.Wai.Middleware.Cors
import System.Environment
import Crypto.JWT
import Data.Set (fromList)
import Data.Maybe
import Text.Read (readMaybe)
import Control.Lens hiding ((.=))
import Control.Monad.Trans (liftIO, MonadIO)
import Control.Concurrent.STM hiding (check)
import Control.Monad
import Data.Either.Validation
import Network.HTTP.Types
import qualified Data.ByteString.Char8 as BS
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import qualified Web.Scotty as S
import qualified Web.Scotty.Trans as ST
import Database.Persist as P
import Database.Persist.Sqlite
import Control.Monad.Logger
import Data.Pool
import Control.Exception (assert)

import qualified Network.Pusher as P

import qualified Auth as A
import Validation as V
import Util (queryTVar, modifyTVarState)
import qualified AppState as AS
import qualified Auth0Management as A0M
import qualified Database as DB

import qualified Service.UserInfo as UI
import qualified Service.Invite as I
import qualified Service.PusherAuth as PA

getEnv' :: Read r => String -> IO (Maybe r)
getEnv' var = do
  mVal <- lookupEnv var
  return $ mVal >>= readMaybe

listOfPairsToObject :: [(String, String)] -> Value
listOfPairsToObject = object . map (uncurry (.=)) . over (mapped._1) T.pack

frontendCorsResourcePolicy frontendOrigin = simpleCorsResourcePolicy {
  corsOrigins = Just ([BS.pack frontendOrigin], True),
  corsMethods = ["PUT"],
  corsRequestHeaders = ["Authorization", "Content-Type"]
}

devCorsResourcePolicy = simpleCorsResourcePolicy {
  corsOrigins = Nothing,
  corsMethods = ["PUT"],
  corsRequestHeaders = ["Authorization", "Content-Type"]
}

authenticate :: Pool SqlBackend -> JWTValidationSettings -> JWKSet -> S.ActionM AS.User
authenticate dbPool jwtValidationSettings jwkSet = do
  (_, claimsSet) <- A.verifyJWT jwtValidationSettings jwkSet

  let userId = T.pack $ view (claimSub._Just.string) claimsSet

  dbUser <- DB.runDbPool dbPool $ do
    let userKey = DB.UserKey userId

    mUser <- P.getEntity userKey
    case mUser of
      Nothing -> do
        let userData = DB.User Nothing
        P.insertKey userKey $ userData
        return $ Entity userKey userData

      Just user -> return user

  return (DB.fromDbUser dbUser :: AS.User)

testAuthenticate isTest appStateTVar = do
  guard isTest
  mAuth <- S.header "Authorization"
  case LT.toStrict <$> mAuth of
    Nothing -> S.status status401 >> S.finish
    Just userId -> do
      appState <- liftIO . readTVarIO $ appStateTVar
      return . fromJust $ AS.getUserById userId appState

checkError cond status errMsg = unless cond $ do
  S.status status
  S.json $ object ["error" .= errMsg]
  S.finish

pusherCredentialsFromEnv :: IO P.Credentials
pusherCredentialsFromEnv = do
  pusherAppId <- getEnv "PUSHER_APP_ID"
  pusherAppKey <- getEnv "PUSHER_APP_KEY"
  pusherAppSecret <- getEnv "PUSHER_APP_SECRET"
  pusherCluster <- lookupEnv "PUSHER_CLUSTER"

  return $ P.Credentials {
      P.credentialsAppID = read pusherAppId,
      P.credentialsAppKey = BS.pack pusherAppKey,
      P.credentialsAppSecret = BS.pack pusherAppSecret,
      P.credentialsCluster = P.Cluster . T.pack <$> pusherCluster
    }

data Environment = Production | Development | Test deriving (Eq, Show)

runApp :: IO ()
runApp = do
  -- we don't care if the file is missing
  (void $ loadFile defaultConfig) `onMissingFile` return ()

  isDev <- fromMaybe False <$> getEnv' "DEV"
  appState <- newTVarIO AS.initialAppState

  runNoLoggingT $ withSqlitePool "local.db" 4 $ \dbPool -> liftIO $ do
    DB.runDbPool dbPool $ runMigration DB.migrateAll
    app <- createApp (if isDev then Development else Production) appState dbPool
    runEnv 8080 app

createApp :: Environment -> TVar AS.AppState -> Pool SqlBackend -> IO Application
createApp environment appState dbPool = do
  let isDev = environment == Development
  let isTest = environment == Test
  unless isTest $ print ("Dev?", isDev)

  corsResPolicy <- if environment == Production
    then frontendCorsResourcePolicy <$> getEnv "FRONTEND_ORIGIN"
    else return devCorsResourcePolicy

  (Just audience) <- preview stringOrUri <$> getEnv "JWT_AUDIENCE"
  (Just issuer) <- preview stringOrUri <$> getEnv "JWT_ISSUER"

  mCreds <- if isTest then return Nothing else Just <$> pusherCredentialsFromEnv

  mPusher <- case mCreds of
    Just creds -> Just <$> P.getPusher creds
    Nothing -> return Nothing

  mJwkSetOrError <- if environment == Test
    then return Nothing
    else do
      mDomain <- lookupEnv "AUTH0_DOMAIN"
      case mDomain of
        Nothing -> return Nothing
        Just domain -> Just <$> A.fetchJWKSet domain

  -- domain <- T.pack <$> getEnv "AUTH0_DOMAIN"
  -- clientId <- T.pack <$> getEnv "AUTH0_CLIENT_ID"
  -- clientSecret <- T.pack <$> getEnv "AUTH0_CLIENT_SECRET"
  -- a0Config <- A0M.getConfig domain clientId clientSecret

  let
    jwtValidationSettings =
      defaultJWTValidationSettings (==audience)
        & algorithms .~ fromList [RS256]
        & issuerPredicate .~ (==issuer)
        & allowedSkew .~ 30 * 60

    auth :: S.ActionM AS.User
    auth = case mJwkSetOrError of
      Nothing -> testAuthenticate isTest appState
      Just (Right jwkSet) -> authenticate dbPool jwtValidationSettings jwkSet

    pushClient :: [P.Channel] -> P.Event -> P.EventData -> S.ActionM ()
    pushClient channels event eventData = do
      case mPusher of
        Nothing -> return ()
        Just pusher -> do
          res <- P.trigger pusher channels event eventData Nothing
          case res of
            Left err -> S.raise $ ST.stringError $ show err
            Right () -> return ()

  S.scottyApp $ do
    unless isTest $
      S.middleware $ if isDev then logStdoutDev else logStdout

    S.middleware . cors . const . Just $ corsResPolicy

    S.get "/" $ do
      S.text "hello"

    S.get "/some-json" $ auth >> do
      S.json $ object ["foo" .= Number 23, "bar" .= Number 42]

    S.get "/.env" $ auth >> do
      env <- liftIO getEnvironment
      S.json . listOfPairsToObject $ env

    when isDev $
      S.get "/.app-state" $ auth >> do
        res <- DB.runDbPool dbPool $ P.selectList [] []
        liftIO $ print (res :: [P.Entity DB.User])

        res <- DB.runDbPool dbPool $ P.selectList [] []
        liftIO $ print (res :: [P.Entity DB.Invite])

        as <- liftIO . readTVarIO $ appState
        S.text . LT.pack $ show as

    S.get "/auth" $ do
      userId <- view AS.userId <$> auth
      S.text $ "gj on the authenticating!: " <> LT.pack (show userId)

    when (isJust mCreds) $ S.post "/pusher/auth" $ PA.pusherAuthenticate auth (fromJust mCreds)

    S.get "/me" $ do
      userId <- view AS.userId <$> auth
      S.json userId

    S.get "/user-info" $ UI.getUserInfo auth
    S.put "/user-info" $ UI.updateUserInfo auth dbPool pushClient

    S.get "/invites" $ I.getInvites auth dbPool
    S.post "/invites" $ I.createInvite auth dbPool pushClient
    S.post "/invites/accept" $ I.acceptInvite auth appState dbPool pushClient
