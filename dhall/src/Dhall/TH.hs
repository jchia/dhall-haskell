{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards     #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}

-- | Template Haskell utilities
module Dhall.TH
    ( -- * Embedding Dhall in Haskell
      staticDhallExpression
    , dhall
      -- * Generating Haskell from Dhall expressions
    , makeHaskellTypeFromUnion
    , makeHaskellTypes
    , makeHaskellTypesWith
    , HaskellType(..)
    , GenerateOptions(..)
    , defaultGenerateOptions
    ) where

import Data.Text                 (Text)
import Dhall                     (FromDhall, ToDhall)
import Dhall.Syntax              (Expr (..))
import GHC.Generics              (Generic)
import Language.Haskell.TH.Quote (QuasiQuoter (..), dataToExpQ)
import Prettyprinter             (Pretty)

import Language.Haskell.TH.Syntax
    ( Bang (..)
    , Body (..)
    , Con (..)
    , Dec (..)
    , Exp (..)
    , Match (..)
    , Pat (..)
    , Q
    , SourceStrictness (..)
    , SourceUnpackedness (..)
    , Type (..)
    )

import Language.Haskell.TH.Syntax (DerivClause (..), DerivStrategy (..))

import qualified Data.List                   as List
import qualified Data.Set                    as Set
import qualified Data.Text                   as Text
import qualified Data.Typeable               as Typeable
import qualified Dhall
import qualified Dhall.Core                  as Core
import qualified Dhall.Map
import qualified Dhall.Pretty
import qualified Dhall.Util
import qualified GHC.IO.Encoding
import qualified Language.Haskell.TH.Syntax  as Syntax
import qualified Numeric.Natural
import qualified Prettyprinter.Render.String as Pretty
import qualified System.IO

{-| This fully resolves, type checks, and normalizes the expression, so the
    resulting AST is self-contained.

    This can be used to resolve all of an expression’s imports at compile time,
    allowing one to reference Dhall expressions from Haskell without having a
    runtime dependency on the location of Dhall files.

    For example, given a file @".\/Some\/Type.dhall"@ containing

    > < This : Natural | Other : ../Other/Type.dhall >

    ... rather than duplicating the AST manually in a Haskell `Dhall.Type`, you
    can do:

    > Dhall.Type
    > (\case
    >     UnionLit "This" _ _  -> ...
    >     UnionLit "Other" _ _ -> ...)
    > $(staticDhallExpression "./Some/Type.dhall")

    This would create the Dhall Expr AST from the @".\/Some\/Type.dhall"@ file
    at compile time with all imports resolved, making it easy to keep your Dhall
    configs and Haskell interpreters in sync.
-}
staticDhallExpression :: Text -> Q Exp
staticDhallExpression text = do
    Syntax.runIO (GHC.IO.Encoding.setLocaleEncoding System.IO.utf8)

    expression <- Syntax.runIO (Dhall.inputExpr text)

    dataToExpQ (fmap liftText . Typeable.cast) expression
  where
    -- A workaround for a problem in TemplateHaskell (see
    -- https://stackoverflow.com/questions/38143464/cant-find-inerface-file-declaration-for-variable)
    liftText = fmap (AppE (VarE 'Text.pack)) . Syntax.lift . Text.unpack

{-| A quasi-quoter for Dhall expressions.

    This quoter is build on top of 'staticDhallExpression'. Therefore consult the
    documentation of that function for further information.

    This quoter is meant to be used in expression context only; Other contexts
    like pattern contexts or declaration contexts are not supported and will
    result in an error.
-}
dhall :: QuasiQuoter
dhall = QuasiQuoter
    { quoteExp = staticDhallExpression . Text.pack
    , quotePat = const $ error "dhall quasi-quoter: Quoting patterns is not supported!"
    , quoteType = const $ error "dhall quasi-quoter: Quoting types is not supported!"
    , quoteDec = const $ error "dhall quasi-quoter: Quoting declarations is not supported!"
    }

{-| Convert a Dhall type to a Haskell type that does not require any new
    data declarations beyond the data declarations supplied as the first
    argument
-}
toNestedHaskellType
    :: (Eq a, Pretty a)
    => [HaskellType (Expr s a)]
    -- ^ All Dhall-derived data declarations
    --
    -- Used to replace complex types with references to one of these
    -- data declarations when the types match
    -> Expr s a
    -- ^ Dhall expression to convert to a simple Haskell type
    -> Q Type
toNestedHaskellType haskellTypes = loop
  where
    loop dhallType = case dhallType of
        Bool ->
            return (ConT ''Bool)

        Double ->
            return (ConT ''Double)

        Integer ->
            return (ConT ''Integer)

        Natural ->
            return (ConT ''Numeric.Natural.Natural)

        Text ->
            return (ConT ''Text)

        App List dhallElementType -> do
            haskellElementType <- loop dhallElementType

            return (AppT (ConT ''[]) haskellElementType)

        App Optional dhallElementType -> do
            haskellElementType <- loop dhallElementType

            return (AppT (ConT ''Maybe) haskellElementType)

        _   | Just haskellType <- List.find predicate haskellTypes -> do
                let name = Syntax.mkName (Text.unpack (typeName haskellType))

                return (ConT name)
            | otherwise -> do
            let document =
                    mconcat
                    [ "Unsupported nested type\n"
                    , "                                                                                \n"
                    , "Explanation: Not all Dhall types can be nested within Haskell datatype          \n"
                    , "declarations.  Specifically, only the following simple Dhall types are supported\n"
                    , "as a nested type inside of a data declaration:                                  \n"
                    , "                                                                                \n"
                    , "• ❰Bool❱                                                                        \n"
                    , "• ❰Double❱                                                                      \n"
                    , "• ❰Integer❱                                                                     \n"
                    , "• ❰Natural❱                                                                     \n"
                    , "• ❰Text❱                                                                        \n"
                    , "• ❰List a❱     (where ❰a❱ is also a valid nested type)                          \n"
                    , "• ❰Optional a❱ (where ❰a❱ is also a valid nested type)                          \n"
                    , "• Another matching datatype declaration                                         \n"
                    , "                                                                                \n"
                    , "The Haskell datatype generation logic encountered the following Dhall type:     \n"
                    , "                                                                                \n"
                    , " " <> Dhall.Util.insert dhallType <> "\n"
                    , "                                                                                \n"
                    , "... which did not fit any of the above criteria."
                    ]

            let message = Pretty.renderString (Dhall.Pretty.layout document)

            fail message
          where
            predicate haskellType =
                Core.judgmentallyEqual (code haskellType) dhallType

-- | A deriving clause for `Generic`.
derivingGenericClause :: DerivClause
derivingGenericClause = DerivClause (Just StockStrategy) [ ConT ''Generic ]

-- | Generates a `FromDhall` instances.
fromDhallInstance
    :: Syntax.Name -- ^ The name of the type the instances is for
    -> Q Exp       -- ^ A TH splice generating some `Dhall.InterpretOptions`
    -> Q [Dec]
fromDhallInstance n interpretOptions = [d|
    instance FromDhall $(pure $ ConT n) where
        autoWith = Dhall.genericAutoWithInputNormalizer $(interpretOptions)
    |]

-- | Generates a `ToDhall` instances.
toDhallInstance
    :: Syntax.Name -- ^ The name of the type the instances is for
    -> Q Exp       -- ^ A TH splice generating some `Dhall.InterpretOptions`
    -> Q [Dec]
toDhallInstance n interpretOptions = [d|
    instance ToDhall $(pure $ ConT n) where
        injectWith = Dhall.genericToDhallWithInputNormalizer $(interpretOptions)
    |]

-- | Convert a Dhall type to the corresponding Haskell datatype declaration
toDeclaration
    :: (Eq a, Pretty a)
    => GenerateOptions
    -> [HaskellType (Expr s a)]
    -> HaskellType (Expr s a)
    -> Q [Dec]
toDeclaration generateOptions@GenerateOptions{..} haskellTypes typ@MultipleConstructors{..} =
    case code of
        Union kts -> do
            let name = Syntax.mkName (Text.unpack typeName)

            let derivingClauses =
                    [ derivingGenericClause | generateFromDhallInstance || generateToDhallInstance ]

            constructors <- traverse (toConstructor generateOptions haskellTypes typeName) (Dhall.Map.toList kts)

            let interpretOptions = generateToInterpretOptions generateOptions typ

            fmap concat . sequence $
                [pure [DataD [] name [] Nothing constructors derivingClauses]] <>
                [ fromDhallInstance name interpretOptions | generateFromDhallInstance ] <>
                [ toDhallInstance name interpretOptions | generateToDhallInstance ]

        _ -> do
            let document =
                    mconcat
                    [ "Dhall.TH.makeHaskellTypes: Not a union type\n"
                    , "                                                                                \n"
                    , "Explanation: This function expects the ❰code❱ field of ❰MultipleConstructors❱ to\n"
                    , "evaluate to a union type.                                                       \n"
                    , "                                                                                \n"
                    , "For example, this is a valid Dhall union type that this function would accept:  \n"
                    , "                                                                                \n"
                    , "                                                                                \n"
                    , "    ┌──────────────────────────────────────────────────────────────────┐        \n"
                    , "    │ Dhall.TH.makeHaskellTypes (MultipleConstructors \"T\" \"< A | B >\") │        \n"
                    , "    └──────────────────────────────────────────────────────────────────┘        \n"
                    , "                                                                                \n"
                    , "                                                                                \n"
                    , "... which corresponds to this Haskell type declaration:                         \n"
                    , "                                                                                \n"
                    , "                                                                                \n"
                    , "    ┌────────────────┐                                                          \n"
                    , "    │ data T = A | B │                                                          \n"
                    , "    └────────────────┘                                                          \n"
                    , "                                                                                \n"
                    , "                                                                                \n"
                    , "... but the following Dhall type is rejected due to being a bare record type:   \n"
                    , "                                                                                \n"
                    , "                                                                                \n"
                    , "    ┌──────────────────────────────────────────────┐                            \n"
                    , "    │ Dhall.TH.makeHaskellTypes \"T\" \"{ x : Bool }\" │  Not valid                 \n"
                    , "    └──────────────────────────────────────────────┘                            \n"
                    , "                                                                                \n"
                    , "                                                                                \n"
                    , "The Haskell datatype generation logic encountered the following Dhall type:     \n"
                    , "                                                                                \n"
                    , " " <> Dhall.Util.insert code <> "\n"
                    , "                                                                                \n"
                    , "... which is not a union type."
                    ]

            let message = Pretty.renderString (Dhall.Pretty.layout document)

            fail message
toDeclaration generateOptions@GenerateOptions{..} haskellTypes typ@SingleConstructor{..} = do
    let name = Syntax.mkName (Text.unpack typeName)

    let derivingClauses =
            [ derivingGenericClause | generateFromDhallInstance || generateToDhallInstance ]

    let interpretOptions = generateToInterpretOptions generateOptions typ

    constructor <- toConstructor generateOptions haskellTypes typeName (constructorName, Just code)

    fmap concat . sequence $
        [pure [DataD [] name [] Nothing [constructor] derivingClauses]] <>
        [ fromDhallInstance name interpretOptions | generateFromDhallInstance ] <>
        [ toDhallInstance name interpretOptions | generateToDhallInstance ]

-- | Convert a Dhall type to the corresponding Haskell constructor
toConstructor
    :: (Eq a, Pretty a)
    => GenerateOptions
    -> [HaskellType (Expr s a)]
    -> Text
    -- ^ typeName
    -> (Text, Maybe (Expr s a))
    -- ^ @(constructorName, fieldType)@
    -> Q Con
toConstructor GenerateOptions{..} haskellTypes outerTypeName (constructorName, maybeAlternativeType) = do
    let name = Syntax.mkName (Text.unpack $ constructorModifier constructorName)

    let bang = Bang NoSourceUnpackedness NoSourceStrictness

    case maybeAlternativeType of
        Just dhallType
            | let predicate haskellType =
                    Core.judgmentallyEqual (code haskellType) dhallType
                    && typeName haskellType /= outerTypeName
            , Just haskellType <- List.find predicate haskellTypes -> do
                let innerName =
                        Syntax.mkName (Text.unpack (typeName haskellType))

                return (NormalC name [ (bang, ConT innerName) ])

        Just (Record kts) -> do
            let process (key, dhallFieldType) = do
                    haskellFieldType <- toNestedHaskellType haskellTypes dhallFieldType

                    return (Syntax.mkName (Text.unpack $ fieldModifier key), bang, haskellFieldType)

            varBangTypes <- traverse process (Dhall.Map.toList $ Core.recordFieldValue <$> kts)

            return (RecC name varBangTypes)

        Just dhallAlternativeType -> do
            haskellAlternativeType <- toNestedHaskellType haskellTypes dhallAlternativeType

            return (NormalC name [ (bang, haskellAlternativeType) ])

        Nothing ->
            return (NormalC name [])

-- | Generate a Haskell datatype declaration from a Dhall union type where
-- each union alternative corresponds to a Haskell constructor
--
-- For example, this Template Haskell splice:
--
-- > Dhall.TH.makeHaskellTypeFromUnion "T" "< A : { x : Bool } | B >"
--
-- ... generates this Haskell code:
--
-- > data T = A {x :: GHC.Types.Bool} | B
--
-- This is a special case of `Dhall.TH.makeHaskellTypes`:
--
-- > makeHaskellTypeFromUnion typeName code =
-- >     makeHaskellTypes [ MultipleConstructors{..} ]
makeHaskellTypeFromUnion
    :: Text
    -- ^ Name of the generated Haskell type
    -> Text
    -- ^ Dhall code that evaluates to a union type
    -> Q [Dec]
makeHaskellTypeFromUnion typeName code =
    makeHaskellTypes [ MultipleConstructors{..} ]

-- | Used by `makeHaskellTypes` and `makeHaskellTypesWith` to specify how to
-- generate Haskell types.
data HaskellType code
    -- | Generate a Haskell type with more than one constructor from a Dhall
    -- union type.
    = MultipleConstructors
        { typeName :: Text
        -- ^ Name of the generated Haskell type
        , code :: code
        -- ^ Dhall code that evaluates to a union type
        }
    -- | Generate a Haskell type with one constructor from any Dhall type.
    --
    -- To generate a constructor with multiple named fields, supply a Dhall
    -- record type.  This does not support more than one anonymous field.
    | SingleConstructor
        { typeName :: Text
        -- ^ Name of the generated Haskell type
        , constructorName :: Text
        -- ^ Name of the constructor
        , code :: code
        -- ^ Dhall code that evaluates to a type
        }
    deriving (Functor, Foldable, Traversable)

-- | This data type holds various options that let you control several aspects
-- how Haskell code is generated. In particular you can
--
--   * disable the generation of `FromDhall`/`ToDhall` instances.
--   * modify how a Dhall union field translates to a Haskell data constructor.
data GenerateOptions = GenerateOptions
    { constructorModifier :: Text -> Text
    -- ^ How to map a Dhall union field name to a Haskell constructor.
    -- Note: The `constructorName` of `SingleConstructor` will be passed to this function, too.
    , fieldModifier :: Text -> Text
    -- ^ How to map a Dhall record field names to a Haskell record field names.
    , generateFromDhallInstance :: Bool
    -- ^ Generate a `FromDhall` instance for the Haskell type
    , generateToDhallInstance :: Bool
    -- ^ Generate a `ToDhall` instance for the Haskell type
    }

-- | A default set of options used by `makeHaskellTypes`. That means:
--
--     * Constructors and fields are passed unmodified.
--     * Both `FromDhall` and `ToDhall` instances are generated.
defaultGenerateOptions :: GenerateOptions
defaultGenerateOptions = GenerateOptions
    { constructorModifier = id
    , fieldModifier = id
    , generateFromDhallInstance = True
    , generateToDhallInstance = True
    }

-- | This function generates `Dhall.InterpretOptions` that can be used for the
--   marshalling of the Haskell type generated according to the `GenerateOptions`.
--   I.e. those `Dhall.InterpretOptions` reflect the mapping done by
--   `constructorModifier` and `fieldModifier` on the value level.
generateToInterpretOptions :: GenerateOptions -> HaskellType (Expr s a) -> Q Exp
generateToInterpretOptions GenerateOptions{..} haskellType = [| Dhall.InterpretOptions
    { Dhall.fieldModifier = \ $(pure nameP) ->
        $(toCases fieldModifier $ fields haskellType)
    , Dhall.constructorModifier = \ $(pure nameP) ->
        $(toCases constructorModifier $ constructors haskellType)
    , Dhall.singletonConstructors = Dhall.singletonConstructors Dhall.defaultInterpretOptions
    }|]
    where
        constructors :: HaskellType (Expr s a) -> [Text]
        constructors SingleConstructor{..} = [constructorName]
        constructors MultipleConstructors{..} | Union kts <- code = Dhall.Map.keys kts
        constructors _ = []

        fields :: HaskellType (Expr s a) -> [Text]
        fields SingleConstructor{..} | Record kts <- code = Dhall.Map.keys kts
        fields MultipleConstructors{..} | Union kts <- code = Set.toList $ mconcat
            [ Dhall.Map.keysSet kts'
            | (_, Just (Record kts')) <- Dhall.Map.toList kts
            ]
        fields _ = []

        toCases :: (Text -> Text) -> [Text] -> Q Exp
        toCases f xs = do
            err <- [| Core.internalError $ "Unmatched " <> Text.pack (show $(pure nameE)) |]
            pure $ CaseE nameE $ map mkMatch xs <> [Match WildP (NormalB err) []]
            where
                mkMatch n = Match (textToPat $ f n) (NormalB $ textToExp n) []

        nameE :: Exp
        nameE = Syntax.VarE $ Syntax.mkName "n"

        nameP :: Pat
        nameP = Syntax.VarP $ Syntax.mkName "n"

        textToExp :: Text -> Exp
        textToExp = Syntax.LitE . Syntax.StringL . Text.unpack

        textToPat :: Text -> Pat
        textToPat = Syntax.LitP . Syntax.StringL . Text.unpack

-- | Generate a Haskell datatype declaration with one constructor from a Dhall
-- type.
--
-- This comes in handy if you need to keep Dhall types and Haskell types in
-- sync.  You make the Dhall types the source of truth and use Template Haskell
-- to generate the matching Haskell type declarations from the Dhall types.
--
-- For example, given this Dhall code:
--
-- > -- ./Department.dhall
-- > < Sales | Engineering | Marketing >
--
-- > -- ./Employee.dhall
-- > { name : Text, department : ./Department.dhall }
--
-- ... this Template Haskell splice:
--
-- > {-# LANGUAGE DeriveAnyClass     #-}
-- > {-# LANGUAGE DeriveGeneric      #-}
-- > {-# LANGUAGE DerivingStrategies #-}
-- > {-# LANGUAGE OverloadedStrings  #-}
-- > {-# LANGUAGE TemplateHaskell    #-}
-- >
-- > Dhall.TH.makeHaskellTypes
-- >     [ MultipleConstructors "Department" "./tests/th/Department.dhall"
-- >     , SingleConstructor "Employee" "MakeEmployee" "./tests/th/Employee.dhall"
-- >     ]
--
-- ... generates this Haskell code:
--
-- > data Department = Engineering | Marketing | Sales
-- >   deriving stock (GHC.Generics.Generic)
-- >   deriving anyclass (Dhall.FromDhall, Dhall.ToDhall)
-- >
-- > data Employee
-- >   = MakeEmployee {department :: Department,
-- >                   name :: Data.Text.Internal.Text}
-- >   deriving stock (GHC.Generics.Generic)
-- >   deriving anyclass (Dhall.FromDhall, Dhall.ToDhall)
--
-- Carefully note that the conversion makes a best-effort attempt to
-- auto-detect when a Dhall type (like @./Employee.dhall@) refers to another
-- Dhall type (like @./Department.dhall@) and replaces that reference with the
-- corresponding Haskell type.
--
-- This Template Haskell splice requires you to enable the following extensions:
--
-- * @DeriveGeneric@
-- * @DerivingAnyClass@
-- * @DerivingStrategies@
--
-- By default, the generated types only derive `GHC.Generics.Generic`,
-- `Dhall.FromDhall`, and `Dhall.ToDhall`.  To add any desired instances (such
-- as `Eq`\/`Ord`\/`Show`), you can use the @StandaloneDeriving@ language
-- extension, like this:
--
-- > {-# LANGUAGE DeriveAnyClass     #-}
-- > {-# LANGUAGE DeriveGeneric      #-}
-- > {-# LANGUAGE DerivingStrategies #-}
-- > {-# LANGUAGE OverloadedStrings  #-}
-- > {-# LANGUAGE StandaloneDeriving #-}
-- > {-# LANGUAGE TemplateHaskell    #-}
-- >
-- > Dhall.TH.makeHaskellTypes
-- >     [ MultipleConstructors "Department" "./tests/th/Department.dhall"
-- >     , SingleConstructor "Employee" "MakeEmployee" "./tests/th/Employee.dhall"
-- >     ]
-- >
-- > deriving instance Eq   Department
-- > deriving instance Ord  Department
-- > deriving instance Show Department
-- >
-- > deriving instance Eq   Employee
-- > deriving instance Ord  Employee
-- > deriving instance Show Employee
makeHaskellTypes :: [HaskellType Text] -> Q [Dec]
makeHaskellTypes = makeHaskellTypesWith defaultGenerateOptions

-- | Like `makeHaskellTypes`, but with the ability to customize the generated
-- Haskell code by passing `GenerateOptions`.
--
-- For instance, `makeHaskellTypes` is implemented using this function:
--
-- > makeHaskellTypes = makeHaskellTypesWith defaultGenerateOptions
makeHaskellTypesWith :: GenerateOptions -> [HaskellType Text] -> Q [Dec]
makeHaskellTypesWith generateOptions haskellTypes = do
    Syntax.runIO (GHC.IO.Encoding.setLocaleEncoding System.IO.utf8)

    haskellTypes' <- traverse (traverse (Syntax.runIO . Dhall.inputExpr)) haskellTypes

    concat <$> traverse (toDeclaration generateOptions haskellTypes') haskellTypes'
