{-# language ApplicativeDo #-}
{-# language BlockArguments #-}
{-# language FlexibleContexts #-}
{-# language LambdaCase #-}
{-# language LambdaCase #-}
{-# language NamedFieldPuns #-}
{-# language OverloadedStrings #-}

module Weeder.Main ( main, mainWithConfig ) where

-- base
import Control.Monad ( guard )
import Control.Monad.IO.Class ( liftIO )
import Data.Bool
import Data.Foldable

-- containers
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

-- dhall
import qualified Dhall

-- directory
import System.Directory ( canonicalizePath, doesDirectoryExist, doesFileExist, doesPathExist, listDirectory, withCurrentDirectory )

-- filepath
import System.FilePath ( isExtensionOf )

-- ghc
import HieBin ( HieFileResult( HieFileResult, hie_file_result ) )
import HieBin ( readHieFile )
import NameCache ( initNameCache )
import OccName ( occNameString )
import SrcLoc ( realSrcSpanStart, srcLocCol, srcLocLine )
import UniqSupply ( mkSplitUniqSupply )

-- optparse-applicative
import Options.Applicative

-- transformers
import Control.Monad.Trans.State.Strict ( execStateT )

-- weeder
import Weeder
import Weeder.Config


main :: IO ()
main = do
  configExpr <-
    execParser $
      info
        ( strOption
            (    long "config"
              <> help "A Dhall expression for Weeder's configuration. Can either be a file path (a Dhall import) or a literal Dhall expression."
              <> value "./weeder.dhall"
            )
        )
        mempty

  Dhall.input config configExpr >>= mainWithConfig


mainWithConfig :: Config -> IO ()
mainWithConfig Config{ roots, typeClassRoots, ignore } = do
  hieFilePaths <-
    getHieFilesIn "./."

  nameCache <- do
    uniqSupply <- mkSplitUniqSupply 'z'
    return ( initNameCache uniqSupply [] )

  analysis <-
    flip execStateT emptyAnalysis do
      for_ hieFilePaths \hieFilePath -> do
        ( HieFileResult{ hie_file_result }, _ ) <-
          liftIO ( readHieFile nameCache hieFilePath )

        analyseHieFile hie_file_result

  let
    reachableSet =
      reachable
        analysis
        ( roots <> bool mempty ( Set.map DeclarationRoot ( implicitRoots analysis ) ) typeClassRoots )

    dead =
      Set.filter
        ( not . ( `Set.member` ignore ) )
        ( allDeclarations analysis Set.\\ reachableSet )

    warnings =
      Map.unionsWith (++) $
      foldMap
        ( \d ->
            fold $ do
              moduleFilePath <- Map.lookup ( declModule d ) ( modulePaths analysis )

              spans <- Map.lookup d ( declarationSites analysis )
              guard $ not $ null spans

              return [ Map.singleton moduleFilePath ( liftA2 (,) (Set.toList spans) (pure d) ) ]
        )
        dead

  for_ ( Map.toList warnings ) \( path, declarations ) ->
    for_ declarations \( srcSpan, d ) -> do
      let start = realSrcSpanStart srcSpan

      putStrLn $
        unwords
          [ foldMap ( <> ":" ) [ path, show ( srcLocLine start ), show ( srcLocCol start ) ]
          , occNameString ( declOccName d )
          ]


-- | Recursively search for .hie files in given directory
getHieFilesIn :: FilePath -> IO [FilePath]
getHieFilesIn path = do
  exists <-
    doesPathExist path

  if exists
    then do
      isFile <-
        doesFileExist path

      if isFile && "hie" `isExtensionOf` path
        then do
          path' <-
            canonicalizePath path

          return [ path' ]

        else do
          isDir <-
            doesDirectoryExist path

          if isDir
            then do
              cnts <-
                listDirectory path

              withCurrentDirectory path ( foldMap getHieFilesIn cnts )

            else
              return []

    else
      return []
