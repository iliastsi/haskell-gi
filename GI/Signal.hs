module GI.Signal
    ( genSignal
    , genCallback
    ) where

import Control.Applicative ((<$>))
import Control.Monad (when)
import Control.Monad (forM, forM_)
import Data.List (intercalate)
import Data.Typeable (typeOf)

import Text.Show.Pretty (ppShow)

import GI.API
import GI.Callable (hOutType, arrayLengths, wrapMaybe)
import GI.Code
import GI.Conversions
import GI.SymbolNaming
import GI.Transfer (freeElements, freeContainer)
import GI.Type
import GI.Util (split, parenthesize, withComment)
import GI.Internal.ArgInfo

-- The prototype of the callback on the Haskell side (what users of
-- the binding will see)
genHaskellCallbackPrototype :: Callable -> String -> [Arg] -> [Arg] ->
                               CodeGen ()
genHaskellCallbackPrototype cb name' hInArgs hOutArgs =
  group $ do
    line $ "type " ++ name' ++ " ="
    indent $ do
      forM_ hInArgs $ \arg -> do
        ht <- haskellType (argType arg)
        line $ (show $ if wrapMaybe arg
                       then maybeT ht
                       else ht) ++ " ->"
      ret <- hOutType cb hOutArgs False
      line $ show $ io $ if returnMayBeNull cb
                         then maybeT ret
                         else ret

-- Prototype of the callback on the C side
genCCallbackPrototype :: Callable -> String -> Bool -> CodeGen ()
genCCallbackPrototype cb name' isSignal =
  group $ do
    line $ "type " ++ name' ++ "C ="
    indent $ do
      when isSignal $ line $ withComment "Ptr () ->" "object"
      forM_ (args cb) $ \arg -> do
        ht <- foreignType $ argType arg
        let ht' = if direction arg /= DirectionIn
                  then ptr ht
                  else ht
        line $ show ht' ++ " ->"
      when isSignal $ line $ withComment "Ptr () ->" "user_data"
      ret <- io <$> case returnType cb of
                      TBasicType TVoid -> return $ typeOf ()
                      t -> foreignType t
      line $ show ret

-- Generator for wrappers callable from C
genCallbackWrapperFactory :: String -> CodeGen ()
genCallbackWrapperFactory name' =
  group $ do
    line $ "foreign import ccall \"wrapper\""
    indent $ line $ "mk" ++ name' ++ " :: "
               ++ name' ++ "C -> IO (FunPtr " ++ name' ++ "C)"

-- Wrap a conversion of a nullable object into "Maybe" object, by
-- checking whether the pointer is NULL.
convertNullable :: String -> CodeGen String -> CodeGen String
convertNullable aname c = do
  line $ "maybe" ++ ucFirst aname ++ " <-"
  indent $ do
    line $ "if " ++ aname ++ " == nullPtr"
    line $ "then return Nothing"
    line $ "else do"
    indent $ do
             unpacked <- c
             line $ "return $ Just " ++ unpacked
    return $ "maybe" ++ ucFirst aname

-- Convert a non-zero terminated out array, stored in a variable
-- named "aname", into the corresponding Haskell object.
convertCallbackInCArray :: Callable -> Arg -> Type -> String -> CodeGen String
convertCallbackInCArray callable arg t@(TCArray False (-1) length _) aname = do
  if length > -1 then do
          if wrapMaybe arg
          then do convertNullable aname convertAndFree
          else convertAndFree
  else
      -- Not much we can do, we just pass the pointer along, and let
      -- the callback deal with it.
      return aname
  where
    lname = escapeReserved $ argName $ (args callable)!!length

    convertAndFree :: CodeGen String
    convertAndFree = do
      unpacked <- convert aname $ unpackCArray lname t (transfer arg)
      -- Free the memory associated with the array
      when ((transfer arg) == TransferEverything) $
           mapM_ line =<< freeElements t aname lname
      when ((transfer arg) /= TransferNothing) $
           mapM_ line =<< freeContainer t aname
      return unpacked

-- Remove the warning, this should never be reached.
convertCallbackInCArray _ t _ _ =
    error $ "convertOutCArray : unexpected " ++ show t

-- Prepare an argument for passing into the Haskell side.
prepareArgForCall :: Callable -> Arg -> CodeGen String
prepareArgForCall cb arg = do
  case direction arg of
    DirectionIn -> prepareInArg cb arg
    DirectionInout -> prepareInoutArg arg
    DirectionOut -> error "Unexpected DirectionOut!"

prepareInArg :: Callable -> Arg -> CodeGen String
prepareInArg cb arg = do
  let name = (escapeReserved . argName) arg
  case argType arg of
    t@(TCArray False _ _ _) -> convertCallbackInCArray cb arg t name
    _ -> do
      let c = convert name $ fToH (argType arg) (transfer arg)
      if wrapMaybe arg
      then convertNullable name c
      else c

prepareInoutArg :: Arg -> CodeGen String
prepareInoutArg arg = do
  let name = (escapeReserved . argName) arg
  name' <- genConversion name $ apply $ M "peek"
  convert name' $ fToH (argType arg) (transfer arg)

saveOutArg :: Arg -> CodeGen ()
saveOutArg arg = do
  let name = (escapeReserved . argName) arg
      name' = "out" ++ name
  when (transfer arg /= TransferEverything) $
       line $ "-- XXX Unexpected transfer type for \"" ++ name
                ++ "\". Leak?"
  name'' <- convert name' $ hToF (argType arg) TransferEverything
  line $ "poke " ++ name ++ " " ++ name''

-- The wrapper itself, marshalling to and from Haskell. The first
-- argument is possibly a pointer to a FunPtr to free (via
-- freeHaskellFunPtr) once the callback is run once, or Nothing if the
-- FunPtr will be freed by someone else (the function registering the
-- callback for ScopeTypeCall, or a destroy notifier for
-- ScopeTypeNotified).
genCallbackWrapper :: Callable -> String -> [Arg] -> [Arg] -> [Arg] ->
                      Bool -> CodeGen ()
genCallbackWrapper cb name' dataptrs hInArgs hOutArgs isSignal = do
  let cName arg = if arg `elem` dataptrs
                  then "_"
                  else (escapeReserved . argName) arg
      cArgNames = map cName (args cb)

  group $ do
    line $ lcFirst name' ++ "Wrapper ::"
    indent $ do
      when (not isSignal) $
           line $ "Maybe (Ptr (FunPtr (" ++ name' ++ "C))) ->"
      line $ name' ++ " ->"
      when isSignal $ line "Ptr () ->"
      forM_ (args cb) $ \arg -> do
        ht <- foreignType $ argType arg
        let ht' = if direction arg /= DirectionIn
                  then ptr ht
                  else ht
        line $ show ht' ++ " ->"
      when isSignal $ line "Ptr () ->"
      ret <- io <$> case returnType cb of
                      TBasicType TVoid -> return $ typeOf ()
                      t -> foreignType t
      line $ show ret

    let allArgs = if isSignal
                  then intercalate " " $ ["_cb", "_"] ++ cArgNames ++ ["_"]
                  else intercalate " " $ ["funptrptr", "_cb"] ++ cArgNames
    line $ lcFirst name' ++ "Wrapper " ++ allArgs ++ " = do"
    indent $ do
      hInNames <- forM hInArgs (prepareArgForCall cb)

      let maybeReturn = case returnType cb of
                          TBasicType TVoid -> []
                          _                -> ["result"]
          argName' = escapeReserved . argName
          returnVars = maybeReturn ++ (map (("out"++) . argName') hOutArgs)
          returnBind = case returnVars of
                         [] -> ""
                         r:[] -> r ++ " <- "
                         _ -> parenthesize (intercalate ", " returnVars) ++ " <- "
      line $ returnBind ++ "_cb " ++ concatMap (" " ++) hInNames

      forM_ hOutArgs saveOutArg

      when (not isSignal) $ line "maybeReleaseFunPtr funptrptr"

      when (returnType cb /= TBasicType TVoid) $ do
           result' <- convert "result" $ hToF (returnType cb) (returnTransfer cb)
           line $ "return " ++ result'

genCallback :: Name -> Callback -> CodeGen ()
genCallback n (Callback cb) = do
  name' <- upperName n
  line $ "-- callback " ++ name'

  let -- user_data pointers, which we generically omit
      dataptrs = map ((args cb)!!) . filter (/= -1) . map argClosure $ args cb
      hidden = dataptrs ++ arrayLengths cb

      inArgs = filter ((/= DirectionOut) . direction) $ args cb
      hInArgs = filter (not . (`elem` hidden)) inArgs
      outArgs = filter ((/= DirectionIn) . direction) $ args cb
      hOutArgs = filter (not . (`elem` hidden)) outArgs

  when (skipReturn cb) $
       error $ "Callbacks skipping return unsupported :\n"
                 ++ ppShow n ++ "\n" ++ ppShow cb

  genHaskellCallbackPrototype cb name' hInArgs hOutArgs

  genCCallbackPrototype cb name' False

  genCallbackWrapperFactory name'

  genCallbackWrapper cb name' dataptrs hInArgs hOutArgs False

genSignal :: Name -> Signal -> Name -> CodeGen ()
genSignal sn (Signal { sigCallable = cb }) on = do
  on' <- upperName on
  let (w:ws) = split '-' $ name sn
      sn' = w ++ concatMap ucFirst ws
  line $ "-- signal " ++ on' ++ "::" ++ name sn

  let inArgs = filter ((/= DirectionOut) . direction) $ args cb
      hInArgs = filter (not . (`elem` (arrayLengths cb))) inArgs
      outArgs = filter ((/= DirectionIn) . direction) $ args cb
      hOutArgs = filter (not . (`elem` (arrayLengths cb))) outArgs
      signalConnectorName = on' ++ ucFirst sn'
      cbType = signalConnectorName ++ "Callback"

  genHaskellCallbackPrototype cb cbType hInArgs hOutArgs

  genCCallbackPrototype cb cbType True

  genCallbackWrapperFactory cbType

  genCallbackWrapper cb cbType [] hInArgs hOutArgs True

  -- Wrapper for connecting functions to the signal
  -- We can connect to a signal either before the default handler runs
  -- ("on...") or after the default handler runs (after...). We
  -- provide convenient wrappers for both cases.
  group $ do
    line $ "on" ++ signalConnectorName ++ " obj cb = connect"
             ++ signalConnectorName ++ " obj cb False"
    line $ "after" ++ signalConnectorName ++ " obj cb = connect"
             ++ signalConnectorName ++ " obj cb True"

  group $ do
    let fullName = "connect" ++ signalConnectorName
        signatureConstraints =
          "(ManagedPtr a, GObject a) =>"
        signatureArgs = "a -> " ++ cbType ++ " -> Bool -> IO CULong"
    line $ fullName ++ " :: " ++ signatureConstraints
    line $ replicate (4 + length fullName) ' ' ++ signatureArgs
    line $ fullName ++ " obj cb after = do"
    indent $ do
        line $ "cb' <- mk" ++ cbType ++ " (" ++ lcFirst cbType ++ "Wrapper cb)"
        line $ "connectSignal obj \"" ++ (name sn) ++ "\" cb' after"