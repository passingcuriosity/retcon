--
-- Copyright © 2014-2015 Anchor Systems, Pty Ltd and Others
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the 3-clause BSD licence.
--

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards          #-}

-- | Description: Define and operate on data sources.
--
-- /Synchronise/ interacts with external systems and propagates changes to
-- duplicated data between them; these external systems are 'DataSource's.
module Synchronise.DataSource (
    DataSource(..),
    Command,
    DSMonad,
    runDSMonad,
    -- * Operations
    createDocument,
    readDocument,
    updateDocument,
    deleteDocument,
) where

import Control.Applicative
import Control.Monad
import Control.Monad.Error.Class
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Data.Aeson
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.Monoid
import Data.String ()
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Text.Regex
import System.Exit
import System.IO
import System.Process

import Synchronise.Configuration
import Synchronise.Document
import Synchronise.Identifier

data DataSourceError
    = DecodeError String
    | ForeignError Int Text
    | IncompatibleDataSource
  deriving (Eq, Show)

newtype DSMonad a = DSMonad { unDSMonad :: ExceptT DataSourceError IO a }
  deriving (Applicative, Functor, Monad, MonadIO, MonadError DataSourceError)

runDSMonad :: DSMonad a -> IO (Either DataSourceError a)
runDSMonad = runExceptT . unDSMonad

-- | Replace a named hole in a string.
subNamedHole
    :: String    -- ^ hole name
    -> String    -- ^ Input string
    -> String    -- ^ Replacement text
    -> String    -- ^ Output string
subNamedHole name = subRegex $ mkRegex $ "\\$\\{" <> name <> "\\}"

-- | Prepare a 'Command' by interpolating
prepareCommand
    :: DataSource
    -> Maybe ForeignKey
    -> Command
    -> String
prepareCommand _ds fk cmd =
    case fk of
        Nothing -> T.unpack . unCommand $ cmd
        Just ForeignKey{..} ->
            let cmd' = T.unpack . unCommand $ cmd
            in subNamedHole "fk" cmd' (T.unpack fkKey)

-- | Check that a 'DataSource' and a 'ForeignKey' are compatible, otherwise
-- raise an error in the monad.
checkCompatibility
    :: (Synchronisable a, Synchronisable b)
    => a
    -> b
    -> DSMonad ()
checkCompatibility a b =
    unless (compatibleSource a b) $ throwError IncompatibleDataSource

-- | Access a 'DataSource' and create a new 'Document' returning the
-- 'ForeignKey' which, in that source, identifies the document.
--
-- It is an error if the 'DataSource' and 'Document' supplied do not agree on
-- the entity and source names.
createDocument
    :: DataSource
    -> Document
    -> DSMonad ForeignKey
createDocument src doc = do
    -- 1. Check source and key are compatible.
    checkCompatibility src doc
    -- 2. Spawn process.
    let cmd = prepareCommand src Nothing . commandCreate $ src
    liftIO $ BS.hPutStrLn stderr $ BS.pack cmd
    let process = (shell cmd) { std_out = CreatePipe, std_in = CreatePipe }
    (Just hin, Just hout, Nothing, hproc) <- liftIO $ createProcess process
    -- 3. Write input.
    liftIO . BSL.hPutStrLn hin . encode . _documentContent $ doc
    liftIO $ hClose hin
    -- 4. Read handles
    output <- T.decodeUtf8 <$> (liftIO . BS.hGetContents $ hout)
    -- 5. Check return code, raising error if required.
    exit <- liftIO $ waitForProcess hproc
    case exit of
        ExitFailure c -> throwError $ ForeignError c output
        ExitSuccess -> return ()
    -- 6. Close handles.
    liftIO $ hClose hout
    -- 7. Parse response.
    return $ ForeignKey "entity" "source" output

-- | Access a 'DataSource' and retrieve the 'Document' identified, in that source,
-- by the given 'ForeignKey'.
--
-- It is an error if the 'DataSource' and 'ForeignKey' supplied do not agree on
-- the entity and source names.
readDocument
    :: DataSource
    -> ForeignKey
    -> DSMonad Document
readDocument src fk = do
    -- 1. Check source and key are compatible.
    checkCompatibility src fk
    -- 2. Spawn process.
    let cmd = prepareCommand src (Just fk) . commandRead $ src
    let process = (shell cmd) { std_out = CreatePipe }
    (Nothing, Just hout, Nothing, hproc) <- liftIO $ createProcess process
    -- 3. Read output.
    output <- liftIO $ BS.hGetContents hout
    -- 4. Check return code, raising error if required.
    exit <- liftIO $ waitForProcess hproc
    case exit of
        ExitFailure c -> throwError $ ForeignError c (T.decodeUtf8 output)
        ExitSuccess -> return ()
    -- 5. Close handles.
    liftIO $ hClose hout
    -- 6. Parse input and return value.
    case eitherDecode' . BSL.fromStrict $ output of
        Left e -> throwError $ DecodeError e
        Right j -> return $ Document (fkEntity fk) (fkSource fk) j

-- | Access a 'DataSource' and save the 'Document' under the specified
-- 'ForeignKey', returning the 'ForeignKey' to use for the updated document in
-- future.
--
-- It is an error if the 'DataSource' and 'ForeignKey' supplied do not agree on
-- the entity and source names.
updateDocument
    :: DataSource
    -> ForeignKey
    -> Document
    -> DSMonad ForeignKey -- ^ New (or old) key for this document.
updateDocument src fk doc = do
    -- 1. Check source, key, and document are compatible.
    checkCompatibility src fk
    checkCompatibility src doc
    -- 2. Spawn process.
    -- 3. Write input.
    -- 4. Read output.
    -- 5. Check return code, raising error if required.
    -- 6. Close handles.
    -- 7. Parse input and return value.
    error "DataSource.updateDcoument is not implemented"

-- | Access a 'DataSource' and delete the 'Document' identified in that source
-- by the given 'ForeignKey'.
--
-- It is an error if the 'DataSource' and 'ForeignKey' do not agree on the
-- entity and source names.
deleteDocument
    :: DataSource
    -> ForeignKey
    -> DSMonad ()
deleteDocument src fk = do
    -- 1. Check source and key are compatible.
    checkCompatibility src fk
    -- 2. Spawn process.
    let cmd = prepareCommand src (Just fk) . commandDelete $ src
    let process = (shell cmd) { std_out = CreatePipe }
    (Nothing, Just hout, Nothing, hproc) <- liftIO $ createProcess process
    -- 3. Read output
    output <- liftIO $ BS.hGetContents hout
    -- 4. Check return code, raising error if required.
    exit <- liftIO $ waitForProcess hproc
    case exit of
        ExitFailure c -> throwError $ ForeignError c (T.decodeUtf8 output)
        ExitSuccess -> return ()
    -- 5. Close handles.
    liftIO $ hClose hout
