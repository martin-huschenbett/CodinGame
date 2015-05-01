import Control.Applicative
import Control.Monad
import Control.Monad.ST
import Data.Array
import Data.Array.ST
import Data.Char
import Data.Function
import Data.Graph
import Data.List
import qualified Data.Map.Strict as Map
import Data.Maybe
import Data.STRef
import Text.ParserCombinators.ReadP

data Point =
  Point
    { latitude  :: Double
    , longitude :: Double
    }
    deriving (Show)

type Ident = String

data Stop =
  Stop
    { ident    :: Ident
    , name     :: String
    , position :: Point
    }
    deriving (Show)

point :: ReadP Point
point =
  Point <$> radians <*> radians
  where
    radians = ((/ 180.0) . (* pi)) <$> readS_to_P reads <* comma

comma :: ReadP ()
comma = void $ char ','

quote :: ReadP ()
quote = void $ char '\"'

field :: ReadP String
field = get `manyTill` comma

eol :: ReadP ()
eol = void $ munch1 (`elem` "\r\n")

stop :: ReadP Stop
stop =
  Stop
    <$> field
    <*> ((quote *> get `manyTill` quote) <++ munch (',' /=)) <* comma <* field
    <*> point <* replicateM 3 field <* munch (`notElem` "\r\n")

list :: ReadP a -> ReadP [a]
list item = do
  n <- read <$> munch1 isDigit <* eol
  replicateM n (item <* eol)

edge :: ReadP (Ident,Ident)
edge =
  (,) <$> get `manyTill` munch1 isSpace <*> munch1 (not . isSpace)

request :: ReadP (Ident,Ident,[Stop],[(Ident,Ident)])
request =
    (,,,) <$> get `manyTill` eol <*> get `manyTill` eol <*> list stop <*> list edge

dist :: Point -> Point -> Double
dist (Point lat1 lon1) (Point lat2 lon2) =
  let x = (lon2 - lon1) * cos ((lat1 + lat2) / 2)
      y = lat2 - lat1
  in  6371.0 * sqrt (x*x + y*y)

main :: IO ()
main = do
  input <- getContents
  let ((src,tgt,stops,edges),""):_ = readP_to_S request (input ++ "\n")
  case solve src tgt stops edges of
    Nothing  -> putStrLn "IMPOSSIBLE"
    Just pth -> mapM_ (putStrLn . name) pth

infinity :: Double
infinity = 1/0

solve :: Ident -> Ident -> [Stop] -> [(Ident,Ident)] -> Maybe [Stop]
solve src tgt stops edges
  | src == tgt = Just [fromJust $ find ((src ==) . ident) stops]
solve src tgt stops edges =
  let n2sArray  = listArray (1,length stops) stops
      -- number to stop
      n2s n     = n2sArray ! n

      i2nMap    = Map.fromList [ (ident s,n) | (n,s) <- assocs n2sArray ]
      -- ident to number
      i2n i     = i `Map.lookup` i2nMap

      graph =
        accumArray (flip (:)) [] (bounds n2sArray) $ do
          (i1,i2) <- edges
          let on1 = i2n i1
              on2 = i2n i2
          guard $ isJust on1 && isJust on2
          return (fromJust on1,fromJust on2)
      n2p = position . n2s
      metric n1 n2 = dist (n2p n1) (n2p n2)
  in  map n2s <$> astar graph metric (fromJust $ i2n src) (fromJust $ i2n tgt)

type PQueue s v p = STRef s [(v,p)]

newPQ :: ST s (PQueue s v p)
newPQ = newSTRef []

insertPQ :: Ord p => PQueue s v p -> v -> p -> ST s ()
insertPQ queue val pty =
  modifySTRef' queue $ insertBy (compare `on` snd) (val,pty)

deletePQ :: Eq v => PQueue s v p -> v -> ST s ()
deletePQ queue val =
  modifySTRef' queue $ deleteBy ((==) `on` fst) (val,undefined)

extractPQ :: PQueue s v p -> ST s (Maybe v)
extractPQ queue = do
  ls <- readSTRef queue
  case ls of
    []    -> return Nothing
    hd:tl -> writeSTRef queue tl >> return (Just $ fst hd)

astar :: Graph -> (Vertex -> Vertex -> Double) -> Vertex -> Vertex -> Maybe [Vertex]
astar graph metric src tgt = runST $ do
  table <- newArray (bounds graph) (infinity,Nothing)
  queue <- newPQ
  insertTPQ table queue src 0 Nothing
  loop table queue
  where
    insertTPQ :: STArray s Vertex (Double,Maybe Vertex) -> PQueue s Vertex Double -> Vertex -> Double -> Maybe Vertex -> ST s ()
    insertTPQ table queue nod dst pre = do
      writeArray table nod (dst,pre)
      insertPQ queue nod (dst + metric nod tgt)
    path :: STArray s Vertex (Double,Maybe Vertex) -> [Vertex] -> ST s [Vertex]
    path table pth@(cur:_) = do
      (_,opre) <- readArray table cur
      case opre of
        Nothing  -> return pth
        Just pre -> path table (pre:pth)
    loop :: STArray s Vertex (Double,Maybe Vertex) -> PQueue s Vertex Double -> ST s (Maybe [Vertex])
    loop table queue = do
      omin <- extractPQ queue
      case omin of
        Nothing        -> return Nothing
        Just cur
          | cur == tgt -> liftM Just $ path table [tgt]
          | otherwise  -> do
              expand table queue cur
              loop table queue
    expand :: STArray s Vertex (Double,Maybe Vertex) -> PQueue s Vertex Double -> Vertex -> ST s ()
    expand table queue cur =
      forM_ (graph ! cur) $ \nxt -> do
        (curDst,_) <- readArray table cur
        let newNxtDst = curDst + metric cur nxt
        (oldNxtDst,_) <- readArray table nxt
        when (newNxtDst < oldNxtDst) $ do
          deletePQ queue nxt
          insertTPQ table queue nxt newNxtDst (Just cur)