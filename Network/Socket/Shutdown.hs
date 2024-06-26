{-# LANGUAGE CPP #-}

#include "HsNetDef.h"

module Network.Socket.Shutdown (
    ShutdownCmd(..)
  , shutdown
  , gracefulClose
  ) where

import qualified Control.Exception as E
import Foreign.Marshal.Alloc (mallocBytes, free)

import Control.Concurrent (threadDelay, yield)

import Network.Socket.Buffer
import Network.Socket.Imports
import Network.Socket.Internal
import Network.Socket.Types

data ShutdownCmd = ShutdownReceive
                 | ShutdownSend
                 | ShutdownBoth

sdownCmdToInt :: ShutdownCmd -> CInt
sdownCmdToInt ShutdownReceive = 0
sdownCmdToInt ShutdownSend    = 1
sdownCmdToInt ShutdownBoth    = 2

-- | Shut down one or both halves of the connection, depending on the
-- second argument to the function.  If the second argument is
-- 'ShutdownReceive', further receives are disallowed.  If it is
-- 'ShutdownSend', further sends are disallowed.  If it is
-- 'ShutdownBoth', further sends and receives are disallowed.
shutdown :: Socket -> ShutdownCmd -> IO ()
shutdown s stype = void $ withFdSocket s $ \fd ->
  throwSocketErrorIfMinus1Retry_ "Network.Socket.shutdown" $
    c_shutdown fd $ sdownCmdToInt stype

foreign import CALLCONV unsafe "shutdown"
  c_shutdown :: CInt -> CInt -> IO CInt

-- | Closing a socket gracefully.
--   This sends TCP FIN and check if TCP FIN is received from the peer.
--   The second argument is time out to receive TCP FIN in millisecond.
--   In both normal cases and error cases, socket is deallocated finally.
--
--   Since: 3.1.1.0
gracefulClose :: Socket -> Int -> IO ()
gracefulClose s tmout0 = sendRecvFIN `E.finally` close s
  where
    sendRecvFIN = do
        -- Sending TCP FIN.
        ex <- E.try $ shutdown s ShutdownSend
        case ex of
          Left (E.SomeException _) -> return ()
          Right () -> do
              -- Giving CPU time to other threads hoping that
              -- FIN arrives meanwhile.
              yield
              -- Waiting TCP FIN.
              E.bracket (mallocBytes bufSize) free recvEOFloop
    recvEOFloop buf = loop 1 0
      where
        loop delay tmout = do
            -- We don't check the (positive) length.
            -- In normal case, it's 0. That is, only FIN is received.
            -- In error cases, data is available. But there is no
            -- application which can read it. So, let's stop receiving
            -- to prevent attacks.
            r <- recvBufNoWait s buf bufSize
            when (r == -1 && tmout < tmout0) $ do
                threadDelay (delay * 1000)
                loop (delay * 2) (tmout + delay)
    -- Don't use 4092 here. The GHC runtime takes the global lock
    -- if the length is over 3276 bytes in 32bit or 3272 bytes in 64bit.
    bufSize = 1024
