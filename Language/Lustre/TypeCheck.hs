{-# Language OverloadedStrings #-}
module Language.Lustre.TypeCheck where

import qualified Data.Map as Map
import qualified Data.Set as Set
import Control.Monad(when,unless,zipWithM_)
import Text.PrettyPrint as PP
import Data.List(group,sort)

import Language.Lustre.AST
import Language.Lustre.Pretty
import Language.Lustre.Transform.OrderDecls
import Language.Lustre.Panic
import Language.Lustre.TypeCheck.Monad


quickCheckDecls :: [TopDecl] -> Either Doc ()
quickCheckDecls = runTC . go . orderTopDecls
  where
  go xs = case xs of
            [] -> pure ()
            x : more -> checkTopDecl x (go more)

checkTopDecl :: TopDecl -> M a -> M a
checkTopDecl td m =
  case td of
    DeclareType tyd -> checkTypeDecl tyd m
    DeclareConst cd -> checkConstDef cd m
    DeclareNode nd -> checkNodeDecl nd m
    DeclareNodeInst _nid -> notYetImplemented "node instances"


checkTypeDecl :: TypeDecl -> M a -> M a
checkTypeDecl td m =
  case typeDef td of
    Nothing -> done AbstractTy
    Just dec ->
      case dec of

        IsEnum is ->
          do mapM_ uniqueConst is
             let n      = typeName td
                 addE i = withConst i (NamedType (Unqual n))
             withNamedType n (EnumTy (Set.fromList is)) (foldr addE m is)

        IsStruct fs ->
          do mapM_ checkFieldType fs
             mapM_ checkDup $ group $ sort $ map fieldName fs
             done (StructTy (Map.fromList [ (fieldName f, fieldType f)
                                             | f <- fs  ]))

        IsType t ->
           do checkType t
              t1 <- tidyType t
              done (AliasTy t1)
  where
  done x = withNamedType (typeName td) x m

  checkDup xs =
    case xs of
      [] -> pure ()
      [_] -> pure ()
      x : _ ->
        reportError $ nestedError
          "Multiple fields with the same name." $
          [ "Struct:" <+> pp (typeName td)
          , "Field:" <+> pp x
          ] ++ [ "Location:" <+> pp (range f) | f <- xs ]


checkFieldType :: FieldType -> M ()
checkFieldType f =
  do let t = fieldType f
     checkType t
     case fieldDefault f of
       Nothing -> pure ()
       Just e  -> checkConstExpr e t

checkNodeDecl :: NodeDecl -> M a -> M a
checkNodeDecl nd k =
  do (a,b) <- check
     mapM_ (\(x,y) -> subType' False x y) =<< resetSubConstraints
     withNode a b k
  where
  check =
    inRange (range (nodeName nd)) $
    allowTemporal (nodeType nd == Node) $
    allowUnsafe   (nodeSafety nd == Unsafe) $
    do unless (null (nodeStaticInputs nd)) $
         notYetImplemented "static parameters"
       when (nodeExtern nd) $
         case nodeDef nd of
           Just _ -> reportError $ nestedError
                     "Extern node with a definition."
                     ["Node:" <+> pp (nodeName nd)]
           Nothing -> pure ()
       let prof = nodeProfile nd
       checkBinders (nodeInputs prof ++ nodeOutputs prof) $
         do case nodeDef nd of
              Nothing -> unless (nodeExtern nd) $ reportError $ nestedError
                           "Missing node definition"
                           ["Node:" <+> pp (nodeName nd)]
              Just b -> checkNodeBody b
            pure (nodeName nd, (nodeSafety nd, nodeType nd, nodeProfile nd))



checkNodeBody :: NodeBody -> M ()
checkNodeBody nb = addLocals (nodeLocals nb)
  where
  -- XXX: check for duplicate constant declarations.
  -- XXX: after checking that equations are OK individually,
  -- we should check that the LHS define proper values
  -- (e.g., no missing parts of structs/arrays etc)
  -- XXX: we also need to check that all outputs were defined.
  -- XXX: also check that that all locals have definitions
  -- XXX: also check that there aren't any extra equations.
  addLocals ls =
    case ls of
      []       -> mapM_ checkEquation (nodeEqns nb)
      l : more -> checkLocalDecl l (addLocals more)

checkLocalDecl :: LocalDecl -> M a -> M a
checkLocalDecl ld m =
  case ld of
    LocalVar b   -> checkBinder b m
    LocalConst c -> checkConstDef c m


checkConstDef :: ConstDef -> M a -> M a
checkConstDef c m =
  inRange (range (constName c)) $
  case constDef c of
    Nothing ->
      case constType c of
        Nothing -> reportError $ nestedError
                   "Constant declaration with no type or default."
                   [ "Name:" <+> pp (constName c) ]
        Just t -> do checkType t
                     done t

    Just e ->
      do t <- case constType c of
                Nothing -> newTVar
                Just t  -> do checkType t
                              pure t
         checkConstExpr e t
         done t
  where
  done t = withConst (constName c) t m

checkBinder :: Binder -> M a -> M a
checkBinder b m =
  do c <- case binderClock b of
            Nothing -> pure BaseClock
            Just e  -> do _c <- checkClockExpr e
                          pure (KnownClock e)
     checkType (binderType b)
     let ty = CType { cType = binderType b, cClock = c }
     withLocal (binderDefines b) ty m

checkBinders :: [Binder] -> M a -> M a
checkBinders bs m =
  case bs of
    [] -> m
    b : more -> checkBinder b (checkBinders more m)


checkType :: Type -> M ()
checkType ty =
  case ty of
    TypeRange r t -> inRange r (checkType t)
    IntType       -> pure ()
    BoolType      -> pure ()
    RealType      -> pure ()
    TVar x        -> panic "checkType" [ "Unexpected type variable:"
                                       , "*** Tvar: " ++ showPP x ]
    IntSubrange x y ->
      do checkConstExpr x IntType
         checkConstExpr y IntType
         leqConsts x y
    NamedType x ->
      do _ <- resolveNamed x
         pure ()
    ArrayType t n ->
      do checkConstExpr n IntType
         leqConsts (Lit (Int 0)) n
         checkType t


checkEquation :: Equation -> M ()
checkEquation eqn =
  enterRange $
  case eqn of
    Assert _ e ->
      checkExpr1 e CType { cType = BoolType, cClock = BaseClock }
         -- XXX: maybe make sure that this only uses inputs
         -- as nothing else is under the caller's control.

    Property _ e ->
      checkExpr1 e CType { cType = BoolType, cClock = BaseClock }

    IsMain _ -> pure ()

    IVC _ -> pure () -- XXX: what should we check here?

    Define ls e ->
      do lts <- mapM checkLHS ls
         checkExpr e lts

  where
  enterRange = case eqnRangeMaybe eqn of
                 Nothing -> id
                 Just r  -> inRange r


checkLHS :: LHS Expression -> M CType
checkLHS lhs =
  case lhs of
    LVar i -> lookupIdent i
    LSelect l s ->
      do t  <- checkLHS l
         t1 <- inferSelector s (cType t)
         pure t { cType = t1 }




-- | Infer the type of a constant expression.
checkConstExpr :: Expression -> Type -> M ()
checkConstExpr expr ty =
  case expr of
    ERange r e -> inRange r (checkConstExpr e ty)
    Var x      -> checkConstVar x ty
    Lit l      -> subType (inferLit l) ty
    _ `When` _ -> reportError "`when` is not a constant expression."
    Tuple {}   -> reportError "tuples cannot be used in constant expressions."
    Array es   ->
      do elT <- newTVar
         mapM_ (`checkConstExpr` elT) es
         let n = Lit $ Int $ fromIntegral $ length es
         subType (ArrayType elT n) ty

    Struct {} -> undefined

    Select e s ->
      do t <- newTVar
         checkConstExpr e t
         t1 <- inferSelector s t
         subType t1 ty

    WithThenElse e1 e2 e3 ->
      do checkConstExpr e1 BoolType
         checkConstExpr e2 ty
         checkConstExpr e3 ty

    Merge {}   -> reportError "`merge` is not a constant expression."
    CallPos {} -> reportError "constant expressions do not support calls."

-- | Check that the expression has the given type.
checkExpr1 :: Expression -> CType -> M ()
checkExpr1 e t = checkExpr e [t]

{- | Check if an expression has the given type.
Tuples and function calls may return multiple results,
which is why we provide multiple clocked types. -}
checkExpr :: Expression -> [CType] -> M ()
checkExpr expr tys =
  case expr of
    ERange r e -> inRange r (checkExpr e tys)

    Var x      -> inRange (range x) $
                  do ty <- one tys
                     checkVar x ty

    Lit l      -> do ty <- one tys
                     let lt = inferLit l
                     subType lt (cType ty)

    e `When` c ->
      do checkTemporalOk "when"
         ty <- one tys
         c1 <- checkClockExpr c -- `c1` is the clock of c
         sameClock (cClock ty) (KnownClock c)
         checkExpr1 e ty { cClock = c1 }

    Tuple es
      | have == need -> zipWithM_ checkExpr1 es tys
      | otherwise    -> reportError $ nestedError "Arity mismatch in tuple"
                          [ "Expected arity:" <+> text (show need)
                          , "Actual arity:" <+> text (show have) ]
      where have = length es
            need = length tys

    Array es ->
      do ty  <- one tys
         elT <- newTVar
         let n = Lit $ Int $ fromIntegral $ length es
         subType (ArrayType elT n) (cType ty)
         let elCT = ty { cType = elT }
         mapM_ (`checkExpr1` elCT) es


    Select e s ->
      do ty <- one tys
         recT <- newTVar
         checkExpr1 e ty { cType = recT }
         t1 <- inferSelector s recT
         subType t1 (cType ty)

    Struct {} -> undefined

    WithThenElse e1 e2 e3 ->
      do checkConstExpr e1 BoolType
         checkExpr e2 tys
         checkExpr e3 tys

    Merge i as ->
      do t <- lookupIdent i
         mapM_ (sameClock (cClock t) . cClock) tys
         let it      = cType t
             ts      = map cType tys
             check c = checkMergeCase i c it ts
         mapM_ check as

    CallPos (NodeInst call as) es
      | not (null as) -> notYetImplemented "Call with static arguments."

      -- Special case for @^@ because its second argument is a constant
      -- expression, not an ordinary one.
      | CallPrim r (Op2 Replicate) <- call ->
        inRange r $
        case es of
          [e1,e2] ->
            do ty <- one tys
               checkConstExpr e2 IntType
               elT <- newTVar
               checkExpr e1 [ty { cType = elT }]
               subType (ArrayType elT e2) (cType ty)
          _ -> reportError $ text (showPP call ++ " expexts 2 arguments.")

      | otherwise ->
        case call of
          CallUser f      -> checkCall f es tys
          CallPrim _ prim -> checkPrim prim es tys

-- | Assert that a given expression has only one type (i.e., is not a tuple)
one :: [CType] -> M CType
one xs =
  case xs of
    [x] -> pure x
    _   -> reportError $
           nestedError "Arity mismatch."
            [ "Expected arity:" <+> int (length xs)
            , "Actual arity:" <+> "1"
            ]



-- | Infer the type of a call to a user-defined node.
checkCall :: Name -> [Expression] -> [CType] -> M ()
checkCall f es0 tys =
  do (safe,ty,prof) <- lookupNodeProfile f
     case safe of
       Safe   -> pure ()
       Unsafe -> checkUnsafeOk (pp f)
     case ty of
       Node     -> checkTemporalOk ("node" <+> pp f)
       Function -> pure ()
     mp   <- checkInputs Map.empty (nodeInputs prof) es0
     checkOuts mp (nodeOutputs prof)
  where
  renBinderClock mp b =
    case binderClock b of
      Nothing -> pure BaseClock
      Just (WhenClock r p i) ->
        case Map.lookup i mp of
          Just j  -> pure (KnownClock (WhenClock r p j))
          Nothing -> reportError $ text ("Parameter for clock " ++ showPP i ++
                                                      "is not an identifier.")

  checkInputs mp is es =
    case (is,es) of
      ([],[]) -> pure mp
      (b:bs,a:as) -> do mp1 <- checkIn mp b a
                        checkInputs mp1 bs as
      _ -> reportError $ text ("Bad arity in call to " ++ showPP f)

  checkIn mp b e =
    do c <- renBinderClock mp b
       checkExpr1 e CType { cClock = c, cType = binderType b }
       pure $ case isIdent e of
                Just k  -> Map.insert (binderDefines b) k mp
                Nothing -> mp

  isIdent e =
    case e of
      ERange _ e1    -> isIdent e1
      Var (Unqual i) -> Just i
      _              -> Nothing

  checkOuts mp bs
    | have == need = zipWithM_ (checkOut mp) bs tys
    | otherwise = reportError $ nestedError
                  "Arity mistmatch in function call."
                  [ "Function:" <+> pp f
                  , "Returns:" <+> text (show have) <+> "restuls"
                  , "Expected:" <+> text (show need) <+> "restuls" ]
      where have = length bs
            need = length tys


  checkOut mp b ty =
    do let t = binderType b
       c <- renBinderClock mp b
       subCType CType { cClock = c, cType = t } ty


-- | Infer the type of a call to a primitive node.
checkPrim :: PrimNode -> [Expression] -> [CType] -> M ()
checkPrim prim es tys =
  case prim of

    Iter {} -> notYetImplemented "iterators."

    Op1 op1 ->
      case es of
        [e] -> do ty <- one tys
                  checkOp1 op1 e ty
        _   -> reportError $ text (showPP op1 ++ " expects 1 argument.")

    -- IMPORTANT: all binary operators work with the same clocks,
    -- so we do the clock checking here.  THIS MAY CHANGE if we add more ops!
    Op2 op2 ->
      case es of
        [e1,e2] -> do ty <- one tys
                      checkOp2 op2 e1 e2 ty
        _ -> reportError $ text (showPP op2 ++ " expects 2 arguments.")

    ITE ->
      case es of
        [e1,e2,e3] ->
          do c <- case tys of
                    []     -> newClockVar -- XXX: or report error?
                    t : ts -> do let c = cClock t
                                 mapM_ (sameClock c . cClock) ts
                                 pure c
             checkExpr1 e1 CType { cClock = c, cType = BoolType }
             checkExpr e2 tys
             checkExpr e3 tys

        _ -> reportError "`if-then-else` expects 3 arguments."


    -- IMPORTANT: For the moment these all work with bools, so we
    -- just do them in one go.  THIS MAY CHANGE if we add
    -- other operators!
    OpN _ ->
      do ty <- one tys
         let bool = ty { cType = BoolType }
         mapM_ (`checkExpr1` bool) es
         subType BoolType (cType ty)



-- | Infer the type for a branch of a merge.
checkMergeCase :: Ident -> MergeCase -> Type -> [Type] -> M ()
checkMergeCase i (MergeCase p e) it ts =
  do checkConstExpr p it
     checkExpr e (map toCType ts)
  where
  clk       = KnownClock (WhenClock (range p) p i)
  toCType t = CType { cClock = clk, cType = t }

-- | Types of unary opertaors.
checkOp1 :: Op1 -> Expression -> CType -> M ()
checkOp1 op e ty =
  case op of
    Pre -> do checkTemporalOk "pre"
              checkExpr1 e ty

    Current ->
      do checkTemporalOk "current"
         c <- newClockVar
         checkExpr1 e ty { cClock = c }
         -- By now we should have figured out the missing clock,
         -- so check straight away
         sameClock (cClock ty) =<< clockParent c

    Not ->
      do checkExpr1 e ty { cType = BoolType }
         subType BoolType (cType ty)

    Neg -> do t <- newTVar
              checkExpr1 e ty { cType = t }
              classArith1 "-" t (cType ty)

    IntCast ->
      do checkExpr1 e ty { cType = IntType }
         subType RealType (cType ty)

    RealCast ->
      do checkExpr1 e ty { cType = RealType }
         subType IntType (cType ty)


-- | Types of binary operators.
checkOp2 :: Op2 -> Expression -> Expression -> CType -> M ()
checkOp2 op2 e1 e2 res =
  case op2 of
    FbyArr   -> do checkTemporalOk "->"
                   checkExpr1 e1 res
                   checkExpr1 e2 res

    Fby      -> do checkTemporalOk "fby"
                   checkExpr1 e1 res
                   checkExpr1 e2 res

    And      -> bool2
    Or       -> bool2
    Xor      -> bool2
    Implies  -> bool2

    Eq       -> rel classEq
    Neq      -> rel classEq

    Lt       -> rel (classOrd "<")
    Leq      -> rel (classOrd "<=")
    Gt       -> rel (classOrd ">")
    Geq      -> rel (classOrd ">=")

    Add      -> arith "+"
    Sub      -> arith "-"
    Mul      -> arith "*"
    Div      -> arith "/"
    Mod      -> arith "mod"

    Power    -> notYetImplemented "Exponentiation"

    Replicate -> panic "checkOp2" [ "`replicate` should have been checked."]

    Concat -> notYetImplemented "Concat"
      {-
      do t1 <- tidyType tx
         t2 <- tidyType ty
         case (t1,t2) of
           (ArrayType elT1 n, ArrayType elT2 m) ->
             do elT <- typeLUB elT1 elT2
                l   <- addConsts n m
                pure (ArrayType elT l)
           _ -> reportError "`|` expects two arrays."
      -}

  where
  bool2 = do checkExpr1 e1 res { cType = BoolType }
             checkExpr1 e1 res { cType = BoolType }
             retBool

  infer2 = do t1 <- newTVar
              checkExpr1 e1 res { cType = t1 }
              t2 <- newTVar
              checkExpr1 e2 res { cType = t2 }
              pure (t1,t2)

  rel f = do (t1,t2) <- infer2
             () <- f t1 t2
             retBool

  retBool = subType BoolType (cType res)

  arith x = do (t1,t2) <- infer2
               classArith2 x t1 t2 (cType res)



-- | Check the type of a variable.
checkVar :: Name -> CType -> M ()
checkVar x ty =
  case x of
    Unqual i -> do mb <- lookupIdentMaybe i
                   case mb of
                     Just c  -> subCType c ty
                     Nothing -> checkConstVar x (cType ty)
    Qual {}  -> checkConstVar x (cType ty)

-- | Check the type of a named constnat.
checkConstVar :: Name -> Type -> M ()
checkConstVar x ty = inRange (range x) $
                     do t1 <- lookupConst x
                        t1 `subType` ty

-- | Infer the type of a literal.
inferLit :: Literal -> Type
inferLit lit =
     case lit of
       Int _   -> IntSubrange (Lit lit) (Lit lit)
       Real _  -> RealType
       Bool _  -> BoolType

-- | Check a clock expression, and return its clock.
checkClockExpr :: ClockExpr -> M IClock
checkClockExpr (WhenClock r v i) =
  inRange r $
    do ct <- lookupIdent i
       checkConstExpr v (cType ct)
       pure (cClock ct)

--------------------------------------------------------------------------------

inferSelector :: Selector Expression -> Type -> M Type
inferSelector sel ty0 =
  do ty <- tidyType ty0
     case sel of
       SelectField f ->
         case ty of
           NamedType a ->
             do fs <- lookupStruct a
                case Map.lookup f fs of
                  Just t  -> pure t
                  Nothing ->
                    reportError $
                    nestedError
                    "Struct has no such field:"
                      [ "Struct:" <+> pp a
                      , "Field:" <+> pp f ]

           TVar {} -> notYetImplemented "Record selection from unknown type"

           _ -> reportError $
                nestedError
                  "Argument to struct selector is not a struct:"
                  [ "Selector:" <+> pp sel
                  , "Input:" <+> pp ty0
                  ]

       SelectElement n ->
         case ty of
           ArrayType t _sz ->
             do checkConstExpr n IntType
                -- XXX: check that 0 <= && n < sz ?
                pure t

           TVar {} -> notYetImplemented "Array selection from unknown type"

           _ -> reportError $
                nestedError
               "Argument to array selector is not an array:"
                [ "Selector:" <+> pp sel
                , "Input:" <+> pp ty0
                ]

       SelectSlice _s ->
        case ty of
          ArrayType _t _sz -> notYetImplemented "array slices"
          TVar {} -> notYetImplemented "array slice on unknown type."
          _ -> reportError $
               nestedError
               "Arrgument to array slice is not an array:"
               [ "Selector:" <+> pp sel
               , "Input:" <+> pp ty0
               ]





--------------------------------------------------------------------------------
-- Comparsions of types

subCType :: CType -> CType -> M ()
subCType x y =
  do subType   (cType x) (cType y)
     sameClock (cClock x) (cClock y)

sameType :: Type -> Type -> M ()
sameType x y =
  do s <- tidyType x
     t <- tidyType y
     case (s,t) of
      (TVar v, _) -> bindTVar v t
      (_,TVar v)  -> bindTVar v s
      (NamedType a,   NamedType b)   | a == b -> pure ()
      (ArrayType a m, ArrayType b n) -> sameConsts m n >> sameType a b

      (IntType,IntType)   -> pure ()
      (RealType,RealType) -> pure ()
      (BoolType,BoolType) -> pure ()
      (IntSubrange a b, IntSubrange c d) ->
        sameConsts a c >> sameConsts b d
      _ -> reportError $ nestedError
            "Type mismatch:"
            [ "Values of type:" <+> pp s
            , "Do not fit into type:" <+> pp t
            ]

subType :: Type -> Type -> M ()
subType = subType' True

-- Subtype is like "subset"
subType' :: Bool -> Type -> Type -> M ()
subType' delay x y =
  do s <- tidyType x
     case s of
       IntSubrange a b ->
         do t <- tidyType y
            case t of
              IntType         -> pure ()
              IntSubrange c d -> leqConsts c a >> leqConsts b d
              TVar {}         -> later s t
              _               -> sameType s t

       ArrayType elT n ->
         do elT' <- newTVar
            subType' True elT elT'
            sameType (ArrayType elT' n) y

       TVar {} ->
         do t <- tidyType y
            case t of
              TypeRange {} -> panic "subType"
                                      ["`tidyType` returned `TypeRange`"]
              RealType     -> sameType s t
              BoolType     -> sameType s t
              NamedType {} -> sameType s t
              ArrayType elT sz ->
                do elT' <- newTVar
                   subType' True elT' elT
                   sameType s (ArrayType elT' sz)
              IntType        -> later s t
              IntSubrange {} -> later s t
              TVar {} -> notYetImplemented "subType: 2 vars"

       _ -> sameType s y
  where
  later a b = if delay
                then subConstraint a b
                else hackDefault a b

  hackDefault a b =
    do a' <- tidyType a
       case a' of
         TVar v -> bindTVar v b
         _ -> do b' <- tidyType b
                 case b' of
                   TVar v -> bindTVar v a'
                   _ -> typeError a' b'

  typeError a b= reportError $ nestedError
                     "Failed to discharge subtyping constraint"
                      [ "Values of type:" <+> pp a
                      , "Should fit in type:" <+> pp b]





--------------------------------------------------------------------------------
-- Clocks


-- | Are these the same clock.  If so, return the one that is NOT a 'ConstExpr'
-- (if any).
sameClock :: IClock -> IClock -> M ()
sameClock x0 y0 =
  do x <- zonkClock x0
     y <- zonkClock y0
     case (x,y) of
       (ClockVar a, _) -> bindClockVar a y
       (_, ClockVar a) -> bindClockVar a x
       (BaseClock,BaseClock) -> pure ()
       (KnownClock a, KnownClock b) -> sameKnownClock a b
       _ -> reportError $ nestedError
             "The given clocks are different:"
             [ "Clock 1:" <+> pp x
             , "Clock 2:" <+> pp y
             ]

-- | Is this the same known clock.
sameKnownClock :: ClockExpr -> ClockExpr -> M ()
sameKnownClock c1@(WhenClock _ e1_init i1) c2@(WhenClock _ e2_init i2) =
  do unless (i1 == i2) $
        reportError $
        nestedError
          "The given clocks are different:"
          [ "Clock 1:" <+> pp c1
          , "Clock 2:" <+> pp c2
          ]
     sameConsts e1_init e2_init

-- | Get the clock of a clock, or fail if we are the base clock.
clockParent :: IClock -> M IClock
clockParent ct0 =
  do ct <- zonkClock ct0
     case ct of
       BaseClock -> reportError "The base clock has no parent."
       KnownClock (WhenClock _ _ i) -> cClock <$> lookupIdent i
       ClockVar _ -> reportError "Failed to infer the expressions's clock"



--------------------------------------------------------------------------------
-- Expressions

intConst :: Expression -> M Integer
intConst x =
  case x of
    ERange _ y  -> intConst y
    Lit (Int a) -> pure a
    _ -> reportError $ nestedError
           "Constant expression is not a concrete integer."
           [ "Expression:" <+> pp x ]

binConst :: (Integer -> Integer -> Integer) ->
            Expression -> Expression -> M Expression
binConst f e1 e2 =
  do x <- intConst e1
     y <- intConst e2
     pure $ Lit $ Int $ f x y

cmpConsts :: Doc ->
             (Integer -> Integer -> Bool) ->
             Expression -> Expression -> M ()
cmpConsts op p e1 e2 =
  do x <- intConst e1
     y <- intConst e2
     unless (p x y) $ reportError $ pp x <+> "is not" <+> op <+> pp y

addConsts :: Expression -> Expression -> M Expression
addConsts = binConst (+)

minConsts :: Expression -> Expression -> M Expression
minConsts = binConst min

maxConsts :: Expression -> Expression -> M Expression
maxConsts = binConst max

sameConsts :: Expression -> Expression -> M ()
sameConsts e1 e2 =
  case (e1,e2) of
    (ERange _ x,_)  -> sameConsts x e2
    (_, ERange _ x) -> sameConsts e1 x
    (Var x, Var y) | x == y -> pure ()
    (Lit x, Lit y) | x == y -> pure ()
    _ -> reportError $ nestedError
           "Constants do not match"
           [ "Constant 1:" <+> pp e1
           , "Constant 2:" <+> pp e2
           ]

leqConsts :: Expression -> Expression -> M ()
leqConsts = cmpConsts "less-than, or equal to" (<=)



--------------------------------------------------------------------------------

-- | Are these types comparable of equality
classEq :: Type -> Type -> M ()
classEq s0 t0 =
  do s <- tidyType s0
     case s of
       IntSubrange {} -> subType t0 IntType
       ArrayType elT sz ->
         do elT' <- newTVar
            subType t0 (ArrayType elT' sz)
            classEq elT elT'

       TVar {} ->
         do t <- tidyType t0
            case t of
              IntSubrange {} -> subType s IntType
              _              -> subType s t
       _ -> subType t0 s



-- | Are these types comparable for ordering
classOrd :: Doc -> Type -> Type -> M ()
classOrd op s' t' =
  do s <- tidyType s'
     case s of
       IntType        -> subType t' IntType
       IntSubrange {} -> subType t' IntType
       RealType       -> subType t' RealType
       TVar {} ->
         do t <- tidyType t'
            case t of
              IntType        -> subType s IntType
              IntSubrange {} -> subType s IntType
              RealType       -> subType s RealType
              TVar {} -> notYetImplemented "Very polymorhic Eq comparison"
              _ -> typeError
       _ -> typeError
  where
  typeError = reportError $ nestedError
                "Invalid use of comparison operator:"
                [ "Operator:" <+> op
                , "Input 1:" <+> pp s'
                , "Input 2:" <+> pp t'
                ]



classArith1 :: Doc -> Type -> Type -> M ()
classArith1 op s0 t0 =
  do t <- tidyType t0
     case t of
       IntType  -> subType s0 IntType
       RealType -> subType s0 RealType
       TVar {} ->
         do s <- tidyType s0
            case s of
              IntType         -> subType IntType t0
              IntSubrange {}  -> subType IntType t0
              RealType        -> subType RealType t0
              TVar {} -> notYetImplemented $
                          "Very polymorhic unary arithmetic:" <+> op
              _ -> typeError
       _ -> typeError
  where
  typeError = reportError $ nestedError
              "Invalid use of unary arithmetic operator."
              [ "Operator:" <+> op
              , "Input:"    <+> pp s0
              , "Result:"   <+> pp t0 ]


-- | Can we do binary arithemtic on this type, and if so what's the
-- type of the answer.
classArith2 :: Doc -> Type -> Type -> Type -> M ()
classArith2 op s0 t0 r0 =
  do r <- tidyType r0
     case r of
       IntType  -> subType s0 IntType  >> subType t0 IntType
       RealType -> subType s0 RealType >> subType t0 RealType
       TVar {}  ->
         do s <- tidyType s0
            case s of
              IntType  -> subType t0 IntType  >> subType IntType r
              IntSubrange {} -> subType t0 IntType >> subType IntType r
              RealType -> subType t0 RealType >> subType RealType r
              TVar {} ->
                do t <- tidyType t0
                   case t of
                     IntType  -> subType s0 IntType  >> subType IntType r
                     IntSubrange {} -> subType t0 IntType >> subType IntType r
                     RealType -> subType s0 RealType >> subType RealType r
                     TVar {} -> notYetImplemented
                                   $ "Very polymorphic bin op:" <+> op
                     _ -> typeError
              _ -> typeError
       _ -> typeError

  where
  typeError =
    reportError $ nestedError
      "Invalid use of binary arithmetic operator:"
      [ "Operator:" <+> op
      , "Input 1:"  <+> pp s0
      , "Input 2:"  <+> pp t0
      , "Result:"   <+> pp r0
      ]






