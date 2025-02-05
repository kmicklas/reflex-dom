{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

import Control.Concurrent
import Control.Monad
import Control.Monad.Catch
import Control.Monad.Fix
import Control.Monad.IO.Class
import Control.Monad.Ref
import Data.Constraint.Extras
import Data.Constraint.Extras.TH
import Data.Dependent.Map (DMap)
import Data.Dependent.Sum (DSum(..), (==>), EqTag(..), ShowTag(..))
import Data.Functor.Identity
import Data.Functor.Misc
import Data.GADT.Compare.TH
import Data.GADT.Show.TH
import Data.IORef (IORef)
import Data.Maybe
import Data.Proxy
import Data.Text (Text)
import Language.Javascript.JSaddle (syncPoint, liftJSM)
import Language.Javascript.JSaddle.Warp
import Network.HTTP.Types (status200)
import Network.Socket
import Network.Wai
import Network.WebSockets
import Reflex.Dom.Core
import Reflex.Patch.DMapWithMove
import System.Directory
import System.Environment
import System.IO (stderr)
import System.IO.Silently
import System.IO.Temp
import System.Process
import qualified Test.HUnit as HUnit (assertEqual, assertFailure)
import qualified Test.Hspec as H
import qualified Test.Hspec.Core.Spec as H
import Test.Hspec (xit)
import Test.Hspec.WebDriver hiding (runWD, click, uploadFile, WD)
import qualified Test.Hspec.WebDriver as WD
import Test.WebDriver (WD(..))

import qualified Data.ByteString.Lazy as LBS
import qualified Data.Dependent.Map as DMap
import qualified Data.IntMap as IntMap
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified GHCJS.DOM.File as File
import qualified Network.Wai.Handler.Warp as Warp
import qualified System.FilePath as FilePath
import qualified Test.WebDriver as WD
import qualified Test.WebDriver.Capabilities as WD

import Test.Util.ChromeFlags
import Test.Util.UnshareNetwork

seleniumPort, jsaddlePort :: PortNumber
seleniumPort = 8000
jsaddlePort = 8001

-- TODO Remove orphan
instance MonadRef WD where
  type Ref WD = Ref IO
  newRef = WD . newRef
  readRef = WD . readRef
  writeRef r = WD . writeRef r

assertEqual :: (MonadIO m, Eq a, Show a) => String -> a -> a -> m ()
assertEqual a b = liftIO . HUnit.assertEqual a b

assertFailure :: MonadIO m => String -> m ()
assertFailure = liftIO . HUnit.assertFailure

chromeConfig :: Text -> [Text] -> WD.WDConfig
chromeConfig fp flags = WD.useBrowser (WD.chrome { WD.chromeBinary = Just $ T.unpack fp, WD.chromeOptions = T.unpack <$> flags }) WD.defaultConfig

keyMap :: DMap DKey Identity
keyMap = DMap.fromList
  [ Key_Int ==> 0
  , Key_Char ==> 'A'
  ]

data DKey a where
  Key_Int :: DKey Int
  Key_Char :: DKey Char
  Key_Bool :: DKey Bool


textKey :: DKey a -> Text
textKey = \case
  Key_Int -> "Key_Int"
  Key_Char -> "Key_Char"
  Key_Bool -> "Key_Bool"

deriveArgDict ''DKey
deriveGEq ''DKey
deriveGCompare ''DKey
deriveGShow ''DKey

main :: IO ()
main = do
  unshareNetork
  isHeadless <- (== Nothing) <$> lookupEnv "NO_HEADLESS"
  withSandboxedChromeFlags isHeadless $ \chromeFlags -> do
    withSeleniumServer $ \selenium -> do
      browserPath <- liftIO $ T.strip . T.pack <$> readProcess "which" [ "chromium" ] ""
      when (T.null browserPath) $ fail "No browser found"
      withDebugging <- isNothing <$> lookupEnv "NO_DEBUG"
      let wdConfig = WD.defaultConfig { WD.wdPort = fromIntegral $ _selenium_portNumber selenium }
          chromeCaps' = WD.getCaps $ chromeConfig browserPath chromeFlags
      hspec (tests withDebugging wdConfig [chromeCaps'] selenium) `finally` _selenium_stopServer selenium

tests :: Bool -> WD.WDConfig -> [Capabilities] -> Selenium -> Spec
tests withDebugging wdConfig caps _selenium = do
  let putStrLnDebug :: MonadIO m => Text -> m ()
      putStrLnDebug m = when withDebugging $ liftIO $ putStrLn $ T.unpack m
      session' = sessionWith wdConfig "" . using (map (,"") caps)
      runWD m = runWDOptions (WdOptions False) $ do
        putStrLnDebug "before"
        r <- m
        putStrLnDebug "after"
        return r
      testWidgetStatic :: WD b -> (forall m js. TestWidget js (SpiderTimeline Global) m => m ()) -> WD b
      testWidgetStatic = testWidgetStaticDebug withDebugging
      testWidget :: WD () -> WD b -> (forall m js. TestWidget js (SpiderTimeline Global) m => m ()) -> WD b
      testWidget = testWidgetDebug withDebugging
      testWidget' :: WD a -> (a -> WD b) -> (forall m js. TestWidget js (SpiderTimeline Global) m => m ()) -> WD b
      testWidget' = testWidgetDebug' withDebugging
  describe "text" $ session' $ do
    it "works" $ runWD $ do
      testWidgetStatic (checkBodyText "hello world") $ do
        text "hello world"
    it "works with postBuild" $ runWD $ do
      testWidgetStatic (checkBodyText "pb") $ do
        pb <- getPostBuild
        void $ textNode $ TextNodeConfig "" $ Just $ "pb" <$ pb
    it "works for adjacent text nodes" $ runWD $ do
      testWidgetStatic (checkBodyText "hello world") $ do
        text "hello "
        text "world"
    it "works for empty adjacent text nodes" $ runWD $ do
      testWidgetStatic (checkBodyText "hello world") $ do
        pb <- getPostBuild
        text ""
        text ""
        _ <- textNode $ TextNodeConfig "" $ Just $ "hello " <$ pb
        _ <- textNode $ TextNodeConfig "abc" $ Just $ "" <$ pb
        _ <- textNode $ TextNodeConfig "" $ Just $ "world" <$ pb
        text ""
    it "works when empty text nodes are the only children of an element" $ runWD $ do
      testWidgetStatic (checkBodyText "hello world") $ do
        el "div" $ do
          text ""
          text ""
        text "hello world"
    it "works when an empty text node is the first child before text" $ runWD $ do
      testWidgetStatic (checkTextInTag "div" "hello world") $ do
        el "div" $ do
          text ""
          text "hello world"
    it "works when an empty text node is the first child before element" $ runWD $ do
      testWidgetStatic (checkTextInTag "div" "hello world") $ do
        el "div" $ do
          text ""
          el "span" $ text "hello world"
    it "works when an empty text node is the last child" $ runWD $ do
      testWidgetStatic (checkTextInTag "div" "hello world") $ do
        el "div" $ do
          el "span" $ text "hello world"
          text ""
-- TODO I think these two tests are broken
--    it "updates after postBuild" $ runWD $ do
--      testWidget (checkBodyText "initial") (checkBodyText "after") $ do
--        after <- delay 0 =<< getPostBuild
--        void $ textNode $ TextNodeConfig "initial" $ Just $ "after" <$ after
--    it "updates immediately after postBuild" $ runWD $ do
--      testWidget (checkBodyText "pb") (checkBodyText "after") $ do
--        pb <- getPostBuild
--        after <- delay 0 pb
--        void $ textNode $ TextNodeConfig "initial" $ Just $ leftmost ["pb" <$ pb, "after" <$ after]
    it "updates in immediate mode" $ runWD $ do
      let checkUpdated = do
            checkBodyText "initial"
            WD.click =<< findElemWithRetry (WD.ByTag "button")
            checkBodyText "after"
      testWidget (pure ()) checkUpdated $ prerender_ (pure ()) $ do
        click <- button ""
        void $ textNode $ TextNodeConfig "initial" $ Just $ "after" <$ click

  describe "element" $ session' $ do
    it "works with domEvent Click" $ runWD $ do
      clickedRef <- liftIO $ newRef False
      testWidget' (findElemWithRetry $ WD.ByTag "div") WD.click $ do
        (e, _) <- el' "div" $ text "hello world"
        performEvent_ $ liftIO (writeRef clickedRef True) <$ domEvent Click e
      readRef clickedRef `shouldBeWithRetryM` True
    it "works with eventFlags stopPropagation" $ runWD $ do
      firstClickedRef <- newRef False
      secondClickedRef <- newRef False
      let clickBoth = do
            findElemWithRetry (WD.ById "first") >>= WD.click
            findElemWithRetry (WD.ById "second") >>= WD.click
      testWidget (pure ()) clickBoth $ do
        (firstDivEl, _) <- el' "div" $ prerender_ (pure ()) $ do
          void $ elAttr "span" ("id" =: "first") $ text "hello world"
        performEvent_ $ liftIO (writeRef firstClickedRef True) <$ domEvent Click firstDivEl
        (secondDivEl, _) <- el' "div" $ prerender_ (pure ()) $ do
          let conf :: ElementConfig EventResult (SpiderTimeline Global) GhcjsDomSpace
              conf = (def :: ElementConfig EventResult (SpiderTimeline Global) GhcjsDomSpace)
                & initialAttributes .~ "id" =: "second"
                & elementConfig_eventSpec .~ addEventSpecFlags (Proxy :: Proxy GhcjsDomSpace) Click (\_ -> stopPropagation) def
          void $ element "span" conf $ text "hello world"
        performEvent_ $ liftIO (writeRef secondClickedRef True) <$ domEvent Click secondDivEl
      firstClicked <- readRef firstClickedRef
      secondClicked <- readRef secondClickedRef
      assertEqual "Click propagated when it should have stopped" (True, False) (firstClicked, secondClicked)
    it "works with eventFlags preventDefault" $ runWD $ do
      let click = do
            e <- findElemWithRetry $ WD.ByTag "input"
            s0 <- WD.isSelected e
            WD.click e
            s1 <- WD.isSelected e
            pure (s0, s1)
      clicked <- testWidget (pure ()) click $ prerender_ (pure ()) $ do
        let conf :: ElementConfig EventResult (SpiderTimeline Global) GhcjsDomSpace
            conf = (def :: ElementConfig EventResult (SpiderTimeline Global) GhcjsDomSpace)
              & elementConfig_eventSpec .~ addEventSpecFlags (Proxy :: Proxy GhcjsDomSpace) Click (\_ -> preventDefault) def
              & initialAttributes .~ "type" =: "checkbox"
        void $ element "input" conf $ text "hello world"
      assertEqual "Click not prevented" (False, False) clicked
    it "can add/update/remove attributes" $ runWD $ do
      let checkInitialAttrs = do
            e <- findElemWithRetry $ WD.ByTag "div"
            assertAttr e "const" (Just "const")
            assertAttr e "delete" (Just "delete")
            assertAttr e "init" (Just "init")
            assertAttr e "click" Nothing
            pure e
          checkModifyAttrs e = do
            WD.click e
            withRetry $ do
              assertAttr e "const" (Just "const")
              assertAttr e "delete" Nothing
              assertAttr e "init" (Just "click")
              assertAttr e "click" (Just "click")
      testWidget' checkInitialAttrs checkModifyAttrs $ mdo
        let conf = def
              & initialAttributes .~ "const" =: "const" <> "delete" =: "delete" <> "init" =: "init"
              & modifyAttributes .~ (("delete" =: Nothing <> "init" =: Just "click" <> "click" =: Just "click") <$ click)
        (e, ()) <- element "div" conf $ text "hello world"
        let click = domEvent Click e
        return ()

  describe "inputElement" $ do
    describe "hydration" $ session' $ do
      it "doesn't wipe user input when switching over" $ runWD $ do
        inputRef <- newRef ("" :: Text)
        testWidget'
          (do
            e <- findElemWithRetry $ WD.ByTag "input"
            WD.sendKeys "hello world" e
            pure e)
          (\e -> do
            WD.attr e "value" `shouldBeWithRetryM` Just "hello world"
            WD.click =<< findElemWithRetry (WD.ByTag "button")
            readRef inputRef `shouldBeWithRetryM` "hello world"
          ) $ do
          e <- inputElement def
          click <- button "save"
          performEvent_ $ liftIO . writeRef inputRef <$> tag (current (value e)) click
      it "captures user input after switchover" $ runWD $ do
        inputRef <- newRef ("" :: Text)
        let checkValue = do
              WD.sendKeys "hello world" =<< findElemWithRetry (WD.ByTag "input")
              WD.click =<< findElemWithRetry (WD.ByTag "button")
              readRef inputRef `shouldBeWithRetryM` "hello world"
        testWidget (pure ()) checkValue $ do
          e <- inputElement def
          click <- button "save"
          performEvent_ $ liftIO . writeRef inputRef <$> tag (current (value e)) click
      it "sets focus appropriately" $ runWD $ do
        focusRef <- newRef False
        let checkValue = do
              readRef focusRef `shouldBeWithRetryM` False
              e <- findElemWithRetry $ WD.ByTag "input"
              WD.click e
              readRef focusRef `shouldBeWithRetryM` True
        testWidget (pure ()) checkValue $ do
          e <- inputElement def
          performEvent_ $ liftIO . writeRef focusRef <$> updated (_inputElement_hasFocus e)
      it "sets focus when focus occurs before hydration" $ runWD $ do
        focusRef <- newRef False
        let setup = do
              e <- findElemWithRetry $ WD.ByTag "input"
              WD.click e
              ((== e) <$> WD.activeElem) `shouldBeWithRetryM` True
              readRef focusRef `shouldBeWithRetryM` False
            check = readRef focusRef `shouldBeWithRetryM` True
        testWidget setup check $ do
          e <- inputElement def
          performEvent_ $ liftIO . writeRef focusRef <$> updated (_inputElement_hasFocus e)
      it "sets value appropriately" $ runWD $ do
        valueByUIRef <- newRef ("" :: Text)
        valueRef <- newRef ("" :: Text)
        setValueChan :: Chan Text <- liftIO newChan
        let checkValue = do
              readRef valueByUIRef `shouldBeWithRetryM` ""
              readRef valueRef `shouldBeWithRetryM` ""
              e <- findElemWithRetry $ WD.ByTag "input"
              WD.sendKeys "hello" e
              readRef valueByUIRef `shouldBeWithRetryM` "hello"
              readRef valueRef `shouldBeWithRetryM` "hello"
              liftIO $ writeChan setValueChan "world"
              readRef valueByUIRef `shouldBeWithRetryM` "hello"
              readRef valueRef `shouldBeWithRetryM` "world"
        testWidget (pure ()) checkValue $ do
          update <- triggerEventWithChan setValueChan
          e <- inputElement $ def & inputElementConfig_setValue .~ update
          performEvent_ $ liftIO . writeRef valueByUIRef <$> _inputElement_input e
          performEvent_ $ liftIO . writeRef valueRef <$> updated (value e)
      it "sets checked appropriately" $ runWD $ do
        checkedByUIRef <- newRef False
        checkedRef <- newRef False
        setCheckedChan <- liftIO newChan
        let checkValue = do
              readRef checkedByUIRef `shouldBeWithRetryM` False
              readRef checkedRef `shouldBeWithRetryM` False
              e <- findElemWithRetry $ WD.ByTag "input"
              WD.moveToCenter e
              WD.click e
              readRef checkedByUIRef `shouldBeWithRetryM` True
              readRef checkedRef `shouldBeWithRetryM` True
              liftIO $ writeChan setCheckedChan False
              readRef checkedByUIRef `shouldBeWithRetryM` True
              readRef checkedRef `shouldBeWithRetryM` False
        testWidget (pure ()) checkValue $ do
          setChecked <- triggerEventWithChan setCheckedChan
          e <- inputElement $ def
            & initialAttributes .~ "type" =: "checkbox"
            & inputElementConfig_setChecked .~ setChecked
          performEvent_ $ liftIO . writeRef checkedByUIRef <$> _inputElement_checkedChange e
          performEvent_ $ liftIO . writeRef checkedRef <$> updated (_inputElement_checked e)
      it "captures file uploads" $ runWD $ do
        filesRef :: IORef [Text] <- newRef []
        let uploadFile = do
              e <- findElemWithRetry $ WD.ByTag "input"
              path <- liftIO $ writeSystemTempFile "testFile" "file contents"
              WD.sendKeys (T.pack path) e
              WD.click =<< findElemWithRetry (WD.ByTag "button")
              liftIO $ removeFile path
              readRef filesRef `shouldBeWithRetryM` [T.pack $ FilePath.takeFileName path]
        testWidget (pure ()) uploadFile $ do
          e <- inputElement $ def & initialAttributes .~ "type" =: "file"
          click <- button "save"
          prerender_ (pure ()) $ performEvent_ $ ffor (tag (current (_inputElement_files e)) click) $ \fs -> do
            names <- liftJSM $ traverse File.getName fs
            liftIO $ writeRef filesRef names

    describe "hydration/immediate" $ session' $ do
      it "captures user input after switchover" $ runWD $ do
        inputRef :: IORef Text <- newRef ""
        let checkValue = do
              WD.sendKeys "hello world" =<< findElemWithRetry (WD.ByTag "input")
              WD.click =<< findElemWithRetry (WD.ByTag "button")
              readRef inputRef `shouldBeWithRetryM` "hello world"
        testWidget (pure ()) checkValue $ prerender_ (pure ()) $ do
          e <- inputElement def
          click <- button "save"
          performEvent_ $ liftIO . writeRef inputRef <$> tag (current (value e)) click
      it "sets focus appropriately" $ runWD $ do
        focusRef <- newRef False
        let checkValue = do
              readRef focusRef `shouldBeWithRetryM` False
              e <- findElemWithRetry $ WD.ByTag "input"
              WD.click e
              readRef focusRef `shouldBeWithRetryM` True
        testWidget (pure ()) checkValue $ prerender_ (pure ()) $ do
          e <- inputElement def
          performEvent_ $ liftIO . writeRef focusRef <$> updated (_inputElement_hasFocus e)
      it "sets value appropriately" $ runWD $ do
        valueByUIRef :: IORef Text <- newRef ""
        valueRef :: IORef Text <- newRef ""
        setValueChan :: Chan Text <- liftIO newChan
        let checkValue = do
              readRef valueByUIRef `shouldBeWithRetryM` ""
              readRef valueRef `shouldBeWithRetryM` ""
              e <- findElemWithRetry $ WD.ByTag "input"
              WD.sendKeys "hello" e
              readRef valueByUIRef `shouldBeWithRetryM` "hello"
              readRef valueRef `shouldBeWithRetryM` "hello"
              liftIO $ writeChan setValueChan "world"
              readRef valueByUIRef `shouldBeWithRetryM` "hello"
              readRef valueRef `shouldBeWithRetryM` "world"
        testWidget (pure ()) checkValue $ do
          update <- triggerEventWithChan setValueChan
          prerender_ (pure ()) $ do
            e <- inputElement $ def & inputElementConfig_setValue .~ update
            performEvent_ $ liftIO . writeRef valueByUIRef <$> _inputElement_input e
            performEvent_ $ liftIO . writeRef valueRef <$> updated (value e)
      it "sets checked appropriately" $ runWD $ do
        checkedByUIRef <- newRef False
        checkedRef <- newRef False
        setCheckedChan <- liftIO newChan
        let checkValue = do
              readRef checkedByUIRef `shouldBeWithRetryM` False
              readRef checkedRef `shouldBeWithRetryM` False
              e <- findElemWithRetry $ WD.ByTag "input"
              WD.moveToCenter e
              WD.click e
              readRef checkedByUIRef `shouldBeWithRetryM` True
              readRef checkedRef `shouldBeWithRetryM` True
              liftIO $ writeChan setCheckedChan False
              readRef checkedByUIRef `shouldBeWithRetryM` True
              readRef checkedRef `shouldBeWithRetryM` False
        testWidget (pure ()) checkValue $ do
          setChecked <- triggerEventWithChan setCheckedChan
          prerender_ (pure ()) $ do
            e <- inputElement $ def
              & initialAttributes .~ "type" =: "checkbox"
              & inputElementConfig_setChecked .~ setChecked
            performEvent_ $ liftIO . writeRef checkedByUIRef <$> _inputElement_checkedChange e
            performEvent_ $ liftIO . writeRef checkedRef <$> updated (_inputElement_checked e)
      it "captures file uploads" $ runWD $ do
        filesRef :: IORef [Text] <- newRef []
        let uploadFile = do
              e <- findElemWithRetry $ WD.ByTag "input"
              path <- liftIO $ writeSystemTempFile "testFile" "file contents"
              WD.sendKeys (T.pack path) e
              WD.click =<< findElemWithRetry (WD.ByTag "button")
              liftIO $ removeFile path
              readRef filesRef `shouldBeWithRetryM` [T.pack $ FilePath.takeFileName path]
        testWidget (pure ()) uploadFile $ prerender_ (pure ()) $ do
          e <- inputElement $ def & initialAttributes .~ "type" =: "file"
          click <- button "save"
          performEvent_ $ ffor (tag (current (_inputElement_files e)) click) $ \fs -> do
            names <- liftJSM $ traverse File.getName fs
            liftIO $ writeRef filesRef names

  describe "textAreaElement" $ do
    describe "hydration" $ session' $ do
      it "doesn't wipe user input when switching over" $ runWD $ do
        inputRef <- newRef ("" :: Text)
        testWidget'
          (do
            e <- findElemWithRetry $ WD.ByTag "textarea"
            WD.sendKeys "hello world" e
            pure e)
          (\e -> do
            WD.attr e "value" `shouldBeWithRetryM` Just "hello world"
            WD.click <=< findElemWithRetry $ WD.ByTag "button"
            readRef inputRef `shouldBeWithRetryM` "hello world"
          ) $ do
          e <- textAreaElement def
          click <- button "save"
          performEvent_ $ liftIO . writeRef inputRef <$> tag (current (value e)) click
      it "captures user input after switchover" $ runWD $ do
        inputRef <- newRef ("" :: Text)
        let checkValue = do
              WD.sendKeys "hello world" =<< findElemWithRetry (WD.ByTag "textarea")
              WD.click =<< findElemWithRetry (WD.ByTag "button")
              readRef inputRef `shouldBeWithRetryM` "hello world"
        testWidget (pure ()) checkValue $ do
          e <- textAreaElement def
          click <- button "save"
          performEvent_ $ liftIO . writeRef inputRef <$> tag (current (value e)) click
      it "sets focus appropriately" $ runWD $ do
        focusRef <- newRef False
        let checkValue = do
              readRef focusRef `shouldBeWithRetryM` False
              e <- findElemWithRetry $ WD.ByTag "textarea"
              WD.click e
              readRef focusRef `shouldBeWithRetryM` True
        testWidget (pure ()) checkValue $ do
          e <- textAreaElement def
          performEvent_ $ liftIO . writeRef focusRef <$> updated (_textAreaElement_hasFocus e)
      it "sets focus when focus occurs before hydration" $ runWD $ do
        focusRef <- newRef False
        let setup = do
              e <- findElemWithRetry $ WD.ByTag "textarea"
              WD.click e
              ((== e) <$> WD.activeElem) `shouldBeWithRetryM` True
              readRef focusRef `shouldBeWithRetryM` False
            check = readRef focusRef `shouldBeWithRetryM` True
        testWidget setup check $ do
          e <- textAreaElement def
          performEvent_ $ liftIO . writeRef focusRef <$> updated (_textAreaElement_hasFocus e)
      it "sets value appropriately" $ runWD $ do
        valueByUIRef <- newRef ("" :: Text)
        valueRef <- newRef ("" :: Text)
        setValueChan :: Chan Text <- liftIO newChan
        let checkValue = do
              readRef valueByUIRef `shouldBeWithRetryM` ""
              readRef valueRef `shouldBeWithRetryM` ""
              e <- findElemWithRetry $ WD.ByTag "textarea"
              WD.sendKeys "hello" e
              readRef valueByUIRef `shouldBeWithRetryM` "hello"
              readRef valueRef `shouldBeWithRetryM` "hello"
              liftIO $ writeChan setValueChan "world"
              readRef valueByUIRef `shouldBeWithRetryM` "hello"
              readRef valueRef `shouldBeWithRetryM` "world"
        testWidget (pure ()) checkValue $ do
          setValue' <- triggerEventWithChan setValueChan
          e <- textAreaElement $ def { _textAreaElementConfig_setValue = Just setValue' }
          performEvent_ $ liftIO . writeRef valueByUIRef <$> _textAreaElement_input e
          performEvent_ $ liftIO . writeRef valueRef <$> updated (value e)

    describe "hydration/immediate" $ session' $ do
      it "captures user input after switchover" $ runWD $ do
        inputRef :: IORef Text <- newRef ""
        let checkValue = do
              WD.sendKeys "hello world" <=< findElemWithRetry $ WD.ByTag "textarea"
              WD.click <=< findElemWithRetry $ WD.ByTag "button"
              readRef inputRef `shouldBeWithRetryM` "hello world"
        testWidget (pure ()) checkValue $ prerender_ (pure ()) $ do
          e <- textAreaElement def
          click <- button "save"
          performEvent_ $ liftIO . writeRef inputRef <$> tag (current (value e)) click
      it "sets focus appropriately" $ runWD $ do
        focusRef <- newRef False
        let checkValue = do
              readRef focusRef `shouldBeWithRetryM` False
              e <- findElemWithRetry $ WD.ByTag "textarea"
              WD.click e
              readRef focusRef `shouldBeWithRetryM` True
        testWidget (pure ()) checkValue $ prerender_ (pure ()) $ do
          e <- textAreaElement def
          performEvent_ $ liftIO . writeRef focusRef <$> updated (_textAreaElement_hasFocus e)
      it "sets value appropriately" $ runWD $ do
        valueByUIRef :: IORef Text <- newRef ""
        valueRef :: IORef Text <- newRef ""
        setValueChan :: Chan Text <- liftIO newChan
        let checkValue = do
              readRef valueByUIRef `shouldBeWithRetryM` ""
              readRef valueRef `shouldBeWithRetryM` ""
              e <- findElemWithRetry $ WD.ByTag "textarea"
              WD.sendKeys "hello" e
              readRef valueByUIRef `shouldBeWithRetryM` "hello"
              readRef valueRef `shouldBeWithRetryM` "hello"
              liftIO $ writeChan setValueChan "world"
              readRef valueByUIRef `shouldBeWithRetryM` "hello"
              readRef valueRef `shouldBeWithRetryM` "world"
        testWidget (pure ()) checkValue $ do
          setValue' <- triggerEventWithChan setValueChan
          prerender_ (pure ()) $ do
            e <- textAreaElement $ def { _textAreaElementConfig_setValue = Just setValue' }
            performEvent_ $ liftIO . writeRef valueByUIRef <$> _textAreaElement_input e
            performEvent_ $ liftIO . writeRef valueRef <$> updated (value e)

  describe "selectElement" $ do
    let options :: DomBuilder t m => m ()
        options = do
          elAttr "option" ("value" =: "one" <> "id" =: "one") $ text "one"
          elAttr "option" ("value" =: "two" <> "id" =: "two") $ text "two"
          elAttr "option" ("value" =: "three" <> "id" =: "three") $ text "three"
    describe "hydration" $ session' $ do
      it "sets initial value correctly" $ runWD $ do
        inputRef <- newRef ("" :: Text)
        let setup = do
              e <- findElemWithRetry $ WD.ByTag "select"
              assertAttr e "value" (Just "three")
              WD.click =<< findElemWithRetry (WD.ById "two")
              pure e
            check e = do
              assertAttr e "value" (Just "two")
              readRef inputRef `shouldBeWithRetryM` "three"
              WD.click =<< findElemWithRetry (WD.ByTag "button")
              assertAttr e "value" (Just "two")
              readRef inputRef `shouldBeWithRetryM` "two"
        testWidget' setup check $ do
          (e, ()) <- selectElement (def { _selectElementConfig_initialValue = "three" }) options
          click <- button "save"
          liftIO . writeRef inputRef <=< sample $ current $ _selectElement_value e
          performEvent_ $ liftIO . writeRef inputRef <$> tag (current (_selectElement_value e)) click
      it "captures user input after switchover" $ runWD $ do
        inputRef <- newRef ("" :: Text)
        let checkValue = do
              e <- findElemWithRetry $ WD.ByTag "select"
              assertAttr e "value" (Just "one")
              WD.click =<< findElemWithRetry (WD.ById "two")
              assertAttr e "value" (Just "two")
              WD.click =<< findElemWithRetry (WD.ByTag "button")
              readRef inputRef `shouldBeWithRetryM` "two"
        testWidget (pure ()) checkValue $ do
          (e, ()) <- selectElement def options
          click <- button "save"
          performEvent_ $ liftIO . writeRef inputRef <$> tag (current (_selectElement_value e)) click
      it "sets focus appropriately" $ runWD $ do
        focusRef <- newRef False
        let checkValue = do
              readRef focusRef `shouldBeWithRetryM` False
              e <- findElemWithRetry $ WD.ByTag "select"
              WD.click e
              readRef focusRef `shouldBeWithRetryM` True
        testWidget (pure ()) checkValue $ do
          (e, ()) <- selectElement def options
          performEvent_ $ liftIO . writeRef focusRef <$> updated (_selectElement_hasFocus e)
      it "sets focus when focus occurs before hydration" $ runWD $ do
        focusRef <- newRef False
        let setup = do
              e <- findElemWithRetry $ WD.ByTag "select"
              WD.click e
              ((== e) <$> WD.activeElem) `shouldBeWithRetryM` True
              readRef focusRef `shouldBeWithRetryM` False
            check = readRef focusRef `shouldBeWithRetryM` True
        testWidget setup check $ do
          (e, ()) <- selectElement def options
          performEvent_ $ liftIO . writeRef focusRef <$> updated (_selectElement_hasFocus e)
      it "sets value appropriately" $ runWD $ do
        valueByUIRef <- newRef ("" :: Text)
        valueRef <- newRef ("" :: Text)
        setValueChan :: Chan Text <- liftIO newChan
        let checkValue = do
              e <- findElemWithRetry $ WD.ByTag "select"
              assertAttr e "value" (Just "one")
              readRef valueByUIRef `shouldBeWithRetryM` "one"
              readRef valueRef `shouldBeWithRetryM` "one"
              WD.click <=< findElemWithRetry $ WD.ById "two"
              readRef valueByUIRef `shouldBeWithRetryM` "two"
              readRef valueRef `shouldBeWithRetryM` "two"
              liftIO $ writeChan setValueChan "three"
              readRef valueByUIRef `shouldBeWithRetryM` "two"
              readRef valueRef `shouldBeWithRetryM` "three"
        testWidget (pure ()) checkValue $ do
          setValue' <- triggerEventWithChan setValueChan
          (e, ()) <- selectElement def { _selectElementConfig_setValue = Just setValue' } options
          performEvent_ $ liftIO . writeRef valueByUIRef <$> _selectElement_change e
          performEvent_ $ liftIO . writeRef valueRef <$> updated (_selectElement_value e)

    describe "hydration/immediate" $ session' $ do
      it "captures user input after switchover" $ runWD $ do
        inputRef :: IORef Text <- newRef ""
        let checkValue = do
              WD.click <=< findElemWithRetry $ WD.ById "two"
              WD.click <=< findElemWithRetry $ WD.ByTag "button"
              readRef inputRef `shouldBeWithRetryM` "two"
        testWidget (pure ()) checkValue $ prerender_ (pure ()) $ do
          (e, ()) <- selectElement def options
          click <- button "save"
          performEvent_ $ liftIO . writeRef inputRef <$> tag (current (_selectElement_value e)) click
      it "sets focus appropriately" $ runWD $ do
        focusRef <- newRef False
        let checkValue = do
              readRef focusRef `shouldBeWithRetryM` False
              e <- findElemWithRetry $ WD.ByTag "select"
              WD.click e
              readRef focusRef `shouldBeWithRetryM` True
        testWidget (pure ()) checkValue $ prerender_ (pure ()) $ do
          (e, ()) <- selectElement def options
          performEvent_ $ liftIO . writeRef focusRef <$> updated (_selectElement_hasFocus e)
      it "has correct initial value" $ runWD $ do
        valueRef :: IORef Text <- newRef ""
        let checkValue = readRef valueRef `shouldBeWithRetryM` "one"
        testWidget (pure ()) checkValue $ do
          prerender_ (pure ()) $ do
            (e, ()) <- selectElement def { _selectElementConfig_initialValue = "one" } options
            liftIO . writeRef valueRef <=< sample $ current $ _selectElement_value e
      it "sets value appropriately" $ runWD $ do
        valueByUIRef :: IORef Text <- newRef ""
        valueRef :: IORef Text <- newRef ""
        setValueChan :: Chan Text <- liftIO newChan
        let checkValue = do
              WD.click =<< findElemWithRetry (WD.ById "two")
              readRef valueByUIRef `shouldBeWithRetryM` "two"
              readRef valueRef `shouldBeWithRetryM` "two"
              liftIO $ writeChan setValueChan "three"
              readRef valueByUIRef `shouldBeWithRetryM` "two"
              readRef valueRef `shouldBeWithRetryM` "three"
        testWidget (pure ()) checkValue $ do
          setValue' <- triggerEventWithChan setValueChan
          prerender_ (pure ()) $ do
            (e, ()) <- selectElement def { _selectElementConfig_setValue = Just setValue' } options
            performEvent_ $ liftIO . writeRef valueByUIRef <$> _selectElement_change e
            performEvent_ $ liftIO . writeRef valueRef <$> updated (_selectElement_value e)

  describe "prerender" $ session' $ do
    it "works in simple case" $ runWD $ do
      testWidget (checkBodyText "One") (checkBodyText "Two") $ do
        prerender_ (text "One") (text "Two")
    it "removes element correctly" $ runWD $ do
      testWidget' (findElemWithRetry $ WD.ByTag "span") elementShouldBeRemoved $ do
        prerender_ (el "span" $ text "One") (text "Two")
    it "can be nested in server widget" $ runWD $ do
      testWidget (checkBodyText "One") (checkBodyText "Three") $ do
        prerender_ (prerender_ (text "One") (text "Two")) (text "Three")
    it "can be nested in client widget" $ runWD $ do
      testWidget (checkBodyText "One") (checkBodyText "Three") $ do
        prerender_ (text "One") (prerender_ (text "Two") (text "Three"))
    it "works with prerender_ siblings" $ runWD $ do
      testWidget
        (checkTextInId "a1" "One" >> checkTextInId "b1" "Three" >> checkTextInId "c1" "Five")
        (checkTextInId "a2" "Two" >> checkTextInId "b2" "Four" >> checkTextInId "c2" "Six") $ do
          prerender_ (divId "a1" $ text "One") (divId "a2" $ text "Two")
          prerender_ (divId "b1" $ text "Three") (divId "b2" $ text "Four")
          prerender_ (divId "c1" $ text "Five") (divId "c2" $ text "Six")
    it "works inside other element" $ runWD $ do
      testWidget (checkTextInTag "div" "One") (checkTextInTag "div" "Two") $ do
        el "div" $ prerender_ (text "One") (text "Two")
-- TODO re-enable this
--    it "places fences and removes them" $ runWD $ do
--      testWidget'
--        (do
--          scripts <- WD.findElems $ WD.ByTag "script"
--          filterM (\s -> maybe False (\t -> "prerender" `T.isPrefixOf` t) <$> WD.attr s "type") scripts
--        )
--        (traverse_ elementShouldBeRemoved)
--        (el "span" $ prerender_ (text "One") (text "Two"))
    it "postBuild works on server side" $ runWD $ do
      lock :: MVar () <- liftIO newEmptyMVar
      testWidget (liftIO $ takeMVar lock) (pure ()) $ do
        prerender_ (do
          pb <- getPostBuild
          performEvent_ $ liftIO (putMVar lock ()) <$ pb) blank
    it "postBuild works on client side" $ runWD $ do
      lock :: MVar () <- liftIO newEmptyMVar
      testWidget (pure ()) (liftIO $ takeMVar lock) $ do
        prerender_ blank $ do
          pb <- getPostBuild
          performEvent_ $ liftIO (putMVar lock ()) <$ pb
    it "result Dynamic is updated *after* switchover" $ runWD $ do
      let static = checkBodyText "PostBuild"
          check = checkBodyText "Client"
      testWidget static check $ void $ do
        d <- prerender (pure "Initial") (pure "Client")
        pb <- getPostBuild
        initial <- sample $ current d
        textNode $ TextNodeConfig initial $ Just $ leftmost [updated d, "PostBuild" <$ pb]
    -- This essentially checks that the client IO runs *after* switchover/postBuild,
    -- thus can't create conflicting DOM
    it "can't exploit IO to break hydration" $ runWD $ do
      let static = checkBodyText "Initial"
      testWidgetStatic static $ void $ do
        ref <- liftIO $ newRef "Initial"
        prerender_ (pure ()) (liftIO $ writeRef ref "Client")
        text <=< liftIO $ readRef ref
    -- As above, so below
    it "can't exploit triggerEvent to break hydration" $ runWD $ do
      let static = checkBodyText "Initial"
          check = checkBodyText "Client"
      testWidget static check $ void $ do
        (e, trigger) <- newTriggerEvent
        prerender_ (pure ()) (liftIO $ trigger "Client")
        textNode $ TextNodeConfig "Initial" $ Just e

  describe "runWithReplace" $ session' $ do
    it "works" $ runWD $ do
      replaceChan :: Chan Text <- liftIO newChan
      let setup = findElemWithRetry $ WD.ByTag "div"
          check ssr = do
            -- Check that the original element still exists and has the correct text
            shouldContainText "two" ssr
            liftIO $ writeChan replaceChan "three"
            elementShouldBeRemoved ssr
            shouldContainText "three" =<< findElemWithRetry (WD.ByTag "span")
      testWidget' setup check $ do
        replace <- triggerEventWithChan replaceChan
        pb <- getPostBuild
        void $ runWithReplace (el "div" $ text "one") $ leftmost
          [ el "div" (text "two") <$ pb
          , el "span" . text <$> replace
          ]
    it "can be nested in initial widget" $ runWD $ do
      replaceChan :: Chan Text <- liftIO newChan
      let setup = findElemWithRetry $ WD.ByTag "div"
          check ssr = do
            -- Check that the original element still exists and has the correct text
            shouldContainText "two" ssr
            liftIO $ writeChan replaceChan "three"
            elementShouldBeRemoved ssr
            shouldContainText "three" =<< findElemWithRetry (WD.ByTag "span")
      testWidget' setup check $ void $ flip runWithReplace never $ do
        replace <- triggerEventWithChan replaceChan
        pb <- getPostBuild
        void $ runWithReplace (el "div" $ text "one") $ leftmost
          [ el "div" (text "two") <$ pb
          , el "span" . text <$> replace
          ]
    it "can be nested in postBuild widget" $ runWD $ do
      replaceChan :: Chan Text <- liftIO newChan
      let setup = findElemWithRetry $ WD.ByTag "div"
          check ssr = do
            -- Check that the original element still exists and has the correct text
            shouldContainText "two" ssr
            liftIO $ writeChan replaceChan "three"
            elementShouldBeRemoved ssr
            shouldContainText "three" =<< findElemWithRetry (WD.ByTag "span")
      testWidget' setup check $ void $ do
        pb <- getPostBuild
        runWithReplace (pure ()) $ ffor pb $ \() -> do
          replace <- triggerEventWithChan replaceChan
          pb' <- getPostBuild
          void $ runWithReplace (el "div" $ text "one") $ leftmost
            [ el "div" (text "two") <$ pb'
            , el "span" . text <$> replace
            ]
    it "postBuild works in replaced widget" $ runWD $ do
      replaceChan <- liftIO newChan
      pbLock <- liftIO newEmptyMVar
      let check = liftIO $ do
            writeChan replaceChan ()
            takeMVar pbLock
      testWidget (pure ()) check $ void $ do
        replace <- triggerEventWithChan replaceChan
        runWithReplace (pure ()) $ ffor replace $ \() -> do
          pb <- getPostBuild
          performEvent_ $ liftIO (putMVar pbLock ()) <$ pb
    it "can be nested in event widget" $ runWD $ do
      replaceChan1 :: Chan Text <- liftIO newChan
      replaceChan2 :: Chan Text <- liftIO newChan
      lock :: MVar () <- liftIO newEmptyMVar
      let check = do
            shouldContainText "" =<< findElemWithRetry (WD.ByTag "body")
            liftIO $ do
              writeChan replaceChan1 "one"
              takeMVar lock
            one <- findElemWithRetry $ WD.ByTag "div"
            shouldContainText "pb" one
            liftIO $ writeChan replaceChan2 "two"
            elementShouldBeRemoved one
            shouldContainText "two" =<< findElemWithRetry (WD.ByTag "span")
      testWidget (pure ()) check $ void $ do
        replace1 <- triggerEventWithChan replaceChan1
        runWithReplace (pure ()) $ ffor replace1 $ \r1 -> do
          replace2 <- triggerEventWithChan replaceChan2
          pb <- getPostBuild
          performEvent_ $ liftIO (putMVar lock ()) <$ pb
          void $ runWithReplace (el "div" $ text r1) $ leftmost
            [ el "span" . text <$> replace2
            , el "div" (text "pb") <$ pb
            ]
    it "prerender works in replaced widget" $ runWD $ do
      replaceChan <- liftIO newChan
      lock :: MVar () <- liftIO newEmptyMVar
      pbLock :: MVar () <- liftIO newEmptyMVar
      let check = do
            liftIO $ do
              writeChan replaceChan ()
              takeMVar lock
              takeMVar pbLock
      testWidget (pure ()) check $ void $ do
        replace <- triggerEventWithChan replaceChan
        runWithReplace (pure ()) $ ffor replace $ \() -> do
          prerender_ (pure ()) $ do
            liftIO $ putMVar lock ()
            pb <- getPostBuild
            performEvent_ $ liftIO (putMVar pbLock ()) <$ pb
    it "prerender returns in immediate mode" $ runWD $ do
      replaceChan <- liftIO newChan
      pbLock <- liftIO newEmptyMVar
      let check = liftIO $ do
            writeChan replaceChan ()
            takeMVar pbLock
      testWidget (pure ()) check $ void $ do
        replace <- triggerEventWithChan replaceChan
        runWithReplace (pure ()) $ ffor replace $ \() -> do
          prerender_ (pure ()) (pure ())
          liftIO $ putMVar pbLock ()
    it "works in immediate mode (RHS of prerender)" $ runWD $ do
      replaceChan :: Chan Text <- liftIO newChan
      let check = do
            checkBodyText "one"
            one <- findElemWithRetry $ WD.ByTag "div"
            shouldContainText "one" one
            liftIO $ writeChan replaceChan "pb"
            elementShouldBeRemoved one
            shouldContainText "pb" =<< findElemWithRetry (WD.ByTag "span")
      testWidget (pure ()) check $ void $ do
        replace <- triggerEventWithChan replaceChan
        prerender_ blank $ do
          void $ runWithReplace (el "div" $ text "one") $ el "span" . text <$> replace
    it "works with postBuild in immediate mode (RHS of prerender)" $ runWD $ do
      replaceChan :: Chan Text <- liftIO newChan
      let check = do
            checkBodyText "two"
            two <- findElemWithRetry $ WD.ByTag "div"
            shouldContainText "two" two
            liftIO $ writeChan replaceChan "three"
            elementShouldBeRemoved two
            shouldContainText "three" =<< findElemWithRetry (WD.ByTag "span")
      testWidget (pure ()) check $ void $ do
        replace <- triggerEventWithChan replaceChan
        prerender_ blank $ do
          pb <- getPostBuild
          void $ runWithReplace (el "div" $ text "one") $ leftmost
            [ el "div" (text "two") <$ pb
            , el "span" . text <$> replace
            ]

  describe "traverseDMapWithKeyWithAdjust" $ session' $ do
    let widget :: DomBuilder t m => DKey a -> Identity a -> m (Identity a)
        widget k (Identity v) = elAttr "li" ("id" =: textKey k) $ do
          elClass "span" "key" $ text $ textKey k
          elClass "span" "value" $ text $ T.pack $ has @Show k $ show v
          pure (Identity v)
        checkItem :: WD.Element -> Text -> Text -> WD ()
        checkItem li k v = do
          putStrLnDebug "checkItem"
          shouldContainTextNoRetry k =<< WD.findElemFrom li (WD.ByClass "key")
          shouldContainTextNoRetry v =<< WD.findElemFrom li (WD.ByClass "value")
        checkInitialItems dm xs = do
          putStrLnDebug "checkInitialItems"
          liftIO $ assertEqual "Wrong amount of items in DOM" (DMap.size dm) (length xs)
          forM_ (zip xs (DMap.toList dm)) $ \(e, k :=> Identity v) -> checkItem e (textKey k) (T.pack $ has @Show k $ show v)
        getAndCheckInitialItems dm = withRetry $ do
          putStrLnDebug "getAndCheckInitialItems"
          xs <- WD.findElems (WD.ByTag "li")
          checkInitialItems dm xs
          pure xs
        checkRemoval chan k = do
          putStrLnDebug "checkRemoval"
          e <- findElemWithRetry (WD.ById $ textKey k)
          liftIO $ writeChan chan $ PatchDMap $ DMap.singleton k (ComposeMaybe Nothing)
          elementShouldBeRemoved e
        checkReplace chan k v = do
          putStrLnDebug "checkReplace"
          e <- findElemWithRetry (WD.ById $ textKey k)
          liftIO $ writeChan chan $ PatchDMap $ DMap.singleton k (ComposeMaybe $ Just $ Identity v)
          elementShouldBeRemoved e
          e' <- findElemWithRetry $ WD.ById $ textKey k
          checkItem e' (textKey k) (T.pack $ show v)
        checkInsert chan k v = do
          putStrLnDebug "checkInsert"
          liftIO $ writeChan chan $ PatchDMap $ DMap.singleton k (ComposeMaybe $ Just $ Identity v)
          e <- findElemWithRetry (WD.ById $ textKey k)
          checkItem e (textKey k) (T.pack $ show v)
        postBuildPatch = PatchDMap $ DMap.fromList [Key_Char :=> ComposeMaybe Nothing, Key_Bool :=> ComposeMaybe (Just $ Identity True)]
    it "doesn't replace elements at switchover, can delete/update/insert" $ runWD $ do
      chan <- liftIO newChan
      let static :: WD [WD.Element]
          static = getAndCheckInitialItems keyMap
          check :: [WD.Element] -> WD ()
          check xs = do
            checkInitialItems keyMap xs
            checkRemoval chan Key_Int
            checkReplace chan Key_Char 'B'
            checkInsert chan Key_Bool True
      testWidget' static check $ do
        (dmap, _evt) <- traverseDMapWithKeyWithAdjust widget keyMap =<< triggerEventWithChan chan
        liftIO $ dmap `H.shouldBe` keyMap
    it "handles postBuild correctly" $ runWD $ do
      chan <- liftIO newChan
      let static = getAndCheckInitialItems $ applyAlways postBuildPatch keyMap
          check xs = do
            withRetry $ checkInitialItems (applyAlways postBuildPatch keyMap) xs
            checkRemoval chan Key_Int
            checkInsert chan Key_Char 'B'
            checkReplace chan Key_Bool True
      testWidget' static check $ void $ do
        pb <- getPostBuild
        replace <- triggerEventWithChan chan
        (dmap, _evt) <- traverseDMapWithKeyWithAdjust widget keyMap $ leftmost [postBuildPatch <$ pb, replace]
        liftIO $ dmap `H.shouldBe` keyMap
    it "can delete/update/insert when built in prerender" $ runWD $ do
      chan <- liftIO newChan
      let check = do
            _ <- getAndCheckInitialItems keyMap
            checkRemoval chan Key_Int
            checkReplace chan Key_Char 'B'
            checkInsert chan Key_Bool True
      testWidget (pure ()) check $ do
        replace <- triggerEventWithChan chan
        prerender_ (pure ()) $ do
          (dmap, _evt) <- traverseDMapWithKeyWithAdjust widget keyMap replace
          liftIO $ dmap `H.shouldBe` keyMap
    it "can delete/update/insert when built in immediate mode" $ runWD $ do
      chan <- liftIO newChan
      let check = do
            _ <- getAndCheckInitialItems keyMap
            checkRemoval chan Key_Int
            checkReplace chan Key_Char 'B'
            checkInsert chan Key_Bool True
      testWidget (pure ()) check $ void $ do
        pb <- getPostBuild
        runWithReplace (pure ()) $ ffor pb $ \() -> void $ do
          (dmap, _evt) <- traverseDMapWithKeyWithAdjust widget keyMap =<< triggerEventWithChan chan
          liftIO $ dmap `H.shouldBe` keyMap
    -- Should be fixed by prerender changes!
    it "handles postBuild correctly in prerender" $ runWD $ do
      chan <- liftIO newChan
      let check = do
            _ <- getAndCheckInitialItems $ applyAlways postBuildPatch keyMap
            checkRemoval chan Key_Int
            checkInsert chan Key_Char 'B'
            checkReplace chan Key_Bool True
      testWidget (pure ()) check $ do
        replace <- triggerEventWithChan chan
        prerender_ (pure ()) $ void $ do
          pb <- getPostBuild
          (dmap, _evt) <- traverseDMapWithKeyWithAdjust widget keyMap $ leftmost [postBuildPatch <$ pb, replace]
          liftIO $ dmap `H.shouldBe` keyMap

  describe "traverseIntMapWithKeyWithAdjust" $ session' $ do
    let textKeyInt k = "key" <> T.pack (show k)
        intMap = IntMap.fromList
          [ (1, "one")
          , (2, "two")
          , (3, "three")
          ]
    let widget :: DomBuilder t m => IntMap.Key -> Text -> m Text
        widget k v = elAttr "li" ("id" =: textKeyInt k) $ do
          elClass "span" "key" $ text $ textKeyInt k
          elClass "span" "value" $ text v
          pure v
        checkItem :: WD.Element -> Text -> Text -> WD ()
        checkItem li k v = do
          putStrLnDebug "checkItem"
          shouldContainTextNoRetry k =<< WD.findElemFrom li (WD.ByClass "key")
          shouldContainTextNoRetry v =<< WD.findElemFrom li (WD.ByClass "value")
        checkInitialItems dm xs = do
          putStrLnDebug "checkInitialItems"
          liftIO $ assertEqual "Wrong amount of items in DOM" (IntMap.size dm) (length xs)
          forM_ (zip xs (IntMap.toList dm)) $ \(e, (k, v)) -> checkItem e (textKeyInt k) v
        getAndCheckInitialItems dm = withRetry $ do
          putStrLnDebug "getAndCheckInitialItems"
          xs <- WD.findElems (WD.ByTag "li")
          checkInitialItems dm xs
          pure xs
        checkRemoval chan k = do
          putStrLnDebug "checkRemoval"
          e <- findElemWithRetry (WD.ById $ textKeyInt k)
          liftIO $ writeChan chan $ PatchIntMap $ IntMap.singleton k Nothing
          elementShouldBeRemoved e
        checkReplace chan k v = do
          putStrLnDebug "checkReplace"
          e <- findElemWithRetry (WD.ById $ textKeyInt k)
          liftIO $ writeChan chan $ PatchIntMap $ IntMap.singleton k $ Just v
          elementShouldBeRemoved e
          e' <- findElemWithRetry (WD.ById $ textKeyInt k)
          withRetry $ checkItem e' (textKeyInt k) v
        checkInsert chan k v = do
          putStrLnDebug "checkInsert"
          liftIO $ writeChan chan $ PatchIntMap $ IntMap.singleton k $ Just v
          e <- findElemWithRetry (WD.ById $ textKeyInt k)
          checkItem e (textKeyInt k) v
        postBuildPatch = PatchIntMap $ IntMap.fromList [(2, Nothing), (3, Just "trois"), (4, Just "four")]
    xit "doesn't replace elements at switchover, can delete/update/insert" $ runWD $ do
      chan <- liftIO newChan
      let static = getAndCheckInitialItems intMap
          check xs = do
            checkInitialItems intMap xs
            checkRemoval chan 1
            checkReplace chan 2 "deux"
            checkInsert chan 4 "four"
      testWidget' static check $ void $ do
        (im, _evt) <- traverseIntMapWithKeyWithAdjust widget intMap =<< triggerEventWithChan chan
        liftIO $ im `H.shouldBe` intMap
    xit "handles postBuild correctly" $ runWD $ do
      chan <- liftIO newChan
      let static = getAndCheckInitialItems $ applyAlways postBuildPatch intMap
          check xs = do
            withRetry $ checkInitialItems (applyAlways postBuildPatch intMap) xs
            checkRemoval chan 1
            checkInsert chan 2 "deux"
            checkReplace chan 3 "trois"
      testWidget' static check $ void $ do
        pb <- getPostBuild
        replace <- triggerEventWithChan chan
        (dmap, _evt) <- traverseIntMapWithKeyWithAdjust widget intMap $ leftmost [postBuildPatch <$ pb, replace]
        liftIO $ dmap `H.shouldBe` intMap
    xit "can delete/update/insert when built in prerender" $ runWD $ do
      chan <- liftIO newChan
      let check = do
            _ <- getAndCheckInitialItems intMap
            checkRemoval chan 1
            checkReplace chan 2 "deux"
            checkInsert chan 4 "quatre"
      testWidget (pure ()) check $ do
        replace <- triggerEventWithChan chan
        prerender_ (pure ()) $ do
          (dmap, _evt) <- traverseIntMapWithKeyWithAdjust widget intMap replace
          liftIO $ dmap `H.shouldBe` intMap
    xit "can delete/update/insert when built in immediate mode" $ runWD $ do
      chan <- liftIO newChan
      let check = do
            _ <- getAndCheckInitialItems intMap
            checkRemoval chan 1
            checkReplace chan 2 "deux"
            checkInsert chan 4 "quatre"
      testWidget (pure ()) check $ void $ do
        pb <- getPostBuild
        runWithReplace (pure ()) $ ffor pb $ \() -> void $ do
          (dmap, _evt) <- traverseIntMapWithKeyWithAdjust widget intMap =<< triggerEventWithChan chan
          liftIO $ dmap `H.shouldBe` intMap
    -- Should be fixed by prerender changes!
    xit "handles postBuild correctly in prerender" $ runWD $ do
      chan <- liftIO newChan
      let check = do
            _ <- getAndCheckInitialItems $ applyAlways postBuildPatch intMap
            checkRemoval chan 1
            checkInsert chan 2 "deux"
            checkReplace chan 3 "trois"
      testWidget (pure ()) check $ do
        replace <- triggerEventWithChan chan
        prerender_ (pure ()) $ void $ do
          pb <- getPostBuild
          (dmap, _evt) <- traverseIntMapWithKeyWithAdjust widget intMap $ leftmost [postBuildPatch <$ pb, replace]
          liftIO $ dmap `H.shouldBe` intMap

  describe "traverseDMapWithKeyWithAdjustWithMove" $ session' $ do
    let widget :: DomBuilder t m => Key2 a -> Identity a -> m (Identity a)
        widget k (Identity v) = elAttr "li" ("id" =: textKey2 k) $ do
          elClass "span" "key" $ text $ textKey2 k
          elClass "span" "value" $ text $ T.pack $ has @Show k $ show v
          pure (Identity v)
        textKey2 :: Key2 a -> Text
        textKey2 = \case
          Key2_Int i -> "i" <> T.pack (show i)
          Key2_Char c -> "c" <> T.pack [c]
        checkItem :: WD.Element -> Text -> Text -> WD ()
        checkItem li k v = do
          shouldContainTextNoRetry k =<< WD.findElemFrom li (WD.ByClass "key")
          shouldContainTextNoRetry v =<< WD.findElemFrom li (WD.ByClass "value")
        checkInitialItems dm xs = do
          liftIO $ assertEqual "Wrong amount of items in DOM" (DMap.size dm) (length xs)
          forM_ (zip xs (DMap.toList dm)) $ \(e, k :=> Identity v) -> checkItem e (textKey2 k) (T.pack $ has @Show k $ show v)
        getAndCheckInitialItems dm = withRetry $ do
          xs <- WD.findElems (WD.ByTag "li")
          checkInitialItems dm xs
          pure xs
        moveSpec
          :: (DMap Key2 Identity -> (WD.Element -> Chan (PatchDMapWithMove Key2 Identity) -> WD ()) -> WD ())
          -> H.SpecM (WdTestSession ()) ()
        moveSpec testMove = do
          it "can insert an item" $ runWD $ testMove (DMap.fromList [Key2_Int 1 ==> 1, Key2_Int 3 ==> 3]) $ \body chan -> do
            shouldContainText (T.strip $ T.unlines ["i11","i33"]) body
            liftIO $ writeChan chan (insertDMapKey (Key2_Int 2) 2)
            shouldContainText (T.strip $ T.unlines ["i11","i22","i33"]) body
          it "can delete an item" $ runWD $ testMove (DMap.fromList [Key2_Int 1 ==> 1, Key2_Int 2 ==> 2, Key2_Int 3 ==> 3]) $ \body chan -> do
            shouldContainText (T.strip $ T.unlines ["i11","i22","i33"]) body
            liftIO $ writeChan chan (deleteDMapKey (Key2_Int 2))
            shouldContainText (T.strip $ T.unlines ["i11","i33"]) body
          it "can swap items" $ runWD $ testMove (DMap.fromList [Key2_Int 1 ==> 1, Key2_Int 2 ==> 2, Key2_Int 3 ==> 3, Key2_Int 4 ==> 4]) $ \body chan -> do
            shouldContainText (T.strip $ T.unlines ["i11","i22","i33","i44"]) body
            liftIO $ writeChan chan (swapDMapKey (Key2_Int 2) (Key2_Int 3))
            shouldContainText (T.strip $ T.unlines ["i11","i33","i22","i44"]) body
-- TODO re-enable this
--          it "can move items" $ runWD $ testMove (DMap.fromList [Key2_Int 1 ==> 1, Key2_Int 2 ==> 2, Key2_Int 3 ==> 3, Key2_Int 4 ==> 4]) $ \body chan -> do
--            shouldContainText (T.strip $ T.unlines ["i11","i22","i33", "i44"]) body
--            liftIO $ writeChan chan (moveDMapKey (Key2_Int 2) (Key2_Int 3))
--            shouldContainText (T.strip $ T.unlines ["i11","i22","i44"]) body
--            liftIO $ writeChan chan (moveDMapKey (Key2_Int 2) (Key2_Int 3)) -- attempt a move to nonexistent key should delete
--            shouldContainText (T.strip $ T.unlines ["i11","i44"]) body
--            liftIO $ writeChan chan (moveDMapKey (Key2_Int 2) (Key2_Int 3)) -- this causes a JSException in immediate builder too
--            shouldContainText (T.strip $ T.unlines ["i11","i44"]) body
--            liftIO $ writeChan chan (insertDMapKey (Key2_Int 2) 2) -- this step will fail if the above caused an exception, thus works as a proxy for detecting the exception given we can't catch it
--            shouldContainText (T.strip $ T.unlines ["i11","i22","i44"]) body

    describe "hydration" $ moveSpec $ \initMap test -> do
      chan <- liftIO newChan
      let static = getAndCheckInitialItems initMap
          check xs = do
            checkInitialItems initMap xs
            body <- getBody
            test body chan
      testWidget' static check $ void $ do
        (dmap, _evt) <- traverseDMapWithKeyWithAdjustWithMove widget initMap =<< triggerEventWithChan chan
        liftIO $ assertEqual "DMap" initMap dmap

    describe "hydration/immediate" $ moveSpec $ \initMap test -> do
      chan <- liftIO newChan
      replace <- liftIO newChan
      lock :: MVar () <- liftIO newEmptyMVar
      let check = do
            liftIO $ do
              writeChan replace ()
              takeMVar lock
            xs <- getAndCheckInitialItems initMap
            checkInitialItems initMap xs
            body <- getBody
            test body chan
      testWidget (pure ()) check $ void $ do
        e <- triggerEventWithChan replace
        runWithReplace (pure ()) $ ffor e $ \() -> void $ do
          pb <- getPostBuild
          performEvent_ $ liftIO (putMVar lock ()) <$ pb
          (dmap, _evt) <- traverseDMapWithKeyWithAdjustWithMove widget initMap =<< triggerEventWithChan chan
          liftIO $ assertEqual "DMap" initMap dmap

  describe "hydrating invalid HTML" $ session' $ do
    it "can hydrate list in paragraph" $ runWD $ do
      let static = do
            checkBodyText "before\ninner\nafter"
            -- Two <p> tags should be present
            (p1, p2) <- WD.findElems (WD.ByTag "p") >>= \case
              [p1, p2] -> pure (p1, p2)
              _ -> error "Unexpected number of `p` tags (expected 2)"
            ol <- findElemWithRetry (WD.ByTag "ol")
            shouldContainText "before" p1
            shouldContainText "inner" ol
            shouldContainText "" p2
            pure (p1, ol, p2)
          check (p1, ol, p2) = do
            checkBodyText "before\ninner\nafter"
            shouldContainText "before\ninner\nafter" p1
            elementShouldBeRemoved ol
            elementShouldBeRemoved p2
      testWidget' static check $ do
        -- This is deliberately invalid HTML, the browser will interpret it as
        -- <p>before</p><ol>inner</ol>after<p></p>
        el "p" $ do
          text "before"
          el "ol" $ text "inner"
          text "after"

data Selenium = Selenium
  { _selenium_portNumber :: PortNumber
  , _selenium_stopServer :: IO ()
  }

startSeleniumServer :: PortNumber -> IO (IO ())
startSeleniumServer port = do
  (_,_,_,ph) <- createProcess $ (proc "selenium-server" ["-port", show port])
    { std_in = NoStream
    , std_out = NoStream
    , std_err = NoStream
    }
  return $ terminateProcess ph

withSeleniumServer :: (Selenium -> IO ()) -> IO ()
withSeleniumServer f = do
  stopServer <- startSeleniumServer seleniumPort
  threadDelay $ 1000 * 1000 * 2 -- TODO poll or wait on a a signal to block on
  f $ Selenium
    { _selenium_portNumber = seleniumPort
    , _selenium_stopServer = stopServer
    }

triggerEventWithChan :: (Reflex t, TriggerEvent t m, Prerender js t m) => Chan a -> m (Event t a)
triggerEventWithChan chan = do
  (e, trigger) <- newTriggerEvent
  -- In prerender because we only want to do this on the client
  prerender_ (pure ()) $ void $ liftIO $ forkIO $ forever $ trigger =<< readChan chan
  pure e

shouldBeWithRetryM :: (Eq a, Show a) => WD a -> a -> WD ()
shouldBeWithRetryM m expected = withRetry $ do
  got <- m
  got `shouldBe` expected

assertAttr :: WD.Element -> Text -> Maybe Text -> WD ()
assertAttr e k v = liftIO . assertEqual "Incorrect attribute value" v =<< WD.attr e k

elementShouldBeRemoved :: WD.Element -> WD ()
elementShouldBeRemoved e = withRetry $ do
  try (WD.getText e) >>= \case
    Left (WD.FailedCommand WD.StaleElementReference _) -> return ()
    Left err -> throwM err
    Right !_ -> liftIO $ assertFailure "Expected element to be removed, but it still exists"

shouldContainText :: Text -> WD.Element -> WD ()
shouldContainText t = withRetry . shouldContainTextNoRetry t

shouldContainTextNoRetry :: Text -> WD.Element -> WD ()
shouldContainTextNoRetry t = flip shouldBe t <=< WD.getText

checkBodyText :: Text -> WD ()
checkBodyText = checkTextInTag "body"

checkTextInTag :: Text -> Text -> WD ()
checkTextInTag t expected = do
  e <- findElemWithRetry (WD.ByTag t)
  shouldContainText expected e

checkTextInId :: Text -> Text -> WD ()
checkTextInId i expected = do
  e <- findElemWithRetry (WD.ById i)
  shouldContainText expected e

findElemWithRetry :: Selector -> WD WD.Element
findElemWithRetry = withRetry . WD.findElem

getBody :: WD WD.Element
getBody = WD.findElem $ WD.ByTag "body"

withRetry :: forall a. WD a -> WD a
withRetry a = wait 300
  where wait :: Int -> WD a
        wait 0 = a
        wait n = try a >>= \case
          Left (_ :: SomeException) -> do
            liftIO $ threadDelay 100000
            wait $ n - 1
          Right v -> return v

divId :: DomBuilder t m => Text -> m a -> m a
divId i = elAttr "div" ("id" =: i)

type TestWidget js t m = (DomBuilder t m, MonadHold t m, PostBuild t m, Prerender js t m, PerformEvent t m, TriggerEvent t m, MonadFix m, MonadIO (Performable m), MonadIO m)

testWidgetStaticDebug
  :: Bool
  -> WD b
  -- ^ Webdriver commands to run before JS runs and after hydration switchover
  -> (forall m js. TestWidget js (SpiderTimeline Global) m => m ())
  -- ^ Widget we are testing
  -> WD b
testWidgetStaticDebug withDebugging w = testWidgetDebug withDebugging (void w) w

-- | TODO: do something about JSExceptions not causing tests to fail
testWidgetDebug
  :: Bool
  -> WD ()
  -- ^ Webdriver commands to run before the JS runs (i.e. on the statically rendered page)
  -> WD b
  -- ^ Webdriver commands to run after hydration switchover
  -> (forall m js. TestWidget js (SpiderTimeline Global) m => m ())
  -- ^ Widget we are testing
  -> WD b
testWidgetDebug withDebugging beforeJS afterSwitchover =
  testWidgetDebug' withDebugging beforeJS (const afterSwitchover)

-- | TODO: do something about JSExceptions not causing tests to fail
testWidgetDebug'
  :: Bool
  -> WD a
  -- ^ Webdriver commands to run before the JS runs (i.e. on the statically rendered page)
  -> (a -> WD b)
  -- ^ Webdriver commands to run after hydration switchover
  -> (forall m js. TestWidget js (SpiderTimeline Global) m => m ())
  -- ^ Widget we are testing (contents of body)
  -> WD b
testWidgetDebug' withDebugging beforeJS afterSwitchover bodyWidget = do
  let putStrLnDebug :: MonadIO m => Text -> m ()
      putStrLnDebug m = when withDebugging $ liftIO $ putStrLn $ T.unpack m
      staticApp = do
        el "head" $ pure ()
        el "body" $ do
          bodyWidget
          el "script" $ text $ TE.decodeUtf8 $ LBS.toStrict $ jsaddleJs False
  putStrLnDebug "rendering static"
  ((), html) <- liftIO $ renderStatic staticApp
  putStrLnDebug "rendered static"
  waitBeforeJS <- liftIO newEmptyMVar -- Empty until JS should be run
  waitUntilSwitchover <- liftIO newEmptyMVar -- Empty until switchover
  let entryPoint = do
        putStrLnDebug "taking waitBeforeJS"
        liftIO $ takeMVar waitBeforeJS
        let switchOverAction = do
              putStrLnDebug "switchover syncPoint"
              syncPoint
              putStrLnDebug "putting waitUntilSwitchover"
              liftIO $ putMVar waitUntilSwitchover ()
              putStrLnDebug "put waitUntilSwitchover"
        putStrLnDebug "running mainHydrationWidgetWithSwitchoverAction"
        mainHydrationWidgetWithSwitchoverAction switchOverAction blank bodyWidget
        putStrLnDebug "syncPoint after mainHydrationWidgetWithSwitchoverAction"
        syncPoint
  application <- liftIO $ jsaddleOr defaultConnectionOptions entryPoint $ \_ sendResponse -> do
    putStrLnDebug "sending response"
    r <- sendResponse $ responseLBS status200 [] $ "<!doctype html>\n" <> LBS.fromStrict html
    putStrLnDebug "sent response"
    return r
  waitJSaddle <- liftIO newEmptyMVar
  let settings = foldr ($) Warp.defaultSettings
        [ Warp.setPort $ fromIntegral $ toInteger jsaddlePort
        , Warp.setBeforeMainLoop $ do
            putStrLnDebug "putting waitJSaddle"
            putMVar waitJSaddle ()
            putStrLnDebug "put waitJSaddle"
        ]
      -- hSilence to get rid of ConnectionClosed logs
      silenceIfDebug = if withDebugging then id else hSilence [stderr]
      jsaddleWarp = forkIO $ silenceIfDebug $ Warp.runSettings settings application
  jsaddleTid <- liftIO jsaddleWarp
  putStrLnDebug "taking waitJSaddle"
  liftIO $ takeMVar waitJSaddle
  putStrLnDebug "opening page"
  WD.openPage $ "http://localhost:" <> show jsaddlePort
  putStrLnDebug "running beforeJS"
  a <- beforeJS
  putStrLnDebug "putting waitBeforeJS"
  liftIO $ putMVar waitBeforeJS ()
  putStrLnDebug "taking waitUntilSwitchover"
  liftIO $ takeMVar waitUntilSwitchover
  putStrLnDebug "running afterSwitchover"
  b <- afterSwitchover a
  putStrLnDebug "killing jsaddle thread"
  liftIO $ killThread jsaddleTid
  return b

data Key2 a where
  Key2_Int :: Int -> Key2 Int
  Key2_Char :: Char -> Key2 Char

deriveGEq ''Key2
deriveGCompare ''Key2
deriveGShow ''Key2
deriveArgDict ''Key2
