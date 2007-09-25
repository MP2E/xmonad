{-# OPTIONS -fglasgow-exts #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  XMonad.hs
-- Copyright   :  (c) Spencer Janssen 2007
-- License     :  BSD3-style (see LICENSE)
--
-- Maintainer  :  sjanssen@cse.unl.edu
-- Stability   :  unstable
-- Portability :  not portable, uses cunning newtype deriving
--
-- The X monad, a state monad transformer over IO, for the window
-- manager state, and support routines.
--
-----------------------------------------------------------------------------

module XMonad (
    X, WindowSet, WindowSpace, WorkspaceId, ScreenId(..), ScreenDetail(..), XState(..), XConf(..), Layout(..), SomeLayout(..), ReadableSomeLayout(..),
    Typeable, Message, SomeMessage(..), fromMessage, runLayout,
    runX, catchX, io, catchIO, withDisplay, withWindowSet, isRoot, getAtom, spawn, restart, trace, whenJust, whenX,
    atom_WM_STATE, atom_WM_PROTOCOLS, atom_WM_DELETE_WINDOW
  ) where

import StackSet

import Control.Monad.State
import Control.Monad.Reader
import System.IO
import System.Posix.Process (executeFile, forkProcess, getProcessStatus, createSession)
import System.Exit
import System.Environment
import Graphics.X11.Xlib
-- for Read instance
import Graphics.X11.Xlib.Extras ()
import Data.Typeable

import qualified Data.Map as M
import qualified Data.Set as S

-- | XState, the window manager state.
-- Just the display, width, height and a window list
data XState = XState
    { windowset    :: !WindowSet           -- ^ workspace list
    , mapped       :: !(S.Set Window)      -- ^ the Set of mapped windows
    , waitingUnmap :: !(M.Map Window Int)  -- ^ the number of expected UnmapEvents
    , dragging     :: !(Maybe (Position -> Position -> X (), X ())) }
data XConf = XConf
    { display       :: Display      -- ^ the X11 display
    , theRoot       :: !Window      -- ^ the root window
    , normalBorder  :: !Pixel       -- ^ border color of unfocused windows
    , focusedBorder :: !Pixel     } -- ^ border color of the focused window

type WindowSet = StackSet WorkspaceId (SomeLayout Window) Window ScreenId ScreenDetail
type WindowSpace = Workspace WorkspaceId (SomeLayout Window) Window

-- | Virtual workspace indicies
type WorkspaceId = String

-- | Physical screen indicies
newtype ScreenId    = S Int deriving (Eq,Ord,Show,Read,Enum,Num,Integral,Real)

data ScreenDetail   = SD { screenRect :: !Rectangle
                         , statusGap  :: !(Int,Int,Int,Int) -- ^ width of status bar on the screen
                         } deriving (Eq,Show, Read)

------------------------------------------------------------------------

-- | The X monad, a StateT transformer over IO encapsulating the window
-- manager state
--
-- Dynamic components may be retrieved with 'get', static components
-- with 'ask'. With newtype deriving we get readers and state monads
-- instantiated on XConf and XState automatically.
--
newtype X a = X (ReaderT XConf (StateT XState IO) a)
    deriving (Functor, Monad, MonadIO, MonadState XState, MonadReader XConf)

-- | Run the X monad, given a chunk of X monad code, and an initial state
-- Return the result, and final state
runX :: XConf -> XState -> X a -> IO ()
runX c st (X a) = runStateT (runReaderT a c) st >> return ()

-- | Run in the X monad, and in case of exception, and catch it and log it
-- to stderr, and run the error case.
catchX :: X a -> X a -> X a
catchX (X job) (X errcase) = do
    st <- get
    c <- ask
    (a,s') <- io ((runStateT (runReaderT job c) st) `catch`
                  \e -> (do hPutStrLn stderr (show e); runStateT (runReaderT errcase c) st))
    put s'
    return a

-- ---------------------------------------------------------------------
-- Convenient wrappers to state

-- | Run a monad action with the current display settings
withDisplay :: (Display -> X a) -> X a
withDisplay   f = asks display >>= f

-- | Run a monadic action with the current stack set
withWindowSet :: (WindowSet -> X a) -> X a
withWindowSet f = gets windowset >>= f

-- | True if the given window is the root window
isRoot :: Window -> X Bool
isRoot w = liftM (w==) (asks theRoot)

-- | Wrapper for the common case of atom internment
getAtom :: String -> X Atom
getAtom str = withDisplay $ \dpy -> io $ internAtom dpy str False

-- | Common non-predefined atoms
atom_WM_PROTOCOLS, atom_WM_DELETE_WINDOW, atom_WM_STATE :: X Atom
atom_WM_PROTOCOLS       = getAtom "WM_PROTOCOLS"
atom_WM_DELETE_WINDOW   = getAtom "WM_DELETE_WINDOW"
atom_WM_STATE           = getAtom "WM_STATE"

------------------------------------------------------------------------
-- | Layout handling

-- The different layout modes
-- 'doLayout': given a Rectangle and a Stack, layout the stack elements
-- inside the given Rectangle.  If an element is not given a Rectangle
-- by 'doLayout', then it is not shown on screen.  Windows are restacked
-- according to the order they are returned by 'doLayout'.
--
-- 'modifyLayout' performs message handling for that layout.  If
-- 'modifyLayout' returns Nothing, then the layout did not respond to
-- that message and the screen is not refreshed.  Otherwise, 'modifyLayout'
-- returns an updated 'Layout' and the screen is refreshed.
--
data SomeLayout a = forall l. Layout l a => SomeLayout (l a)

class ReadableSomeLayout a where
    defaults :: [SomeLayout a]
instance ReadableSomeLayout a => Read (SomeLayout a) where
    readsPrec _ = readLayout defaults
instance ReadableSomeLayout a => Layout SomeLayout a where
    doLayout (SomeLayout l) r s = fmap (fmap $ fmap SomeLayout) $ doLayout l r s
    modifyLayout (SomeLayout l) = fmap (fmap SomeLayout) . modifyLayout l

instance Show (SomeLayout a) where
    show (SomeLayout l) = show l

readLayout :: [SomeLayout a] -> String -> [(SomeLayout a, String)]
readLayout ls s = concatMap rl ls
    where rl (SomeLayout x) = map (\(l,s') -> (SomeLayout l,s')) $ rl' x
          rl' :: Layout l a => l a -> [(l a,String)]
          rl' _ = reads s

class (Show (layout a), Read (layout a)) => Layout layout a where
    doLayout :: layout a -> Rectangle -> Stack a -> X ([(a, Rectangle)], Maybe (layout a))
    doLayout l r s = return (pureLayout l r s, Nothing)
    pureLayout :: layout a -> Rectangle -> Stack a -> [(a, Rectangle)]
    pureLayout _ r s = [(focus s, r)]

    modifyLayout :: layout a -> SomeMessage -> X (Maybe (layout a))
    modifyLayout _ _ = return Nothing
    description :: layout a -> String
    description = show

runLayout :: Layout l a => l a -> Rectangle -> StackOrNot a -> X ([(a, Rectangle)], Maybe (l a))
runLayout l r = maybe (return ([], Nothing)) (doLayout l r)

-- | Based on ideas in /An Extensible Dynamically-Typed Hierarchy of Exceptions/,
-- Simon Marlow, 2006. Use extensible messages to the modifyLayout handler.
-- 
-- User-extensible messages must be a member of this class.
--
class Typeable a => Message a

-- |
-- A wrapped value of some type in the Message class.
--
data SomeMessage = forall a. Message a => SomeMessage a

-- |
-- And now, unwrap a given, unknown Message type, performing a (dynamic)
-- type check on the result.
--
fromMessage :: Message m => SomeMessage -> Maybe m
fromMessage (SomeMessage m) = cast m

-- ---------------------------------------------------------------------
-- | General utilities
--
-- Lift an IO action into the X monad
io :: IO a -> X a
io = liftIO

-- | Lift an IO action into the X monad.  If the action results in an IO
-- exception, log the exception to stderr and continue normal execution.
catchIO :: IO () -> X ()
catchIO f = liftIO (f `catch` \e -> hPrint stderr e >> hFlush stderr)

-- | spawn. Launch an external application
spawn :: String -> X ()
spawn x = io $ do
    pid <- forkProcess $ do
        forkProcess (createSession >> executeFile "/bin/sh" False ["-c", x] Nothing)
        exitWith ExitSuccess
    getProcessStatus True False pid
    return ()

-- | Restart xmonad via exec().
--
-- If the first parameter is 'Just name', restart will attempt to execute the
-- program corresponding to 'name'.  Otherwise, xmonad will attempt to execute
-- the name of the current program.
--
-- When the second parameter is 'True', xmonad will attempt to resume with the
-- current window state.
restart :: Maybe String -> Bool -> X ()
restart mprog resume = do
    prog <- maybe (io getProgName) return mprog
    args <- if resume then gets (("--resume":) . return . show . windowset) else return []
    catchIO (executeFile prog True args Nothing)

-- | Run a side effecting action with the current workspace. Like 'when' but
whenJust :: Maybe a -> (a -> X ()) -> X ()
whenJust mg f = maybe (return ()) f mg

-- | Conditionally run an action, using a X event to decide
whenX :: X Bool -> X () -> X ()
whenX a f = a >>= \b -> when b f

-- Grab the X server (lock it) from the X monad
-- withServerX :: X () -> X ()
-- withServerX f = withDisplay $ \dpy -> do
--     io $ grabServer dpy
--     f
--     io $ ungrabServer dpy

-- | A 'trace' for the X monad. Logs a string to stderr. The result may
-- be found in your .xsession-errors file
trace :: String -> X ()
trace msg = io $! do hPutStrLn stderr msg; hFlush stderr
