module IRTS.Lang where

import Core.TT
import Control.Monad.State hiding(lift)
import Data.List
import Debug.Trace

data LVar = Loc Int | Glob Name
  deriving (Show, Eq)

data LExp = LV LVar
          | LApp Bool LExp [LExp] -- True = tail call
          | LLazyApp Name [LExp] -- True = tail call
          | LLazyExp LExp
          | LForce LExp -- make sure Exp is evaluted
          | LLet Name LExp LExp -- name just for pretty printing
          | LLam [Name] LExp -- lambda, lifted out before compiling
          | LProj LExp Int -- projection
          | LCon Int Name [LExp]
          | LCase LExp [LAlt]
          | LConst Const
          | LForeign FLang FType String [(FType, LExp)]
          | LOp PrimFn [LExp]
          | LNothing
          | LError String
  deriving Eq

-- Primitive operators. Backends are not *required* to implement all
-- of these, but should report an error if they are unable

data PrimFn = LPlus | LMinus | LTimes | LDiv | LMod 
            | LAnd | LOr | LXOr | LCompl | LSHL| LSHR
            | LEq | LLt | LLe | LGt | LGe
            | LFPlus | LFMinus | LFTimes | LFDiv 
            | LFEq | LFLt | LFLe | LFGt | LFGe
            | LBPlus | LBMinus | LBDec | LBTimes | LBDiv | LBMod 
            | LBEq | LBLt | LBLe | LBGt | LBGe
            | LStrConcat | LStrLt | LStrEq | LStrLen
            | LIntFloat | LFloatInt | LIntStr | LStrInt | LFloatStr | LStrFloat
            | LIntBig | LBigInt | LStrBig | LBigStr | LChInt | LIntCh
            | LPrintNum | LPrintStr | LReadStr

            | LB8Lt | LB8Lte | LB8Eq | LB8Gt | LB8Gte
            | LB8Plus | LB8Minus | LB8Times | LB8UDiv | LB8SDiv | LB8URem | LB8SRem
            | LB8Shl | LB8LShr | LB8AShr | LB8And | LB8Or | LB8Xor | LB8Compl
            | LB8Z16 | LB8Z32 | LB8Z64 | LB8S16 | LB8S32 | LB8S64 -- Zero/Sign extension
            | LB16Lt | LB16Lte | LB16Eq | LB16Gt | LB16Gte
            | LB16Plus | LB16Minus | LB16Times | LB16UDiv | LB16SDiv | LB16URem | LB16SRem
            | LB16Shl | LB16LShr | LB16AShr | LB16And | LB16Or | LB16Xor | LB16Compl
            | LB16Z32 | LB16Z64 | LB16S32 | LB16S64 | LB16T8 -- and Truncation
            | LB32Lt | LB32Lte | LB32Eq | LB32Gt | LB32Gte
            | LB32Plus | LB32Minus | LB32Times | LB32UDiv | LB32SDiv | LB32URem | LB32SRem
            | LB32Shl | LB32LShr | LB32AShr | LB32And | LB32Or | LB32Xor | LB32Compl
            | LB32Z64 | LB32S64 | LB32T8 | LB32T16
            | LB64Lt | LB64Lte | LB64Eq | LB64Gt | LB64Gte
            | LB64Plus | LB64Minus | LB64Times | LB64UDiv | LB64SDiv | LB64URem | LB64SRem
            | LB64Shl | LB64LShr | LB64AShr | LB64And | LB64Or | LB64Xor | LB64Compl
            | LB64T8 | LB64T16 | LB64T32
            | LIntB8 | LIntB16 | LIntB32 | LIntB64 | LB32Int

            | LFExp | LFLog | LFSin | LFCos | LFTan | LFASin | LFACos | LFATan
            | LFSqrt | LFFloor | LFCeil

            | LStrHead | LStrTail | LStrCons | LStrIndex | LStrRev
            | LStdIn | LStdOut | LStdErr

            | LFork  
            | LPar -- evaluate argument anywhere, possibly on another
                   -- core or another machine. 'id' is a valid implementation
            | LVMPtr 
            | LNoOp
  deriving (Show, Eq)

-- Supported target languages for foreign calls

data FLang = LANG_C
  deriving (Show, Eq)

data FType = FInt | FChar | FString | FUnit | FPtr | FDouble | FAny
  deriving (Show, Eq)

data LAlt = LConCase Int Name [Name] LExp
          | LConstCase Const LExp
          | LDefaultCase LExp
  deriving (Show, Eq)

data LDecl = LFun [LOpt] Name [Name] LExp -- options, name, arg names, def
           | LConstructor Name Int Int -- constructor name, tag, arity
  deriving (Show, Eq)

type LDefs = Ctxt LDecl

data LOpt = Inline | NoInline
  deriving (Show, Eq)

addTags :: Int -> [(Name, LDecl)] -> (Int, [(Name, LDecl)])
addTags i ds = tag i ds []
  where tag i ((n, LConstructor n' (-1) a) : as) acc
            = tag (i + 1) as ((n, LConstructor n' i a) : acc) 
        tag i ((n, LConstructor n' t a) : as) acc
            = tag i as ((n, LConstructor n' t a) : acc) 
        tag i (x : as) acc = tag i as (x : acc)
        tag i [] acc  = (i, reverse acc)

data LiftState = LS Name Int [(Name, LDecl)]

lname (NS n x) i = NS (lname n i) x
lname (UN n) i = MN i n
lname x i = MN i (show x)

liftAll :: [(Name, LDecl)] -> [(Name, LDecl)]
liftAll xs = concatMap (\ (x, d) -> lambdaLift x d) xs

lambdaLift :: Name -> LDecl -> [(Name, LDecl)]
lambdaLift n (LFun _ _ args e) 
      = let (e', (LS _ _ decls)) = runState (lift args e) (LS n 0 []) in
            (n, LFun [] n args e') : decls
lambdaLift n x = [(n, x)]

getNextName :: State LiftState Name
getNextName = do LS n i ds <- get
                 put (LS n (i + 1) ds)
                 return (lname n i)

addFn :: Name -> LDecl -> State LiftState ()
addFn fn d = do LS n i ds <- get
                put (LS n i ((fn, d) : ds))

lift :: [Name] -> LExp -> State LiftState LExp
lift env (LV v) = return (LV v) -- Lifting happens before these can exist...
lift env (LApp tc (LV (Glob n)) args) = do args' <- mapM (lift env) args
                                           return (LApp tc (LV (Glob n)) args')
lift env (LApp tc f args) = do f' <- lift env f
                               fn <- getNextName
                               addFn fn (LFun [Inline] fn env f')
                               args' <- mapM (lift env) args
                               return (LApp tc (LV (Glob fn)) (map (LV . Glob) env ++ args'))
lift env (LLazyApp n args) = do args' <- mapM (lift env) args
                                return (LLazyApp n args')
lift env (LLazyExp (LConst c)) = return (LConst c)
-- lift env (LLazyExp (LApp tc (LV (Glob f)) args)) 
--                       = lift env (LLazyApp f args)
lift env (LLazyExp e) = do e' <- lift env e
                           let usedArgs = nub $ usedIn env e'
                           fn <- getNextName
                           addFn fn (LFun [NoInline] fn usedArgs e')
                           return (LLazyApp fn (map (LV . Glob) usedArgs))
lift env (LForce e) = do e' <- lift env e
                         return (LForce e') 
lift env (LLet n v e) = do v' <- lift env v
                           e' <- lift (env ++ [n]) e
                           return (LLet n v' e')
lift env (LLam args e) = do e' <- lift (env ++ args) e
                            let usedArgs = nub $ usedIn env e'
                            fn <- getNextName
                            addFn fn (LFun [Inline] fn (usedArgs ++ args) e')
                            return (LApp False (LV (Glob fn)) (map (LV . Glob) usedArgs))
lift env (LProj t i) = do t' <- lift env t
                          return (LProj t' i)
lift env (LCon i n args) = do args' <- mapM (lift env) args
                              return (LCon i n args')
lift env (LCase e alts) = do alts' <- mapM liftA alts
                             e' <- lift env e
                             return (LCase e' alts')
  where
    liftA (LConCase i n args e) = do e' <- lift (env ++ args) e
                                     return (LConCase i n args e')
    liftA (LConstCase c e) = do e' <- lift env e
                                return (LConstCase c e')
    liftA (LDefaultCase e) = do e' <- lift env e
                                return (LDefaultCase e')
lift env (LConst c) = return (LConst c)
lift env (LForeign l t s args) = do args' <- mapM (liftF env) args
                                    return (LForeign l t s args')
  where
    liftF env (t, e) = do e' <- lift env e
                          return (t, e')
lift env (LOp f args) = do args' <- mapM (lift env) args
                           return (LOp f args')
lift env (LError str) = return $ LError str
lift env LNothing = return $ LNothing

-- Return variables in list which are used in the expression

usedArg env n | n `elem` env = [n]
              | otherwise = []

usedIn :: [Name] -> LExp -> [Name]
usedIn env (LV (Glob n)) = usedArg env n 
usedIn env (LApp _ e args) = usedIn env e ++ concatMap (usedIn env) args 
usedIn env (LLazyApp n args) = concatMap (usedIn env) args ++ usedArg env n
usedIn env (LLazyExp e) = usedIn env e
usedIn env (LForce e) = usedIn env e
usedIn env (LLet n v e) = usedIn env v ++ usedIn (env \\ [n]) e
usedIn env (LLam ns e) = usedIn (env \\ ns) e
usedIn env (LCon i n args) = concatMap (usedIn env) args
usedIn env (LProj t i) = usedIn env t
usedIn env (LCase e alts) = usedIn env e ++ concatMap (usedInA env) alts
  where usedInA env (LConCase i n ns e) = usedIn env e
        usedInA env (LConstCase c e) = usedIn env e
        usedInA env (LDefaultCase e) = usedIn env e
usedIn env (LForeign _ _ _ args) = concatMap (usedIn env) (map snd args)
usedIn env (LOp f args) = concatMap (usedIn env) args
usedIn env _ = []

instance Show LExp where
   show e = show' [] e where
     show' env (LV (Loc i)) = env!!i
     show' env (LV (Glob n)) = show n
     show' env (LLazyApp e args) = show e ++ "|(" ++
                                     showSep ", " (map (show' env) args) ++")"
     show' env (LApp _ e args) = show' env e ++ "(" ++
                                   showSep ", " (map (show' env) args) ++")"
     show' env (LLazyExp e) = "%lazy(" ++ show' env e ++ ")" 
     show' env (LForce e) = "%force(" ++ show' env e ++ ")"
     show' env (LLet n v e) = "let " ++ show n ++ " = " ++ show' env v ++ " in " ++
                               show' (env ++ [show n]) e
     show' env (LLam args e) = "\\ " ++ showSep "," (map show args) ++ " => " ++
                                 show' (env ++ (map show args)) e
     show' env (LProj t i) = show t ++ "!" ++ show i
     show' env (LCon i n args) = show n ++ ")" ++ showSep ", " (map (show' env) args) ++ ")"
     show' env (LCase e alts) = "case " ++ show' env e ++ " of {\n\t" ++
                                    showSep "\n\t| " (map (showAlt env) alts)
     show' env (LConst c) = show c
     show' env (LForeign lang ty n args)
           = "foreign " ++ n ++ "(" ++ showSep ", " (map (show' env) (map snd args)) ++ ")"
     show' env (LOp f args) = show f ++ "(" ++ showSep ", " (map (show' env) args) ++ ")"
     show' env (LError str) = "error " ++ show str
     show' env LNothing = "____"

     showAlt env (LConCase _ n args e) 
          = show n ++ "(" ++ showSep ", " (map show args) ++ ") => "
             ++ show' env e
     showAlt env (LConstCase c e) = show c ++ " => " ++ show' env e
     showAlt env (LDefaultCase e) = "_ => " ++ show' env e




