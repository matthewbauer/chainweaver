{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}

module Frontend.Wallet
  (  -- * Types & Classes
    PrivateKey
  , KeyPair (..)
  , WalletCfg (..)
  , HasWalletCfg (..)
  , IsWalletCfg
  , Wallet (..)
  , HasWallet (..)
  , AccountName (..)
  , AccountBalance (..)
  , AccountNotes (..)
  , mkAccountNotes
  , mkAccountName
  , AccountGuard (..)
  -- * Creation
  , emptyWallet
  , makeWallet
  , loadKeys
  , storeKeys
  , StoreWallet(..)
  -- * Parsing
  , parseWalletKeyPair
  -- * Other helper functions
  , accountIsCreated
  , accountToKadenaAddress
  , checkAccountNameValidity
  , snocIntMap
  , findNextKey
  , findFirstVanityAccount
  , getSigningPairs
  , module Common.Wallet
  ) where

import Control.Lens hiding ((.=))
import Control.Monad.Except (runExcept)
import Control.Monad.Fix
import Data.Aeson
import Data.IntMap (IntMap)
import Data.Set (Set)
import Data.Some (Some(Some))
import Data.Text (Text)
import GHC.Generics (Generic)
import Kadena.SigningApi (AccountName(..), mkAccountName)
import Pact.Types.ChainId
import Reflex
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.IntMap as IntMap
import qualified Data.Text as T

import Common.Network (NetworkName)
import Common.Wallet
import Common.Orphans ()
import Frontend.Crypto.Class
import Frontend.Crypto.Ed25519
import Frontend.Foundation
import Frontend.KadenaAddress
import Frontend.Storage
import Frontend.Network

accountIsCreated:: Account -> AccountCreated
accountIsCreated = maybe AccountCreated_No (const AccountCreated_Yes) . _accountInfo_balance . accountInfo

accountToKadenaAddress :: Account -> KadenaAddress
accountToKadenaAddress a = mkKadenaAddress (accountIsCreated a) (accountChain a) (accountToName a)

data WalletCfg key t = WalletCfg
  { _walletCfg_genKey :: Event t ()
  -- ^ Request generation of a new key
  , _walletCfg_delKey :: Event t IntMap.Key
  -- ^ Hide a key in the wallet.
  , _walletCfg_delAccount :: Event t AccountName
  -- ^ Hide an account in the wallet.
  , _walletCfg_importAccount  :: Event t (NetworkName, AccountName, ChainId, VanityAccount)
  , _walletCfg_createWalletOnlyAccount :: Event t (NetworkName, ChainId, AccountNotes)
  -- ^ Create a wallet only account that uses the public key as the account name
  , _walletCfg_refreshBalances :: Event t ()
  -- ^ Refresh balances in the wallet
  , _walletCfg_setCrossChainTransfer :: Event t (IntMap.Key, Maybe UnfinishedCrossChainTransfer)
  -- ^ Start a cross chain transfer on some account. This field allows us to
  -- recover when something goes badly wrong in the middle, since it's
  -- immediately stored with all info we need to retry.
  , _walletCfg_updateAccountNotes :: Event t (AccountName, AccountNotes)
  }
  deriving Generic

makePactLenses ''WalletCfg

-- | HasWalletCfg with additional constraints to make it behave like a proper
-- "Config".
type IsWalletCfg cfg key t = (HasWalletCfg cfg key t, Monoid cfg, Flattenable cfg t)

-- | We keep track of deletions at a given index so that we don't regenerate
-- keys with BIP32.
--data SomeAccount key
--  = SomeAccount_Deleted
--  | SomeAccount_Account (Account key)

--someAccount :: a -> (Account key -> a) -> SomeAccount key -> a
--someAccount a _ SomeAccount_Deleted = a
--someAccount _ f (SomeAccount_Account a) = f a

--instance ToJSON key => ToJSON (SomeAccount key) where
--  toJSON = \case
--    SomeAccount_Deleted -> Null
--    SomeAccount_Account a -> toJSON a
--
--instance FromJSON key => FromJSON (SomeAccount key) where
--  parseJSON Null = pure SomeAccount_Deleted
--  parseJSON x = SomeAccount_Account <$> parseJSON x

--activeAccountOnNetwork :: NetworkName -> SomeAccount key -> Maybe (Account key)
--activeAccountOnNetwork net = someAccount
--  Nothing
--  (\a -> a <$ guard (_account_network a == net))

getSigningPairs :: KeyStorage key -> Accounts -> Set (Some AccountRef) -> [KeyPair key]
getSigningPairs allKeys allAccounts signing = Map.elems $ Map.restrictKeys allKeysMap wantedKeys
  where
    allKeysMap = Map.fromList $ fmap (\k -> (_keyPair_publicKey $ _key_pair k, _key_pair k)) $ IntMap.elems allKeys
    wantedKeys = Set.fromList $ Map.elems $ Map.restrictKeys accountRefs signing
    accountRefs = vanityRefs <> nonVanityRefs
    vanityRefs = Map.foldMapWithKey
      (\n -> Map.foldMapWithKey $ \c v -> Map.singleton (Some $ AccountRef_Vanity n c) (_vanityAccount_key v))
      (_accounts_vanity allAccounts)
    nonVanityRefs = Map.foldMapWithKey
      (\pk -> Map.foldMapWithKey $ \c _ -> Map.singleton (Some $ AccountRef_NonVanity pk c) pk)
      (_accounts_nonVanity allAccounts)


data Wallet key t = Wallet
  { _wallet_keys :: Dynamic t (KeyStorage key)
    -- ^ Accounts added and removed by the user
  , _wallet_accounts :: Dynamic t AccountStorage
    -- ^ Accounts added and removed by the user
  , _wallet_walletOnlyAccountCreated :: Event t AccountName
    -- ^ A new wallet only account has been created
  }
  deriving Generic

makePactLenses ''Wallet

-- | Find the first vanity account in the wallet
findFirstVanityAccount :: Accounts -> Maybe (AccountName, ChainId, VanityAccount)
findFirstVanityAccount as = do
  (n, cm) <- Map.lookupMin $ _accounts_vanity as
  (c, va) <- Map.lookupMin cm
  pure (n, c, va)

-- | An empty wallet that will never contain any keys.
emptyWallet :: Reflex t => Wallet key t
emptyWallet = mempty

snocIntMap :: a -> IntMap a -> IntMap a
snocIntMap a m = IntMap.insert (nextKey m) a m

nextKey :: IntMap a -> Int
nextKey = maybe 0 (succ . fst) . IntMap.lookupMax

findNextKey :: Reflex t => Wallet key t -> Dynamic t Int
findNextKey = fmap nextKey . _wallet_keys

-- | Make a functional wallet that can contain actual keys.
makeWallet
  :: forall model key t m.
    ( MonadHold t m, PerformEvent t m
    , MonadFix m, MonadJSM (Performable m)
    , MonadJSM m
    , HasStorage (Performable m), HasStorage m
    , HasCrypto key (Performable m)
    , FromJSON key, ToJSON key
    )
  => model
  -> WalletCfg key t
  -> m (Wallet key t)
makeWallet model conf = do
  initialKeys <- fromMaybe IntMap.empty <$> loadKeys
  initialAccounts <- fromMaybe Map.empty <$> loadAccounts
  let
    onGenKey = _walletCfg_genKey conf
    onDelKey = _walletCfg_delKey conf
    onCreateWOAcc = _walletCfg_createWalletOnlyAccount conf
    refresh = _walletCfg_refreshBalances conf
    setCrossChain = _walletCfg_setCrossChainTransfer conf

  performEvent_ $ liftIO (putStrLn "Refresh wallet balances") <$ refresh

  rec
    onNewKey <- performEvent $ attachWith (\a _ -> createKey $ nextKey a) (current keys) onGenKey
    --onWOAccountCreate <- performEvent $ attachWith (createWalletOnlyAccount . nextKey) (current accounts) onCreateWOAcc
    --newBalances <- getBalances model $ current accounts <@ refresh

     --foldDyn id initialKeys $ leftmost
     -- [ ffor onNewKey $ snocIntMap . SomeAccount_Account
     -- , ffor (_walletCfg_importAccount conf) $ snocIntMap . SomeAccount_Account
     -- , ffor onDelKey $ \i -> IntMap.insert i SomeAccount_Deleted
     -- , ffor onWOAccountCreate $ snocIntMap . SomeAccount_Account
     -- , ffor (_walletCfg_updateAccountNotes conf) updateAccountNotes
     -- , const <$> newBalances
     -- , let f cc = someAccount SomeAccount_Deleted (\a -> SomeAccount_Account a { _account_unfinishedCrossChainTransfer = cc })
     --    in ffor setCrossChain $ \(i, cc) -> IntMap.adjust (f cc) i
     -- ]

    keys <- foldDyn id initialKeys never

    accounts <- foldDyn id initialAccounts never
    --  [ ffor onNewKey $ snocIntMap . SomeAccount_Account
    --  , ffor (_walletCfg_importAccount conf) $ snocIntMap . SomeAccount_Account
    --  , ffor onDelKey $ \i -> IntMap.insert i SomeAccount_Deleted
    --  , ffor onWOAccountCreate $ snocIntMap . SomeAccount_Account
    -- -- , const <$> newBalances
    --  , let f cc = someAccount SomeAccount_Deleted (\a -> SomeAccount_Account a { _account_unfinishedCrossChainTransfer = cc })
    --     in ffor setCrossChain $ \(i, cc) -> IntMap.adjust (f cc) i
    --  ]

  performEvent_ $ storeKeys <$> updated keys

  pure $ Wallet
    { _wallet_keys = keys
    , _wallet_accounts = accounts
    , _wallet_walletOnlyAccountCreated = never -- _account_name <$> onWOAccountCreate
    }
  where
    --updateAccountNotes :: (IntMap.Key, AccountNotes) -> Accounts key -> Accounts key
    --updateAccountNotes (k, n) = at k . _Just . _SomeAccount_Account . account_notes .~ n

    --createWalletOnlyAccount :: Int -> (NetworkName, ChainId, AccountNotes) -> Performable m (Account key)
    --createWalletOnlyAccount i (net, c, t) = do
    --  (privKey, pubKey) <- cryptoGenKey i
    --  pure $ buildAccount (AccountName $ keyToText pubKey) pubKey privKey net c t

    createKey :: Int -> Performable m (Key key)
    createKey i = do
      (privKey, pubKey) <- cryptoGenKey i
      pure $ Key
        { _key_pair = KeyPair pubKey (Just privKey)
        , _key_hidden = False
        , _key_notes = mkAccountNotes ""
        }

    --buildAccount n pubKey privKey net c t = Account
    --    { _account_name = n
    --    , _account_key = KeyPair pubKey (Just privKey)
    --    , _account_chainId = c
    --    , _account_network = net
    --    , _account_notes = t
    --    , _account_balance = Nothing
    --    , _account_unfinishedCrossChainTransfer = Nothing
    --    }

-- | Get the balance of some accounts from the network.
getBalances
  :: forall model key t m.
    ( PerformEvent t m, TriggerEvent t m
    , MonadSample t (Performable m), MonadIO m
    , MonadJSM (Performable m)
    , HasNetwork model t, HasCrypto key (Performable m)
    )
  => model -> Event t Accounts -> m (Event t Accounts)
getBalances model accounts = do
  pure never
--  reqs <- performEvent $ attachWith mkReqs (current $ getNetworkNameAndMeta model) accounts
--  response <- performLocalReadCustom (model ^. network) toReqList reqs
--  pure $ toBalances <$> response
--  where
--    toBalance = (^? there . _2 . to (\case (Pact.PLiteral (Pact.LDecimal d)) -> Just $ AccountBalance d; _ -> Nothing) . _Just)
--    toBalances :: (IntMap (SomeAccount key, Maybe NetworkRequest), [NetworkErrorResult]) -> Accounts key
--    toBalances (m, results) = IntMap.fromList $ stepwise (IntMap.toList (fmap fst m)) (toBalance <$> results)
--    -- I don't like this, I'd rather just block in a forked thread manually than have to do this dodgy alignment. TODO
--    stepwise :: [(IntMap.Key, SomeAccount key)] -> [Maybe AccountBalance] -> [(IntMap.Key, SomeAccount key)]
--    stepwise ((i, sa):accs) (bal:bals) = case sa of
--      SomeAccount_Deleted -> (i, SomeAccount_Deleted) : stepwise accs (bal:bals)
--      SomeAccount_Account a ->
--        (i, SomeAccount_Account a { _account_balance = bal <|> _account_balance a })
--        : stepwise accs bals
--    stepwise as _ = as
--    toReqList :: Foldable f => f (SomeAccount key, Maybe NetworkRequest) -> [NetworkRequest]
--    toReqList = fmapMaybe snd . toList
--    accountBalanceReq acc = "(coin.get-balance " <> tshow (unAccountName acc) <> ")"
--    mkReqs :: (NetworkName, PublicMeta) -> Accounts key -> Performable m (IntMap (SomeAccount key, Maybe NetworkRequest))
--    mkReqs meta someaccs = for someaccs $ \sa ->
--      fmap (sa,) . traverse (mkReq meta) $ someAccount Nothing Just sa
--    mkReq (netName, pm) acc = mkSimpleReadReq (accountBalanceReq $ _account_name acc) netName pm (ChainRef Nothing $ _account_chainId acc)


-- Storing data:

-- | Storage keys for referencing data to be stored/retrieved.
data StoreWallet key a where
  StoreWallet_Keys :: StoreWallet key (KeyStorage key)
  StoreWallet_Accounts :: StoreWallet key AccountStorage
deriving instance Show (StoreWallet key a)

-- | Parse a private key with additional checks based on the given public key.
--
--   In case a `Left` value is given instead of a valid public key, the
--   corresponding value will be returned instead.
parseWalletKeyPair :: Either Text PublicKey -> Text -> Either Text (KeyPair PrivateKey)
parseWalletKeyPair errPubKey privKey = do
  pubKey <- errPubKey
  runExcept $ uncurry KeyPair <$> parseKeyPair pubKey privKey

-- | Check account name validity (uniqueness).
--
--   Returns `Left` error msg in case it is not valid.
checkAccountNameValidity
  :: (Reflex t, HasNetwork m t, HasWallet m key t)
  => m
  -> Dynamic t (Maybe ChainId -> Text -> Either Text AccountName)
checkAccountNameValidity m = getErr <$> (m ^. network_selectedNetwork) <*> (m ^. wallet_accounts)
  where
    getErr net networks mChain k = do
      acc <- mkAccountName k
      case Map.lookup net networks of
        Nothing -> Right acc
        Just accounts
          | acc `elem` Map.keys (_accounts_vanity accounts) -> Left $ T.pack "This account name is already in use"
          | otherwise -> Right acc
--      let existsOnChain = \case
--            SomeAccount_Account a
--              -- If we don't have a chain, don't bother checking for duplicates.
--              | Just chain <- mChain -> and
--                [ _account_name a == acc
--                , _account_chainId a == chain
--                ]
--            _ -> False

-- | Write key pairs to localstorage.
storeKeys :: (ToJSON key, HasStorage m, MonadJSM m) => KeyStorage key -> m ()
storeKeys = setItemStorage localStorage StoreWallet_Keys

-- | Load key pairs from localstorage.
loadKeys :: (FromJSON key, HasStorage m, MonadJSM m) => m (Maybe (KeyStorage key))
loadKeys = getItemStorage localStorage StoreWallet_Keys

-- | Write key pairs to localstorage.
storeAccounts :: (HasStorage m, MonadJSM m) => AccountStorage -> m ()
storeAccounts = setItemStorage localStorage StoreWallet_Accounts

-- | Load accounts from localstorage.
loadAccounts :: (HasStorage m, MonadJSM m) => m (Maybe AccountStorage)
loadAccounts = getItemStorage localStorage StoreWallet_Accounts

-- Utility functions:

instance Reflex t => Semigroup (WalletCfg key t) where
  c1 <> c2 = WalletCfg
    { _walletCfg_genKey = leftmost
      [ _walletCfg_genKey c1
      , _walletCfg_genKey c2
      ]
    , _walletCfg_importAccount = leftmost
      [ _walletCfg_importAccount c1
      , _walletCfg_importAccount c2
      ]
    , _walletCfg_delKey = leftmost
      [ _walletCfg_delKey c1
      , _walletCfg_delKey c2
      ]
    , _walletCfg_delAccount = leftmost
      [ _walletCfg_delAccount c1
      , _walletCfg_delAccount c2
      ]
    , _walletCfg_createWalletOnlyAccount = leftmost
      [ _walletCfg_createWalletOnlyAccount c1
      , _walletCfg_createWalletOnlyAccount c2
      ]
    , _walletCfg_refreshBalances = leftmost
      [ _walletCfg_refreshBalances c1
      , _walletCfg_refreshBalances c2
      ]
    , _walletCfg_setCrossChainTransfer = leftmost
      [ _walletCfg_setCrossChainTransfer c1
      , _walletCfg_setCrossChainTransfer c2
      ]
    , _walletCfg_updateAccountNotes = leftmost
      [ _walletCfg_updateAccountNotes c1
      , _walletCfg_updateAccountNotes c2
      ]
    }

instance Reflex t => Monoid (WalletCfg key t) where
  mempty = WalletCfg never never never never never never never never
  mappend = (<>)

instance Flattenable (WalletCfg key t) t where
  flattenWith doSwitch ev =
    WalletCfg
      <$> doSwitch never (_walletCfg_genKey <$> ev)
      <*> doSwitch never (_walletCfg_delKey <$> ev)
      <*> doSwitch never (_walletCfg_delAccount <$> ev)
      <*> doSwitch never (_walletCfg_importAccount <$> ev)
      <*> doSwitch never (_walletCfg_createWalletOnlyAccount <$> ev)
      <*> doSwitch never (_walletCfg_refreshBalances <$> ev)
      <*> doSwitch never (_walletCfg_setCrossChainTransfer <$> ev)
      <*> doSwitch never (_walletCfg_updateAccountNotes <$> ev)

instance Reflex t => Semigroup (Wallet key t) where
  wa <> wb = Wallet
    { _wallet_keys = _wallet_keys wa <> _wallet_keys wb
    , _wallet_accounts = _wallet_accounts wa <> _wallet_accounts wb
    , _wallet_walletOnlyAccountCreated = leftmost
      [ _wallet_walletOnlyAccountCreated wa
      , _wallet_walletOnlyAccountCreated wb
      ]
    }

instance Reflex t => Monoid (Wallet key t) where
  mempty = Wallet mempty mempty never
  mappend = (<>)
