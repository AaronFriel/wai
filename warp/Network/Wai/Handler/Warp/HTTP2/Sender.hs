{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns, CPP #-}
{-# LANGUAGE RecordWildCards, NamedFieldPuns #-}

module Network.Wai.Handler.Warp.HTTP2.Sender (frameSender) where

#if __GLASGOW_HASKELL__ < 709
import Control.Applicative
#endif
import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Monad (void, unless)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder.Extra as B
import Foreign.Ptr
import Network.HTTP2
import Network.HTTP2.Priority
import Network.Wai
import Network.Wai.Handler.Warp.Buffer
import Network.Wai.Handler.Warp.HTTP2.EncodeFrame
import Network.Wai.Handler.Warp.HTTP2.HPACK
import Network.Wai.Handler.Warp.HTTP2.Types
import Network.Wai.Handler.Warp.IORef
import qualified Network.Wai.Handler.Warp.Settings as S
import Network.Wai.Handler.Warp.Types
import Network.Wai.Internal (Response(..))
import qualified System.PosixCompat.Files as P

#ifdef WINDOWS
import qualified System.IO as IO
#else
import Network.Wai.Handler.Warp.FdCache
import Network.Wai.Handler.Warp.SendFile (positionRead)
import System.Posix.IO (openFd, OpenFileFlags(..), defaultFileFlags, OpenMode(ReadOnly))
import System.Posix.Types
#endif

----------------------------------------------------------------

data Leftover = LZero
              | LOne B.BufferWriter
              | LTwo BS.ByteString B.BufferWriter

----------------------------------------------------------------

unlessClosed :: Context -> Connection -> Stream -> IO () -> IO ()
unlessClosed ctx
             Connection{connSendAll}
             strm@Stream{streamState,streamNumber}
             body = E.handle resetStream $ do
    state <- readIORef streamState
    unless (isClosed state) body
  where
    resetStream e = do
        closed ctx strm (ResetByMe e)
        let rst = resetFrame InternalError streamNumber
        connSendAll rst

checkWindowSize :: TVar WindowSize -> TVar WindowSize -> PriorityTree Output -> Output -> Priority -> (WindowSize -> IO ()) -> IO ()
checkWindowSize connWindow strmWindow outQ out pri body = do
   cw <- atomically $ do
       w <- readTVar connWindow
       check (w > 0)
       return w
   sw <- atomically $ readTVar strmWindow
   if sw == 0 then
       void $ forkIO $ do
           -- checkme: if connection is closed? GC throws dead lock error?
           atomically $ do
               x <- readTVar strmWindow
               check (x > 0)
           enqueue outQ out pri
     else
       body (min cw sw)

frameSender :: Context -> Connection -> InternalInfo -> S.Settings -> IO ()
frameSender ctx@Context{outputQ,connectionWindow}
            conn@Connection{connWriteBuffer,connBufferSize,connSendAll}
            ii settings = go `E.catch` ignore
  where
    initialSettings = [(SettingsMaxConcurrentStreams,recommendedConcurrency)]
    initialFrame = settingsFrame id initialSettings
    bufHeaderPayload = connWriteBuffer `plusPtr` frameHeaderLength
    headerPayloadLim = connBufferSize - frameHeaderLength

    go = do
        connSendAll initialFrame
        loop

    loop = dequeue outputQ >>= \(out, pri) -> switch out pri

    ignore :: E.SomeException -> IO ()
    ignore _ = return ()

    switch OFinish         _ = return ()
    switch (OGoaway frame) _ = connSendAll frame
    switch (OFrame frame)  _ = do
        connSendAll frame
        loop
    switch out@(OResponse strm rsp aux) pri = unlessClosed ctx conn strm $ do
        checkWindowSize connectionWindow (streamWindow strm) outputQ out pri $ \lim -> do
            -- Header frame and Continuation frame
            let sid = streamNumber strm
                endOfStream = case aux of
                    Persist{}  -> False
                    Oneshot hb -> not hb
            len <- headerContinue sid rsp endOfStream
            let total = len + frameHeaderLength
            case aux of
                Oneshot True -> do -- hasBody
                    -- Data frame payload
                    off <- sendHeadersIfNecessary total
                    Next datPayloadLen mnext <- fillResponseBodyGetNext conn ii off lim rsp
                    fillDataHeaderSend strm total datPayloadLen mnext pri
                Oneshot False -> do
                    -- "closed" must be before "connSendAll". If not,
                    -- the context would be switched to the receiver,
                    -- resulting the inconsistency of concurrency.
                    closed ctx strm Finished
                    bufferIO connWriteBuffer total connSendAll
                Persist sq tvar -> do
                    off <- sendHeadersIfNecessary total
                    Next datPayloadLen mnext <- fillStreamBodyGetNext conn off lim sq tvar
                    fillDataHeaderSend strm total datPayloadLen mnext pri
        loop
    switch out@(ONext strm curr) pri = unlessClosed ctx conn strm $ do
        checkWindowSize connectionWindow (streamWindow strm) outputQ out pri $ \lim -> do
            -- Data frame payload
            Next datPayloadLen mnext <- curr lim
            fillDataHeaderSend strm 0 datPayloadLen mnext pri
        loop

    headerContinue sid rsp endOfStream = do
        builder <- hpackEncodeHeader ctx ii settings rsp
        (len, signal) <- B.runBuilder builder bufHeaderPayload headerPayloadLim
        let flag0 = case signal of
                B.Done -> setEndHeader defaultFlags
                _      -> defaultFlags
            flag = if endOfStream then setEndStream flag0 else flag0
        fillFrameHeader FrameHeaders len sid flag connWriteBuffer
        continue sid len signal

    continue _   len B.Done = return len
    continue sid len (B.More _ writer) = do
        let total = len + frameHeaderLength
        bufferIO connWriteBuffer total connSendAll
        (len', signal') <- writer bufHeaderPayload headerPayloadLim
        let flag = case signal' of
                B.Done -> setEndHeader defaultFlags
                _      -> defaultFlags
        fillFrameHeader FrameContinuation len' sid flag connWriteBuffer
        continue sid len' signal'
    continue sid len (B.Chunk bs writer) = do
        let total = len + frameHeaderLength
        bufferIO connWriteBuffer total connSendAll
        let (bs1,bs2) = BS.splitAt headerPayloadLim bs
            len' = BS.length bs1
        void $ copy bufHeaderPayload bs1
        fillFrameHeader FrameContinuation len' sid defaultFlags connWriteBuffer
        if bs2 == "" then
            continue sid len' (B.More 0 writer)
          else
            continue sid len' (B.Chunk bs2 writer)

    sendHeadersIfNecessary total = do
        let datPayloadOff = total + frameHeaderLength
        if datPayloadOff < connBufferSize then
            return datPayloadOff
          else do
            bufferIO connWriteBuffer total connSendAll
            return frameHeaderLength

    fillDataHeaderSend strm otherLen datPayloadLen mnext pri = do
        -- Data frame header
        let sid = streamNumber strm
            buf = connWriteBuffer `plusPtr` otherLen
            total = otherLen + frameHeaderLength + datPayloadLen
            flag = case mnext of
                CFinish -> setEndStream defaultFlags
                _       -> defaultFlags
        fillFrameHeader FrameData datPayloadLen sid flag buf
        -- "closed" must be before "connSendAll". If not,
        -- the context would be switched to the receiver,
        -- resulting the inconsistency of concurrency.
        case mnext of
            CFinish    -> closed ctx strm Finished
            _          -> return ()
        bufferIO connWriteBuffer total connSendAll
        atomically $ do
           modifyTVar' connectionWindow (subtract datPayloadLen)
           modifyTVar' (streamWindow strm) (subtract datPayloadLen)
        case mnext of
            CFinish    -> return ()
            CNext next -> enqueue outputQ (ONext strm next) pri
            CNone      -> return ()

    fillFrameHeader ftyp len sid flag buf = encodeFrameHeaderBuf ftyp hinfo buf
      where
        hinfo = FrameHeader len flag sid

----------------------------------------------------------------

{-
ResponseFile Status ResponseHeaders FilePath (Maybe FilePart)
ResponseBuilder Status ResponseHeaders Builder
ResponseStream Status ResponseHeaders StreamingBody
ResponseRaw (IO ByteString -> (ByteString -> IO ()) -> IO ()) Response
-}

fillResponseBodyGetNext :: Connection -> InternalInfo -> Int -> WindowSize -> Response -> IO Next
fillResponseBodyGetNext Connection{connWriteBuffer,connBufferSize}
                        _ off lim (ResponseBuilder _ _ bb) = do
    let datBuf = connWriteBuffer `plusPtr` off
        room = min (connBufferSize - off) lim
    (len, signal) <- B.runBuilder bb datBuf room
    return $ nextForBuilder connWriteBuffer connBufferSize len signal

#ifdef WINDOWS
fillResponseBodyGetNext Connection{connWriteBuffer,connBufferSize}
                        _ off lim (ResponseFile _ _ path mpart) = do
    let datBuf = connWriteBuffer `plusPtr` off
        room = min (connBufferSize - off) lim
    (start, bytes) <- fileStartEnd path mpart
    -- fixme: how to close Handle? GC does it at this moment.
    h <- IO.openBinaryFile path IO.ReadMode
    IO.hSeek h IO.AbsoluteSeek start
    len <- IO.hGetBufSome h datBuf (mini room bytes)
    let bytes' = bytes - fromIntegral len
    return $ nextForFile len connWriteBuffer connBufferSize h bytes' (return ())
#else
fillResponseBodyGetNext Connection{connWriteBuffer,connBufferSize}
                        ii off lim (ResponseFile _ _ path mpart) = do
    (fd, refresh) <- case fdCacher ii of
        Just fdcache -> getFd fdcache path
        Nothing      -> do
            fd' <- openFd path ReadOnly Nothing defaultFileFlags{nonBlock=True}
            return (fd', return ())
    let datBuf = connWriteBuffer `plusPtr` off
        room = min (connBufferSize - off) lim
    (start, bytes) <- fileStartEnd path mpart
    len <- positionRead fd datBuf (mini room bytes) start
    refresh
    let len' = fromIntegral len
    return $ nextForFile len connWriteBuffer connBufferSize fd (start + len') (bytes - len') refresh
#endif

fillResponseBodyGetNext _ _ _ _ _ = error "fillResponseBodyGetNext"

fileStartEnd :: FilePath -> Maybe FilePart -> IO (Integer, Integer)
fileStartEnd path Nothing = do
    end <- fromIntegral . P.fileSize <$> P.getFileStatus path
    return (0, end)
fileStartEnd _ (Just part) =
    return (filePartOffset part, filePartByteCount part)

----------------------------------------------------------------

fillStreamBodyGetNext :: Connection -> Int -> WindowSize -> TBQueue Sequence -> TVar Sync -> IO Next
fillStreamBodyGetNext Connection{connWriteBuffer,connBufferSize}
                      off lim sq tvar = do
    let datBuf = connWriteBuffer `plusPtr` off
        room = min (connBufferSize - off) lim
    (leftover, cont, len) <- runStreamBuilder datBuf room sq
    nextForStream connWriteBuffer connBufferSize sq tvar leftover cont len

----------------------------------------------------------------

fillBufBuilder :: Buffer -> BufSize -> Leftover -> DynaNext
fillBufBuilder buf0 siz0 leftover lim = do
    let payloadBuf = buf0 `plusPtr` frameHeaderLength
        room = min (siz0 - frameHeaderLength) lim
    case leftover of
        LZero -> error "fillBufBuilder: LZero"
        LOne writer -> do
            (len, signal) <- writer payloadBuf room
            getNext len signal
        LTwo bs writer
          | BS.length bs <= room -> do
              buf1 <- copy payloadBuf bs
              let len1 = BS.length bs
              (len2, signal) <- writer buf1 (room - len1)
              getNext (len1 + len2) signal
          | otherwise -> do
              let (bs1,bs2) = BS.splitAt room bs
              void $ copy payloadBuf bs1
              getNext room (B.Chunk bs2 writer)
  where
    getNext l s = return $ nextForBuilder buf0 siz0 l s

nextForBuilder :: Buffer -> BufSize -> BytesFilled -> B.Next -> Next
nextForBuilder _   _   len B.Done
    = Next len CFinish
nextForBuilder buf siz len (B.More _ writer)
    = Next len (CNext (fillBufBuilder buf siz (LOne writer)))
nextForBuilder buf siz len (B.Chunk bs writer)
    = Next len (CNext (fillBufBuilder buf siz (LTwo bs writer)))

----------------------------------------------------------------

runStreamBuilder :: Buffer -> BufSize -> TBQueue Sequence
                 -> IO (Leftover, Bool, BytesFilled)
runStreamBuilder buf0 room0 sq = loop buf0 room0 0
  where
    loop !buf !room !total = do
        mbuilder <- atomically $ tryReadTBQueue sq
        case mbuilder of
            Nothing      -> return (LZero, True, total)
            Just (SBuilder builder) -> do
                (len, signal) <- B.runBuilder builder buf room
                let !total' = total + len
                case signal of
                    B.Done -> loop (buf `plusPtr` len) (room - len) total'
                    B.More  _ writer  -> return (LOne writer, True, total')
                    B.Chunk bs writer -> return (LTwo bs writer, True, total')
            Just SFlush  -> return (LZero, True, total)
            Just SFinish -> return (LZero, False, total)

fillBufStream :: Buffer -> BufSize -> Leftover -> TBQueue Sequence -> TVar Sync -> DynaNext
fillBufStream buf0 siz0 leftover0 sq tvar lim0 = do
    let payloadBuf = buf0 `plusPtr` frameHeaderLength
        room0 = min (siz0 - frameHeaderLength) lim0
    case leftover0 of
        LZero -> do
            (leftover, cont, len) <- runStreamBuilder payloadBuf room0 sq
            getNext leftover cont len
        LOne writer -> write writer payloadBuf room0 0
        LTwo bs writer
          | BS.length bs <= room0 -> do
              buf1 <- copy payloadBuf bs
              let len = BS.length bs
              write writer buf1 (room0 - len) len
          | otherwise -> do
              let (bs1,bs2) = BS.splitAt room0 bs
              void $ copy payloadBuf bs1
              getNext (LTwo bs2 writer) True room0
  where
    getNext = nextForStream buf0 siz0 sq tvar
    write writer1 buf room sofar = do
        (len, signal) <- writer1 buf room
        case signal of
            B.Done -> do
                (leftover, cont, extra) <- runStreamBuilder (buf `plusPtr` len) (room - len) sq
                let !total = sofar + len + extra
                getNext leftover cont total
            B.More  _ writer -> do
                let !total = sofar + len
                getNext (LOne writer) True total
            B.Chunk bs writer -> do
                let !total = sofar + len
                getNext (LTwo bs writer) True total

nextForStream :: Buffer -> BufSize -> TBQueue Sequence -> TVar Sync
              -> Leftover -> Bool -> BytesFilled
              -> IO Next
nextForStream _  _ _  tvar _ False len = do
    atomically $ writeTVar tvar SyncFinish
    return $ Next len CFinish
nextForStream buf siz sq tvar LZero True len = do
    atomically $ writeTVar tvar $ SyncNext (fillBufStream buf siz LZero sq tvar)
    return $ Next len CNone
nextForStream buf siz sq tvar leftover True len =
    return $ Next len (CNext (fillBufStream buf siz leftover sq tvar))

----------------------------------------------------------------

#ifdef WINDOWS
fillBufFile :: Buffer -> BufSize -> IO.Handle -> Integer -> IO () -> DynaNext
fillBufFile buf siz h bytes refresh lim = do
    let payloadBuf = buf `plusPtr` frameHeaderLength
        room = min (siz - frameHeaderLength) lim
    len <- IO.hGetBufSome h payloadBuf room
    refresh
    let bytes' = bytes - fromIntegral len
    return $ nextForFile len buf siz h bytes' refresh

nextForFile :: BytesFilled -> Buffer -> BufSize -> IO.Handle -> Integer -> IO () -> Next
nextForFile 0   _   _   _  _    _       = Next 0 CFinish
nextForFile len _   _   _  0    _       = Next len CFinish
nextForFile len buf siz h bytes refresh =
    Next len (CNext (fillBufFile buf siz h bytes refresh))
#else
fillBufFile :: Buffer -> BufSize -> Fd -> Integer -> Integer -> IO () -> DynaNext
fillBufFile buf siz fd start bytes refresh lim = do
    let payloadBuf = buf `plusPtr` frameHeaderLength
        room = min (siz - frameHeaderLength) lim
    len <- positionRead fd payloadBuf (mini room bytes) start
    let len' = fromIntegral len
    refresh
    return $ nextForFile len buf siz fd (start + len') (bytes - len') refresh

nextForFile :: BytesFilled -> Buffer -> BufSize -> Fd -> Integer -> Integer -> IO () -> Next
nextForFile 0   _   _   _  _     _     _       = Next 0 CFinish
nextForFile len _   _   _  _     0     _       = Next len CFinish
nextForFile len buf siz fd start bytes refresh =
    Next len (CNext (fillBufFile buf siz fd start bytes refresh))
#endif

mini :: Int -> Integer -> Int
mini i n
  | fromIntegral i < n = i
  | otherwise          = fromIntegral n
