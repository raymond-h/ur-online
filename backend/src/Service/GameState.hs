{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

module Service.GameState where

import Control.Lens
import Control.Concurrent.STM
import Web.Scotty as S
import Network.HTTP.Types
import qualified Control.Monad.Except as E
import qualified Data.Text as T
import System.Random (randomRIO)

import qualified Network.Pusher as P
import PusherCommon

-- import AppState as AS
import Database.Persist as Ps
import Database.Persist.Sql as Ps
import Data.Pool
import qualified Database as DB
import qualified Game as G
import qualified Validation as V

import Util (sendErrorAndFinish)

getGameStates :: ActionM (Entity DB.User) -> Pool SqlBackend -> ActionM ()
getGameStates auth dbPool = do
  user <- auth
  let userKey = Ps.entityKey user

  games <- DB.runDbPool dbPool $ Ps.selectList ([DB.GameAppStatePlayer1 ==. userKey] ||. [DB.GameAppStatePlayer2 ==. userKey]) []

  S.json games

getGameState :: ActionM (Entity DB.User) -> Pool SqlBackend -> ActionM ()
getGameState _ dbPool = do
  gameId <- Ps.toSqlKey <$> S.param "gameId"

  mGame <- DB.runDbPool dbPool $ Ps.getEntity gameId

  let result = getGameStateLogic mGame

  case result of
    Left (status, err) -> sendErrorAndFinish status err
    Right gas -> S.json gas

getGameStateLogic ::
  Maybe (Entity DB.GameAppState) ->
  Either (Status, T.Text) (Entity DB.GameAppState)
getGameStateLogic = V.noteE (status404, "No such game")

plus4 a b c d = a + b + c + d

performMove :: ActionM (Entity DB.User) -> Pool SqlBackend -> ([P.Channel] -> P.Event -> P.EventData -> S.ActionM ()) -> ActionM ()
performMove auth dbPool pushClient = do
  user <- auth
  gameId <- Ps.toSqlKey <$> S.param "gameId"
  move <- S.jsonData

  let
    randomDice = E.liftIO $ plus4 <$> randomRIO (0, 1) <*> randomRIO (0, 1) <*> randomRIO (0, 1) <*> randomRIO (0, 1)
    lookupGame gameId = DB.runDbPool dbPool $ Ps.getEntity gameId
    updateGame gameEntity = DB.runDbPool dbPool $ Ps.replace (Ps.entityKey gameEntity) (Ps.entityVal gameEntity)

  result <- performMoveLogic randomDice lookupGame updateGame (pushClient . fmap toChannel) user gameId move

  case result of
    Left (status, err) -> sendErrorAndFinish status err
    Right gas -> S.json gas

performMoveLogic :: Monad m =>
  m Int ->
  (DB.GameAppStateId -> m (Maybe (Entity DB.GameAppState))) ->
  (Entity DB.GameAppState -> m ()) ->
  ([EventChannel] -> P.Event -> P.EventData -> m ()) ->
  Entity DB.User ->
  DB.GameAppStateId ->
  G.Move ->
  m (Either (Status, T.Text) (Entity DB.GameAppState))
performMoveLogic randomDice lookupGame updateGame pushClient user gameId move = E.runExceptT $ do
  mGas <- E.lift $ lookupGame gameId
  gasEntity <- E.liftEither $ V.noteE (status404, "No such game") mGas

  let
    player1 = gasEntity^.(Ps.fieldLens DB.GameAppStatePlayer1)
    player2 = gasEntity^.(Ps.fieldLens DB.GameAppStatePlayer2)

  E.when (player1 /= Ps.entityKey user && player2 /= Ps.entityKey user) $
    E.throwError (status400, "User not a player in this game")

  let
    currentPlayer = if (gasEntity ^. (Ps.fieldLens DB.GameAppStateState) . G.stateCurrentPlayer == G.Player1)
      then player1 else player2

  E.when (currentPlayer /= Ps.entityKey user) $
    E.throwError (status400, "Not this player's turn")

  mNewGame <- E.lift $ G.performMove randomDice move $ DB.gameAppStateState $ Ps.entityVal gasEntity

  case mNewGame of
    Nothing -> E.throwError (status400, "Invalid move")
    Just newGame -> do
      let newGas = gasEntity & Ps.fieldLens DB.GameAppStateState .~ newGame

      E.lift $ updateGame newGas
      E.lift $ pushClient [Game $ Ps.entityKey gasEntity] "update-state" ""
      return newGas
