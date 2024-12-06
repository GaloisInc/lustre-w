module Language.Lustre.Semantics.Const
  ( evalConst, evalSel, evalSelFun, Env(..), emptyEnv, evalIntConst, valToExpr
  , Value(..)
  )
  where

import Data.Map ( Map )
import qualified Data.Map as Map
import Control.Monad(msum)

import Language.Lustre.Name
import Language.Lustre.AST
import Language.Lustre.Pretty(showPP)
import Language.Lustre.Semantics.Value
import Language.Lustre.Semantics.BuiltIn

data Env = Env
  { envConsts   :: Map OrigName Value
  , envStructs  :: Map OrigName [ (Label, Maybe Value) ]
  }

emptyEnv :: Env
emptyEnv = Env { envConsts = Map.empty
               , envStructs = Map.empty
               }


-- | Evaluate a constant expression of type @int@.
evalIntConst :: Env -> Expression -> EvalM Integer
evalIntConst env e =
  do v <- evalConst env e
     case v of
       VInt i -> pure i
       _      -> typeError "evalIntConst" "an `int`"


-- | Evaluate a constant expression.
-- Note this does not produce 'Nil' values, unless some came in the 'Env'.
evalConst :: Env -> Expression -> EvalM Value
evalConst env expr =
  case expr of

    ERange _ e -> evalConst env e

    Lit l ->
      case l of
        Int n  -> sInt n
        Real n -> sReal n
        Bool n -> sBool n

    WithThenElse be t e ->
      do bv <- evalConst env be
         case bv of
           VBool b -> if b then evalConst env t else evalConst env e
           _       -> typeError "with-then-else" "A `bool`"

    Const e _  -> evalConst env e

    When {}    -> bad "`when` is not a constant expression."
    Merge {}   -> bad "`merge` is not a constant expression."

    Var x ->
      case Map.lookup (nameOrigName x) (envConsts env) of
        Just v  -> pure v
        Nothing -> bad ("Undefined variable `" ++ show x ++ "`.")

    Tuple {}      -> bad "Unexpected constant tuple."

    Array es -> sArray =<< mapM (evalConst env) es

    Struct s fes ->
      case Map.lookup name (envStructs env) of
        Nothing -> bad ("Undefined struct type `" ++ show s ++ "`.")
        Just structDef ->
          do fs  <- Map.fromList <$> mapM (evalField env) fes
             let mkField (f,mb) =
                   case msum [ Map.lookup f fs, mb ] of
                     Just v  -> pure (Field f v)
                     Nothing -> bad ("Missing field `" ++ show f ++ "`.")
             fs1 <- mapM mkField structDef
             pure (VStruct name fs1)
      where name = nameOrigName s

    UpdateStruct mbS y fes ->
      do uv <- evalConst env y
         fs <- Map.fromList <$> mapM (evalField env) fes
         case uv of
           VStruct s fs1
            | maybe True ((== s) . nameOrigName) mbS ->
              pure $ VStruct s
                       [ Field i v1
                       | Field i v <- fs1
                       , let v1 = Map.findWithDefault v i fs
                       ]
             | otherwise -> typeError "struct update"
                                      ("a `" ++ showPP s ++ "`")

           _ -> typeError "struct update" "a struct"

    Select e sel ->
      do s <- evalSel env sel
         evalSelFun s =<< evalConst env e

    Call (NodeInst (CallPrim _ p) []) es cl _ ->
      do case cl of
           BaseClock -> pure ()
           _ -> bad "calls with a clock do not make sense for constants"
         vs <- mapM (evalConst env) es
         case (p, vs) of

           (ITE, [b,t,e]) -> sITE b t e

           (Op1 op, [v]) ->
             case op of
               Not       -> sNot v
               Neg       -> sNeg v
               IntCast   -> sReal2Int v
               RealCast  -> sInt2Real v
               FloorCast -> sReal2IntFloor v

               Pre       -> bad "`pre` is not a constant"
               Current   -> bad "`current` is not a constant"

           (Op2 op, [x,y]) ->
             case op of
               Fby        -> bad "`fby` is not a constant"
               FbyArr     -> bad "`->` is not a constant"
               CurrentWith-> bad "`current` is not a constant"

               And        -> sAnd x y
               Or         -> sOr x y
               Xor        -> sXor x y
               Implies    -> sImplies x y

               Eq         -> sEq x y
               Neq        -> sNeq x y

               Lt         -> sLt x y
               Leq        -> sLeq x y
               Gt         -> sGt x y
               Geq        -> sGeq x y

               Mul        -> sMul x y
               Mod        -> sMod x y
               Div        -> sDiv x y
               Add        -> sAdd x y
               Sub        -> sSub x y
               Power      -> sPow x y

               Replicate  -> sReplicate x y
               Concat     -> sConcat x y

           (OpN op, _) ->
             case op of
               AtMostOne -> sBoolRed "at-most-one" 0 1 vs
               Nor       -> sBoolRed "nor" 0 0 vs

           (_, _) -> bad ("Unknown primitive expression: " ++ showPP p)


    Call {} -> bad "`call` is not a constant expression."

  where
  bad = crash "evalConst"


evalField :: Env -> Field Expression -> EvalM (Label, Value)
evalField env (Field f v) = do v1 <- evalConst env v
                               pure (f,v1)

-- | Evaluate a selector.
evalSel :: Env -> Selector Expression -> EvalM (Selector Value)
evalSel env sel =
  case sel of

    SelectField f ->
      pure (SelectField f)

    SelectElement ei ->
      do i <- evalConst env ei
         pure (SelectElement i)

    SelectSlice s   ->
      do start <- evalConst env (arrayStart s)
         end   <- evalConst env (arrayEnd s)
         step  <- mapM (evalConst env) (arrayStep s)
         pure (SelectSlice ArraySlice { arrayStart = start
                                      , arrayEnd   = end
                                      , arrayStep  = step
                                      })


-- | Evaluate a selector to a selecting function.
evalSelFun :: Selector Value -> Value -> EvalM Value
evalSelFun sel v =
  case sel of
    SelectField f   -> sSelectField f v
    SelectElement i -> sSelectIndex i v
    SelectSlice s   -> sSelectSlice s v


-- | Convert an evaluated expression back into an ordinary expression.
-- Note that the resulting expression does not have meaninful position
-- information.
valToExpr :: Value -> Expression
valToExpr val =
  case val of
    VInt i        -> Lit (Int i)
    VBool b       -> Lit (Bool b)
    VReal r       -> Lit (Real r)

    -- we keep enums as variables, leaving representation choice for later.
    VEnum _ x     -> Var (origNameToName x)
    VStruct s fs  -> Struct (origNameToName s) (fmap (fmap valToExpr) fs)

    VArray  vs    -> Array (map valToExpr vs)




