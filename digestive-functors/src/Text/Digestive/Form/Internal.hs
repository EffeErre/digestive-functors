--------------------------------------------------------------------------------
-- | This module mostly meant for internal usage, and might change between minor
-- releases.
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE Rank2Types                #-}
module Text.Digestive.Form.Internal
    ( Form
    , FormTree (..)
    , SomeForm (..)
    , Ref
    , transform
    , monadic
    , toFormTree
    , children
    , (.:)
    , getRef
    , lookupForm
    , lookupList
    , toField
    , queryField
    , eval
    , formMapView

      -- * Debugging
    , debugFormPaths
    ) where


--------------------------------------------------------------------------------
import           Control.Applicative                (Alternative (..),
                                                     Applicative (..))
import           Control.Monad                      (liftM, liftM2,
                                                     mapAndUnzipM, (>=>))
import           Control.Monad.Identity             (Identity (..))
import           Data.Monoid                        (Monoid)
import           Data.Traversable                   (mapM, sequenceA)
import           Prelude                            hiding (mapM)


--------------------------------------------------------------------------------
import           Data.Text                          (Text)
import qualified Data.Text                          as T


--------------------------------------------------------------------------------
import           Text.Digestive.Form.Internal.Field
import           Text.Digestive.Form.List
import           Text.Digestive.Types


--------------------------------------------------------------------------------
-- | Base type for a form.
--
-- The three type parameters are:
--
-- * @v@: the type for textual information, displayed to the user. For example,
--   error messages are of this type. @v@ stands for "view".
--
-- * @m@: the monad in which validators operate. The classical example is when
--   validating input requires access to a database, in which case this @m@
--   should be an instance of @MonadIO@.
--
-- * @a@: the type of the value returned by the form, used for its Applicative
--   instance.
--
type Form v m a = FormTree m v m a


--------------------------------------------------------------------------------
data FormTree t v m a where
    -- Setting refs
    Ref     :: Ref -> FormTree t v m a -> FormTree t v m a

    -- Applicative interface
    Pure    :: Field v a -> FormTree t v m a
    App     :: FormTree t v m (b -> a)
            -> FormTree t v m b
            -> FormTree t v m a

    -- Alternative interface
    Empty   :: FormTree t v m a
    Alt     :: FormTree t v m a
            -> FormTree t v m a
            -> FormTree t v m a

    -- Modifications
    Map     :: (b -> m (Result v a)) -> FormTree t v m b -> FormTree t v m a
    Monadic :: t (FormTree t v m a) -> FormTree t v m a

    -- Dynamic lists
    List    :: DefaultList (FormTree t v m a)  -- Not the optimal structure
            -> FormTree t v m [Int]
            -> FormTree t v m [a]


--------------------------------------------------------------------------------
instance Monad m => Functor (FormTree t v m) where
    fmap = transform . (return .) . (return .)


--------------------------------------------------------------------------------
instance (Monad m, Monoid v) => Applicative (FormTree t v m) where
    pure x  = Pure (Singleton x)
    x <*> y = App x y


--------------------------------------------------------------------------------
instance (Monad m, Monoid v) => Alternative (FormTree t v m) where
    empty   = Empty
    x <|> y = Alt x y


--------------------------------------------------------------------------------
instance Show (FormTree Identity v m a) where
    show = unlines . showForm


--------------------------------------------------------------------------------
data SomeForm v m = forall a. SomeForm (FormTree Identity v m a)


--------------------------------------------------------------------------------
instance Show (SomeForm v m) where
    show (SomeForm f) = show f


--------------------------------------------------------------------------------
type Ref = Text


--------------------------------------------------------------------------------
showForm :: FormTree Identity v m a -> [String]
showForm form = case form of
    (Ref r x) -> ("Ref " ++ show r) : map indent (showForm x)
    (Pure x)  -> ["Pure (" ++ show x ++ ")"]
    (App x y) -> concat
        [ ["App"]
        , map indent (showForm x)
        , map indent (showForm y)
        ]
    Empty       -> ["Empty"]
    (Alt x y)   -> concat
        [ ["Alt"]
        , map indent (showForm x)
        , map indent (showForm y)
        ]
    (Map _ x)   -> "Map _" : map indent (showForm x)
    (Monadic x) -> "Monadic" : map indent (showForm $ runIdentity x)
    (List _ is) -> concat
        [ ["List <defaults>"]  -- TODO show defaults
        , map indent (showForm is)
        ]
  where
    indent = ("  " ++)


--------------------------------------------------------------------------------
transform :: Monad m
          => (a -> m (Result v b)) -> FormTree t v m a -> FormTree t v m b
transform f (Map g x) = flip Map x $ \y -> bindResult (g y) f
transform f x         = Map f x


--------------------------------------------------------------------------------
monadic :: m (Form v m a) -> Form v m a
monadic = Monadic


--------------------------------------------------------------------------------
toFormTree :: Monad m => Form v m a -> m (FormTree Identity v m a)
toFormTree (Ref r x)   = liftM (Ref r) (toFormTree x)
toFormTree (Pure x)    = return $ Pure x
toFormTree (App x y)   = liftM2 App (toFormTree x) (toFormTree y)
toFormTree Empty       = return Empty
toFormTree (Alt x y)   = liftM2 Alt (toFormTree x) (toFormTree y)
toFormTree (Map f x)   = liftM (Map f) (toFormTree x)
toFormTree (Monadic x) = x >>= toFormTree >>= return . Monadic . Identity
toFormTree (List d is) = liftM2 List (mapM toFormTree d) (toFormTree is)


--------------------------------------------------------------------------------
children :: FormTree Identity v m a -> [SomeForm v m]
children (Ref _ x )  = children x
children (Pure _)    = []
children (App x y)   = [SomeForm x, SomeForm y]
children Empty       = []
children (Alt x y)   = [SomeForm x, SomeForm y]
children (Map _ x)   = children x
children (Monadic x) = children $ runIdentity x
children (List _ is) = [SomeForm is]


--------------------------------------------------------------------------------
pushRef :: Monad t => Ref -> FormTree t v m a -> FormTree t v m a
pushRef = Ref


--------------------------------------------------------------------------------
-- | Operator to set a name for a subform.
(.:) :: Monad m => Text -> Form v m a -> Form v m a
(.:) = pushRef
infixr 5 .:


--------------------------------------------------------------------------------
popRef :: FormTree Identity v m a -> (Maybe Ref, FormTree Identity v m a)
popRef form = case form of
    (Ref r x)   -> (Just r, x)
    (Pure _)    -> (Nothing, form)
    (App _ _)   -> (Nothing, form)
    Empty       -> (Nothing, form)
    (Alt _ _)   -> (Nothing, form)
    (Map f x)   -> let (r, form') = popRef x in (r, Map f form')
    (Monadic x) -> popRef $ runIdentity x
    (List _ _)  -> (Nothing, form)


--------------------------------------------------------------------------------
getRef :: FormTree Identity v m a -> Maybe Ref
getRef = fst . popRef


--------------------------------------------------------------------------------
lookupForm :: Path -> FormTree Identity v m a -> [SomeForm v m]
lookupForm path = go path . SomeForm
  where
    -- Note how we use `popRef` to strip the ref away. This is really important.
    go []       form            = [form]
    go (r : rs) (SomeForm form) = case popRef form of
        (Just r', stripped)
            | r == r' && null rs -> [SomeForm stripped]
            | r == r'            -> children form >>= go rs
            | otherwise          -> []
        (Nothing, _)             -> children form >>= go (r : rs)


--------------------------------------------------------------------------------
-- | Always returns a List
lookupList :: Path -> FormTree Identity v m a -> SomeForm v m
lookupList path form = case candidates of
    (SomeForm f : _) -> SomeForm f
    []               -> error $ "Text.Digestive.Form.Internal: " ++
        T.unpack (fromPath path) ++ ": expected List, but got another form"
  where
    candidates =
        [ x
        | SomeForm f <- lookupForm path form
        , x          <- getList f
        ]

    getList :: forall a v m. FormTree Identity v m a -> [SomeForm v m]
    getList (Ref _ _)   = []
    getList (Pure _)    = []
    getList (App x y)   = getList x ++ getList y
    getList Empty       = []
    getList (Alt x y)   = getList x ++ getList y
    getList (Map _ x)   = getList x
    getList (Monadic x) = getList $ runIdentity x
    getList (List d is) = [SomeForm (List d is)]


--------------------------------------------------------------------------------
toField :: FormTree Identity v m a -> Maybe (SomeField v)
toField (Ref _ x)   = toField x
toField (Pure x)    = Just (SomeField x)
toField (App _ _)   = Nothing
toField Empty       = Nothing
toField (Alt _ _)   = Nothing
toField (Map _ x)   = toField x
toField (Monadic x) = toField (runIdentity x)
toField (List _ _)  = Nothing


--------------------------------------------------------------------------------
queryField :: Path
           -> FormTree Identity v m a
           -> (forall b. Field v b -> c)
           -> c
queryField path form f = case lookupForm path form of
    []                   -> error $ ref ++ " does not exist"
    (SomeForm form' : _) -> case toField form' of
        Just (SomeField field) -> f field
        _                      -> error $ ref ++ " is not a field"
  where
    ref = T.unpack $ fromPath path


--------------------------------------------------------------------------------
ann :: Path -> Result v a -> Result [(Path, v)] a
ann _    (Success x) = Success x
ann path (Error x)   = Error [(path, x)]


--------------------------------------------------------------------------------
eval :: Monad m => Method -> Env m -> FormTree Identity v m a
     -> m (Result [(Path, v)] a, [(Path, FormInput)])
eval = eval' []

eval' :: Monad m => Path -> Method -> Env m -> FormTree Identity v m a
      -> m (Result [(Path, v)] a, [(Path, FormInput)])

eval' path method env form = case form of
    Ref r x -> eval' (path ++ [r]) method env x

    Pure field -> do
        val <- env path
        let x = evalField method val field
        return $ (pure x, [(path, v) | v <- val])

    App x y -> do
        (x', inp1) <- eval' path method env x
        (y', inp2) <- eval' path method env y
        return (x' <*> y', inp1 ++ inp2)

    Empty -> return (Error [], [])  -- TODO maybe generate error message...

    Alt x y -> do
        (x', inp1) <- eval' path method env x
        case x' of
            Success _ -> return (x', inp1)
            _         -> eval' path method env y

    Map f x -> do
        (x', inp) <- eval' path method env x
        x''       <- bindResult (return x') (f >=> return . ann path)
        return (x'', inp)

    Monadic x -> eval' path method env $ runIdentity x

    List defs fis -> do
        (ris, inp1) <- eval' path method env fis
        case ris of
            Error errs -> return (Error errs, inp1)
            Success is -> do
                (results, inps) <- mapAndUnzipM
                    -- TODO fix head defs
                    (\i -> eval' (path ++ [T.pack $ show i])
                        method env $ defs `defaultListIndex` i) is
                return (sequenceA results, inp1 ++ concat inps)


--------------------------------------------------------------------------------
formMapView :: Monad m
            => (v -> w) -> FormTree Identity v m a -> FormTree Identity w m a
formMapView f (Ref r x)   = Ref r $ formMapView f x
formMapView f (Pure x)    = Pure $ fieldMapView f x
formMapView f (App x y)   = App (formMapView f x) (formMapView f y)
formMapView _ Empty       = Empty
formMapView f (Alt x y)   = Alt (formMapView f x) (formMapView f y)
formMapView f (Map g x)   = Map (g >=> return . resultMapError f) (formMapView f x)
formMapView f (Monadic x) = formMapView f $ runIdentity x
formMapView f (List d is) = List (fmap (formMapView f) d) (formMapView f is)


--------------------------------------------------------------------------------
-- | Utility: bind for 'Result' inside another monad
bindResult :: Monad m
           => m (Result v a) -> (a -> m (Result v b)) -> m (Result v b)
bindResult mx f = do
    x <- mx
    case x of
        Error errs  -> return $ Error errs
        Success x'  -> f x'


--------------------------------------------------------------------------------
-- | Debugging purposes
debugFormPaths :: Monad m => FormTree Identity v m a -> [Path]
debugFormPaths (Pure _)    = [[]]
debugFormPaths (App x y)   = debugFormPaths x ++ debugFormPaths y
debugFormPaths Empty       = [[]]
debugFormPaths (Alt x y)   = debugFormPaths x ++ debugFormPaths y
debugFormPaths (Map _ x)   = debugFormPaths x
debugFormPaths (Monadic x) = debugFormPaths $ runIdentity x
debugFormPaths (List d is) =
    debugFormPaths is ++
    (map ("0" :) $ debugFormPaths $ d `defaultListIndex` 0)
debugFormPaths (Ref r x)   = map (r :) $ debugFormPaths x
