module Lunapark.Helpers where

import Prelude

import CSS as CSS
import Control.Monad.Aff as Aff
import Control.Monad.Aff.Class (liftAff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Ref as Ref
import Control.Monad.Error.Class as EC
import Control.Monad.State.Class as SC
import Data.Argonaut as J
import Data.Maybe (Maybe(..))
import Lunapark.API as LA
import Lunapark.Error as LE
import Lunapark.Types as LT
import Node.Buffer as B
import Node.FS (FileFlags(W))
import Node.FS.Aff as FS
import Node.Path as Path

import Debug.Trace (traceAnyA)

isVisible ∷ ∀ e m. LA.LunaparkConstraints e m (LT.Element → m Boolean)
isVisible el = EC.catchError (LA.isDisplayed el) \err → case err.error of
  LE.UnknownCommand → stepByStep
  e → EC.throwError err
  where
  script =
    { script: """var el = arguments[0]; return el.offsetHeight > 0 && el.offsetWidth > 0"""
    , args: [ LT.encodeElement el ]
    }

  stepByStep = do
    res ← LA.executeScript script
    LA.wrapEither $ J.decodeJson res

isStale ∷ ∀ e m. LA.LunaparkConstraints e m (LT.Element → m Boolean)
isStale el = EC.catchError (false <$ (LA.findElementsFromElement el $ LT.ByCss $ CSS.fromString "*")) \err →
  case err.error of
    LE.StaleElementReference → pure true
    _ → EC.throwError err

setTimeouts ∷ ∀ e m. LA.LunaparkConstraints e m (LT.Timeouts → m Unit)
setTimeouts ts = EC.catchError (LA.setTimeouts ts) \err →
  case err.error of
    LE.InvalidArgument → do
      LA.setWireTimeouts ts
      SC.modify _{ timeouts = ts }
    _ → EC.throwError err

getTimeouts ∷ ∀ e m. LA.LunaparkConstraints e m (m LT.Timeouts)
getTimeouts =
  EC.catchError action \err → case err.error of
    LE.UnknownCommand → do
      SC.gets _.timeouts
    _ → EC.throwError err
  where
  action = do
    ts ← LA.getTimeouts
    SC.modify _{ timeouts = ts }
    pure ts

-- | Might be useful for setting implicit timeout of finding element
localTimeouts
  ∷ ∀ e m a
  . LA.LunaparkConstraints e m
  ( (LT.Timeouts → LT.Timeouts)
  → m a
  → m a
  )
localTimeouts fn action = do
  ts ← getTimeouts
  setTimeouts $ fn ts
  res ← action
  setTimeouts ts
  pure res

-- | Currently used in ps-webdriver but with duration passed explicitly
-- | since we already have timeouts it might be good idea to use them
repeatedly ∷ ∀ e m a. LA.LunaparkConstraints (ref ∷ Ref.REF|e) m (m a → m a)
repeatedly action = do
  ts ← getTimeouts
  ref ← liftEff $ Ref.newRef false
  _ ← liftAff $ Aff.forkAff do
    Aff.delay ts.script
    liftEff $ Ref.writeRef ref true
  let attempt = EC.catchError action \e → do
        shouldRethrow ← liftEff $ Ref.readRef ref
        if shouldRethrow
          then EC.throwError e
          else do
          liftAff $ Aff.delay ts.implicit
          attempt
  attempt

screenshot ∷ ∀ m e. LA.LunaparkConstraints (buffer ∷ B.BUFFER, fs ∷ FS.FS|e) m (Path.FilePath → m Unit)
screenshot fp = do
  res ← LA.takeScreenshot
  buffer ← liftEff $ B.fromString res.content res.encoding
  liftAff do
    FS.writeFile fp buffer

elementScreenshot
  ∷ ∀ m e
  . LA.LunaparkConstraints (buffer ∷ B.BUFFER, fs ∷ FS.FS|e) m
  ( LT.Element → Path.FilePath → m Unit )
elementScreenshot el fp = do
 traceAnyA "ELEMENT SCREENSHOT"
 res ← LA.takeElementScreenshot el
 traceAnyA res
 buffer ← liftEff $ B.fromString res.content res.encoding
 liftAff do
   FS.writeFile fp buffer
