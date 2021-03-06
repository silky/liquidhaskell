{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE DoAndIfThenElse     #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import Control.Applicative
import Control.Monad
import Data.Char
import Data.Proxy
import Data.Tagged
import Data.Typeable
import Options.Applicative
import System.Directory
import System.Exit
import System.FilePath
import System.IO
-- import qualified System.Posix as Posix
import System.Process
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.Ingredients.Rerun
import Test.Tasty.Options
import Test.Tasty.Runners
import Text.Printf

main :: IO ()
main = run =<< tests 
  where
    run   = defaultMainWithIngredients [ 
                rerunningTests   [ listingTests, consoleTestReporter ]
              , includingOptions [ Option (Proxy :: Proxy NumThreads)
                                 , Option (Proxy :: Proxy SmtSolver) ]
              ]
    
    tests = group "Tests" [ unitTests, benchTests ]

data SmtSolver = Z3 | CVC4 deriving (Show, Read, Eq, Ord, Typeable)
instance IsOption SmtSolver where
  defaultValue = Z3
  parseValue = safeRead . map toUpper
  optionName = return "smtsolver"
  optionHelp = return "Use this SMT solver"
  optionCLParser =
    option (fmap (read . map toUpper) str)
      (  long (untag (optionName :: Tagged SmtSolver String))
      <> help (untag (optionHelp :: Tagged SmtSolver String))
      )

unitTests  
  = group "Unit" [ 
      testGroup "pos"         <$> dirTests "tests/pos"                            []           ExitSuccess
    , testGroup "neg"         <$> dirTests "tests/neg"                            []           (ExitFailure 1)
    , testGroup "crash"       <$> dirTests "tests/crash"                          []           (ExitFailure 2) 
    , testGroup "parserpos"   <$> dirTests "tests/parser/pos"                    []           ExitSuccess
    , testGroup "errorcrash"  <$> dirTests "tests/error_messages/crash"           []           (ExitFailure 2)
    , testGroup "errorpos"    <$> dirTests "tests/parser/pos"                     []           ExitSuccess
   ]

benchTests
  = group "Benchmarks" [ 
      testGroup "text"        <$> dirTests "benchmarks/text-0.11.2.3"             textIgnored  ExitSuccess
    , testGroup "bytestring"  <$> dirTests "benchmarks/bytestring-0.9.2.1"        []           ExitSuccess
    , testGroup "esop"        <$> dirTests "benchmarks/esop2013-submission"       ["Base0.hs"] ExitSuccess
    , testGroup "vect-algs"   <$> dirTests "benchmarks/vector-algorithms-0.5.4.2" []           ExitSuccess
    , testGroup "hscolour"    <$> dirTests "benchmarks/hscolour-1.20.0.0"         []           ExitSuccess

    ]

---------------------------------------------------------------------------
dirTests :: FilePath -> [FilePath] -> ExitCode -> IO [TestTree]
---------------------------------------------------------------------------
dirTests root ignored code
  = do files    <- walkDirectory root
       let tests = [ rel | f <- files, isTest f, let rel = makeRelative root f, rel `notElem` ignored ]
       return    $ mkTest code root <$> tests --  hs f code | f <- hs]

isTest   :: FilePath -> Bool
isTest f = takeExtension f == ".hs" -- `elem` [".hs", ".lhs"]

---------------------------------------------------------------------------
mkTest :: ExitCode -> FilePath -> FilePath -> TestTree
---------------------------------------------------------------------------
mkTest code dir file
  = askOption $ \(smt :: SmtSolver) -> testCase file $ do
      if test `elem` knownToFail smt
      then do
        printf "%s is known to fail with %s: SKIPPING" test (show smt)
        assertEqual "" True True
      else do
        createDirectoryIfMissing True $ takeDirectory log
        liquid <- canonicalizePath "dist/build/liquid/liquid"
        withFile log WriteMode $ \h -> do
          let cmd     = testCmd liquid dir file smt
          (_,_,_,ph) <- createProcess $ (shell cmd) {std_out = UseHandle h, std_err = UseHandle h}
          c          <- waitForProcess ph
          assertEqual "Wrong exit code" code c
  where
    test = dir </> file
    log = let (d,f) = splitFileName file in dir </> d </> ".liquid" </> f <.> "log"

knownToFail CVC4 = [ "tests/pos/linspace.hs", "tests/pos/RealProps.hs", "tests/pos/RealProps1.hs", "tests/pos/initarray.hs" ]
knownToFail Z3   = [ "tests/pos/linspace.hs" ]

---------------------------------------------------------------------------
testCmd :: FilePath -> FilePath -> FilePath -> SmtSolver -> String
---------------------------------------------------------------------------
testCmd liquid dir file smt 
  = printf "cd %s && %s --verbose --smtsolver %s %s" dir liquid (show smt) file


textIgnored = [ "Data/Text/Axioms.hs"
              , "Data/Text/Encoding/Error.hs"
              , "Data/Text/Encoding/Fusion.hs"
              , "Data/Text/Encoding/Fusion/Common.hs"
              , "Data/Text/Encoding/Utf16.hs"
              , "Data/Text/Encoding/Utf32.hs"
              , "Data/Text/Encoding/Utf8.hs"
              , "Data/Text/Fusion/CaseMapping.hs"
              , "Data/Text/Fusion/Common.hs"
              , "Data/Text/Fusion/Internal.hs"
              , "Data/Text/IO.hs"
              , "Data/Text/IO/Internal.hs"
              , "Data/Text/Lazy/Builder/Functions.hs"
              , "Data/Text/Lazy/Builder/Int.hs"
              , "Data/Text/Lazy/Builder/Int/Digits.hs"
              , "Data/Text/Lazy/Builder/Internal.hs"
              , "Data/Text/Lazy/Builder/RealFloat.hs"
              , "Data/Text/Lazy/Builder/RealFloat/Functions.hs"
              , "Data/Text/Lazy/Encoding/Fusion.hs"
              , "Data/Text/Lazy/IO.hs"
              , "Data/Text/Lazy/Read.hs"
              , "Data/Text/Read.hs"
              , "Data/Text/Unsafe/Base.hs"
              , "Data/Text/UnsafeShift.hs"
              , "Data/Text/Util.hs"
              ]


demosIgnored = [ "Composition.hs"
               , "Eval.hs"
               , "Inductive.hs"
               , "Loop.hs"
               , "TalkingAboutSets.hs"
               , "refinements101reax.hs"
               ]

----------------------------------------------------------------------------------------
-- Generic Helpers
----------------------------------------------------------------------------------------

group n xs = testGroup n <$> sequence xs

----------------------------------------------------------------------------------------
walkDirectory :: FilePath -> IO [FilePath]
----------------------------------------------------------------------------------------
walkDirectory root
  = do (ds,fs) <- partitionM doesDirectoryExist . candidates =<< getDirectoryContents root
       (fs++) <$> concatMapM walkDirectory ds
  where
    candidates fs = [root </> f | f <- fs, not (isExtSeparator (head f))]

partitionM :: Monad m => (a -> m Bool) -> [a] -> m ([a],[a])
partitionM f = go [] []
  where
    go ls rs []     = return (ls,rs)
    go ls rs (x:xs) = do b <- f x
                         if b then go (x:ls) rs xs
                              else go ls (x:rs) xs

-- isDirectory :: FilePath -> IO Bool
-- isDirectory = fmap Posix.isDirectory . Posix.getFileStatus

concatMapM :: Applicative m => (a -> m [b]) -> [a] -> m [b]
concatMapM f []     = pure []
concatMapM f (x:xs) = (++) <$> f x <*> concatMapM f xs


