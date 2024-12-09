{-# Language FlexibleInstances #-}
{-# Language OverloadedStrings #-}
{-# Language TypeSynonymInstances #-}
-- | Translate siplified Lustre into the Core representation.
module Language.Lustre.Transform.ToCore
  ( getEnumInfo, EnumInfo, evalNodeDecl, enumFromVal
  ) where

import Data.Map(Map)
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Semigroup ( (<>) )
import Data.Text (Text)
import qualified Data.Text as Text
import MonadLib hiding (Label)
import AlexTools(SourceRange(..),SourcePos(..))
import Data.Foldable(toList)
import Data.Graph.SCC(stronglyConnComp)

import Language.Lustre.Name
import qualified Language.Lustre.AST  as P
import qualified Language.Lustre.Core as C
import Language.Lustre.Core (CoreName, coreNameFromOrig)
import Language.Lustre.Monad
import Language.Lustre.Panic
import Language.Lustre.Pretty(showPP)


data EnumInfo = EnumInfo
  { enumConMap :: !(Map OrigName C.Literal)
    -- ^ Maps enum constructor to value

  , enumMax :: !(Map OrigName C.Literal)
    -- ^ Maps enum type to largest con

  , enumFromVal :: !(Map (OrigName,Integer) OrigName)
    -- ^ Given a type and a number, give back the constructor.
  }

blankEnumInfo :: EnumInfo
blankEnumInfo = EnumInfo { enumConMap = Map.empty
                         , enumMax = Map.empty
                         , enumFromVal = Map.empty
                         }

-- | Compute info about enums from some top-level declarations.
-- The result maps the original names of enum constructors, to numeric
-- expressions that should represent them.
getEnumInfo :: [ P.TopDecl ] {- ^ Renamed decls -} -> EnumInfo
getEnumInfo tds = foldr addDefs blankEnumInfo enums
  where
  aliases = Map.fromList
              [ (nameOrigName t, identOrigName n) | P.DeclareType
                  P.TypeDecl { P.typeName = n
                             , P.typeDef = Just (P.IsType (P.NamedType t))
                             } <- tds
              ]

  enumAliases n = case Map.lookup n aliases of
                    Nothing -> [n]
                    Just s  -> s : enumAliases s


  enums = [ (identOrigName n,is) | P.DeclareType
                 P.TypeDecl { P.typeName = n
                            , P.typeDef = Just (P.IsEnum is) } <- tds ]

  -- The constructors of an enum are represented by 0, 1, .. etc
  addDefs (n,is) ei = EnumInfo
    { enumConMap = foldr addDef (enumConMap ei) (zipWith mkDef is [ 0 .. ])
    , enumMax = Map.insert n (C.Int (fromIntegral (length is) - 1))
                             (enumMax ei)
    , enumFromVal = Map.union
                    (Map.fromList (concatMap (mkRevDef n) (zip [0..] is)))
                    (enumFromVal ei)

    }


  mkDef i n = (identOrigName i, C.Int n)
  mkRevDef n (i,c) = [ ((j,i),identOrigName c) | j <- enumAliases n ]

  addDef (i,n) = Map.insert i n


-- | Translate a node to core form, given information about enumerations.
-- We don't return a mapping from original name to core names because
-- for the moment this mapping is very simple: just use 'origNameToCoreName'
evalNodeDecl ::
  EnumInfo              {- ^ Information about enums -} ->
  P.NodeDecl            {- ^ Simplified source Lustre -} ->
  LustreM C.Node
evalNodeDecl enumCs nd
  | null (P.nodeStaticInputs nd)
  , Just def <- P.nodeDef nd =
      runProcessNode enumCs $
      do let prof = P.nodeProfile nd
         ins  <- mapM evalInputBinder (P.nodeInputs prof)
         outs <- mapM evalBinder (P.nodeOutputs prof)
         locs <- mapM evalBinder
               $ orderLocals [ b | P.LocalVar b <- P.nodeLocals def ]

         eqnss <- mapM evalEqn (P.nodeEqns def)
         let withDef = Set.fromList
                        [ x | eqns <- eqnss, (x C.::: _) C.:= _ <- eqns ]

         asts <- getAssertNames
         props <- getPropertyNames
         pure C.Node { C.nName     = P.nodeName nd
                     , C.nInputs   = ins
                     , C.nOutputs  = outs
                     , C.nAbstract = [ l | l@(x C.::: _) <- locs
                                         , not (x `Set.member` withDef) ]
                     , C.nAssuming = asts
                     , C.nShows    = props
                     , C.nEqns     = C.orderedEqns (concat eqnss)
                     }

  | otherwise = panic "evalNodeDecl"
                [ "Unexpected node declaration"
                , "*** Node: " ++ showPP nd
                ]

  where
  depsOf b = case P.cClock (P.binderType b) of
               P.KnownClock (P.WhenClock _ _ c) -> [c]
               _ -> []

  orderLocals bs = concatMap toList
                 $ stronglyConnComp [ (b,P.binderDefines b,depsOf b) | b <- bs]


-- | Rewrite a type, replacing named enumeration types with @int@.
evalType :: P.Type -> C.Type
evalType ty =
  case ty of
    P.NamedType {}   -> C.TInt -- Only enum types should be left by now
    P.IntSubrange {} -> C.TInt -- Represented with a number
    P.IntType        -> C.TInt
    P.RealType       -> C.TReal
    P.BoolType       -> C.TBool
    P.TypeRange _ t  -> evalType t
    P.ArrayType {}   -> panic "evalType"
                         [ "Unexpected array type"
                         , "*** Type: " ++ showPP ty
                         ]

--------------------------------------------------------------------------------
type M = StateT St LustreM


runProcessNode :: EnumInfo -> M a -> LustreM a
runProcessNode enumCs m =
  do (a,_finS) <- runStateT st m
     pure a
  where
  st = St { stLocalTypes = Map.empty
          , stSrcLocalTypes = Map.empty
          , stGlobEnumCons = enumCs
          , stEqns = []
          , stAssertNames = []
          , stPropertyNames = []
          , stVarMap = Map.empty
          }

data St = St
  { stLocalTypes :: Map CoreName C.CType
    -- ^ Types of local translated variables.
    -- These may change as we generate new equations.

  , stSrcLocalTypes :: Map OrigName C.CType
    -- ^ Types of local variables from the source.
    -- These shouldn't change.

  , stGlobEnumCons  :: EnumInfo
    -- ^ Definitions for enum constants.
    -- Currently we assume that these would be int constants.

  , stEqns :: [C.Eqn]
    -- ^ Generated equations naming subcomponents.
    -- Most recently generated first.
    -- Since we process things in depth-first fashion, this should be
    -- reverse to get proper definition order.

  , stAssertNames :: [(Label,CoreName)]
    -- ^ The names of the equations corresponding to asserts.

  , stPropertyNames :: [(Label,CoreName)]
    -- ^ The names of the equatiosn corresponding to properties.


  , stVarMap :: Map OrigName CoreName
    {- ^ Remembers what names we used for values in the core.
    This is so that when we can parse traces into their original names. -}
  }

-- | Get the collected assert names.
getAssertNames :: M [(Label,CoreName)]
getAssertNames = stAssertNames <$> get

-- | Get the collected property names.
getPropertyNames :: M [(Label,CoreName)]
getPropertyNames = stPropertyNames <$> get

-- | Get the map of enumeration constants.
getEnumCons :: M EnumInfo
getEnumCons = stGlobEnumCons <$> get

-- | Get the collection of local types.
getLocalTypes :: M (Map CoreName C.CType)
getLocalTypes = stLocalTypes <$> get

-- | Record the type of a local.
addLocal :: CoreName -> C.CType -> M ()
addLocal i t = sets_ $ \s -> s { stLocalTypes = Map.insert i t (stLocalTypes s)}

addBinder :: C.Binder -> M ()
addBinder (i C.::: t) = addLocal i t

-- | Generate a fresh local name with the given stemp
newIdentFrom :: Text -> M CoreName
newIdentFrom stem =
  do x <- inBase newInt
     let i = Ident { identLabel    = toLabel stem
                   , identResolved = Nothing
                   }
         o = OrigName { rnUID     = x
                      , rnModule  = Nothing
                      , rnIdent   = i
                      , rnThing   = AVal
                      }
     pure (coreNameFromOrig o)


toLabel :: Text -> Label
toLabel t = Label { labText = t, labRange = noLoc }

-- XXX: Currently core epxressions have no locations.
noLoc :: SourceRange
noLoc = SourceRange { sourceFrom = noPos, sourceTo = noPos }
  where
  noPos = SourcePos { sourceIndex = -1, sourceLine = -1
                    , sourceColumn = -1, sourceFile = "" }


-- | Remember an equation.
addEqn :: C.Eqn -> M ()
addEqn eqn@(i C.::: t C.:= _) =
  do sets_ $ \s -> s { stEqns = eqn : stEqns s }
     addLocal i t

-- | Return the collected equations, and clear them.
clearEqns :: M [ C.Eqn ]
clearEqns = sets $ \s -> (stEqns s, s { stEqns = [] })

-- | Generate a fresh name for this expression, record the equation,
-- and return the name.
nameExpr :: C.Expr -> M C.Atom
nameExpr expr =
  do tys <- getLocalTypes
     let t = C.typeOf tys expr
     i <- newIdentFrom stem
     addEqn (i C.::: t C.:= expr)
     pure (C.Var i)

  where
  stem = case expr of
           C.Atom a -> case a of
                         C.Prim op _ _ -> Text.pack (show op)
                         _ -> panic "nameExpr" [ "Naming a simple atom?"
                                               , "*** Atom:" ++ showPP a ]
           C.Pre a       -> namedStem "pre" a
           _ C.:-> a     -> namedStem "init" a
           C.When _ a    -> namedStem "when" a
           C.Current a   -> namedStem "current" a
           C.Merge (a, _) _ -> namedStem "merge" (C.Var a)

  namedStem t a = case a of
                    C.Var i -> t <> "_" <> C.coreNameTextName i
                    _       -> "$" <> t

-- | Remember that the given identifier was used for an assert.
addAssertName :: Label -> CoreName -> M ()
addAssertName t i = sets_ $ \s -> s { stAssertNames = (t,i) : stAssertNames s }

-- | Remember that the given identifier was used for a property.
addPropertyName :: Label -> CoreName -> M ()
addPropertyName t i =
  sets_ $ \s -> s { stPropertyNames = (t,i) : stPropertyNames s }


--------------------------------------------------------------------------------

evalInputBinder :: P.InputBinder -> M C.Binder
evalInputBinder inp =
  case inp of
    P.InputBinder b -> do b1 <- evalBinder b
                          inputTypeAsmps b1 (P.cType (P.binderType b))
                          pure b1
    P.InputConst i t ->
      panic "evalInputBinder"
        [ "Unexpected constant parameter"
        , "*** Name: " ++ showPP i
        , "*** Type: " ++ showPP t ]


-- | Type assumptions for an input.
-- Currently these are assumptions arising from sub-range types and enums.
inputTypeAsmps :: C.Binder -> P.Type -> M ()
inputTypeAsmps (v C.::: ct) ty =

  case ty of
    P.NamedType i ->
      do x <- getEnumCons
         case Map.lookup (nameOrigName i) (enumMax x) of
           Just s -> inRange (C.Int 0) s
           Nothing -> panic "inputTypeAsmps"
                        [ "Undefined `enum` type", showPP i ]

    P.IntSubrange l u ->
      do le <- evalConstExpr l
         ue <- evalConstExpr u
         inRange le ue

    P.IntType        -> pure ()
    P.RealType       -> pure ()
    P.BoolType       -> pure ()
    P.TypeRange {}   -> panic "evalTypeAsmps" [ "Unexpected type range" ]
    P.ArrayType {}   -> panic "evalTypeAsmps"
                         [ "Unexpected array type"
                         , "*** Type: " ++ showPP ty
                         ]


  where
  lit l = C.Lit l ct

  inRange x y =
    do let va   = C.Var v
           lb   = C.Prim C.Leq [ lit x, va ] [boolTy]
           ub   = C.Prim C.Leq [ va, lit y ] [boolTy]
           prop = C.Prim C.And [ lb, ub ] [boolTy]
           boolTy = C.TBool `C.On` C.clockOfCType ct
           lab  = C.coreNameTextName v <> "_bounds"
       pn <- newIdentFrom lab
       let lhs = pn C.::: C.TBool `C.On` C.clockOfCType ct
           eqn = lhs C.:= C.Atom prop
       addEqn eqn
       addAssertName (toLabel lab) pn


-- | Add the type of a binder to the environment.
evalBinder :: P.Binder -> M C.Binder
evalBinder b =
  do c <- case P.cClock (P.binderType b) of
            P.BaseClock     -> pure C.BaseClock
            P.KnownClock c  -> C.WhenTrue <$> evalClockExpr c
            P.ClockVar i -> panic "evalBinder"
                              [ "Unexpected clock variable", showPP i ]
     let t = evalType (P.cType (P.binderType b)) `C.On` c
     let xi = evalIdent (P.binderDefines b)
     addLocal xi t
     let bn = xi C.::: t
     addBinder bn
     pure bn

-- | Translate an equation.
-- Invariant: 'stEqns' should be empty before and after this executes.
evalEqn :: P.Equation -> M [C.Eqn]
evalEqn eqn =
  case eqn of
    P.IsMain _ -> pure []
    P.IVC _    -> pure [] -- XXX: we should do something with these
    P.Realizable _ -> pure [] -- XXX: we should do something with these

    P.Property t e -> evalForm "--%PROPERTY" (addPropertyName t) e
    P.Assert t _ty e -> evalForm "assert" (addAssertName t) e
      -- at the top-level both kinds of assert are treated as assumptions.

    P.Define ls e ->
      case ls of
        [ P.LVar x ] ->
            do tys <- getLocalTypes
               let x' = evalIdent x
               let t = case Map.lookup x' tys of
                         Just ty -> ty
                         Nothing ->
                            panic "evalEqn" [ "Defining unknown variable:"
                                            , "*** Name: " ++ showPP x ]
               e1  <- evalExpr (Just x') e
               addEqn (x' C.::: t C.:= e1)
               clearEqns


        _ -> panic "evalExpr"
                [ "Unexpected LHS of equation"
                , "*** Equation: " ++ showPP eqn
                ]

  where
  evalForm :: String -> (CoreName -> M ()) -> P.Expression -> M [ C.Eqn ]
  evalForm x f e =
    do e1 <- evalExprAtom e
       case e1 of
         C.Var i ->
           do f i
              clearEqns
         C.Lit n _ ->
          case n of
            C.Bool True  -> pure []
            _ -> panic ("Constant in " ++ x) [ "*** Constant: " ++ show n ]
         C.Prim {} ->
           do ~(C.Var i) <- nameExpr (C.Atom e1)
              f i
              clearEqns



-- | Evaluate a source expression to an a core atom, naming subexpressions
-- as needed.
evalExprAtom :: P.Expression -> M C.Atom
evalExprAtom expr =
  do e1 <- evalExpr Nothing expr
     case e1 of
       C.Atom a -> pure a
       _        -> nameExpr e1


evalIdent :: Ident -> CoreName
evalIdent = coreNameFromOrig . identOrigName



-- | Evaluate a clock-expression to an atom.
evalClockExpr :: P.ClockExpr -> M C.Atom
evalClockExpr (P.WhenClock _ e1 i) =
  do a1  <- evalConstExpr e1
     env <- getLocalTypes
     let a2 = C.Var (evalIdent i)
         ty = C.typeOf env a2
         boolTy = C.TBool `C.On` C.clockOfCType ty
     pure $ case a1 of
              C.Bool True -> a2
              _           -> C.Prim C.Eq [ C.Lit a1 ty, a2 ] [boolTy]

evalIClock :: P.IClock -> M C.Clock
evalIClock clo =
  case clo of
    P.BaseClock -> pure C.BaseClock
    P.KnownClock c -> C.WhenTrue <$> evalClockExpr c
    P.ClockVar {} -> panic "evalIClockExpr" [ "Unexpectec clock variable." ]

evalCurrentWith :: Maybe CoreName -> C.Atom -> C.Atom -> M C.Expr
evalCurrentWith xt d e =
  do env <- getLocalTypes
     let ty = C.typeOf env e
         c@(C.WhenTrue ca) = C.clockOfCType ty
         Just cc = C.clockParent env c
     case xt of
       Just x -> desugar x ca ty
       Nothing ->
         do i  <- newIdentFrom "curW"
            let thisTy = C.typeOfCType ty `C.On` cc
            addLocal i thisTy
            e1 <- desugar i ca thisTy
            addEqn (i C.::: thisTy C.:= e1)
            pure (C.Atom (C.Var i))
  where
  desugar x c ty =
    do cur  <- nameExpr (C.Current e)
       pre  <- nameExpr (C.Pre (C.Var x))
       hold <- nameExpr ((d, ty) C.:->  pre)
       pure (C.Atom (C.Prim C.ITE [c,cur,hold] [ty]))

evalConstExpr :: P.Expression -> M C.Literal
evalConstExpr expr =
  case expr of
    P.ERange _ e -> evalConstExpr e
    P.Var i ->
      do cons <- getEnumCons
         case Map.lookup (nameOrigName i) (enumConMap cons) of
          Just e -> pure e
          Nothing -> bad "undefined constant symbol"
    P.Lit l -> pure l
    _ -> bad "constant expression"

  where
  bad msg = panic "evalConstExpr" [ "Unexpected " ++ msg
                             , "*** Expression: " ++ showPP expr
                             ]

evalCType :: P.CType -> M C.CType
evalCType t =
  do c <- evalIClock (P.cClock t)
     pure (evalType (P.cType t) `C.On` c)

-- | Evaluate a source expression to a core expression.
evalExpr :: Maybe CoreName -> P.Expression -> M C.Expr
evalExpr xt expr =
  case expr of
    P.ERange _ e -> evalExpr xt e

    P.Var i -> pure (C.Atom (C.Var (coreNameFromOrig (nameOrigName i))))

    P.Const e t ->
      do l <- evalConstExpr e
         ty <- evalCType t
         pure (C.Atom (C.Lit l ty))

    P.Lit {} -> bad "literal outside `Const`."

    e `P.When` ce ->
      do a1 <- evalExprAtom e
         a2 <- evalClockExpr ce
         pure (C.When a1 a2)


    P.Merge i alts ->
      do let iName = evalIdent i
         env <- getLocalTypes
         let ty = C.typeOf env (C.Var iName)

         bs <- forM alts $ \(P.MergeCase k e) -> do p  <- evalConstExpr k
                                                    e' <- evalExprAtom e
                                                    pure (p,e')

         pure (C.Merge (iName, ty) bs)

    P.Tuple {}  -> bad "tuple"
    P.Array {}  -> bad "array"
    P.Select {} -> bad "selection"
    P.Struct {} -> bad "struct"
    P.UpdateStruct {} -> bad "update-struct"
    P.WithThenElse {} -> bad "with-then-else"

    P.Call ni es _ Nothing ->
        panic "ToCore.evalExpr" $ [ "Got a Call with no type", "NodeInst:", show ni, "Arguments:"] ++ (show <$> es)

    P.Call ni es cl (Just tys) ->
      do _clv <- evalIClock cl
         tys' <- mapM evalCType tys
         {- NOTE: we don't really store the clock of the call anywhere,
         because for primitives (which is all that should be left)
         it can be computed from the clocks of the arguments. -}

         as <- mapM evalExprAtom es
         let prim x = pure (C.Atom (C.Prim x as tys'))
         case ni of
           P.NodeInst (P.CallPrim _ p) [] ->
             case p of

               P.Op1 op1 ->
                 case as of
                   [v] -> case op1 of
                            P.Not      -> prim C.Not
                            P.Neg      -> prim C.Neg
                            P.Pre      -> pure (C.Pre v)
                            P.Current  -> pure (C.Current v)
                            P.IntCast  -> prim C.IntCast
                            P.FloorCast-> prim C.FloorCast
                            P.RealCast -> prim C.RealCast
                   _ -> bad "unary operator"

               P.Op2 op2 ->
                 case as of
                   [v1,v2] -> case op2 of
                                P.Fby       -> do v3 <- nameExpr (C.Pre v2)
                                                  pure ((v1, tys' !! 0) C.:-> v3)
                                P.FbyArr    -> pure ((v1, tys' !! 0) C.:-> v2)
                                P.CurrentWith -> evalCurrentWith xt v1 v2
                                P.And       -> prim C.And
                                P.Or        -> prim C.Or
                                P.Xor       -> prim C.Xor
                                P.Implies   -> prim C.Implies
                                P.Eq        -> prim C.Eq
                                P.Neq       -> prim C.Neq
                                P.Lt        -> prim C.Lt
                                P.Leq       -> prim C.Leq
                                P.Gt        -> prim C.Gt
                                P.Geq       -> prim C.Geq
                                P.Mul       -> prim C.Mul
                                P.Mod       -> prim C.Mod
                                P.Div       -> prim C.Div
                                P.Add       -> prim C.Add
                                P.Sub       -> prim C.Sub
                                P.Power     -> prim C.Power
                                P.Replicate -> bad "`^`"
                                P.Concat    -> bad "`|`"
                   _ -> bad "binary operator"

               P.OpN op ->
                  case op of
                    P.AtMostOne -> prim C.AtMostOne
                    P.Nor       -> prim C.Nor


               P.ITE -> prim C.ITE

               _ -> bad "primitive call"

           _ -> bad "function call"

  where
  bad msg = panic "ToCore.evalExpr" [ "Unexpected " ++ msg
                                    , "*** Expression: " ++ showPP expr
                                    ]
