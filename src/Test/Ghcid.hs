
-- | Test behavior of the executable, polling files for changes
module Test.Ghcid(ghcidTest) where

import Control.Concurrent
import Control.Exception.Extra
import Control.Monad.Extra
import Data.Char
import Data.List.Extra
import System.Directory.Extra
import System.IO.Extra
import System.Time.Extra
import Data.Version.Extra
import System.Environment
import System.Process.Extra

import Test.Tasty
import Test.Tasty.HUnit

import Ghcid
import Language.Haskell.Ghcid.Util
import Data.Functor
import Prelude


ghcidTest :: TestTree
ghcidTest = testCase "Ghcid Test" $ withTempDir $ \dir -> withCurrentDirectory dir $ do
    chan <- newChan
    let require p = do
            t <- timeout 5 $ readChan chan
            case t of
                Nothing -> fail "require failed"
                Just v -> p v
            sleep =<< getModTimeResolution

    writeFile "Main.hs" "main = print 1"

    let output = writeChan chan . filter (/= "") . map snd
    bracket
        (forkIO $ withArgs ["-c\"ghci -fwarn-unused-binds Main.hs\"","--notitle","--no-status"] $ mainWithTerminal (return (100, 50)) output)
        killThread $ \_ -> do
            require requireAllGood
            testScript require
            outStrLn "\nSuccess"


-- | The all good message, something like "All good (2 modules)"
requireAllGood :: [String] -> IO ()
requireAllGood = requireSimilar [allGoodMessage]

-- | Since different versions of GHCi give different messages, we only try to find what we require anywhere in the obtained messages
requireSimilar :: [String] -> [String] -> IO ()
requireSimilar want got = do
    -- Spacing and quotes tend to be different on different GHCi versions
    let simple = lower . filter (\x -> isLetter x || isDigit x || x == ':')
        got2 = simple $ unwords got
    all (`isInfixOf` got2) (map simple got) @?
        "Expected " ++ show want ++ ", got " ++ show got


---------------------------------------------------------------------
-- ACTUAL TEST SUITE

testScript :: (([String] -> IO ()) -> IO ()) -> IO ()
testScript require = do
    writeFile <- return $ \name x -> do print ("writeFile",name,x); writeFile name x
    renameFile <- return $ \from to -> do print ("renameFile",from,to); renameFile from to

    writeFile "Main.hs" "x"
    require $ requireSimilar ["Main.hs:1:1"," Parse error: naked expression at top level"]
    writeFile "Util.hs" "module Util where"
    writeFile "Main.hs" "import Util\nmain = print 1"
    require requireAllGood
    writeFile "Util.hs" "module Util where\nx"
    require $ requireSimilar ["Util.hs:2:1","Parse error: naked expression at top level"]
    writeFile "Util.hs" "module Util() where\nx = 1"
    require $ requireSimilar ["Util.hs:2:1","Warning: Defined but not used: `x'"]

    -- check warnings persist properly
    writeFile "Main.hs" "import Util\nx"
    require $ requireSimilar ["Main.hs:2:1","Parse error: naked expression at top level"
                             ,"Util.hs:2:1","Warning: Defined but not used: `x'"]
    writeFile "Main.hs" "import Util\nmain = print 2"
    require $ requireSimilar ["Util.hs:2:1","Warning: Defined but not used: `x'"]
    writeFile "Main.hs" "main = print 3"
    require requireAllGood
    writeFile "Main.hs" "import Util\nmain = print 4"
    require $ requireSimilar ["Util.hs:2:1","Warning: Defined but not used: `x'"]
    writeFile "Util.hs" "module Util where"
    require requireAllGood

    -- check recursive modules work
    writeFile "Util.hs" "module Util where\nimport Main"
    require $ requireSimilar ["imports form a cycle","Main.hs","Util.hs"]
    writeFile "Util.hs" "module Util where"
    require requireAllGood

    ghcVer <- readVersion <$> systemOutput_ "ghc --numeric-version"

    -- check renaming files works
    when (ghcVer < makeVersion [8]) $ do
        -- note that due to GHC bug #9648 and #11596 this doesn't work with newer GHC
        -- see https://ghc.haskell.org/trac/ghc/ticket/11596
        renameFile "Util.hs" "Util2.hs"
        require $ requireSimilar ["Main.hs:1:8:","Could not find module `Util'"]
        renameFile "Util2.hs" "Util.hs"
        require requireAllGood

    -- after this point GHC bugs mean nothing really works too much
