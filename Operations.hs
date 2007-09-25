{-# OPTIONS -fno-warn-orphans -fglasgow-exts #-}
-- \^^ deriving Typeable
-- --------------------------------------------------------------------------
-- |
-- Module      :  Operations.hs
-- Copyright   :  (c) Spencer Janssen 2007
-- License     :  BSD3-style (see LICENSE)
-- 
-- Maintainer  :  dons@cse.unsw.edu.au
-- Stability   :  unstable
-- Portability :  not portable, Typeable deriving, mtl, posix
--
-- Operations.
--
-----------------------------------------------------------------------------

module Operations where

import XMonad
import qualified StackSet as W
import {-# SOURCE #-} Config (borderWidth,logHook,numlockMask,defaultLayouts,otherPossibleLayouts)

import Data.Maybe
import Data.List            (nub, (\\), find, partition)
import Data.Bits            ((.|.), (.&.), complement)
import Data.Ratio
import qualified Data.Map as M
import qualified Data.Set as S

import Control.Monad.State
import Control.Monad.Reader
import Control.Arrow ((***), second)

import System.IO
import Graphics.X11.Xlib
import Graphics.X11.Xinerama (getScreenInfo)
import Graphics.X11.Xlib.Extras

-- ---------------------------------------------------------------------
-- |
-- Window manager operations
-- manage. Add a new window to be managed in the current workspace.
-- Bring it into focus.
--
-- Whether the window is already managed, or not, it is mapped, has its
-- border set, and its event mask set.
--
manage :: Window -> X ()
manage w = whenX (fmap not $ isClient w) $ withDisplay $ \d -> do
    setInitialProperties w

    -- FIXME: This is pretty awkward. We can't can't let "refresh" happen
    -- before the call to float, because that will resize the window and
    -- lose the default sizing.

    sh <- io $ getWMNormalHints d w
    let isFixedSize = sh_min_size sh /= Nothing && sh_min_size sh == sh_max_size sh
    isTransient <- isJust `liftM` io (getTransientForHint d w)
    if isFixedSize || isTransient
        then do modify $ \s -> s { windowset = W.insertUp w (windowset s) }
                float w -- \^^ now go the refresh.
        else windows $ W.insertUp w

-- | unmanage. A window no longer exists, remove it from the window
-- list, on whatever workspace it is.
--
-- should also unmap?
--
unmanage :: Window -> X ()
unmanage w = do
    windows (W.delete w)
    setWMState w 0 {-withdrawn-}
    modify (\s -> s {mapped = S.delete w (mapped s), waitingUnmap = M.delete w (waitingUnmap s)})

-- | Modify the size of the status gap at the top of the current screen
-- Taking a function giving the current screen, and current geometry.
modifyGap :: (Int -> (Int,Int,Int,Int) -> (Int,Int,Int,Int)) -> X ()
modifyGap f = do
    windows $ \ws@(W.StackSet { W.current = c@(W.Screen { W.screenDetail = sd }) }) ->
        let n = fromIntegral . W.screen $ c
            g = f n . statusGap $ sd
        in ws { W.current = c { W.screenDetail = sd { statusGap = g } } }

-- | Kill the currently focused client. If we do kill it, we'll get a
-- delete notify back from X.
--
-- There are two ways to delete a window. Either just kill it, or if it
-- supports the delete protocol, send a delete event (e.g. firefox)
--
kill :: X ()
kill = withDisplay $ \d -> withFocused $ \w -> do
    wmdelt <- atom_WM_DELETE_WINDOW  ;  wmprot <- atom_WM_PROTOCOLS

    protocols <- io $ getWMProtocols d w
    io $ if wmdelt `elem` protocols
        then allocaXEvent $ \ev -> do
                setEventType ev clientMessage
                setClientMessageEvent ev w wmprot 32 wmdelt 0
                sendEvent d w False noEventMask ev
        else killClient d w >> return ()

-- ---------------------------------------------------------------------
-- Managing windows

data LayoutMessages = Hide | ReleaseResources deriving ( Typeable, Eq )
instance Message LayoutMessages


-- | windows. Modify the current window list with a pure function, and refresh
windows :: (WindowSet -> WindowSet) -> X ()
windows f = do
    XState { windowset = old } <- get
    let oldvisible = concatMap (W.integrate' . W.stack . W.workspace) $ W.current old : W.visible old
        ws = f old
    modify (\s -> s { windowset = ws })
    d <- asks display

    -- notify non visibility
    let oldvistags = map (W.tag . W.workspace) $ W.current old : W.visible old
        gottenHidden  = filter (\w -> elem w oldvistags) $ map W.tag $ W.hidden ws
    sendMessageToWorkspaces Hide gottenHidden

    -- for each workspace, layout the currently visible workspaces
    let allscreens     = W.screens ws
        summed_visible = scanl (++) [] $ map (W.integrate' . W.stack . W.workspace) allscreens
    visible <- fmap concat $ forM (zip allscreens summed_visible) $ \ (w, vis) -> do
        let n      = W.tag (W.workspace w)
            this   = W.view n ws
            l = W.layout (W.workspace w)
            flt = filter (flip M.member (W.floating ws)) (W.index this)
            tiled = (W.stack . W.workspace . W.current $ this)
                    >>= W.filter (not . flip M.member (W.floating ws))
                    >>= W.filter (not . (`elem` vis))
            (SD (Rectangle sx sy sw sh)
                (gt,gb,gl,gr))          = W.screenDetail w
            viewrect = Rectangle (sx + fromIntegral gl)        (sy + fromIntegral gt)
                                 (sw - fromIntegral (gl + gr)) (sh - fromIntegral (gt + gb))

        -- just the tiled windows:
        -- now tile the windows on this workspace, modified by the gap
        (rs, ml') <- runLayout l viewrect tiled `catchX` runLayout (SomeLayout Full) viewrect tiled
        mapM_ (uncurry tileWindow) rs
        whenJust ml' $ \l' -> runOnWorkspaces (\ww -> if W.tag ww == n
                                                      then return $ ww { W.layout = l'}
                                                      else return ww)

        -- now the floating windows:
        -- move/resize the floating windows, if there are any
        forM_ flt $ \fw -> whenJust (M.lookup fw (W.floating ws)) $
          \(W.RationalRect rx ry rw rh) -> do
            tileWindow fw $ Rectangle
                (sx + floor (toRational sw*rx)) (sy + floor (toRational sh*ry))
                (floor (toRational sw*rw)) (floor (toRational sh*rh))

        let vs = flt ++ map fst rs
        io $ restackWindows d vs
        -- return the visible windows for this workspace:
        return vs

    setTopFocus
    logHook
    -- io performGC -- really helps, but seems to trigger GC bugs?

    -- hide every window that was potentially visible before, but is not
    -- given a position by a layout now.
    mapM_ hide (nub oldvisible \\ visible)

    clearEvents enterWindowMask

-- | setWMState.  set the WM_STATE property
setWMState :: Window -> Int -> X ()
setWMState w v = withDisplay $ \dpy -> do
    a <- atom_WM_STATE
    io $ changeProperty32 dpy w a a propModeReplace [fromIntegral v, fromIntegral none]

-- | hide. Hide a window by unmapping it, and setting Iconified.
hide :: Window -> X ()
hide w = whenX (gets (S.member w . mapped)) $ withDisplay $ \d -> do
    io $ do selectInput d w (clientMask .&. complement structureNotifyMask)
            unmapWindow d w
            selectInput d w clientMask
    setWMState w 3 --iconic
    -- this part is key: we increment the waitingUnmap counter to distinguish
    -- between client and xmonad initiated unmaps.
    modify (\s -> s { waitingUnmap = M.insertWith (+) w 1 (waitingUnmap s)
                    , mapped       = S.delete w (mapped s) })

-- | reveal. Show a window by mapping it and setting Normal
-- this is harmless if the window was already visible
reveal :: Window -> X ()
reveal w = withDisplay $ \d -> do
    setWMState w 1 --normal
    io $ mapWindow d w
    modify (\s -> s { mapped = S.insert w (mapped s) })

-- | The client events that xmonad is interested in
clientMask :: EventMask
clientMask = structureNotifyMask .|. enterWindowMask .|. propertyChangeMask

-- | Set some properties when we initially gain control of a window
setInitialProperties :: Window -> X ()
setInitialProperties w = withDisplay $ \d -> io $ do
    selectInput d w $ clientMask
    setWindowBorderWidth d w borderWidth

-- | refresh. Render the currently visible workspaces, as determined by
-- the StackSet. Also, set focus to the focused window.
--
-- This is our 'view' operation (MVC), in that it pretty prints our model
-- with X calls.
--
refresh :: X ()
refresh = windows id

-- | clearEvents.  Remove all events of a given type from the event queue.
clearEvents :: EventMask -> X ()
clearEvents mask = withDisplay $ \d -> io $ do
    sync d False
    allocaXEvent $ \p -> fix $ \again -> do
        more <- checkMaskEvent d mask p
        when more again -- beautiful

-- | tileWindow. Moves and resizes w such that it fits inside the given
-- rectangle, including its border.
tileWindow :: Window -> Rectangle -> X ()
tileWindow w r = withDisplay $ \d -> do
    bw <- (fromIntegral . wa_border_width) `liftM` io (getWindowAttributes d w)
    -- give all windows at least 1x1 pixels
    let least x | x <= bw*2  = 1
                | otherwise  = x - bw*2
    io $ moveResizeWindow d w (rect_x r) (rect_y r)
                              (least $ rect_width r) (least $ rect_height r)
    reveal w

-- ---------------------------------------------------------------------

-- | rescreen.  The screen configuration may have changed (due to
-- xrandr), update the state and refresh the screen, and reset the gap.
rescreen :: X ()
rescreen = do
    xinesc <- withDisplay (io . getScreenInfo)

    windows $ \ws@(W.StackSet { W.current = v, W.visible = vs, W.hidden = hs }) ->
        let (xs, ys) = splitAt (length xinesc) $ map W.workspace (v:vs) ++ hs
            (a:as)   = zipWith3 W.Screen xs [0..] $ zipWith SD xinesc gs
            sgs      = map (statusGap . W.screenDetail) (v:vs)
            gs       = take (length xinesc) (sgs ++ repeat (0,0,0,0))
        in  ws { W.current = a
               , W.visible = as
               , W.hidden  = ys }

-- ---------------------------------------------------------------------

-- | setButtonGrab. Tell whether or not to intercept clicks on a given window
setButtonGrab :: Bool -> Window -> X ()
setButtonGrab grab w = withDisplay $ \d -> io $
    if grab
        then forM_ [button1, button2, button3] $ \b ->
            grabButton d b anyModifier w False buttonPressMask
                       grabModeAsync grabModeSync none none
        else ungrabButton d anyButton anyModifier w

-- ---------------------------------------------------------------------
-- Setting keyboard focus

-- | Set the focus to the window on top of the stack, or root
setTopFocus :: X ()
setTopFocus = withWindowSet $ maybe (setFocusX =<< asks theRoot) setFocusX . W.peek

-- | Set focus explicitly to window 'w' if it is managed by us, or root.
-- This happens if X notices we've moved the mouse (and perhaps moved
-- the mouse to a new screen).
focus :: Window -> X ()
focus w = withWindowSet $ \s -> do
    if W.member w s then when (W.peek s /= Just w) $ windows (W.focusWindow w)
                    else whenX (isRoot w) $ setFocusX w

-- | Call X to set the keyboard focus details.
setFocusX :: Window -> X ()
setFocusX w = withWindowSet $ \ws -> do
    XConf { display = dpy , normalBorder = nbc, focusedBorder = fbc } <- ask

    -- clear mouse button grab and border on other windows
    forM_ (W.current ws : W.visible ws) $ \wk -> do
        forM_ (W.index (W.view (W.tag (W.workspace wk)) ws)) $ \otherw -> do
            setButtonGrab True otherw
            io $ setWindowBorder dpy otherw nbc

    -- If we ungrab buttons on the root window, we lose our mouse bindings.
    whenX (not `liftM` isRoot w) $ setButtonGrab False w
    io $ do setInputFocus dpy w revertToPointerRoot 0
            -- raiseWindow dpy w
    io $ setWindowBorder dpy w fbc

-- | Throw a message to the current Layout possibly modifying how we
-- layout the windows, then refresh.
--
sendMessage :: Message a => a -> X ()
sendMessage a = do w <- (W.workspace . W.current) `fmap` gets windowset
                   ml' <- handleMessage (W.layout w) (SomeMessage a) `catchX` return Nothing
                   whenJust ml' $ \l' ->
                       do windows $ \ws -> ws { W.current = (W.current ws)
                                                { W.workspace = (W.workspace $ W.current ws)
                                                  { W.layout = l' }}}

-- | Send a message to a list of workspaces' layouts, without necessarily refreshing.
sendMessageToWorkspaces :: Message a => a -> [WorkspaceId] -> X ()
sendMessageToWorkspaces a l = runOnWorkspaces modw
    where modw w = if W.tag w `elem` l
                      then do ml' <- handleMessage (W.layout w) (SomeMessage a) `catchX` return Nothing
                              return $ w { W.layout = maybe (W.layout w) id ml' }
                      else return w

-- | Send a message to all visible layouts, without necessarily refreshing.
-- This is how we implement the hooks, such as UnDoLayout.
broadcastMessage :: Message a => a -> X ()
broadcastMessage a = runOnWorkspaces modw
    where modw w = do ml' <- handleMessage (W.layout w) (SomeMessage a) `catchX` return Nothing
                      return $ w { W.layout = maybe (W.layout w) id ml' }

runOnWorkspaces :: (WindowSpace -> X WindowSpace) -> X ()
runOnWorkspaces job = do ws <- gets windowset
                         h <- mapM job $ W.hidden ws
                         c:v <- mapM (\s -> fmap (\w -> s { W.workspace = w}) $ job (W.workspace s))
                                 $ W.current ws : W.visible ws
                         modify $ \s -> s { windowset = ws { W.current = c, W.visible = v, W.hidden = h } }

instance Message Event

-- Layout selection manager

-- This is a layout that allows users to switch between various layout
-- options.  This layout accepts three Messages, NextLayout, PrevLayout and
-- JumpToLayout.

data ChangeLayout = NextLayout | PrevLayout | JumpToLayout String
                 deriving ( Eq, Show, Typeable )
instance Message ChangeLayout

instance ReadableSomeLayout Window where
    defaults = SomeLayout (LayoutSelection defaultLayouts) :
               SomeLayout Full : SomeLayout (Tall 1 0.1 0.5) :
               SomeLayout (Mirror $ Tall 1 0.1 0.5) :
               defaultLayouts ++ otherPossibleLayouts

data LayoutSelection a = LayoutSelection [SomeLayout a]
                         deriving ( Show, Read )

instance ReadableSomeLayout a => Layout LayoutSelection a where
    doLayout (LayoutSelection (l:ls)) r s =
        do (x,ml') <- doLayout l r s
           return (x, (\l' -> LayoutSelection (l':ls)) `fmap` ml')
    doLayout (LayoutSelection []) r s = do (x,_) <- doLayout Full r s
                                           return (x,Nothing)
    -- respond to messages only when there's an actual choice:
    handleMessage (LayoutSelection (l:ls@(_:_))) m
        | Just NextLayout <- fromMessage m = switchl rls
        | Just PrevLayout <- fromMessage m = switchl rls'
        | Just (JumpToLayout x) <- fromMessage m = switchl (j x)
        | Just ReleaseResources <- fromMessage m =
              do mlls' <- mapM (\ll -> handleMessage ll m) (l:ls)
                 let lls' = zipWith (\x mx -> maybe x id mx) (l:ls) mlls'
                 return $ Just $ LayoutSelection lls'
        where rls (x:xs) = xs ++ [x]
              rls [] = []
              rls' = reverse . rls . reverse
              j s zs = case partition (\z -> s == description z) zs of
                         (xs,ys) -> xs++ys
              switchl f = do ml' <- handleMessage l (SomeMessage Hide)
                             return $ Just (LayoutSelection $ f $ fromMaybe l ml':ls)
    -- otherwise, or if we don't understand the message, pass it along to the real
    -- layout:
    handleMessage (LayoutSelection (l:ls)) m
        =  do ml' <- handleMessage l m
              return $ (\l' -> LayoutSelection (l':ls)) `fmap` ml'
    -- Unless there is no layout...
    handleMessage (LayoutSelection []) _ = return Nothing
--
-- Builtin layout algorithms:
--
--   fullscreen mode
--   tall mode
-- 
-- The latter algorithms support the following operations:
--
--      Shrink
--      Expand
--

data Resize     = Shrink | Expand   deriving Typeable
data IncMasterN = IncMasterN Int   deriving Typeable
instance Message Resize
instance Message IncMasterN

-- simple fullscreen mode, just render all windows fullscreen.
-- a plea for tuple sections: map . (,sc)
data Full a = Full deriving ( Show, Read )
instance Layout Full a
--
-- The tiling mode of xmonad, and its operations.
--
data Tall a = Tall Int Rational Rational deriving ( Show, Read )
instance Layout Tall a where
    doLayout (Tall nmaster _ frac) r =
        return . (\x->(x,Nothing)) .
        ap zip (tile frac r nmaster . length) . W.integrate
    handleMessage (Tall nmaster delta frac) m =
        return $ msum [fmap resize (fromMessage m)
                      ,fmap incmastern (fromMessage m)]
        where resize Shrink = Tall nmaster delta (max 0 $ frac-delta)
              resize Expand = Tall nmaster delta (min 1 $ frac+delta)
              incmastern (IncMasterN d) = Tall (max 0 (nmaster+d)) delta frac
    description _ = "Tall"

-- | Mirror a rectangle
mirrorRect :: Rectangle -> Rectangle
mirrorRect (Rectangle rx ry rw rh) = (Rectangle ry rx rh rw)

-- | Mirror a layout, compute its 90 degree rotated form.
data Mirror l a = Mirror (l a) deriving (Show, Read)

instance Layout l a => Layout (Mirror l) a where
    doLayout (Mirror l) r s = (map (second mirrorRect) *** fmap Mirror)
                                `fmap` doLayout l (mirrorRect r) s
    handleMessage (Mirror l) = fmap (fmap Mirror) . handleMessage l
    description (Mirror l) = "Mirror "++ description l

-- | tile.  Compute the positions for windows using the default 2 pane tiling algorithm.
--
-- The screen is divided (currently) into two panes. all clients are
-- then partioned between these two panes. one pane, the `master', by
-- convention has the least number of windows in it (by default, 1). 
-- the variable `nmaster' controls how many windows are rendered in the
-- master pane. 
--
-- `delta' specifies the ratio of the screen to resize by.
--
-- 'frac' specifies what proportion of the screen to devote to the
-- master area.
-- 
tile :: Rational -> Rectangle -> Int -> Int -> [Rectangle]
tile f r nmaster n = if n <= nmaster || nmaster == 0
    then splitVertically n r
    else splitVertically nmaster r1 ++ splitVertically (n-nmaster) r2 -- two columns
  where (r1,r2) = splitHorizontallyBy f r

--
-- Divide the screen vertically into n subrectangles
--
splitVertically, splitHorizontally :: Int -> Rectangle -> [Rectangle]
splitVertically n r | n < 2 = [r]
splitVertically n (Rectangle sx sy sw sh) = Rectangle sx sy sw smallh :
    splitVertically (n-1) (Rectangle sx (sy+fromIntegral smallh) sw (sh-smallh))
  where smallh = sh `div` fromIntegral n --hmm, this is a fold or map.

splitHorizontally n = map mirrorRect . splitVertically n . mirrorRect

-- Divide the screen into two rectangles, using a rational to specify the ratio
splitHorizontallyBy, splitVerticallyBy :: RealFrac r => r -> Rectangle -> (Rectangle, Rectangle)
splitHorizontallyBy f (Rectangle sx sy sw sh) =
    ( Rectangle sx sy leftw sh
    , Rectangle (sx + fromIntegral leftw) sy (sw-fromIntegral leftw) sh)
  where leftw = floor $ fromIntegral sw * f

splitVerticallyBy f = (mirrorRect *** mirrorRect) . splitHorizontallyBy f . mirrorRect

------------------------------------------------------------------------
-- Utilities

-- | Return workspace visible on screen 'sc', or Nothing.
screenWorkspace :: ScreenId -> X (Maybe WorkspaceId)
screenWorkspace sc = withWindowSet $ return . W.lookupWorkspace sc

-- | Apply an X operation to the currently focused window, if there is one.
withFocused :: (Window -> X ()) -> X ()
withFocused f = withWindowSet $ \w -> whenJust (W.peek w) f

-- | True if window is under management by us
isClient :: Window -> X Bool
isClient w = withWindowSet $ return . W.member w

-- | Combinations of extra modifier masks we need to grab keys\/buttons for.
-- (numlock and capslock)
extraModifiers :: [KeyMask]
extraModifiers = [0, numlockMask, lockMask, numlockMask .|. lockMask ]

-- | Strip numlock\/capslock from a mask
cleanMask :: KeyMask -> KeyMask
cleanMask = (complement (numlockMask .|. lockMask) .&.)

-- | Get the Pixel value for a named color
initColor :: Display -> String -> IO Pixel
initColor dpy c = (color_pixel . fst) `liftM` allocNamedColor dpy colormap c
    where colormap = defaultColormap dpy (defaultScreen dpy)

------------------------------------------------------------------------
-- | Floating layer support

-- | Given a window, find the screen it is located on, and compute
-- the geometry of that window wrt. that screen.
floatLocation :: Window -> X (ScreenId, W.RationalRect)
floatLocation w = withDisplay $ \d -> do
    ws <- gets windowset
    wa <- io $ getWindowAttributes d w

    let sc = fromMaybe (W.current ws) $ find (pointWithin (fi $ wa_x wa) (fi $ wa_y wa) . screenRect . W.screenDetail) $ W.screens ws
        sr = screenRect . W.screenDetail $ sc
        bw = fi . wa_border_width $ wa
        rr = (W.RationalRect ((fi (wa_x wa) - fi (rect_x sr)) % fi (rect_width sr))
                             ((fi (wa_y wa) - fi (rect_y sr)) % fi (rect_height sr))
                             (fi (wa_width  wa + bw*2) % fi (rect_width sr))
                             (fi (wa_height wa + bw*2) % fi (rect_height sr)))

    return (W.screen $ sc, rr)
  where fi x = fromIntegral x
        pointWithin :: Integer -> Integer -> Rectangle -> Bool
        pointWithin x y r = x >= fi (rect_x r) &&
                            x <  fi (rect_x r) + fi (rect_width r) &&
                            y >= fi (rect_y r) &&
                            y <  fi (rect_y r) + fi (rect_height r)

-- | Make a tiled window floating, using its suggested rectangle
float :: Window -> X ()
float w = do
    (sc, rr) <- floatLocation w
    windows $ \ws -> W.float w rr . fromMaybe ws $ do
        i <- W.findIndex w ws
        guard $ i `elem` map (W.tag . W.workspace) (W.screens ws)
        f <- W.peek ws
        sw <- W.lookupWorkspace sc ws
        return (W.focusWindow f . W.shiftWin sw w $ ws)

-- ---------------------------------------------------------------------
-- Mouse handling

-- | Accumulate mouse motion events
mouseDrag :: (Position -> Position -> X ()) -> X () -> X ()
mouseDrag f done = do
    drag <- gets dragging
    case drag of
        Just _ -> return () -- error case? we're already dragging
        Nothing -> do
            XConf { theRoot = root, display = d } <- ask
            io $ grabPointer d root False (buttonReleaseMask .|. pointerMotionMask)
                    grabModeAsync grabModeAsync none none currentTime
            modify $ \s -> s { dragging = Just (motion, cleanup) }
 where
    cleanup = do
        withDisplay $ io . flip ungrabPointer currentTime
        modify $ \s -> s { dragging = Nothing }
        done
    motion x y = do z <- f x y
                    clearEvents pointerMotionMask
                    return z

mouseMoveWindow :: Window -> X ()
mouseMoveWindow w = whenX (isClient w) $ withDisplay $ \d -> do
    io $ raiseWindow d w
    wa <- io $ getWindowAttributes d w
    (_, _, _, ox', oy', _, _, _) <- io $ queryPointer d w
    let ox = fromIntegral ox'
        oy = fromIntegral oy'
    mouseDrag (\ex ey -> io $ moveWindow d w (fromIntegral (fromIntegral (wa_x wa) + (ex - ox)))
                                             (fromIntegral (fromIntegral (wa_y wa) + (ey - oy))))
              (float w)

mouseResizeWindow :: Window -> X ()
mouseResizeWindow w = whenX (isClient w) $ withDisplay $ \d -> do
    io $ raiseWindow d w
    wa <- io $ getWindowAttributes d w
    sh <- io $ getWMNormalHints d w
    io $ warpPointer d none w 0 0 0 0 (fromIntegral (wa_width wa)) (fromIntegral (wa_height wa))
    mouseDrag (\ex ey -> do
                 io $ resizeWindow d w `uncurry`
                    applySizeHints sh (ex - fromIntegral (wa_x wa),
                                       ey - fromIntegral (wa_y wa)))
              (float w)

-- ---------------------------------------------------------------------
-- | Support for window size hints

type D = (Dimension, Dimension)

-- | Reduce the dimensions if needed to comply to the given SizeHints.
applySizeHints :: Integral a => SizeHints -> (a,a) -> D 
applySizeHints sh (w,h) = applySizeHints' sh (fromIntegral $ max 1 w,
                                              fromIntegral $ max 1 h)

applySizeHints' :: SizeHints -> D -> D
applySizeHints' sh =
      maybe id applyMaxSizeHint                   (sh_max_size   sh)
    . maybe id (\(bw, bh) (w, h) -> (w+bw, h+bh)) (sh_base_size  sh)
    . maybe id applyResizeIncHint                 (sh_resize_inc sh)
    . maybe id applyAspectHint                    (sh_aspect     sh)
    . maybe id (\(bw,bh) (w,h)   -> (w-bw, h-bh)) (sh_base_size  sh)

-- | Reduce the dimensions so their aspect ratio falls between the two given aspect ratios.
applyAspectHint :: (D, D) -> D -> D
applyAspectHint ((minx, miny), (maxx, maxy)) x@(w,h)
    | or [minx < 1, miny < 1, maxx < 1, maxy < 1] = x
    | w * maxy > h * maxx                         = (h * maxx `div` maxy, h)
    | w * miny < h * minx                         = (w, w * miny `div` minx)
    | otherwise                                   = x

-- | Reduce the dimensions so they are a multiple of the size increments.
applyResizeIncHint :: D -> D -> D
applyResizeIncHint (iw,ih) x@(w,h) =
    if iw > 0 && ih > 0 then (w - w `mod` iw, h - h `mod` ih) else x

-- | Reduce the dimensions if they exceed the given maximum dimensions.
applyMaxSizeHint  :: D -> D -> D
applyMaxSizeHint (mw,mh) x@(w,h) =
    if mw > 0 && mh > 0 then (min w mw,min h mh) else x
