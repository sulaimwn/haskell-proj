-- | Writes the frontend's TypeScript API types.
--
-- Usage: reckon-codegen OUTPUT_PATH
module Main (main) where

import Data.Text.IO qualified as Text
import Reckon.Api.TypeScript (renderTypeScriptModule)
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [outputPath] -> do
      Text.writeFile outputPath renderTypeScriptModule
      putStrLn ("Wrote " <> outputPath)
    _ -> die "Usage: reckon-codegen OUTPUT_PATH"
