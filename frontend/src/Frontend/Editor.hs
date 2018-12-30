{-# LANGUAGE CPP                    #-}
{-# LANGUAGE ConstraintKinds        #-}
{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE ExtendedDefaultRules   #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE KindSignatures         #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE QuasiQuotes            #-}
{-# LANGUAGE RecursiveDo            #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE StandaloneDeriving     #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE TupleSections          #-}
{-# LANGUAGE TypeApplications       #-}
{-# LANGUAGE TypeFamilies           #-}

-- | The code editor, holds the currently edited code.
--
--   Also other editor features like error reporting go here.
--
-- Copyright   :  (C) 2018 Kadena
-- License     :  BSD-style (see the file LICENSE)
--

module Frontend.Editor
  ( -- * Types and Classes
    -- ** The basic Model and ModelConfig types
    EditorCfg (..)
  , HasEditorCfg (..)
  , Editor (..)
  , HasEditor (..)
    -- ** Auxilary types
  , Annotation (..)
  , AnnoType (..)
  -- * Creation
  , makeEditor
  ) where

------------------------------------------------------------------------------
import           Control.Applicative      ((<|>))
import           Control.Lens
import           Control.Monad            (void)
import           Data.Map                 (Map)
import qualified Data.Map                 as Map
import           Data.Text                (Text)
import qualified Data.Text                as T
import           Data.Void                (Void)
import           Generics.Deriving.Monoid (mappenddefault, memptydefault)
import           GHC.Generics             (Generic)
import           Reflex
import qualified Text.Megaparsec          as MP
import qualified Text.Megaparsec.Char     as MP
------------------------------------------------------------------------------
import           Frontend.Backend
import           Frontend.Foundation
import           Frontend.JsonData
import           Frontend.Messages
import           Frontend.Repl
import           Frontend.Wallet

-- | Annotation type.
data AnnoType = AnnoType_Warning | AnnoType_Error

instance Show AnnoType where
  show = \case
    AnnoType_Warning -> "warning"
    AnnoType_Error   -> "error"

-- | Annotation to report warning/errors to the user.
data Annotation = Annotation
  { _annotation_type   :: AnnoType -- ^ Is it a warning or an error?
  , _annotation_msg    :: Text -- ^ The message to report.
  , _annotation_line   :: Int -- ^ What line to put the annotation to.
  , _annotation_column :: Int -- ^ What column.
  }
  deriving Show


-- | Configuration for the `Editor`.
data EditorCfg t = EditorCfg
  { _editorCfg_setCode :: Event t Text
    -- * Set the source code/text of the editor.
  }
  deriving Generic

makePactLenses ''EditorCfg

-- | Current editor state.
--
--   Currently we just hold the current Text, this will likely be extended with
--   information about whether or not the current code got modified since last
--   save, type errors and similar things.
data Editor t = Editor
  { _editor_code        :: Dynamic t Text
  -- ^ Currently loaded/edited PACT code.
  , _editor_annotations :: Event t [Annotation]
  -- ^ Annotations for the editor.
  }
  deriving Generic

makePactLenses ''Editor


type HasEditorModel model t = (HasJsonData model t, HasWallet model t, HasBackend model t)

type ReflexConstraints t m =
  ( MonadHold t m, PerformEvent t m, TriggerEvent t m, MonadIO (Performable m)
  , MonadFix m, MonadIO m, PostBuild t m, MonadSample t (Performable m)
  )

-- | Create an `Editor` by providing a `Config`.
makeEditor
  :: forall t m cfg model
  . ( ReflexConstraints t m
    , HasEditorCfg cfg t, HasEditorModel model t
    )
  => model -> cfg -> m (Editor t)
makeEditor m cfg = do
    t <-  holdDyn "" (cfg ^. editorCfg_setCode)
    annotations <- typeCheckVerify m t
    pure $ Editor
      { _editor_code = t
      , _editor_annotations = annotations
      }

-- | Type check and verify code.
typeCheckVerify
  :: (ReflexConstraints t m, HasEditorModel model t)
  => model -> Dynamic t Text -> m (Event t [Annotation])
typeCheckVerify m t = mdo
    let newInput = leftmost [ updated t, tag (current t) $ updated (m ^. jsonData_data)  ]
    -- Reset repl on each check to avoid memory leak.
    onReplReset <- throttle 1 $ newInput
    onTypeCheck <- delay 0 onReplReset

    let
      onTransSuccess = fmapMaybe (^? _Right) $ replL ^. repl_transactionFinished

    (replO :: MessagesCfg t, replL) <- makeRepl m $ mempty
      { _replCfg_sendTransaction = onTypeCheck
      , _replCfg_reset = () <$ onReplReset
      , _replCfg_verifyModules = Map.keysSet . _ts_modules <$> onTransSuccess
      }
    let
      clearAnnotation = [] <$ onReplReset
#ifdef  ghcjs_HOST_OS
    cModules <- holdDyn Map.empty $ _ts_modules <$> onTransSuccess
    let
      newAnnotations = leftmost
       [ attachPromptlyDynWith parseVerifyOutput cModules $ _repl_modulesVerified replL
       , fallBackParser <$> replO ^. messagesCfg_send
       ]
#else
      newAnnotations = leftmost
       [ parseVerifyOutput <$> _repl_modulesVerified replL
       , fallBackParser <$> replO ^. messagesCfg_send
       ]
#endif
    pure $ leftmost [newAnnotations, clearAnnotation]
  where
    parser = MP.parseMaybe pactErrorParser

-- Line numbers are off on ghcjs:
#ifdef  ghcjs_HOST_OS
    parseVerifyOutput :: Map ModuleName Int -> VerifyResult -> [Annotation]
    parseVerifyOutput ms rs =
      let
        successRs :: [(ModuleName, Text)]
        successRs = fmapMaybe (traverse (^? _Right)) . Map.toList $ rs

        parsedRs :: Map ModuleName [Annotation]
        parsedRs = Map.fromList $ fmapMaybe (traverse parser) successRs

        fixLineNumber :: Int -> Annotation -> Annotation
        fixLineNumber n a = a { _annotation_line = _annotation_line a + n }

        fixLineNumbers :: Int -> [Annotation] -> [Annotation]
        fixLineNumbers n = map (fixLineNumber n)
      in
        concat . Map.elems $ Map.intersectionWith fixLineNumbers ms parsedRs
#else
    parseVerifyOutput :: VerifyResult -> [Annotation]
    parseVerifyOutput rs =
      let
        successRs :: [(ModuleName, Text)]
        successRs = fmapMaybe (traverse (^? _Right)) . Map.toList $ rs

        parsedRs :: [(ModuleName, [Annotation])]
        parsedRs = mapMaybe (traverse parser) successRs
      in
        concatMap snd parsedRs
#endif

    -- Some errors have no line number for some reason:
    fallBackParser msg =
      case parser msg of
        Nothing ->
          [ Annotation
            { _annotation_type = AnnoType_Error
            , _annotation_msg = msg
            , _annotation_line = 1
            , _annotation_column = 0
            }
          ]
        Just a -> a


pactErrorParser :: MP.Parsec Void Text [Annotation]
pactErrorParser = MP.many $ do
    startErrorParser
    line <- digitsP
    MP.char ':'
    column <- digitsP
    MP.char ':'
    MP.space
    annoType <- MP.withRecovery (const $ pure AnnoType_Error) $ do
      void $ MP.string' "warning:"
      pure AnnoType_Warning

    msg <- msgParser

    pure $ Annotation
      { _annotation_type = annoType
      , _annotation_msg = msg
      , _annotation_line = max line 1 -- Some errors have linenumber 0 which is invalid.
      , _annotation_column = max column 1
      }
  where
    digitsP :: MP.Parsec Void Text Int
    digitsP = read <$> MP.some MP.digitChar

-- | Parse the actual error message.
msgParser :: MP.Parsec Void Text Text
msgParser = linesParser <|> restParser
  where
    restParser = do
      MP.notFollowedBy startErrorParser
      MP.takeRest

    linesParser = fmap T.unlines . MP.try . MP.some $ lineParser

    lineParser = do
      MP.notFollowedBy startErrorParser
      l <- MP.takeWhileP Nothing (/= '\n')
      MP.newline
      pure l

-- | Error/warning messages start this way:
startErrorParser :: MP.Parsec Void Text ()
startErrorParser = do
    MP.space
    MP.many (MP.string "Property proven valid" >> MP.space)
    MP.oneOf "<(" -- Until now we found messages with '<' and some with '('.
    MP.string "interactive"
    MP.oneOf ">)"
    MP.char ':'
    pure ()

-- Instances:

instance Reflex t => Semigroup (EditorCfg t) where
  (<>) = mappenddefault

instance Reflex t => Monoid (EditorCfg t) where
  mempty = memptydefault
  mappend = (<>)

instance Flattenable (EditorCfg t) t where
  flattenWith doSwitch ev =
    EditorCfg
      <$> doSwitch never (_editorCfg_setCode <$> ev)
