{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module: Chainweb.Miner.POW
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- A true Proof of Work miner.
--

module Chainweb.Miner.POW
( powMiner

-- * Internal
, mineCut
, mine
, mineFast
) where

import Control.Concurrent.Async
import Control.Lens
import Control.Lens (ix, (^?), (^?!), view)
import Control.Monad
import Control.Monad.STM

import Crypto.Hash.Algorithms
import Crypto.Hash.IO

import qualified Data.ByteArray as BA
import Data.Bytes.Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as B
import qualified Data.HashMap.Strict as HM
import Data.Int
import Data.Proxy
import Data.Reflection (Given, give)
import qualified Data.Text as T
import Data.Tuple.Strict (T2(..), T3(..))
import Data.Word

import Foreign.Marshal.Alloc
import Foreign.Ptr
import Foreign.Storable

import System.LogLevel (LogLevel(..))
import qualified System.Random.MWC as MWC

-- internal modules

import Chainweb.BlockHash
import Chainweb.BlockHash (BlockHash)
import Chainweb.BlockHeader
import Chainweb.BlockHeaderDB (BlockHeaderDb)
import Chainweb.ChainId (ChainId)
import Chainweb.Cut
import Chainweb.Cut.CutHashes
import Chainweb.CutDB
import Chainweb.Difficulty
import Chainweb.Graph
import Chainweb.Miner.Config (MinerConfig(..))
import Chainweb.NodeId
import Chainweb.NodeId (NodeId)
import Chainweb.Payload
import Chainweb.Payload.PayloadStore
import Chainweb.PowHash
import Chainweb.Sync.WebBlockHeaderStore
import Chainweb.Time
import Chainweb.Time (getCurrentTimeIntegral)
import Chainweb.TreeDB.Difficulty (hashTarget)
import Chainweb.Utils
import Chainweb.Version
import Chainweb.WebBlockHeaderDB
import Chainweb.WebPactExecutionService

import Data.LogMessage (LogFunction, JsonLog(..))

-- -------------------------------------------------------------------------- --
-- Miner

type Adjustments = HM.HashMap BlockHash (T2 BlockHeight HashTarget)

powMiner
    :: forall cas
    . PayloadCas cas
    => LogFunction
    -> MinerConfig
    -> NodeId
    -> CutDb cas
    -> IO ()
powMiner logFun conf nid cutDb = runForever logFun "POW Miner" $ do
    gen <- MWC.createSystemRandom
    give wcdb $ give payloadDb $ go gen 1 HM.empty
  where
    wcdb = view cutDbWebBlockHeaderDb cutDb
    payloadDb = view cutDbPayloadCas cutDb

    logg :: LogLevel -> T.Text -> IO ()
    logg = logFun

    go
        :: Given WebBlockHeaderDb
        => Given (PayloadDb cas)
        => MWC.GenIO
        -> Int
        -> Adjustments
        -> IO ()
    go gen !i !adjustments0 = do

        nonce0 <- Nonce <$> MWC.uniform gen

        -- Mine a new Cut
        --
        c <- _cut cutDb
        T3 newBh c' adjustments' <- do
            let go2 !x = race (awaitNextCut cutDb x) (mineCut @cas logFun conf nid cutDb x nonce0 adjustments0) >>= \case
                    Left c' -> go2 c'
                    Right !r -> return r
            go2 c

        logg Info $! "created new block" <> sshow i
        logFun @(JsonLog NewMinedBlock) Info $ JsonLog (NewMinedBlock (ObjectEncoded newBh))

        -- Publish the new Cut into the CutDb (add to queue).
        --
        addCutHashes cutDb (cutToCutHashes Nothing c')

        let !wh = case window $ _blockChainwebVersion newBh of
              Just (WindowWidth w) -> BlockHeight (int w)
              Nothing -> error "POW miner used with non-POW chainweb!"
            !limit | _blockHeight newBh < wh = 0
                   | otherwise = _blockHeight newBh - wh

        -- Since mining has been successful, we prune the
        -- `HashMap` of adjustment values that we've seen.
        --
        -- Due to this pruning, the `HashMap` should only ever
        -- contain approximately N entries, where:
        --
        -- @
        -- C := number of chains
        -- W := number of blocks in the epoch window
        --
        -- N = W * C
        -- @
        --
        go gen (i + 1) (HM.filter (\(T2 h _) -> h > limit) adjustments')

awaitNextCut :: CutDb cas -> Cut -> IO Cut
awaitNextCut cutDb c = atomically $ do
    c' <- _cutStm cutDb
    when (c' == c) retry
    return c'

mineCut
    :: PayloadCas cas
    => Given WebBlockHeaderDb
    => Given (PayloadDb cas)
    => LogFunction
    -> MinerConfig
    -> NodeId
    -> CutDb cas
    -> Cut
    -> Nonce
    -> Adjustments
    -> IO (T3 BlockHeader Cut Adjustments)
mineCut logfun conf nid cutDb !c !nonce !adjustments = do

    -- Randomly pick a chain to mine on.
    --
    cid <- randomChainId c

    -- The parent block the mine on. Any given chain will always
    -- contain at least a genesis block, so this otherwise naughty
    -- `^?!` will always succeed.
    --
    let !p = c ^?! ixg cid

    -- check if chain can be mined on (check adjacent parents)
    --
    case getAdjacentParents c p of

        Nothing -> mineCut logfun conf nid cutDb c nonce adjustments
            -- spin until a chain is found that isn't blocked

        Just adjParents -> do

            -- get payload
            payload <- _pactNewBlock pact (_configMinerInfo conf) p

            -- get target
            --
            T2 target adjustments' <- getTarget cid p adjustments

            -- Assemble block without Nonce and Timestamp
            --
            let candidateHeader = newBlockHeader
                    (nodeIdFromNodeId nid cid)
                    adjParents
                    (_payloadWithOutputsPayloadHash payload)
                    (Nonce 0) -- preliminary
                    target
                    epoche -- preliminary
                    p

            newHeader <- (usePowHash v mineFast) candidateHeader nonce

            -- create cut with new block
            --
            -- This is expected to succeed, since the cut invariants should
            -- hold by construction
            --
            !c' <- monotonicCutExtension c newHeader

            -- Validate payload
            --
            logg Info $! "validate block payload"
            validatePayload newHeader payload
            logg Info $! "add block payload to payload cas"
            addNewPayload payloadDb payload

            logg Info $! "add block to payload db"
            insertWebBlockHeaderDb newHeader

            return $! T3 newHeader c' adjustments'

  where
    v = _chainwebVersion cutDb
    wcdb = view cutDbWebBlockHeaderDb cutDb
    payloadDb = view cutDbPayloadCas cutDb
    payloadStore = view cutDbPayloadStore cutDb
    pact = _webPactExecutionService $ _webBlockPayloadStorePact payloadStore

    logg :: LogLevel -> T.Text -> IO ()
    logg = logfun

    blockDb :: ChainId -> Maybe BlockHeaderDb
    blockDb cid = wcdb ^? webBlockHeaderDb . ix cid

    validatePayload :: BlockHeader -> PayloadWithOutputs -> IO ()
    validatePayload h o = void $ _pactValidateBlock pact h $ toPayloadData o

    getTarget
        :: ChainId
        -> BlockHeader
        -> Adjustments
        -> IO (T2 HashTarget Adjustments)
    getTarget cid bh as = case HM.lookup (_blockHash bh) as of
        Just (T2 _ t) -> pure $! T2 t adjustments
        Nothing -> case blockDb cid of
            Nothing -> pure $! T2 (_blockTarget bh) adjustments
            Just db -> do
                t <- hashTarget db bh
                pure $! T2 t (HM.insert (_blockHash bh) (T2 (_blockHeight bh) t) adjustments)

    toPayloadData d = PayloadData
              { _payloadDataTransactions = fst <$> _payloadWithOutputsTransactions d
              , _payloadDataMiner = _payloadWithOutputsMiner d
              , _payloadDataPayloadHash = _payloadWithOutputsPayloadHash d
              , _payloadDataTransactionsHash = _payloadWithOutputsTransactionsHash d
              , _payloadDataOutputsHash = _payloadWithOutputsOutputsHash d
              }

-- -------------------------------------------------------------------------- --
--

getAdjacentParents
    :: (IxedGet s, IxValue s ~ BlockHeader, Index s ~ ChainId)
    => s
    -> BlockHeader
    -> Maybe BlockHashRecord
getAdjacentParents c p = BlockHashRecord <$> newAdjHashes
  where
    -- | Try to get all adjacent hashes dependencies.
    --
    newAdjHashes :: Maybe (HM.HashMap ChainId BlockHash)
    newAdjHashes = iforM (_getBlockHashRecord $ _blockAdjacentHashes p) $ \xcid _ ->
        c ^?! ixg xcid . to (tryAdj (_blockHeight p))

    tryAdj :: BlockHeight -> BlockHeader -> Maybe BlockHash
    tryAdj h b
        | _blockHeight b == h = Just $! _blockHash b
        | _blockHeight b == h + 1 = Just $! _blockParent b
        | otherwise = Nothing

-- | Run a mining loop. Updates creation time and nonce.
-- The result is guaranteed to have a valid nonce.
--
mine :: BlockHeader -> Nonce -> IO BlockHeader
mine h nonce = do
    ct <- getCurrentTimeIntegral
    go (0 :: Int) nonce $ injectTime ct $ runPutS $ encodeBlockHeaderWithoutHash h
  where
    target = _blockTarget h
    hash = powHash (_blockChainwebVersion h)

    -- TODO update bytes in in place (e.g. in a mutable vector) and feed
    -- bytes to the hash function from the same buffer.
    --
    go 100000 !n !bytes = do
        ct <- getCurrentTimeIntegral
        go 0 n (injectTime ct bytes)
    go !i !n !bytes = do
        let bytes' = injectNonce n bytes
        if checkTarget target $ hash bytes'
            then runGet decodeBlockHeaderWithoutHash bytes'
            else go (succ i) (succ n) bytes

    injectTime t b = B.take 8 b
        <> runPutS (encodeTime t)
        <> B.drop 16 b

    injectNonce n b
        = runPutS (encodeNonce n)
        <> B.drop 8 b

-- -------------------------------------------------------------------------- --
-- Fast Miner

usePowHash :: ChainwebVersion -> (forall a . HashAlgorithm a => Proxy a -> f) -> f
usePowHash Test{} f = f $ Proxy @SHA512t_256
usePowHash TestWithTime{} f = f $ Proxy @SHA512t_256
usePowHash TestWithPow{} f = f $ Proxy @SHA512t_256
usePowHash Simulation{} f = f $ Proxy @SHA512t_256
usePowHash Testnet00{} f = f $ Proxy @SHA512t_256

-- This Miner makes low-level assumptions about the chainweb protocol. It may
-- break if the protocol changes.
--
-- TODO: Check the chainweb version to make sure this function can handle the
-- respective version.
--
mineFast
    :: forall a
    . HashAlgorithm a
    => Proxy a
    -> BlockHeader
    -> Nonce
    -> IO BlockHeader
mineFast _ h nonce = do
    !ctx <- hashMutableInit @a
    bytes <- BA.copy initialBytes $ \buf -> do
        allocaBytes (powSize :: Int) $ \pow -> do
            let go 100000 !n = do
                    ct <- getCurrentTimeIntegral
                    injectTime ct buf
                    go 0 n

                go !i !n = do
                    injectNonce n buf
                    hash ctx buf pow
                    powByteString <- mkPowHash =<< B.unsafePackCStringLen (castPtr pow, powSize)
                    if checkTarget target powByteString
                        then return ()
                        else go (succ i) (succ n)

            ct <- getCurrentTimeIntegral
            injectTime ct buf
            go (0 :: Int) nonce

    runGet decodeBlockHeaderWithoutHash bytes
  where
    !initialBytes = runPutS $ encodeBlockHeaderWithoutHash h
    !bufSize = B.length initialBytes
    !target = _blockTarget h
    !powSize = int $ hashDigestSize @a undefined

    hash :: MutableContext a -> Ptr Word8 -> Ptr Word8 -> IO ()
    hash ctx buf pow = do
        hashMutableReset ctx
        BA.withByteArray ctx $ \ctxPtr -> do
            hashInternalUpdate @a ctxPtr buf (int bufSize)
            hashInternalFinalize ctxPtr (castPtr pow)
    {-# INLINE hash #-}

    injectTime :: Time Int64 -> Ptr Word8 -> IO ()
    injectTime t buf = pokeByteOff buf 8 $ encodeTimeToWord64 t
    {-# INLINE injectTime #-}

    injectNonce :: Nonce -> Ptr Word8 -> IO ()
    injectNonce n buf = poke (castPtr buf) $ encodeNonceToWord64 n
    {-# INLINE injectNonce #-}

